import { describe, expect, it } from "vitest";
import {
  ContractStatus,
  GuardState,
  OPEN_STATUSES,
  type Order,
  OrderType,
  Side,
  Trigger,
  currentTrigger,
  describeOrder,
  displayStatus,
  isOpen,
  newestFirst,
  orderKind,
  peakOf,
  placeLabel,
  sideTypeLabel,
  triggerFor,
  triggerMet,
  triggerSummary,
} from "~~/utils/orders/orders";

const order = (overrides: Partial<Order> = {}): Order => ({
  id: 1n,
  marketId: 1,
  side: Side.SellBase,
  orderType: OrderType.Limit,
  status: ContractStatus.Open,
  funded: true,
  slippageBps: 50,
  createdAt: 0,
  expiry: 1,
  amountIn: 1n,
  typeParam: 10_000_000n,
  typeState: `0x${"0".repeat(64)}`,
  budget: 1n,
  ...overrides,
});

describe("displayStatus", () => {
  const open = { state: GuardState.Open, oraclePrice: 12_000_000n };
  const closed = { state: GuardState.DeviationTooHigh, oraclePrice: 12_000_000n };

  it("is open while the guard is open", () => {
    expect(displayStatus(order(), open)).toBe("open");
  });

  it("is held by guard only when the trigger is met and the guard is closed", () => {
    expect(displayStatus(order(), closed)).toBe("held");
    expect(displayStatus(order({ typeParam: 13_000_000n }), closed)).toBe("open");
  });

  it("reports an unfunded order as budget empty before anything else", () => {
    expect(displayStatus(order({ funded: false }), closed)).toBe("budget-empty");
  });

  it("maps settled contract states", () => {
    expect(displayStatus(order({ status: ContractStatus.Filled }), open)).toBe("filled");
    expect(displayStatus(order({ status: ContractStatus.Cancelled }), open)).toBe("cancelled");
    expect(displayStatus(order({ status: ContractStatus.Expired }), open)).toBe("expired");
  });

  it("counts open, held and budget-empty as open everywhere", () => {
    expect(OPEN_STATUSES).toEqual(["open", "held", "budget-empty"]);
    expect(isOpen("held")).toBe(true);
    expect(isOpen("filled")).toBe(false);
  });
});

describe("order kinds", () => {
  it("maps ticket choices onto the contract comparator", () => {
    expect(triggerFor(Side.SellBase, "limit")).toBe(Trigger.AtOrAbove);
    expect(triggerFor(Side.SellBase, "stop")).toBe(Trigger.AtOrBelow);
    expect(triggerFor(Side.BuyBase, "limit")).toBe(Trigger.AtOrBelow);
    expect(triggerFor(Side.BuyBase, "stop")).toBe(Trigger.AtOrAbove);
  });

  it("names every combination", () => {
    expect(orderKind(Side.SellBase, OrderType.Limit)).toBe("Limit sell");
    expect(orderKind(Side.SellBase, OrderType.Stop)).toBe("Stop-loss");
    expect(orderKind(Side.BuyBase, OrderType.Limit)).toBe("Limit buy");
    expect(orderKind(Side.BuyBase, OrderType.Stop)).toBe("Stop-buy");
    expect(orderKind(Side.SellBase, OrderType.Trailing)).toBe("Trailing stop");
  });

  it("names the token a buy order gets, not only the one it spends", () => {
    expect(describeOrder(Side.SellBase, OrderType.Limit, "20", "HBAR", "USDC")).toBe("Limit sell 20 HBAR");
    expect(describeOrder(Side.BuyBase, OrderType.Limit, "50", "HBAR", "USDC")).toBe("Limit buy HBAR with 50 USDC");
  });
});

describe("trailing stop", () => {
  const peak = (value: bigint) => `0x${value.toString(16).padStart(64, "0")}` as const;
  const trailing = (state: `0x${string}`) =>
    order({ orderType: OrderType.Trailing, typeParam: 200n, typeState: state });

  it("reads the stored peak and puts the trigger 2% under it", () => {
    const o = trailing(peak(102_000_000n));
    expect(peakOf(o)).toBe(102_000_000n);
    expect(currentTrigger(o)).toBe(99_960_000n);
  });

  it("follows a price above the stored peak, as the next check will", () => {
    expect(currentTrigger(trailing(peak(100_000_000n)), 110_000_000n)).toBe(107_800_000n);
  });

  it("has no trigger before its first check and no price", () => {
    expect(currentTrigger(trailing(peak(0n)))).toBeUndefined();
    expect(triggerMet(trailing(peak(0n)), 0n)).toBe(false);
  });

  it("is met at or below peak x (1 - trail), so the guard can hold it", () => {
    const o = trailing(peak(102_000_000n));
    expect(triggerMet(o, 99_960_000n)).toBe(true);
    expect(triggerMet(o, 99_960_001n)).toBe(false);
    expect(displayStatus(o, { state: GuardState.DeviationTooHigh, oraclePrice: 99_000_000n })).toBe("held");
  });
});

describe("newestFirst", () => {
  it("sorts by order id descending", () => {
    const ids = newestFirst([{ id: 12n }, { id: 14n }, { id: 9n }, { id: 13n }]).map(o => o.id);
    expect(ids).toEqual([14n, 13n, 12n, 9n]);
  });
});

describe("labels", () => {
  it("names the ticket's action after the order type", () => {
    expect(placeLabel(Side.SellBase, OrderType.Limit)).toBe("Place limit order");
    expect(placeLabel(Side.SellBase, OrderType.Stop)).toBe("Place stop-loss");
    expect(placeLabel(Side.BuyBase, OrderType.Stop)).toBe("Place stop-buy");
    expect(placeLabel(Side.SellBase, OrderType.Trailing)).toBe("Place trailing stop");
  });

  it("labels the side with a word and the type in lower case", () => {
    expect(sideTypeLabel(Side.SellBase, OrderType.Stop)).toBe("Sell · stop-loss");
    expect(sideTypeLabel(Side.BuyBase, OrderType.Limit)).toBe("Buy · limit");
    expect(sideTypeLabel(Side.SellBase, OrderType.Trailing)).toBe("Sell · trailing stop");
  });

  it("summarises a trigger with its direction, and a trailing stop with its stored peak", () => {
    expect(triggerSummary(order())).toEqual({ main: "≥ 0.1000", sub: undefined });
    expect(triggerSummary(order({ orderType: OrderType.Stop })).main).toBe("≤ 0.1000");
    const peak = `0x${100_010_000n.toString(16).padStart(64, "0")}` as const;
    expect(triggerSummary(order({ orderType: OrderType.Trailing, typeParam: 50n, typeState: peak }))).toEqual({
      main: "0.50% trail",
      sub: "trigger 0.9950 · peak 1.0001",
    });
    expect(triggerSummary(order({ orderType: OrderType.Trailing, typeParam: 50n })).sub).toBe(
      "peak set at the first check",
    );
  });
});
