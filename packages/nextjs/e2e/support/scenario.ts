import heldOrderLogs from "../../utils/orders/__fixtures__/order-3-held-logs.json";
import filledOrderLogs from "../../utils/orders/__fixtures__/order-5-logs.json";
import { type LogEvent, mirrorTx } from "./logs";
import { type Hex, pad, toHex, zeroHash } from "viem";

/**
 * Everything the mocked network knows: wallet, balances, markets, guard readings, orders and mirror data.
 * Tests start from `baseScenario()` and change only what their state needs.
 */

export const ACCOUNT = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as const;
export const ACCOUNT_ID = "0.0.4101";
export const VAULT_ID = "0.0.10809822";
export const COLLECTION = "0x0000000000000000000000000000000000a4f1e1" as const;
export const COLLECTION_ID = "0.0.10809825";
export const WHBAR = "0x0000000000000000000000000000000000003ad2" as const;
export const USDC = "0x0000000000000000000000000000000000001549" as const;
export const DAI = "0x0000000000000000000000000000000000001599" as const;
export const POOL_HBAR = "0x914b98992d7ed602d1f5d9084ece8160fc0e741a" as const;
export const POOL_DAI = "0xb431866114b634f611774ec0d094bf11cb91c7e4" as const;

export type GuardReading = {
  state: number;
  oraclePrice: bigint;
  poolPrice: bigint;
  deviationBps: bigint;
  oracleUpdatedAt: bigint;
};

/** The vault's `Order`. orderType 0 limit, 1 stop, 2 trailing stop; typeParam is the trigger price or the trail. */
export type ScenarioOrder = {
  marketId: number;
  side: number;
  orderType: number;
  status: number;
  funded: boolean;
  slippageBps: number;
  createdAt: number;
  expiry: number;
  amountIn: bigint;
  typeParam: bigint;
  budget: bigint;
  /** A trailing stop's peak price (8 decimals) as bytes32; zero for limit and stop orders. */
  typeState: Hex;
};

export type SendOutcome =
  | { kind: "success"; confirmAfterPolls?: number }
  | { kind: "revert"; errorName: string; args: readonly unknown[] }
  | { kind: "rejected" };

export type Scenario = {
  walletChainId: number;
  hbarTinybar: bigint;
  tokens: Record<string, { symbol: string; balance: bigint; allowance: bigint }>;
  /** null: the address has never been used on Hedera testnet. */
  mirrorAccount: { id: string; maxAutoAssociations: number } | null;
  associations: string[];
  guards: Record<number, GuardReading>;
  fundedOrders: Record<number, number>;
  /** Markets whose sweep chain has stopped although orders are funded. */
  stalled: number[];
  orders: Record<string, ScenarioOrder>;
  held: number[];
  /** NFT holder per order id, where it is not the connected account. */
  holders: Record<string, string>;
  logs: Record<string, unknown[]>;
  mirrorLagSeconds: number;
  send: SendOutcome;
  /** Filled in by the mock as transactions arrive. */
  sent: { to: string; data: string; value: string; gas?: string }[];
};

const now = () => Math.floor(Date.now() / 1000);

/** A price as the bytes32 a trailing stop keeps its peak in. */
export const peakState = (price: bigint) => pad(toHex(price), { size: 32 });

export const guardOpen = (oraclePrice: bigint): GuardReading => ({
  state: 0,
  oraclePrice,
  poolPrice: oraclePrice + oraclePrice / 1000n,
  deviationBps: 10n,
  oracleUpdatedAt: BigInt(now() - 120),
});

export const baseScenario = (): Scenario => ({
  walletChainId: 296,
  hbarTinybar: 1_204_52_000_000n,
  tokens: {
    [USDC]: { symbol: "USDC", balance: 250_000_000n, allowance: 0n },
    [DAI]: { symbol: "DAI", balance: 1_000_00_000_000n, allowance: 0n },
  },
  mirrorAccount: { id: ACCOUNT_ID, maxAutoAssociations: -1 },
  associations: [],
  guards: {
    1: {
      state: 4,
      oraclePrice: 10_340_000n,
      poolPrice: 201_790_000n,
      deviationBps: 185_058n,
      oracleUpdatedAt: BigInt(now() - 1_500),
    },
    2: guardOpen(99_980_000n),
  },
  fundedOrders: { 1: 1, 2: 0 },
  stalled: [],
  orders: {},
  held: [],
  holders: {},
  logs: {},
  mirrorLagSeconds: 2,
  send: { kind: "success" },
  sent: [],
});

/** Per-check charge in the trailing stop's history: the live lens's checkCostShared(2), in tinybar. */
const TRAIL_CHARGE = 74_221_496n;

/**
 * Mirror logs for a trailing stop, in the vault's v1.1 layout: placed at `o.createdAt`, a first check that sets
 * the peak at 0.9999, a later one that raises it to 1.0001, then a routine check. `o.budget` is what is left.
 */
const trailingStopLogs = (id: string, o: ScenarioOrder) => {
  const orderId = BigInt(id);
  const placed = o.budget + 3n * TRAIL_CHARGE;
  const check = (n: bigint): LogEvent => [
    "OrderChecked",
    { orderId, charged: TRAIL_CHARGE, budgetLeft: placed - n * TRAIL_CHARGE },
  ];
  const state = (peak: bigint): LogEvent => ["OrderStateUpdated", { orderId, state: peakState(peak) }];
  return [
    ...mirrorTx(`order-${id}-placed`, o.createdAt, [
      [
        "OrderPlaced",
        {
          orderId,
          marketId: BigInt(o.marketId),
          maker: ACCOUNT,
          side: o.side,
          orderType: o.orderType,
          amountIn: o.amountIn,
          typeParam: o.typeParam,
          slippageBps: BigInt(o.slippageBps),
          expiry: BigInt(o.expiry),
          budget: placed,
        },
      ],
    ]),
    ...mirrorTx(`order-${id}-check-1`, o.createdAt + 600, [check(1n), state(99_990_000n)]),
    ...mirrorTx(`order-${id}-check-2`, o.createdAt + 2_400, [check(2n), state(100_010_000n)]),
    ...mirrorTx(`order-${id}-check-3`, o.createdAt + 4_800, [check(3n)]),
  ];
};

/**
 * A realistic book for My orders: one order in every display state. Orders 3 and 5 replay real v1.0.1 logs,
 * whose OrderPlaced layout matches v1.1 (a sell's old trigger byte, 0 at-or-above / 1 at-or-below, reads as
 * orderType limit / stop).
 */
export const withOrderBook = (s: Scenario): Scenario => {
  const t = now();
  const order = (o: Partial<ScenarioOrder>): ScenarioOrder => ({
    marketId: 1,
    side: 0,
    orderType: 0,
    status: 1,
    funded: true,
    slippageBps: 100,
    createdAt: t - 3_600,
    expiry: t + 5 * 86_400,
    amountIn: 250_00_000_000n,
    typeParam: 12_500_000n,
    budget: 12_07_710_000n,
    typeState: zeroHash,
    ...o,
  });
  s.orders = {
    // Trailing stop with a 0.5% trail; its peak has been raised once, so the trigger is 1.0001 x 0.995.
    "15": order({
      marketId: 2,
      orderType: 2,
      typeParam: 50n,
      amountIn: 10_000_000n,
      slippageBps: 30,
      createdAt: t - 7_200,
      budget: 40_00_000_000n,
      typeState: peakState(100_010_000n),
    }),
    "14": order({}),
    "13": order({ typeParam: 10_000_000n }),
    "12": order({ marketId: 2, orderType: 1, amountIn: 1_000_00_000_000n, typeParam: 99_500_000n, slippageBps: 30 }),
    // A limit buy: fires at or below its trigger.
    "11": order({
      side: 1,
      amountIn: 50_000_000n,
      typeParam: 9_800_000n,
      funded: false,
      budget: 69_060_000n,
    }),
    "5": order({
      marketId: 2,
      orderType: 1,
      status: 2,
      funded: false,
      budget: 0n,
      createdAt: 1_790_748_364,
      amountIn: 50_000_000n,
      typeParam: 100_000_000n,
      slippageBps: 30,
    }),
    "3": order({ typeParam: 10_000_000n, createdAt: 1_790_748_036, amountIn: 1_00_000_000n }),
    "9": order({
      status: 3,
      funded: false,
      budget: 0n,
      typeParam: 9_900_000n,
      orderType: 1,
      amountIn: 120_00_000_000n,
    }),
  };
  s.held = [15, 14, 13, 12, 11, 9, 5, 3];
  s.logs = { "15": trailingStopLogs("15", s.orders["15"]), "5": filledOrderLogs, "3": heldOrderLogs };
  return s;
};
