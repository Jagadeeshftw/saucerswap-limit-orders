/**
 * Order vocabulary shared by every screen. Enum values mirror contracts/types/OrderTypes.sol.
 */

export enum Side {
  SellBase = 0,
  BuyBase = 1,
}

export enum Trigger {
  AtOrAbove = 0,
  AtOrBelow = 1,
}

export enum ContractStatus {
  None = 0,
  Open = 1,
  Filled = 2,
  Cancelled = 3,
  Expired = 4,
}

export enum GuardState {
  Open = 0,
  OracleInvalid = 1,
  OracleStale = 2,
  TwapUnavailable = 3,
  DeviationTooHigh = 4,
}

export type Order = {
  id: bigint;
  marketId: number;
  side: Side;
  trigger: Trigger;
  status: ContractStatus;
  funded: boolean;
  slippageBps: number;
  createdAt: number;
  expiry: number;
  amountIn: bigint;
  triggerPrice: bigint;
  budget: bigint;
};

/** What the UI shows. The first three all count as open: the order is live and still holds funds. */
export type DisplayStatus = "open" | "held" | "budget-empty" | "filled" | "cancelled" | "expired";

export const OPEN_STATUSES: readonly DisplayStatus[] = ["open", "held", "budget-empty"];

export const STATUS_LABEL: Record<DisplayStatus, string> = {
  open: "Open",
  held: "Held by guard",
  "budget-empty": "Budget empty",
  filled: "Filled",
  cancelled: "Cancelled",
  expired: "Expired",
};

export const isOpen = (status: DisplayStatus) => OPEN_STATUSES.includes(status);

export const triggerMet = (order: Pick<Order, "trigger" | "triggerPrice">, price: bigint) =>
  order.trigger === Trigger.AtOrAbove ? price >= order.triggerPrice : price <= order.triggerPrice;

/**
 * Display status from contract state plus the market's current guard reading.
 * "Held by guard" means the trigger is met now but the guard would refuse the fill.
 */
export const displayStatus = (
  order: Order,
  guard: { state: GuardState; oraclePrice: bigint } | undefined,
): DisplayStatus => {
  switch (order.status) {
    case ContractStatus.Filled:
      return "filled";
    case ContractStatus.Cancelled:
      return "cancelled";
    case ContractStatus.Expired:
      return "expired";
    default:
      if (!order.funded) return "budget-empty";
      if (guard && guard.state !== GuardState.Open && guard.oraclePrice > 0n && triggerMet(order, guard.oraclePrice)) {
        return "held";
      }
      return "open";
  }
};

/** Orders newest first; ids are NFT serials, so a higher id was placed later. */
export const newestFirst = <T extends { id: bigint }>(orders: T[]) =>
  [...orders].sort((a, b) => (a.id > b.id ? -1 : 1));

/**
 * Plain-language name for the four order kinds.
 * Sell + at or above: limit sell. Sell + at or below: stop-loss.
 * Buy + at or below: limit buy. Buy + at or above: stop-buy.
 */
export const orderKind = (side: Side, trigger: Trigger) => {
  if (side === Side.SellBase) return trigger === Trigger.AtOrAbove ? "Limit sell" : "Stop-loss";
  return trigger === Trigger.AtOrBelow ? "Limit buy" : "Stop-buy";
};

/** "Limit sell 20 HBAR", "Limit buy HBAR with 50 USDC": names the token bought, not only the one spent. */
export const describeOrder = (side: Side, trigger: Trigger, amount: string, base: string, quote: string) =>
  side === Side.SellBase
    ? `${orderKind(side, trigger)} ${amount} ${base}`
    : `${orderKind(side, trigger)} ${base} with ${amount} ${quote}`;

export type OrderKind = "limit" | "stop";

/** Ticket choice to contract comparator: a sell limit fires on the way up, a sell stop on the way down; buys mirror it. */
export const triggerFor = (side: Side, kind: OrderKind) => {
  if (side === Side.SellBase) return kind === "limit" ? Trigger.AtOrAbove : Trigger.AtOrBelow;
  return kind === "limit" ? Trigger.AtOrBelow : Trigger.AtOrAbove;
};

export const comparatorText = (trigger: Trigger) => (trigger === Trigger.AtOrAbove ? "at or above" : "at or below");

export const GUARD_COPY: Record<GuardState, { label: string; tone: "ok" | "warn" | "error"; detail: string }> = {
  [GuardState.Open]: {
    label: "Guard open",
    tone: "ok",
    detail: "The pool price agrees with Chainlink, so orders whose trigger is met can fill.",
  },
  [GuardState.DeviationTooHigh]: {
    label: "Guard closed",
    tone: "error",
    detail: "The pool is too far from Chainlink. Orders keep checking but will not fill until they agree again.",
  },
  [GuardState.OracleStale]: {
    label: "Guard closed",
    tone: "error",
    detail: "A Chainlink feed has not updated within the allowed age. Fills wait for a fresh price.",
  },
  [GuardState.OracleInvalid]: {
    label: "Guard closed",
    tone: "error",
    detail: "A Chainlink feed returned no usable price. Fills wait until it recovers.",
  },
  [GuardState.TwapUnavailable]: {
    label: "Guard closed",
    tone: "error",
    detail: "The pool has too little price history for the time-weighted average. Fills wait for it to build up.",
  },
};
