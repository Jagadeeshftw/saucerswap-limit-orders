# Going to mainnet — checklist

This template ships pointed at Hedera **testnet**. It is a starting point, not an audited production system.
Work through this before putting real value on it. (Skeleton — expanded per step as the template matures.)

## Contracts and config

- [ ] **Audit.** Have `OrderVault`, the libraries, and any custom order types reviewed before mainnet.
- [ ] **Mainnet addresses** in `script/MarketConfig.sol`. For HBAR/USDC: SaucerSwap V2 router `0.0.3949434`,
      WHBAR `0.0.1456986` (8 dp), **native** USDC `0.0.456858` (6 dp, not the bridged USDC[hts]), the
      HBAR/USDC pool `0.0.3964804` at **fee tier 1500 (0.15%)** — note testnet uses 0.3%. Set the correct
      `poolFee` and keep `maxSlippageBps > poolFee/100`.
- [ ] **Chainlink mainnet feeds:** HBAR/USD `0xAF68…b5d5`, USDC/USD `0x2b35…349F` (8 dp). Set `maxOracleAge` to
      the feeds' heartbeat (mainnet HBAR/USD is ~24 h, so keep it generous — e.g. 26 h) so a fresh feed is never
      wrongly treated as stale.
- [ ] **Allow chain 295** in `Deploy.s.sol` (it restricts to testnet today) and add the network to
      `scaffold.config.ts` so the frontend offers it.
- [ ] **Recalibrate costs.** Measure a few scheduled sweeps on mainnet (`gas_used` on the mirror node) and set
      `MarketConfig.costs()` / `setCosts` to mainnet gas and the mainnet HBAR price, so budgets stay honest.
- [ ] **Fund the payer float.** Deploy sends 10 HBAR via `fund()`; size it to at least one costliest sweep at
      mainnet prices, and keep surplus above the float so a withdrawal can't starve the keeper.

## Market sanity

- [ ] **Liquidity and depth.** Confirm each market's pool has enough liquidity that a fill's slippage stays
      inside `maxSlippageBps`, and that the TWAP window is long enough to resist manipulation for that depth.
- [ ] **Guard opens on the real pool.** Run `yarn foundry:fork-guard` against mainnet (and the same for any new
      market) to confirm the guard actually opens where you expect it to.

## Frontend and ops

- [ ] **Your own WalletConnect project id** (`NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID`, from cloud.reown.com, with
      your domains allow-listed) in `.env.local` or your host's environment; the fallback is the scaffold's shared
      id, fine for local testing only. See [Configuration](../README.md#configuration).
- [ ] **Mainnet RPC and mirror node** URLs in the frontend env, and a relay you trust for signing.
- [ ] **Monitoring.** Watch `SweepScheduleFailed` / `Stalled` markets and low order budgets, and have a way to
      call `restartSweep` / top up if a market stalls (anyone can, but someone should be watching).
- [ ] **Keys.** Deploy from a hardware or keystore-held key, never a key in a file; rotate the demo/testnet keys
      out.

## After deploy

- [ ] Regenerate `deployedContracts.ts`, re-run the e2e against the mainnet vault, and update the README
      addresses and proofs to mainnet.
