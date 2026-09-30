import type { Abi } from "viem";
import { describe, expect, it } from "vitest";
import deployedContracts from "~~/contracts/deployedContracts";
import type { MirrorLog } from "~~/services/mirror";
import heldOrderLogs from "~~/utils/orders/__fixtures__/order-3-held-logs.json";
import filledOrderLogs from "~~/utils/orders/__fixtures__/order-5-logs.json";
import { buildTrail, decodeOrderLogs } from "~~/utils/orders/trail";

// Real mirror-node logs of the testnet vault 0.0.10787941 (2026-09-30): order #5, filled by a scheduled sweep, and
// order #3 through its first two scheduled checks, both held by the guard (it was cancelled afterwards).
const abi = deployedContracts[296].OrderVault.abi as Abi;
const DAI = { symbol: "DAI", decimals: 8 };
const USDC = { symbol: "USDC", decimals: 6 };
const HBAR = { symbol: "HBAR", decimals: 8 };

describe("decodeOrderLogs", () => {
  it("keeps the order's own events", () => {
    const names = decodeOrderLogs(abi, filledOrderLogs as MirrorLog[]).map(e => e.eventName);
    expect(names).toEqual(["OrderPlaced", "OrderChecked", "OrderFilled"]);
  });

  it("drops sweep and market events that share topic1 with the order id", () => {
    const marketLevel = {
      ...(filledOrderLogs[0] as MirrorLog),
      // SweepScheduled(marketId, ...) for market 5 would carry the same topic1 as order #5.
      topics: [
        "0x3bafc8a0342d1904e9fc16d0a85040ad804014f5ca02e351a4c038052a50dc99",
        (filledOrderLogs[0] as MirrorLog).topics[1],
      ],
      data: `0x${"0".repeat(64 * 3)}`,
    } as MirrorLog;
    const names = decodeOrderLogs(abi, [marketLevel, ...(filledOrderLogs as MirrorLog[])]).map(e => e.eventName);
    expect(names).not.toContain("SweepScheduled");
  });
});

describe("buildTrail", () => {
  it("tells the story of the DAI order the Schedule Service filled", () => {
    const trail = buildTrail(abi, filledOrderLogs as MirrorLog[], DAI, USDC);
    expect(trail[0].title).toBe("Filled: 0.5 DAI for 0.5008 USDC");
    expect(trail[0].tone).toBe("ok");
    expect(trail[0].detail).toContain("Check 1 charged");
    expect(trail.at(-1)?.title).toBe("Placed: 0.5 DAI escrowed");
  });

  it("shows each guard hold on the HBAR order with both prices", () => {
    const trail = buildTrail(abi, heldOrderLogs as MirrorLog[], HBAR, USDC);
    const holds = trail.filter(t => t.tone === "warn");
    expect(holds.length).toBe(2);
    expect(holds[0].title).toMatch(/^Check \d+: held by guard$/);
    expect(holds[0].detail).toMatch(/pool was too far from Chainlink: Chainlink 0\.\d{4}, pool 2\.\d{4}/);
    expect(trail.at(-1)?.title).toBe("Placed: 1 HBAR escrowed");
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
