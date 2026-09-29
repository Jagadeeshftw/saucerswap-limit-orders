# Agent instructions

Briefing for coding agents in this app (Cursor, Claude Code, Codex). Claude Code loads it through `CLAUDE.md`.

This is a Scaffold-HBAR template for keeperless limit and stop orders on SaucerSwap V2. `OrderVault` escrows orders, represents each one as an HTS NFT, and schedules its own market sweeps through the Hedera Schedule Service (HIP-1215). Before filling, it checks the pool TWAP against Chainlink.

Use the package manager this project was created with (`packageManager` in the root `package.json`, or the lockfile). Examples use `yarn`; with npm, swap `yarn <script>` for `npm run <script>`.

## Packages

- `packages/foundry`: contracts, Forge scripts and tests
- `packages/nextjs`: the frontend (App Router, RainbowKit, Wagmi, Viem, DaisyUI)

## Commands

```bash
yarn next:dev              # frontend against the deployed testnet vault
yarn foundry:deploy        # deploy your own vault to Hedera testnet (~25 HBAR)
yarn foundry:account:import

yarn lint
yarn format
yarn next:check-types
yarn next:build

yarn foundry:test          # unit, fuzz, invariant (mocked system contracts)
yarn foundry:test:fork     # guard against real testnet pools and feeds
yarn next:test             # vitest units
yarn next:test:e2e         # Playwright, 1440 and 390 widths
```

There is no local chain. Anvil has no Schedule Service (`0x16b`), Token Service (`0x167`) or exchange-rate contract (`0x168`). Tests etch mocks of them, from `test/mocks/MockHederaSystem.sol`, at those addresses.

## Contracts

- `contracts/OrderVault.sol`: place, cancel, top up, sweep, fill, settle and claim, plus the cost views.
- `contracts/libraries/MarketGuard.sol`: an external library, which keeps OrderVault under 24 KB. It reads the Chainlink feeds and the pool TWAP.
- `contracts/libraries/PriceMath.sol`: tick math, cross prices and bps helpers.
- `contracts/types/OrderTypes.sol`: the enums and structs shared across contracts, tests and the ABI.
- `script/MarketConfig.sol`: testnet addresses, the two markets and the calibrated gas costs.

Rules that matter when you change the vault:

- **Size.** OrderVault must stay under 24,576 bytes (`forge build --sizes`). Move logic into a library rather than turning off the check.
- **Errors and events.** Use custom errors and events for every state change. The frontend decodes the order trail from events alone, via `utils/orders/trail.ts`.
- **HTS calls.** Check the response code. Settlement must never revert a sweep: `_retireNft` and `_pay` report failure through events and credits.
- **Scheduled calls.** Inside a scheduled call, `msg.sender == tx.origin == address(vault)`. The vault pays for its own schedules, so keep `surplus()` and the check budgets consistent. The invariant tests enforce this.
- **Costs.** Change them in `MarketConfig.costs()` and on-chain with `setCosts`. Never hard-code them in the frontend.

### After deploy

`yarn foundry:deploy` writes ABIs and addresses to `packages/nextjs/contracts/deployedContracts.ts`. Third-party contracts go in `packages/nextjs/contracts/externalContracts.ts`.

## Frontend

- Pages: `app/page.tsx` (Trade, `?market=<id>`), `app/orders/page.tsx` (My orders) and `app/orders/[id]/page.tsx` (order detail and trail).
- `hooks/orders/`: vault reads (`useMarkets`, `useOrders`), wallet setup (`useWallet`: associations, balances, allowances) and transaction state (`useVaultTx`).
- `services/mirror.ts`: mirror-node queries. Topic-filtered log queries need a timestamp range under 7 days, so `fetchLogs` splits the range into windows.
- `utils/orders/units.ts`: the only place amounts and prices are converted. HBAR has 8 decimals as tinybar and 18 as weibar in the EVM `value`.
- `utils/orders/errors.ts`: maps vault custom errors to readable messages. Add an entry when you add an error.

Generic Scaffold-HBAR hooks live in `hooks/scaffold-hbar` (`useScaffoldReadContract`, `useScaffoldWriteContract`, `useDeployedContractInfo`, `useTransactor`). Web3 UI components come from `@scaffold-hbar-ui/components`.

UI rules: use DaisyUI classes, no motion, and every state must look right at 1440 and 390 in light and dark. Every UI state has a Playwright test in `e2e/orders.spec.ts`, backed by the mocks in `e2e/support/`.

## Style

| Style | Use |
| --- | --- |
| `UpperCamelCase` | types, components, contracts |
| `lowerCamelCase` | variables, functions |
| `CONSTANT_CASE` | constants |
| `snake_case` | Foundry scripts |

Next.js imports use the `~~` alias. Prefer `type` over `interface`, and let TypeScript infer when it can. Solidity uses NatSpec on external functions and custom errors, not revert strings. Comments should add information.
