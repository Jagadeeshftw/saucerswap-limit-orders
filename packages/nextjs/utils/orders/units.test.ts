import { describe, expect, it } from "vitest";
import {
  addressFromEntityId,
  entityIdFromAddress,
  formatAmount,
  formatBps,
  formatHbar,
  formatPrice,
  parseAmount,
  parsePrice,
  tinybarToWeibar,
  weibarToTinybar,
} from "~~/utils/orders/units";

describe("HBAR scales", () => {
  it("converts 1 HBAR between tinybar (8 dp) and weibar (18 dp)", () => {
    expect(tinybarToWeibar(100_000_000n)).toBe(10n ** 18n);
    expect(weibarToTinybar(10n ** 18n)).toBe(100_000_000n);
  });

  it("rounds weibar dust down instead of inventing tinybar", () => {
    expect(weibarToTinybar(10n ** 10n - 1n)).toBe(0n);
  });

  it("formats tinybar as HBAR", () => {
    expect(formatHbar(189_774_952n)).toBe("1.8977 HBAR");
    expect(formatHbar(25_000_000_000n)).toBe("250 HBAR");
  });
});

describe("parseAmount", () => {
  it("parses decimals within the token precision", () => {
    expect(parseAmount("250", 8)).toBe(25_000_000_000n);
    expect(parseAmount("0.000001", 6)).toBe(1n);
  });

  it("rejects malformed and over-precise input", () => {
    expect(parseAmount("", 6)).toBeNull();
    expect(parseAmount("1.2.3", 6)).toBeNull();
    expect(parseAmount("-1", 6)).toBeNull();
    expect(parseAmount("0.0000001", 6)).toBeNull();
    expect(parseAmount("1e5", 6)).toBeNull();
  });
});

describe("formatting", () => {
  it("groups thousands and trims trailing zeros", () => {
    expect(formatAmount(1_234_567_890_000n, 6)).toBe("1,234,567.89");
    expect(formatAmount(3_005_271n, 6)).toBe("3.0052");
  });

  it("shows prices with a fixed number of decimals", () => {
    expect(formatPrice(10_466_127n)).toBe("0.1046");
    expect(formatPrice(100_000_000n)).toBe("1.0000");
    expect(parsePrice("0.125")).toBe(12_500_000n);
  });

  it("shows basis points as a percentage", () => {
    expect(formatBps(50)).toBe("0.50%");
  });
});

describe("Hedera entity ids", () => {
  it("round-trips long-zero addresses", () => {
    expect(entityIdFromAddress("0x0000000000000000000000000000000000001549")).toBe("0.0.5449");
    expect(addressFromEntityId("0.0.5449")).toBe("0x0000000000000000000000000000000000001549");
    expect(entityIdFromAddress(addressFromEntityId("0.0.10779996"))).toBe("0.0.10779996");
  });
});
