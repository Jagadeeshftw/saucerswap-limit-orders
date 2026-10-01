# Glossary

Hedera and project terms used across this template.

## Hedera

- **HTS — Hedera Token Service.** Hedera's native token service, reachable from Solidity at the system contract
  `0x167`. Here it mints the order NFTs, moves USDC/DAI/WHBAR, and wipes an NFT at settlement. HTS tokens are
  also exposed as ERC-20/ERC-721, so ordinary `transfer`/`approve`/`ownerOf` work.
- **HSS — Hedera Schedule Service.** The scheduling service, at system contract `0x16b` (HIP-1215). A contract
  calls `scheduleCall` to have the network run a future call, and `hasScheduleCapacity` to check a second has
  room. This template uses it to run each market's sweeps with no bot.
- **HCS — Hedera Consensus Service.** Hedera's ordered-message log. **Not used by this template** — there is no
  messaging or audit-log need here; the on-chain events plus the mirror node cover the order trail.
- **Exchange-rate system contract (`0x168`).** Converts a USD-cent amount to tinybar at the live HBAR rate, so
  the vault can price gas budgets in cents and charge them in HBAR.
- **Mirror node.** Hedera's read API for history and state (transactions, logs, token balances, associations).
  The frontend reads order history and the trail from it; there is no indexer to run.
- **tinybar / weibar.** HBAR has 8 decimals on Hedera (a **tinybar** is 1e-8 HBAR). The EVM expresses value with
  18 decimals (a **weibar**), so `1 HBAR = 1e8 tinybar = 1e18 weibar` and `1 tinybar = 1e10 weibar`. Contracts
  see `msg.value` in tinybar; wallets and the JSON-RPC relay use weibar. `utils/orders/units.ts` is the only
  place amounts cross that boundary.
- **Association.** On Hedera an account must be **associated** with a token before it can hold it. The UI
  associates the order NFT collection and the output token for you (HIP-719 `associate()`), or the account needs
  free auto-association slots.
- **ECDSA vs ED25519 keys.** Hedera accounts can use either; the EVM tooling here (relay, wallet, deploy) needs
  an **ECDSA (secp256k1)** key, which has a matching `0x` EVM address.
- **Account id vs EVM address.** The same account has a Hedera id (`0.0.x`) and a 20-byte EVM address (`0x…`);
  the mirror node maps between them.
- **HashScan.** Hedera's block explorer. Every proof link in the README opens there.

## SaucerSwap and oracles

- **SaucerSwap V2.** The Uniswap-V3-style concentrated-liquidity DEX on Hedera. Fills route through its
  `exactInputSingle`, and the guard reads a pool's own **TWAP** via `observe`.
- **TWAP — time-weighted average price.** The pool's average price over a window (`twapWindow`), harder to
  manipulate than the spot price. The guard compares it to Chainlink.
- **Chainlink feed.** A price oracle (e.g. HBAR/USD, USDC/USD). The order's trigger and the swap's minimum-out
  are priced from Chainlink; the guard blocks a fill unless the pool TWAP is within `maxDeviationBps` of it.

## This template

- **OrderVault.** The contract that escrows orders, mints the NFTs, schedules the sweeps, and fills.
- **Order NFT.** Each order is an HTS NFT whose serial number is the order id. Whoever holds it can cancel it and
  receives the fill; transferring the NFT transfers the order.
- **The guard.** The check before every fill: fresh Chainlink feeds and a pool TWAP within a bounded deviation.
  It can be **Open**, or closed for `OracleStale`, `DeviationTooHigh`, etc.
- **Sweep.** One scheduled pass over a market's open orders: it fills the ones whose trigger is met and the guard
  allows, charges each checked order, and schedules the next sweep.
- **Budget.** The HBAR a maker prepays with an order to cover its scheduled checks. When it runs out the order is
  **parked** until topped up.
- **Distance-aware scheduling.** The next sweep waits roughly as long as the price would need to move to reach
  the nearest trigger (`wait = distanceBps × 3600 / maxMoveBpsPerHour`, clamped), so far-off orders are checked
  rarely and near ones often.
- **Escrow.** The input token the vault holds for an open order; refunded on cancel, swapped on fill.
- **Slippage.** The most the swap may give up versus the Chainlink price (`slippageBps`); the minimum-out is
  Chainlink's price less this.
- **restartSweep.** A permissionless call that reschedules a market whose sweep stopped (see the residual-stall
  note in the architecture doc).
