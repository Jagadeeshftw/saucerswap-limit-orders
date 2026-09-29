# Foundry package

The `OrderVault` contracts, the deploy script and the tests. For how orders run, see the [root README](../../README.md).

## Setup

forge-std is a git submodule; OpenZeppelin comes from npm.

```bash
git submodule update --init --recursive
yarn install
```

## Test

```bash
yarn foundry:test          # from the repo root; or `forge test` here
yarn foundry:test:fork     # FORK_TESTS=true, reads the real testnet pools and Chainlink feeds
```

- `test/OrderVault.t.sol` is the unit test suite: placement, sweeps, fills, guard holds, budgets, expiry, cancel, top-up, claims and admin.
- `test/PriceMath.t.sol` has unit and fuzz tests for the tick and price math.
- `test/OrderVault.invariant.t.sol` holds the handler-driven invariants: escrow and budgets, solvency, credits, bookkeeping, and no NFT left on a settled order.
- `test/MarketGuard.fork.t.sol` runs the guard against testnet state. It is skipped unless `FORK_TESTS=true`.
- `test/mocks/` has mocks of the Hedera system contracts, etched at `0x167`, `0x16b` and `0x168`, plus a mock SaucerSwap pool, router, tokens and feeds.

Anvil has none of Hedera's system contracts, so the suite runs against these mocks. The fork test and the testnet deployment cover the real ones.

## Deploy

```bash
yarn foundry:account:import      # or account:generate, then fund it from the faucet
yarn foundry:deploy              # Hedera testnet (the default network)
```

`script/Deploy.s.sol` deploys `OrderVault` and creates its HTS NFT collection, which costs about 15 HBAR (the script sends 20; the rest becomes withdrawable surplus). It then lists the markets from `script/MarketConfig.sol`.

Before broadcasting, forge runs the script locally, and a local fork has no HTS. So the script mocks HTS for that pass only, gives each HTS call an explicit gas limit, and the Makefile deploys with `--skip-simulation`.

When the deploy finishes, `scripts-js/generateTsAbis.js` writes `packages/nextjs/contracts/deployedContracts.ts`.

## Verify

```bash
yarn foundry:verify:testnet <address> contracts/OrderVault.sol:OrderVault
```

Hedera is supported on the main Sourcify instance.
