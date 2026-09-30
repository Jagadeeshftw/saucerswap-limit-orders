/**
 * Gas limits for calls that touch Hedera's system contracts.
 *
 * The JSON-RPC relay's eth_estimateGas simulates on the mirror node and undercounts HTS and HSS work: a placement
 * it estimated at 551,766 gas ran out, while the same placement uses up to 2,806,431 when it schedules a sweep.
 * So these calls carry explicit limits measured on testnet. Hedera bills the gas used, not the limit, so headroom
 * costs nothing; the wallet only needs limit x gas price available while the transaction runs.
 */
export const GAS_LIMIT = {
  /** Mint and transfer the order NFT, read the guard, schedule or bring forward a sweep: 2,806,431 measured. */
  placeOrder: 3_200_000n,
  /** Can restart a stopped sweep; scheduling alone is 1,410,346. */
  topUp: 2_000_000n,
  restartSweep: 2_000_000n,
  /** Guard read plus a token-in fill and settlement; a sweep that filled one order used ~0.9M beyond scheduling. */
  executeOrder: 2_000_000n,
  /** Refund and NFT wipe: 100,529 measured for an HBAR order. */
  cancel: 600_000n,
  claim: 400_000n,
  /** HTS allowance through the token's ERC-20 facade: 727,032 measured. */
  approve: 1_000_000n,
  /** HIP-719 associate() on the token: three associations measured 1.15M together. */
  associate: 1_000_000n,
} as const;

/** The most a call can cost at `gasPrice` (weibar per gas), in weibar. */
export const maxFee = (limit: bigint, gasPrice: bigint) => limit * gasPrice;
