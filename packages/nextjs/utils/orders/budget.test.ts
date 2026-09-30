import { describe, expect, it } from "vitest";
import { budgetFor, checksFor, checksWhileHeld, coverageSeconds, durationText } from "~~/utils/orders/budget";

// Live values of the testnet vault: 1.8977 HBAR per solo check, 0.6906 HBAR reserve, 12.0771 HBAR minimum.
const SOLO = 189_774_952n;
const RESERVE = 69_063_669n;
const MIN = 1_207_713_381n;

describe("checksFor", () => {
  it("counts one check per wait over the lifetime", () => {
    expect(checksFor(86_400, 7_200)).toBe(12);
    expect(checksFor(86_400, 7_000)).toBe(13);
  });
  it("always funds at least one check", () => {
    expect(checksFor(600, 21_600)).toBe(1);
    expect(checksFor(0, 0)).toBe(1);
  });
});

describe("checksWhileHeld", () => {
  it("follows the vault's back-off: 5, 10, 20, 40 min ... then every 6 h", () => {
    // Checks at 300, 900, 2100, 4500, 9300, 18900, 40500, 62100, 83700 s: nine in a day.
    expect(checksWhileHeld(86_400, 300, 21_600)).toBe(9);
    expect(checksWhileHeld(3_600, 300, 21_600)).toBe(3);
  });
  it("funds the first check even for a very short lifetime", () => {
    expect(checksWhileHeld(60, 300, 21_600)).toBe(1);
  });
});

describe("budgetFor", () => {
  it("covers the lifetime when that costs more than the minimum", () => {
    expect(budgetFor(12, SOLO, RESERVE, MIN)).toBe(RESERVE + 12n * SOLO);
  });
  it("never goes below the vault's minimum budget", () => {
    expect(budgetFor(1, SOLO, RESERVE, MIN)).toBe(MIN);
  });
});

describe("coverageSeconds", () => {
  it("turns the spendable budget into time between checks", () => {
    expect(coverageSeconds(RESERVE + 3n * SOLO, RESERVE, SOLO, 3_600)).toBe(10_800);
  });
  it("is zero once only the reserve is left", () => {
    expect(coverageSeconds(RESERVE, RESERVE, SOLO, 3_600)).toBe(0);
  });
});

describe("durationText", () => {
  it("picks the largest whole unit", () => {
    expect(durationText(172_800)).toBe("2 d");
    expect(durationText(7_200)).toBe("2 h");
    expect(durationText(1_800)).toBe("30 min");
    expect(durationText(10)).toBe("1 min");
  });
  it("rounds to the nearest unit rather than down", () => {
    expect(durationText(7_000)).toBe("2 h");
    expect(durationText(90_000)).toBe("1 d");
  });
});
