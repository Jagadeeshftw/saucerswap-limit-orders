import { describe, expect, it } from "vitest";
import {
  ContractStatus,
  GuardState,
  OPEN_STATUSES,
  type Order,
  Side,
  Trigger,
  describeOrder,
  displayStatus,
  isOpen,
  newestFirst,
  orderKind,
  triggerFor,
} from "~~/utils/orders/orders";

const order = (overrides: Partial<Order> = {}): Order => ({
  id: 1n,
  marketId: 1,
  side: Side.SellBase,
  trigger: Trigger.AtOrAbove,
  status: ContractStatus.Open,
  funded: true,
  slippageBps: 50,
  createdAt: 0,
  expiry: 1,
  amountIn: 1n,
  triggerPrice: 10_000_000n,
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
    expect(displayStatus(order({ triggerPrice: 13_000_000n }), closed)).toBe("open");
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
    expect(orderKind(Side.SellBase, Trigger.AtOrAbove)).toBe("Limit sell");
    expect(orderKind(Side.SellBase, Trigger.AtOrBelow)).toBe("Stop-loss");
    expect(orderKind(Side.BuyBase, Trigger.AtOrBelow)).toBe("Limit buy");
    expect(orderKind(Side.BuyBase, Trigger.AtOrAbove)).toBe("Stop-buy");
  });

  it("names the token a buy order gets, not only the one it spends", () => {
    expect(describeOrder(Side.SellBase, Trigger.AtOrAbove, "20", "HBAR", "USDC")).toBe("Limit sell 20 HBAR");
    expect(describeOrder(Side.BuyBase, Trigger.AtOrBelow, "50", "HBAR", "USDC")).toBe("Limit buy HBAR with 50 USDC");
  });
});

describe("newestFirst", () => {
  it("sorts by order id descending", () => {
    const ids = newestFirst([{ id: 12n }, { id: 14n }, { id: 9n }, { id: 13n }]).map(o => o.id);
    expect(ids).toEqual([14n, 13n, 12n, 9n]);
  });
});
