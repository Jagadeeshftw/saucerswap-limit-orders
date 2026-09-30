import deployedContracts from "../../contracts/deployedContracts";
import {
  ACCOUNT,
  ACCOUNT_ID,
  COLLECTION,
  COLLECTION_ID,
  DAI,
  POOL_DAI,
  POOL_HBAR,
  type Scenario,
  USDC,
  VAULT_ID,
  WHBAR,
} from "./scenario";
import type { Page, Route } from "@playwright/test";
import {
  type Abi,
  type AbiFunction,
  type AbiParameter,
  decodeFunctionData,
  encodeAbiParameters,
  encodeErrorResult,
  encodeEventTopics,
  encodeFunctionResult,
  erc20Abi,
  keccak256,
  pad,
  toFunctionSelector,
  toHex,
  zeroAddress,
} from "viem";

const vault = deployedContracts[296].OrderVault;
const vaultAbi = vault.abi as Abi;
const VAULT = vault.address.toLowerCase();
const RPC = "https://testnet.hashio.io/api";
const MIRROR = "https://testnet.mirrornode.hedera.com";
const GAS_PRICE = 1_090_000_000_000n; // 109 tinybar per gas, in weibar
const ROUTER = "0x0000000000000000000000000000000000159398";

const MARKETS = {
  1: {
    base: WHBAR,
    quote: USDC,
    baseDecimals: 8,
    quoteDecimals: 6,
    baseIsHbar: true,
    quoteIsHbar: false,
    baseFeed: "0x59bc155eb6c6c415fe43255af66ecf0523c92b4a",
    quoteFeed: "0xb632a7e7e02d76c0ce99d9c62c7a2d1b5f92b6b5",
    baseFeedDecimals: 8,
    quoteFeedDecimals: 8,
    pool: POOL_HBAR,
    poolFee: 3000,
    baseIsToken0: false,
    active: true,
    guard: { twapWindow: 1800, maxDeviationBps: 200, maxOracleAge: 90_000, maxSlippageBps: 300 },
    sweep: { minInterval: 300, maxInterval: 21_600, maxMoveBpsPerHour: 250, maxOrders: 20, maxFills: 3 },
  },
  2: {
    base: DAI,
    quote: USDC,
    baseDecimals: 8,
    quoteDecimals: 6,
    baseIsHbar: false,
    quoteIsHbar: false,
    baseFeed: "0xda2abf7c90adc73cdf5ca8d720b87bd5f5863389",
    quoteFeed: "0xb632a7e7e02d76c0ce99d9c62c7a2d1b5f92b6b5",
    baseFeedDecimals: 8,
    quoteFeedDecimals: 8,
    pool: POOL_DAI,
    poolFee: 500,
    baseIsToken0: false,
    active: true,
    guard: { twapWindow: 1800, maxDeviationBps: 100, maxOracleAge: 90_000, maxSlippageBps: 100 },
    sweep: { minInterval: 300, maxInterval: 21_600, maxMoveBpsPerHour: 25, maxOrders: 20, maxFills: 3 },
  },
} as const;

/**
 * Costs as the reference vault reported them on testnet (tinybar), and the vault's sharing rule:
 * each order pays an even share of the sweep's fixed gas plus its own check gas.
 */
// checkCost and fillCost (the fill plus the final check) as the live vault 0.0.10787941 returned them.
const COSTS = { checkCost: 189_774_952n, fillHbarIn: 87_680_832n, fillTokenIn: 123_714_051n };
const FIXED_GAS = 1_520_000n;
const CHECK_GAS = 60_000n;
const checkShared = (orders: bigint) => {
  const n = orders === 0n ? 1n : orders;
  const gas = (FIXED_GAS + n - 1n) / n + CHECK_GAS;
  return (gas * COSTS.checkCost) / (FIXED_GAS + CHECK_GAS);
};
const minBudget = (side: number, marketId: number) =>
  (marketId === 1 && side === 0 ? COSTS.fillHbarIn : COSTS.fillTokenIn) + 6n * COSTS.checkCost;

/** Zero value of an ABI parameter, for the views only the Debug page reads. */
const zeroOf = (param: AbiParameter): unknown => {
  if (param.type.endsWith("]")) return [];
  if (param.type === "tuple") {
    const { components } = param as { components: readonly AbiParameter[] };
    return Object.fromEntries(components.map(c => [c.name, zeroOf(c)]));
  }
  if (param.type === "address") return zeroAddress;
  if (param.type === "bool") return false;
  if (param.type === "string") return "";
  if (param.type === "bytes") return "0x";
  if (param.type.startsWith("bytes")) return pad("0x0", { size: Number(param.type.slice(5)) });
  return 0n;
};

/** The vault's scheduling rule: wait as long as the price needs to reach the trigger, within the market's bounds. */
const checkDelay = (marketId: number, trigger: number, triggerPrice: bigint, expiry: number, s: Scenario) => {
  const { minInterval, maxInterval, maxMoveBpsPerHour } = MARKETS[marketId as 1 | 2].sweep;
  const price = s.guards[marketId].oraclePrice;
  const met = trigger === 0 ? price >= triggerPrice : price <= triggerPrice;
  const diff = triggerPrice > price ? triggerPrice - price : price - triggerPrice;
  const distance = met ? 0n : (diff * 10_000n) / price;
  let wait = Number((distance * 3600n) / BigInt(maxMoveBpsPerHour));
  wait = Math.min(wait, maxInterval, Math.max(0, expiry - Math.floor(Date.now() / 1000)));
  return Math.max(wait, minInterval);
};

/** A stalled market's last schedule was due 25 minutes ago; a live one fires in about 3 hours. */
const nextSweepAt = (s: Scenario, marketId: number) =>
  Math.floor(Date.now() / 1000) + (s.stalled.includes(marketId) ? -1_500 : 10_800);

const vaultCall = (s: Scenario, data: `0x${string}`) => {
  const { functionName, args = [] } = decodeFunctionData({ abi: vaultAbi, data });
  const result = (value: unknown) => encodeFunctionResult({ abi: vaultAbi, functionName, result: value as never });
  const a = args as readonly unknown[];
  switch (functionName) {
    case "marketCount":
      return result(2);
    case "getMarket":
      return result(MARKETS[Number(a[0]) as 1 | 2]);
    case "guardReading":
      return result(s.guards[Number(a[0])]);
    case "collection":
      return result(COLLECTION);
    case "checkCost":
      return result(COSTS.checkCost);
    case "checkCostShared":
      return result(checkShared(a[0] as bigint));
    case "fillCost":
      return result(Number(a[0]) === 1 && Number(a[1]) === 0 ? COSTS.fillHbarIn : COSTS.fillTokenIn);
    case "minBudget":
      return result(minBudget(Number(a[1]), Number(a[0])));
    case "sweeps":
      return result([VAULT, BigInt(nextSweepAt(s, Number(a[0]))), 0, s.fundedOrders[Number(a[0])] ?? 0, 1, 0]);
    case "sweepStatus": {
      const id = Number(a[0]);
      if (!s.fundedOrders[id]) return result([0, 0n]);
      return result([s.stalled.includes(id) ? 2 : 1, BigInt(nextSweepAt(s, id))]);
    }
    case "nextCheckDelay":
      return result(BigInt(checkDelay(Number(a[0]), Number(a[1]), a[2] as bigint, Number(a[3]), s)));
    case "getOrder": {
      const o = s.orders[String(a[0])];
      return result(
        o ?? {
          marketId: 0,
          side: 0,
          trigger: 0,
          status: 0,
          funded: false,
          slippageBps: 0,
          createdAt: 0,
          expiry: 0,
          amountIn: 0n,
          triggerPrice: 0n,
          budget: 0n,
        },
      );
    }
    case "holderOf":
      return result(s.holders[String(a[0])] ?? ACCOUNT);
    case "owner":
      return result(ACCOUNT);
    case "ROUTER":
      return result(ROUTER);
    case "WHBAR":
      return result(WHBAR);
    default: {
      const { outputs } = vaultAbi.find(i => i.type === "function" && i.name === functionName) as AbiFunction;
      return result(outputs.length === 1 ? zeroOf(outputs[0]) : outputs.map(zeroOf));
    }
  }
};

const tokenCall = (s: Scenario, to: string, data: `0x${string}`) => {
  const token = s.tokens[to];
  const { functionName } = decodeFunctionData({ abi: erc20Abi, data });
  const result = (value: unknown) => encodeFunctionResult({ abi: erc20Abi, functionName, result: value as never });
  if (functionName === "symbol") return result(token.symbol);
  if (functionName === "decimals") return result(to === USDC ? 6 : 8);
  if (functionName === "balanceOf") return result(token.balance);
  if (functionName === "allowance") return result(token.allowance);
  throw new Error(`mock has no answer for ${token.symbol}.${functionName}`);
};

const revertData = (s: Scenario) =>
  s.send.kind === "revert"
    ? encodeErrorResult({ abi: vaultAbi, errorName: s.send.errorName, args: s.send.args as never })
    : "0x";

let txCounter = 0;
const receipts = new Map<string, { polls: number; confirmAfter: number; logs: unknown[] }>();

/** Apply a successful transaction to the scenario and return the logs its receipt carries. */
const ASSOCIATE = toFunctionSelector("function associate()");
const ENTITY_IDS: Record<string, string> = { [COLLECTION]: COLLECTION_ID, [USDC]: "0.0.5449", [DAI]: "0.0.5529" };

const execute = (s: Scenario, tx: { to: string; data: `0x${string}`; value?: string }) => {
  if (tx.data.startsWith(ASSOCIATE)) {
    s.associations.push(ENTITY_IDS[tx.to]);
    return [];
  }
  if (s.tokens[tx.to]) {
    const { functionName, args = [] } = decodeFunctionData({ abi: erc20Abi, data: tx.data });
    if (functionName === "approve") s.tokens[tx.to].allowance = (args as readonly bigint[])[1] as bigint;
    return [];
  }
  if (tx.to !== VAULT) return [];
  const { functionName, args = [] } = decodeFunctionData({ abi: vaultAbi, data: tx.data });
  if (functionName === "restartSweep") {
    s.stalled = s.stalled.filter(id => id !== Number((args as readonly bigint[])[0]));
    return [];
  }
  if (functionName !== "placeOrder") return [];
  const p = (args as readonly any[])[0];
  const id = Math.max(20, ...Object.keys(s.orders).map(Number)) + 1;
  const value = BigInt(tx.value ?? "0x0") / 10n ** 10n;
  const budget = p.marketId === 1 && p.side === 0 ? value - p.amountIn : value;
  s.orders[String(id)] = {
    marketId: p.marketId,
    side: p.side,
    trigger: p.trigger,
    status: 1,
    funded: true,
    slippageBps: p.slippageBps,
    createdAt: Math.floor(Date.now() / 1000),
    expiry: p.expiry,
    amountIn: p.amountIn,
    triggerPrice: p.triggerPrice,
    budget,
  };
  s.held.push(id);
  const topics = encodeEventTopics({
    abi: vaultAbi,
    eventName: "OrderPlaced",
    args: { orderId: BigInt(id), marketId: BigInt(p.marketId), maker: ACCOUNT },
  });
  const data = encodeAbiParameters(
    [
      { type: "uint8" },
      { type: "uint8" },
      { type: "uint256" },
      { type: "uint256" },
      { type: "uint256" },
      { type: "uint256" },
      { type: "uint256" },
    ],
    [p.side, p.trigger, p.amountIn, p.triggerPrice, BigInt(p.slippageBps), BigInt(p.expiry), budget],
  );
  return [
    {
      address: VAULT,
      topics,
      data,
      logIndex: "0x0",
      blockNumber: "0x1",
      transactionIndex: "0x0",
      blockHash: pad("0x1"),
      removed: false,
    },
  ];
};

const rpc = (s: Scenario, method: string, params: any[]): { result?: unknown; error?: unknown } => {
  switch (method) {
    case "eth_chainId":
      return { result: toHex(296) };
    case "net_version":
      return { result: "296" };
    case "eth_blockNumber":
      return { result: toHex(Math.floor(Date.now() / 2000)) };
    case "eth_gasPrice":
      return { result: toHex(GAS_PRICE) };
    case "eth_getBalance":
      return { result: toHex(s.hbarTinybar * 10n ** 10n) };
    case "eth_getTransactionCount":
      return { result: "0x1" };
    case "eth_estimateGas":
      return s.send.kind === "revert"
        ? { error: { code: 3, message: "execution reverted", data: revertData(s) } }
        : { result: toHex(2_750_000) };
    case "eth_call": {
      const { to, data } = params[0];
      const target = String(to).toLowerCase();
      if (target === VAULT) return { result: vaultCall(s, data) };
      if (s.tokens[target]) return { result: tokenCall(s, target, data) };
      return { result: "0x" };
    }
    case "eth_getBlockByNumber":
      return {
        result: {
          number: toHex(1),
          timestamp: toHex(Math.floor(Date.now() / 1000)),
          baseFeePerGas: toHex(GAS_PRICE),
          hash: pad("0x1"),
          transactions: [],
        },
      };
    case "eth_sendTransaction": {
      const tx = params[0];
      s.sent.push({ to: tx.to, data: tx.data, value: tx.value ?? "0x0" });
      if (s.send.kind === "rejected") return { error: { code: 4001, message: "User rejected the request." } };
      if (s.send.kind === "revert") return { error: { code: 3, message: "execution reverted", data: revertData(s) } };
      const hash = keccak256(toHex(`tx-${++txCounter}-${Date.now()}`));
      receipts.set(hash, {
        polls: 0,
        confirmAfter: s.send.confirmAfterPolls ?? 0,
        logs: execute(s, { ...tx, to: String(tx.to).toLowerCase() }),
      });
      return { result: hash };
    }
    case "eth_getTransactionReceipt": {
      const r = receipts.get(params[0]);
      if (!r || r.polls++ < r.confirmAfter) return { result: null };
      return {
        result: {
          transactionHash: params[0],
          status: "0x1",
          blockNumber: "0x1",
          blockHash: pad("0x1"),
          transactionIndex: "0x0",
          from: ACCOUNT,
          to: VAULT,
          gasUsed: toHex(2_700_000),
          cumulativeGasUsed: toHex(2_700_000),
          effectiveGasPrice: toHex(GAS_PRICE),
          logs: r.logs,
          logsBloom: pad("0x0", { size: 256 }),
          type: "0x2",
          contractAddress: null,
        },
      };
    }
    case "eth_getTransactionByHash":
      return { result: null };
    case "eth_getCode":
      // The Debug page only checks that code exists at the vault address.
      return { result: String(params[0]).toLowerCase() === VAULT ? "0x6080604052" : "0x" };
    default:
      return { error: { code: -32601, message: `mock RPC does not support ${method}` } };
  }
};

const handleRpc = (s: Scenario) => async (route: Route) => {
  const body = route.request().postDataJSON();
  const answer = (req: { id: number; method: string; params?: any[] }) => ({
    jsonrpc: "2.0",
    id: req.id,
    ...rpc(s, req.method, req.params ?? []),
  });
  await route.fulfill({
    contentType: "application/json",
    body: JSON.stringify(Array.isArray(body) ? body.map(answer) : answer(body), (_, v) =>
      typeof v === "bigint" ? toHex(v) : v,
    ),
  });
};

const placedLog = (id: string) => ({
  address: VAULT,
  topics: encodeEventTopics({
    abi: vaultAbi,
    eventName: "OrderPlaced",
    args: { orderId: BigInt(id), marketId: 1n, maker: ACCOUNT },
  }),
  data: "0x",
  timestamp: "1790702932.000000000",
  transaction_hash: pad(toHex(Number(id))),
});

const handleMirror = (s: Scenario) => async (route: Route) => {
  const url = new URL(route.request().url());
  // wagmi sends checksummed addresses; the mirror node treats them case-insensitively.
  const path = url.pathname.toLowerCase();
  const json = (body: unknown, status = 200) =>
    route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });
  if (path === "/api/v1/blocks") {
    return json({ blocks: [{ timestamp: { to: `${Math.floor(Date.now() / 1000) - s.mirrorLagSeconds}.000000000` } }] });
  }
  if (path === `/api/v1/accounts/${ACCOUNT}`) {
    if (!s.mirrorAccount) return json({ _status: { messages: [{ message: "Not found" }] } }, 404);
    return json({
      account: s.mirrorAccount.id,
      evm_address: ACCOUNT,
      max_automatic_token_associations: s.mirrorAccount.maxAutoAssociations,
      balance: { balance: Number(s.hbarTinybar) },
    });
  }
  if (path === `/api/v1/accounts/${ACCOUNT_ID}/tokens`) {
    const tokenId = url.searchParams.get("token.id");
    return json({ tokens: s.associations.includes(tokenId ?? "") ? [{ token_id: tokenId, balance: 0 }] : [] });
  }
  if (path === `/api/v1/accounts/${ACCOUNT_ID}/nfts`) {
    return json({
      nfts: s.held
        .filter(id => s.orders[String(id)]?.status === 1)
        .map(serial_number => ({ serial_number, token_id: COLLECTION_ID })),
      links: { next: null },
    });
  }
  if (path === `/api/v1/contracts/${POOL_HBAR}`) return json({ contract_id: "0.0.9283328" });
  if (path === `/api/v1/contracts/${POOL_DAI}`) return json({ contract_id: "0.0.2661063" });
  if (path === `/api/v1/contracts/${VAULT}`) return json({ contract_id: VAULT_ID });
  if (path === `/api/v1/contracts/${VAULT}/results/logs`) {
    const topic1 = url.searchParams.get("topic1");
    if (topic1) {
      const id = String(BigInt(topic1));
      const logs = (s.logs[id] ?? []) as { timestamp: string }[];
      const [from, to] = url.searchParams.getAll("timestamp").map(t => Number(t.split(":")[1]));
      return json({
        logs: logs.filter(l => Number(l.timestamp) >= from && Number(l.timestamp) <= to),
        links: { next: null },
      });
    }
    return json({ logs: s.held.map(String).map(placedLog), links: { next: null } });
  }
  return json({ _status: { messages: [{ message: `mock has no ${path}` }] } }, 404);
};

/** Serve the scenario to the page: JSON-RPC, mirror node and third-party calls never leave the browser. */
export const mockNetwork = async (page: Page, s: Scenario) => {
  await page.route(`${RPC}**`, handleRpc(s));
  await page.route(`${MIRROR}/**`, handleMirror(s));
  await page.route("https://api.coingecko.com/**", route =>
    route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({ market_data: { current_price: { usd: 0.1034 } } }),
    }),
  );
  await page.route(/walletconnect|web3modal|reown|coinbase|cca-lite/, route => route.abort());
};
