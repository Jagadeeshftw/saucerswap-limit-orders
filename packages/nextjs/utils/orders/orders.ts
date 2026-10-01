/**
 * Order vocabulary shared by every screen. Enum values mirror contracts/types/OrderTypes.sol.
 */
import { formatBps, formatPrice } from "~~/utils/orders/units";

export enum Side {
  SellBase = 0,
  BuyBase = 1,
}

/** Which way a price must move to fire an order. Derived from the order type and side; not stored on-chain. */
export enum Trigger {
  AtOrAbove = 0,
  AtOrBelow = 1,
}

/** Ids of the order-type plug-ins the vault registers (see Deploy.s.sol): fixed, so the UI can name them. */
export enum OrderType {
  Limit = 0,
  Stop = 1,
  Trailing = 2,
}

/** TrailingStopType's bounds on the trail, in basis points. */
export const MIN_TRAIL_BPS = 50;
export const MAX_TRAIL_BPS = 5000;

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
  orderType: OrderType;
  status: ContractStatus;
  funded: boolean;
  slippageBps: number;
  createdAt: number;
  expiry: number;
  amountIn: bigint;
  /** The type's parameter: the trigger price (8 decimals) for limit and stop, the trail in bps for trailing. */
  typeParam: bigint;
  /** The type's per-order state as a bytes32 hex string: the trailing peak (8 decimals), zero until its first check. */
  typeState: `0x${string}`;
  budget: bigint;
};

/** What the UI shows. The first three all count as open: the order is live and still holds funds. */
export type DisplayStatus = "open" | "held" | "budget-empty" | "filled" | "cancelled" | "expired";

export const OPEN_STATUSES: readonly DisplayStatus[] = ["open", "held", "budget-empty"];

export const STATUS_LABEL: Record<DisplayStatus, string> = {
  open: "Open",
  held: "Held",
  "budget-empty": "Budget empty",
  filled: "Filled",
  cancelled: "Cancelled",
  expired: "Expired",
};

export const isOpen = (status: DisplayStatus) => OPEN_STATUSES.includes(status);

/** Limit sells and stop-buys fire on the way up; limit buys, stop-losses and trailing stops on the way down. */
export const directionOf = (side: Side, orderType: OrderType) => {
  if (orderType === OrderType.Trailing) return Trigger.AtOrBelow;
  const limit = orderType === OrderType.Limit;
  if (side === Side.SellBase) return limit ? Trigger.AtOrAbove : Trigger.AtOrBelow;
  return limit ? Trigger.AtOrBelow : Trigger.AtOrAbove;
};

/** The trailing peak stored on-chain, or 0n before the order's first scheduled check. */
export const peakOf = (order: Pick<Order, "orderType" | "typeState">) =>
  order.orderType === OrderType.Trailing ? BigInt(order.typeState) : 0n;

/** peak x (1 - trail), rounded down as TrailingStopType does. */
export const trailingTrigger = (peak: bigint, trailBps: bigint) => (peak * (10_000n - trailBps)) / 10_000n;

/**
 * The price that fires the order right now. For a trailing stop the next check first raises the peak to the
 * current price if that is higher, so the live trigger uses max(peak, price); with no price and no peak yet
 * there is no trigger to show.
 */
export const currentTrigger = (order: Pick<Order, "orderType" | "typeParam" | "typeState">, price = 0n) => {
  if (order.orderType !== OrderType.Trailing) return order.typeParam;
  const peak = peakOf(order);
  const effective = price > peak ? price : peak;
  return effective > 0n ? trailingTrigger(effective, order.typeParam) : undefined;
};

export const triggerMet = (order: Pick<Order, "side" | "orderType" | "typeParam" | "typeState">, price: bigint) => {
  const trigger = currentTrigger(order, price);
  if (trigger === undefined) return false;
  return directionOf(order.side, order.orderType) === Trigger.AtOrAbove ? price >= trigger : price <= trigger;
};

/**
 * Display status from contract state plus the market's current guard reading.
 * "Held" means the trigger is met now but the guard would refuse the fill.
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

/** Plain-language name for each order kind: limit sell, stop-loss, limit buy, stop-buy, trailing stop. */
export const orderKind = (side: Side, orderType: OrderType) => {
  if (orderType === OrderType.Trailing) return "Trailing stop";
  if (side === Side.SellBase) return orderType === OrderType.Limit ? "Limit sell" : "Stop-loss";
  return orderType === OrderType.Limit ? "Limit buy" : "Stop-buy";
};

/** "Limit sell 20 HBAR", "Limit buy HBAR with 50 USDC": names the token bought, not only the one spent. */
export const describeOrder = (side: Side, orderType: OrderType, amount: string, base: string, quote: string) =>
  side === Side.SellBase
    ? `${orderKind(side, orderType)} ${amount} ${base}`
    : `${orderKind(side, orderType)} ${base} with ${amount} ${quote}`;

/** Short side + type label for lists, e.g. "Sell · stop-loss", "Buy · limit", "Sell · trailing stop". */
export const sideTypeLabel = (side: Side, orderType: OrderType) => {
  const type = orderType === OrderType.Limit ? "limit" : orderKind(side, orderType).toLowerCase();
  return `${side === Side.SellBase ? "Sell" : "Buy"} · ${type}`;
};

/**
 * The trigger as a list shows it: "≥ 1.0100" for a limit or stop; for a trailing stop, the trail plus the peak the
 * vault has stored and the trigger it implies (the same figures as the trail's "Peak raised" rows).
 */
export const triggerSummary = (order: Pick<Order, "side" | "orderType" | "typeParam" | "typeState">) => {
  if (order.orderType !== OrderType.Trailing) {
    const sign = directionOf(order.side, order.orderType) === Trigger.AtOrAbove ? "≥" : "≤";
    return { main: `${sign} ${formatPrice(order.typeParam)}`, sub: undefined };
  }
  const peak = peakOf(order);
  return {
    main: `${formatBps(order.typeParam)} trail`,
    sub:
      peak === 0n
        ? "peak set at the first check"
        : `trigger ${formatPrice(trailingTrigger(peak, order.typeParam))} · peak ${formatPrice(peak)}`,
  };
};

export type OrderKind = "limit" | "stop" | "trailing";

export const orderTypeFor = (kind: OrderKind) =>
  kind === "limit" ? OrderType.Limit : kind === "stop" ? OrderType.Stop : OrderType.Trailing;

/** Ticket choice to comparator: a sell limit fires on the way up, a sell stop on the way down; buys mirror it. */
export const triggerFor = (side: Side, kind: OrderKind) => directionOf(side, orderTypeFor(kind));

export const comparatorText = (trigger: Trigger) => (trigger === Trigger.AtOrAbove ? "at or above" : "at or below");

/** The ticket's primary action for each order type, e.g. "Place stop-loss". */
export const placeLabel = (side: Side, orderType: OrderType) => {
  if (orderType === OrderType.Trailing) return "Place trailing stop";
  if (orderType === OrderType.Limit) return "Place limit order";
  return side === Side.SellBase ? "Place stop-loss" : "Place stop-buy";
};

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
