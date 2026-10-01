import { type Abi, decodeErrorResult, decodeEventLog } from "viem";
import type { MirrorLog } from "~~/services/mirror";
import { GuardState, OrderType, type Side, orderKind, trailingTrigger } from "~~/utils/orders/orders";
import { dateFromConsensus, formatAmount, formatBps, formatHbar, formatPrice } from "~~/utils/orders/units";

export type TokenMeta = { symbol: string; decimals: number };

/** What the trail needs to know about the order itself: its kind, and the trail for a trailing stop. */
export type TrailOrder = { side: Side; orderType: OrderType; typeParam: bigint; quote: string };

export type TrailEntry = {
  key: string;
  tone: "neutral" | "ok" | "warn" | "error" | "primary";
  title: string;
  detail: string;
  at: Date;
  /** Consensus timestamp, which HashScan resolves directly. */
  timestamp: string;
  txHash?: string;
  /** Scheduled checks collapsed into this row. */
  checks?: number;
};

const GUARD_REASON: Record<number, string> = {
  [GuardState.DeviationTooHigh]: "the pool was too far from Chainlink",
  [GuardState.OracleStale]: "a Chainlink feed was stale",
  [GuardState.OracleInvalid]: "a Chainlink feed returned no price",
  [GuardState.TwapUnavailable]: "the pool had too little price history",
};

const ORDER_EVENTS = new Set([
  "OrderPlaced",
  "OrderChecked",
  "OrderStateUpdated",
  "OrderEvalSkipped",
  "FillHeld",
  "FillFailed",
  "BudgetExhausted",
  "BudgetToppedUp",
  "SweepBroughtForward",
  "OrderFilled",
  "OrderCancelled",
  "OrderExpired",
  "NftSettlementFailed",
]);

type Decoded = { eventName: string; args: Record<string, unknown>; log: MirrorLog };

/** Decode vault logs, keeping only events about orders (topic1 also matches sweep events for the same market id). */
export const decodeOrderLogs = (abi: Abi, logs: MirrorLog[]): Decoded[] =>
  logs.flatMap(log => {
    try {
      const decoded = decodeEventLog({ abi, data: log.data, topics: log.topics as [`0x${string}`] });
      if (!decoded.eventName || !ORDER_EVENTS.has(decoded.eventName)) return [];
      return [{ eventName: decoded.eventName, args: decoded.args as unknown as Record<string, unknown>, log }];
    } catch {
      return [];
    }
  });

const readableRevert = (abi: Abi, reason: `0x${string}`) => {
  if (reason === "0x") return "the swap ran out of gas or reverted without a reason";
  try {
    // viem also decodes Solidity's built-in Error(string), which SaucerSwap uses for slippage.
    const error = decodeErrorResult({ abi, data: reason });
    return error.errorName === "Error" ? String(error.args?.[0]) : error.errorName;
  } catch {
    return "the swap reverted";
  }
};

/**
 * Human-readable history of one order, newest first.
 * One sweep is one transaction, so events are grouped by transaction: a check whose transaction has no other
 * order event is routine, and consecutive routine checks collapse into one row.
 * `input` and `output` describe the order's tokens; checks and budgets are always HBAR.
 */
export const buildTrail = (
  abi: Abi,
  logs: MirrorLog[],
  input: TokenMeta,
  output: TokenMeta,
  order: TrailOrder,
): TrailEntry[] => {
  const groups = new Map<string, Decoded[]>();
  for (const event of decodeOrderLogs(abi, logs)) {
    const group = groups.get(event.log.transaction_hash) ?? [];
    group.push(event);
    groups.set(event.log.transaction_hash, group);
  }

  const rows: TrailEntry[] = [];
  let run: { first: number; last: number; at: Date; timestamp: string; charged: bigint; txHash: string } | undefined;
  let checkNumber = 0;
  // A trailing stop's first state update seeds its peak; every later one raises it.
  let stateSeen = false;

  const flushRun = () => {
    if (!run) return;
    const count = run.last - run.first + 1;
    rows.push({
      key: `checks-${run.first}`,
      tone: "neutral",
      title: count === 1 ? `Check ${run.first}: trigger not met` : `Checks ${run.first}–${run.last}: trigger not met`,
      detail: `${count} scheduled ${count === 1 ? "check" : "checks"} run by the Hedera Schedule Service, ${formatHbar(run.charged)} charged`,
      at: run.at,
      timestamp: run.timestamp,
      txHash: run.txHash,
      checks: count,
    });
    run = undefined;
  };

  for (const [txHash, events] of groups) {
    const check = events.find(e => e.eventName === "OrderChecked");
    const others = events.filter(e => e.eventName !== "OrderChecked");
    const timestamp = events[0].log.timestamp;
    const at = dateFromConsensus(timestamp);
    if (check) checkNumber++;

    if (check && others.length === 0) {
      const charged = check.args.charged as bigint;
      if (run) {
        run.last = checkNumber;
        run.at = at;
        run.timestamp = timestamp;
        run.charged += charged;
        run.txHash = txHash;
      } else {
        run = { first: checkNumber, last: checkNumber, at, timestamp, charged, txHash };
      }
      continue;
    }
    flushRun();

    const charge = check ? ` Check ${checkNumber} charged ${formatHbar(check.args.charged as bigint)}.` : "";
    for (const { eventName, args } of others) {
      const row = describe(abi, eventName, args, input, output, order, checkNumber, charge, stateSeen);
      if (eventName === "OrderStateUpdated") stateSeen = true;
      if (row) rows.push({ ...row, key: `${txHash}-${eventName}`, at, timestamp, txHash });
    }
  }
  flushRun();
  return rows.reverse();
};

const describe = (
  abi: Abi,
  eventName: string,
  args: Record<string, unknown>,
  input: TokenMeta,
  output: TokenMeta,
  order: TrailOrder,
  checkNumber: number,
  charge: string,
  stateSeen: boolean,
): Pick<TrailEntry, "tone" | "title" | "detail"> | undefined => {
  const quote = (price: bigint) => `${formatPrice(price)} ${order.quote}`;
  const inAmount = (raw: unknown) => `${formatAmount(raw as bigint, input.decimals)} ${input.symbol}`;
  const outAmount = (raw: unknown) => `${formatAmount(raw as bigint, output.decimals)} ${output.symbol}`;
  switch (eventName) {
    case "OrderPlaced": {
      const kind = orderKind(order.side, order.orderType).toLowerCase();
      const param =
        order.orderType === OrderType.Trailing
          ? `${formatBps(Number(args.typeParam as bigint))} trail`
          : `trigger ${quote(args.typeParam as bigint)}`;
      return {
        tone: "primary",
        title: `Placed: ${inAmount(args.amountIn)} escrowed`,
        detail: `${kind[0].toUpperCase()}${kind.slice(1)}, ${param}. Check budget ${formatHbar(args.budget as bigint)}. Order NFT minted to ${args.maker as string}.`,
      };
    }
    case "OrderStateUpdated": {
      // The only shipped stateful type is the trailing stop, whose state is its peak.
      if (order.orderType !== OrderType.Trailing) {
        return { tone: "neutral", title: "Order state updated", detail: `New state ${String(args.state)}.${charge}` };
      }
      const peak = BigInt(args.state as string);
      return {
        tone: "primary",
        title: `${stateSeen ? "Peak raised" : "Peak set"} to ${quote(peak)}`,
        detail: `Trigger now ${quote(trailingTrigger(peak, order.typeParam))}, ${formatBps(Number(order.typeParam))} under the highest price seen at a check.${charge}`,
      };
    }
    case "OrderEvalSkipped":
      return {
        tone: "warn",
        title: checkNumber > 0 ? `Check ${checkNumber}: skipped` : "Check skipped",
        detail: `The order type's contract did not answer within its gas allowance, so this check neither filled nor moved the order; the next one comes soon.${charge}`,
      };
    case "FillHeld":
      return {
        tone: "warn",
        title: checkNumber > 0 ? `Check ${checkNumber}: held by guard` : "Held by guard",
        detail:
          (args.oraclePrice as bigint) > 0n
            ? `Trigger met, but ${GUARD_REASON[Number(args.reason)] ?? "the guard was closed"}: Chainlink ${formatPrice(args.oraclePrice as bigint)}, pool ${formatPrice(args.poolPrice as bigint)}.${charge}`
            : `Trigger met, but the budget could not cover the fill.${charge}`,
      };
    case "FillFailed":
      return {
        tone: "error",
        title: "Fill attempt failed",
        detail: `The swap did not go through (${readableRevert(abi, args.reason as `0x${string}`)}). The order stays open.${charge}`,
      };
    case "BudgetExhausted":
      return {
        tone: "error",
        title: "Budget empty: checks paused",
        detail: `${formatHbar(args.budgetLeft as bigint)} left, kept back to pay for a fill. Top up to resume.`,
      };
    case "BudgetToppedUp":
      return {
        tone: "neutral",
        title: `Budget topped up by ${formatHbar(args.amount as bigint)}`,
        detail: `New budget ${formatHbar(args.budget as bigint)}.`,
      };
    case "SweepBroughtForward":
      return {
        tone: "neutral",
        title: "Brought the next check forward",
        detail: `This order needed a check sooner than the one already scheduled. It paid ${formatHbar(args.charged as bigint)} for the replaced run; ${formatHbar(args.budgetLeft as bigint)} left.`,
      };
    case "OrderFilled":
      return {
        tone: "ok",
        title: `Filled: ${inAmount(args.amountIn)} for ${outAmount(args.amountOut)}`,
        detail: `Chainlink ${formatPrice(args.oraclePrice as bigint)}, minimum was ${outAmount(args.minAmountOut)}. ${formatHbar(args.budgetRefund as bigint)} budget refunded, order NFT retired.${charge}`,
      };
    case "OrderCancelled":
    case "OrderExpired":
      return {
        tone: "neutral",
        title: eventName === "OrderCancelled" ? "Cancelled" : "Expired",
        detail: `${inAmount(args.refund)} and ${formatHbar(args.budgetRefund as bigint)} budget returned to the holder.`,
      };
    case "NftSettlementFailed":
      return {
        tone: "warn",
        title: "Order NFT could not be retired",
        detail: `HTS response code ${String(args.responseCode)}. Funds were settled normally.`,
      };
    default:
      return undefined;
  }
};
