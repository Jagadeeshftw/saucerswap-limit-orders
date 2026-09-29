import { formatUnits, parseUnits } from "viem";

/**
 * Every unit conversion in the app lives here.
 *
 * Hedera has three HBAR scales:
 * - HBAR: what people read and type.
 * - tinybar (8 decimals): what contracts see in msg.value, balances and return values.
 * - weibar (18 decimals): what the JSON-RPC relay and wallets use for `value` and eth_getBalance.
 *
 * Prices are "quote per 1 base" with 8 decimals, the same scale as Chainlink USD feeds and OrderVault.
 */

export const HBAR_DECIMALS = 8;
export const PRICE_DECIMALS = 8;
const WEIBAR_PER_TINYBAR = 10n ** 10n;

/** Contract amount (tinybar) to wallet `value` (weibar). */
export const tinybarToWeibar = (tinybar: bigint): bigint => tinybar * WEIBAR_PER_TINYBAR;

/** Wallet or RPC balance (weibar) to contract units (tinybar), rounding down. */
export const weibarToTinybar = (weibar: bigint): bigint => weibar / WEIBAR_PER_TINYBAR;

/** Parse user input into raw units. Returns null for empty, malformed or over-precise input. */
export const parseAmount = (input: string, decimals: number): bigint | null => {
  const value = input.trim();
  if (!/^\d+(\.\d+)?$/.test(value)) return null;
  const fraction = value.split(".")[1] ?? "";
  if (fraction.length > decimals) return null;
  return parseUnits(value, decimals);
};

/** Format raw units for display with at most `maxFraction` decimals and thousands separators. */
export const formatAmount = (raw: bigint, decimals: number, maxFraction = 4): string => {
  const [whole, fraction = ""] = formatUnits(raw, decimals).split(".");
  const trimmed = fraction.slice(0, maxFraction).replace(/0+$/, "");
  const grouped = BigInt(whole).toLocaleString("en-US");
  return trimmed ? `${grouped}.${trimmed}` : grouped;
};

export const formatHbar = (tinybar: bigint, maxFraction = 4): string =>
  `${formatAmount(tinybar, HBAR_DECIMALS, maxFraction)} HBAR`;

/** A price with 8 decimals, shown with 4 by default (e.g. 0.1047). */
export const formatPrice = (priceE8: bigint, fractionDigits = 4): string => {
  const [whole, fraction = ""] = formatUnits(priceE8, PRICE_DECIMALS).split(".");
  return `${whole}.${fraction.padEnd(fractionDigits, "0").slice(0, fractionDigits)}`;
};

export const parsePrice = (input: string): bigint | null => parseAmount(input, PRICE_DECIMALS);

/** Basis points as a percentage string: 50 -> "0.50%". */
export const formatBps = (bps: bigint | number): string => `${(Number(bps) / 100).toFixed(2)}%`;

/** True for Hedera "long-zero" addresses, which encode the entity number directly (0x000…1549). */
export const isLongZero = (address: string) => /^0x0{24}/i.test(address);

/** A Hedera long-zero EVM address (0x…1549) as its entity id (0.0.5449). */
export const entityIdFromAddress = (address: string): string => `0.0.${BigInt(address)}`;

/** Entity id (0.0.5449) as the long-zero EVM address the relay accepts. */
export const addressFromEntityId = (entityId: string): `0x${string}` => {
  const num = BigInt(entityId.split(".")[2] ?? "0");
  return `0x${num.toString(16).padStart(40, "0")}`;
};

/** Mirror-node consensus timestamps ("1790703232.028766192") as JS dates. */
export const dateFromConsensus = (timestamp: string): Date => new Date(Number(timestamp.split(".")[0]) * 1000);
