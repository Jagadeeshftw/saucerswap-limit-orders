import { describe, expect, it } from "vitest";
import {
  budgetFor,
  checksAffordable,
  checksFor,
  checksWhileHeld,
  coverageSeconds,
  durationText,
  durationWords,
  heldSeconds,
} from "~~/utils/orders/budget";

// The v1.1 testnet lens for a DAI sell on 2026-10-01: 1.4261 HBAR per solo check, 0.9373 HBAR reserve, 9.4941 minimum.
const SOLO = 142_612_906n;
const RESERVE = 93_729_866n;
const MIN = 949_407_302n;

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

describe("coverage", () => {
  it("counts the checks a budget pays for after the reserve", () => {
    expect(checksAffordable(10n, 4n, 2n)).toBe(3);
    expect(checksAffordable(4n, 4n, 2n)).toBe(0);
  });

  it("follows the vault's back-off while the guard holds a triggered order", () => {
    // First check after 5 min, then retries 10, 20 and 40 min apart, capped at 1 h.
    expect(heldSeconds(0, 300, 3600)).toBe(0);
    expect(heldSeconds(1, 300, 3600)).toBe(300);
    expect(heldSeconds(4, 300, 3600)).toBe(300 + 600 + 1200 + 2400);
    expect(heldSeconds(5, 300, 3600)).toBe(300 + 600 + 1200 + 2400 + 3600);
  });

  it("words a duration for the coverage line", () => {
    expect(durationWords(6 * 86_400 + 5_000)).toBe("6 days");
    expect(durationWords(86_400)).toBe("1 day");
    expect(durationWords(5 * 3600 + 100)).toBe("5 h");
    expect(durationWords(30)).toBe("1 min");
  });
});
