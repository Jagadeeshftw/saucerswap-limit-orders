import filledOrderLogs from "../../utils/orders/__fixtures__/order-1-logs.json";
import heldOrderLogs from "../../utils/orders/__fixtures__/order-2-logs.json";

/**
 * Everything the mocked network knows: wallet, balances, markets, guard readings, orders and mirror data.
 * Tests start from `baseScenario()` and change only what their state needs.
 */

export const ACCOUNT = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as const;
export const ACCOUNT_ID = "0.0.4101";
export const VAULT_ID = "0.0.10779995";
export const COLLECTION = "0x0000000000000000000000000000000000a47d5c" as const;
export const COLLECTION_ID = "0.0.10779996";
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

export type ScenarioOrder = {
  marketId: number;
  side: number;
  trigger: number;
  status: number;
  funded: boolean;
  slippageBps: number;
  createdAt: number;
  expiry: number;
  amountIn: bigint;
  triggerPrice: bigint;
  budget: bigint;
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
  orders: Record<string, ScenarioOrder>;
  held: number[];
  /** NFT holder per order id, where it is not the connected account. */
  holders: Record<string, string>;
  logs: Record<string, unknown[]>;
  mirrorLagSeconds: number;
  send: SendOutcome;
  /** Filled in by the mock as transactions arrive. */
  sent: { to: string; data: string; value: string }[];
};

const now = () => Math.floor(Date.now() / 1000);

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
  orders: {},
  held: [],
  holders: {},
  logs: {},
  mirrorLagSeconds: 2,
  send: { kind: "success" },
  sent: [],
});

/** A realistic book for My orders: one order in every display state. */
export const withOrderBook = (s: Scenario): Scenario => {
  const t = now();
  const order = (o: Partial<ScenarioOrder>): ScenarioOrder => ({
    marketId: 1,
    side: 0,
    trigger: 0,
    status: 1,
    funded: true,
    slippageBps: 100,
    createdAt: t - 3_600,
    expiry: t + 5 * 86_400,
    amountIn: 250_00_000_000n,
    triggerPrice: 12_500_000n,
    budget: 12_07_710_000n,
    ...o,
  });
  s.orders = {
    "14": order({}),
    "13": order({ triggerPrice: 10_000_000n }),
    "12": order({ marketId: 2, trigger: 1, amountIn: 1_000_00_000_000n, triggerPrice: 99_500_000n, slippageBps: 30 }),
    "11": order({
      side: 1,
      trigger: 1,
      amountIn: 50_000_000n,
      triggerPrice: 9_800_000n,
      funded: false,
      budget: 69_060_000n,
    }),
    "2": order({ triggerPrice: 10_000_000n, createdAt: 1_790_702_900, amountIn: 20_00_000_000n }),
    "1": order({
      marketId: 2,
      status: 2,
      funded: false,
      budget: 0n,
      createdAt: 1_790_702_900,
      amountIn: 3_00_000_000n,
      triggerPrice: 99_000_000n,
    }),
    "9": order({
      status: 3,
      funded: false,
      budget: 0n,
      triggerPrice: 9_900_000n,
      trigger: 1,
      amountIn: 120_00_000_000n,
    }),
  };
  s.held = [14, 13, 12, 11, 9, 2, 1];
  s.logs = { "1": filledOrderLogs, "2": heldOrderLogs };
  return s;
};
