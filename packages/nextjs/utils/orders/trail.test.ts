import { type Abi, encodeAbiParameters, encodeEventTopics } from "viem";
import { describe, expect, it } from "vitest";
import deployedContracts from "~~/contracts/deployedContracts";
import type { MirrorLog } from "~~/services/mirror";
import heldOrderLogs from "~~/utils/orders/__fixtures__/order-3-held-logs.json";
import filledOrderLogs from "~~/utils/orders/__fixtures__/order-5-logs.json";
import { OrderType, Side } from "~~/utils/orders/orders";
import { buildTrail, decodeOrderLogs } from "~~/utils/orders/trail";

// Real mirror-node logs of the testnet vault 0.0.10792085 (2026-09-30): order #5, filled by a scheduled sweep, and
// order #3 through its first two scheduled checks, both held by the guard (it was cancelled afterwards).
const abi = deployedContracts[296].OrderVault.abi as Abi;
const DAI = { symbol: "DAI", decimals: 8 };
const USDC = { symbol: "USDC", decimals: 6 };
const HBAR = { symbol: "HBAR", decimals: 8 };
const DAI_STOP = { side: Side.SellBase, orderType: OrderType.Stop, typeParam: 0n, quote: "USDC" };
const HBAR_LIMIT = { side: Side.SellBase, orderType: OrderType.Limit, typeParam: 0n, quote: "USDC" };

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
    const trail = buildTrail(abi, filledOrderLogs as MirrorLog[], DAI, USDC, DAI_STOP);
    expect(trail[0].title).toBe("Filled: 0.5 DAI for 0.5008 USDC");
    expect(trail[0].tone).toBe("ok");
    expect(trail[0].detail).toContain("Check 1 charged");
    expect(trail.at(-1)?.title).toBe("Placed: 0.5 DAI escrowed");
  });

  it("shows each guard hold on the HBAR order with both prices", () => {
    const trail = buildTrail(abi, heldOrderLogs as MirrorLog[], HBAR, USDC, HBAR_LIMIT);
    const holds = trail.filter(t => t.tone === "warn");
    expect(holds.length).toBe(2);
    expect(holds[0].title).toMatch(/^Check \d+: held by guard$/);
    expect(holds[0].detail).toMatch(/pool was too far from Chainlink: Chainlink 0\.\d{4}, pool 2\.\d{4}/);
    expect(trail.at(-1)?.title).toBe("Placed: 1 HBAR escrowed");
  });

  it("links every row to a consensus timestamp", () => {
    for (const entry of buildTrail(abi, heldOrderLogs as MirrorLog[], HBAR, USDC, HBAR_LIMIT)) {
      expect(entry.timestamp).toMatch(/^\d+\.\d+$/);
    }
  });

  it("collapses consecutive routine checks into one row", () => {
    const logs = heldOrderLogs as MirrorLog[];
    const placed = logs.filter(l => decodeOrderLogs(abi, [l])[0]?.eventName === "OrderPlaced");
    const checkedOnly = logs.filter(l => decodeOrderLogs(abi, [l])[0]?.eventName === "OrderChecked");
    const trail = buildTrail(abi, [...placed, ...checkedOnly], HBAR, USDC, HBAR_LIMIT);
    expect(trail[0].title).toBe(`Checks 1–${checkedOnly.length}: trigger not met`);
    expect(trail[0].checks).toBe(checkedOnly.length);
  });

  it("shows a trailing stop setting its peak, then raising it with the trigger following", () => {
    const log = (eventName: string, args: Record<string, unknown>, data: `0x${string}`, tx: string, at: string) =>
      ({
        address: "0x0",
        topics: encodeEventTopics({ abi, eventName, args } as never),
        data,
        transaction_hash: tx,
        timestamp: at,
      }) as unknown as MirrorLog;
    const checked = (tx: string, at: string) =>
      log(
        "OrderChecked",
        { orderId: 9n },
        encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [33_070_706n, 900_000_000n]),
        tx,
        at,
      );
    const peak = (value: bigint, tx: string, at: string) =>
      log(
        "OrderStateUpdated",
        { orderId: 9n },
        encodeAbiParameters([{ type: "bytes32" }], [`0x${value.toString(16).padStart(64, "0")}`]),
        tx,
        at,
      );
    const logs = [
      checked("0xa", "1790800000.000000001"),
      peak(100_000_000n, "0xa", "1790800000.000000001"),
      checked("0xb", "1790807200.000000001"),
      checked("0xc", "1790814400.000000001"),
      peak(102_000_000n, "0xc", "1790814400.000000001"),
    ];
    const trailing = { side: Side.SellBase, orderType: OrderType.Trailing, typeParam: 200n, quote: "USDC" };
    const [raised, routine, set] = buildTrail(abi, logs, DAI, USDC, trailing);
    expect(raised.title).toBe("Peak raised to 1.0200 USDC");
    expect(raised.detail).toMatch(
      /^Trigger now 0\.9996 USDC, 2\.00% under the highest price seen at a check\. Check 3 charged/,
    );
    expect(routine.title).toBe("Check 2: trigger not met");
    expect(set.title).toBe("Peak set to 1.0000 USDC");
    expect(set.detail).toMatch(/^Trigger now 0\.9800 USDC/);
  });
});
