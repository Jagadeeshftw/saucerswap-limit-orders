import type { Abi } from "viem";
import { describe, expect, it } from "vitest";
import deployedContracts from "~~/contracts/deployedContracts";
import type { MirrorLog } from "~~/services/mirror";
import filledOrderLogs from "~~/utils/orders/__fixtures__/order-1-logs.json";
import heldOrderLogs from "~~/utils/orders/__fixtures__/order-2-logs.json";
import { buildTrail, decodeOrderLogs } from "~~/utils/orders/trail";

// Real mirror-node logs of the reference testnet vault 0.0.10779995 (2026-09-29).
const abi = deployedContracts[296].OrderVault.abi as Abi;
const DAI = { symbol: "DAI", decimals: 8 };
const USDC = { symbol: "USDC", decimals: 6 };
const HBAR = { symbol: "HBAR", decimals: 8 };

describe("decodeOrderLogs", () => {
  it("drops sweep and market events that share topic1 with the order id", () => {
    const names = decodeOrderLogs(abi, filledOrderLogs as MirrorLog[]).map(e => e.eventName);
    expect(names).toContain("OrderPlaced");
    expect(names).not.toContain("SweepScheduled");
    expect(names).not.toContain("MarketListed");
  });
});

describe("buildTrail", () => {
  it("tells the story of the DAI order the Schedule Service filled", () => {
    const trail = buildTrail(abi, filledOrderLogs as MirrorLog[], DAI, USDC);
    expect(trail[0].title).toBe("Filled: 3 DAI for 3.0052 USDC");
    expect(trail[0].tone).toBe("ok");
    expect(trail[0].detail).toContain("Check 1 charged");
    expect(trail.at(-1)?.title).toBe("Placed: 3 DAI escrowed");
  });

  it("shows each guard hold on the HBAR order with both prices", () => {
    const trail = buildTrail(abi, heldOrderLogs as MirrorLog[], HBAR, USDC);
    const holds = trail.filter(t => t.tone === "warn");
    expect(holds.length).toBeGreaterThanOrEqual(3);
    expect(holds[0].title).toMatch(/^Check \d+: held by guard$/);
    expect(holds[0].detail).toMatch(/pool was too far from Chainlink: Chainlink 0\.\d{4}, pool 2\.\d{4}/);
    expect(trail.at(-1)?.title).toBe("Placed: 20 HBAR escrowed");
  });

  it("links every row to a consensus timestamp", () => {
    for (const entry of buildTrail(abi, heldOrderLogs as MirrorLog[], HBAR, USDC)) {
      expect(entry.timestamp).toMatch(/^\d+\.\d+$/);
    }
  });

  it("collapses consecutive routine checks into one row", () => {
    const logs = heldOrderLogs as MirrorLog[];
    const placed = logs.filter(l => decodeOrderLogs(abi, [l])[0]?.eventName === "OrderPlaced");
    const checkedOnly = logs.filter(l => decodeOrderLogs(abi, [l])[0]?.eventName === "OrderChecked");
    const trail = buildTrail(abi, [...placed, ...checkedOnly], HBAR, USDC);
    expect(trail[0].title).toBe(`Checks 1–${checkedOnly.length}: trigger not met`);
    expect(trail[0].checks).toBe(checkedOnly.length);
  });
});
