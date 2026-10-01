# Agent instructions

Briefing for coding agents in this app (Cursor, Claude Code, Codex). Claude Code loads it through `CLAUDE.md`.

This is a Scaffold-HBAR template for keeperless limit and stop orders on SaucerSwap V2. `OrderVault` escrows orders, represents each one as an HTS NFT, and schedules its own market sweeps through the Hedera Schedule Service (HIP-1215). Before filling, it checks the pool TWAP against Chainlink.

Use the package manager this project was created with (`packageManager` in the root `package.json`, or the lockfile). The examples below are written for it; with npm, flags for a script go after `--`.

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

yarn foundry:test          # unit, fuzz, invariant, differential (mocked system contracts)
yarn foundry:test:fork     # guard against real testnet pools and feeds
yarn next:test             # vitest units
yarn next:test:e2e         # Playwright, 1440 and 390 widths
```

There is no local chain. Anvil has no Schedule Service (`0x16b`), Token Service (`0x167`) or exchange-rate contract (`0x168`). Tests etch mocks of them, from `test/mocks/MockHederaSystem.sol`, at those addresses.

## Contracts

- `contracts/OrderVault.sol`: place, cancel, top up, sweep, fill, settle and claim, and the order-type registry (`registerOrderType`, `setOrderTypeActive`). Raw getters only; the derived views live in the lens.
- `contracts/OrderVaultLens.sol`: read-only previews for the frontend and Debug page (`minBudget`, `checkCost`, `checkCostShared`, `fillCost`, `nextCheckDelay`, `orderNextCheckDelay`, `sweepStatus`, `sweepGasLimit`, `previewCharges`, `nextBatch`, `payerFloat`, `surplus`), computed from the vault's raw state.
- `contracts/interfaces/IOrderType.sol` and `contracts/ordertypes/`: the order-type plug-in interface and the three shipped types (limit 0, stop 1, trailing stop 2).
- `contracts/libraries/SweepMath.sol`: an internal library with every number the vault charges or schedules by, compiled into both the vault and the lens.
- `contracts/libraries/Settlement.sol`, `MarketRegistry.sol`, `MarketGuard.sol`, `OrderCollection.sol`: external libraries, which keep OrderVault small. Settlement does the swap, HTS and ERC-20 moves; MarketRegistry lists and tunes markets; MarketGuard reads the Chainlink feeds and the pool TWAP and bounds the guard settings; OrderCollection creates the order NFT collection once.
- `contracts/libraries/PriceMath.sol`: tick math, cross prices and bps helpers.
- `contracts/types/OrderTypes.sol`: the enums and structs shared across contracts, tests and the ABI.
- `script/MarketConfig.sol`: testnet addresses, the two markets (guard and sweep parameters) and the gas costs measured on testnet.

Read `docs/ARCHITECTURE.md` before changing how sweeps are scheduled or charged.

Rules that matter when you change the vault:

- **Size.** OrderVault must stay under 24,576 bytes (`forge build --sizes`); it is at 21,254, so 3,322 bytes free. Put new UI reads in `OrderVaultLens` (shared arithmetic in `SweepMath`) and cold, owner-only code in an external library like `MarketRegistry`; keep code every sweep runs in the vault, since a library call costs a cold `delegatecall` each time. See README "Extending the vault".
- **Order types.** A new kind of order is an `IOrderType` contract registered with `registerOrderType`, not a vault change. `evaluate` must return 0 only when the trigger is met (the vault fills on 0); use `PriceMath.distanceBps` for an unmet trigger. Strategies are `view` and reached by `staticcall`, so they cannot move funds; the vault still enforces the guard and its own Chainlink floor.
- **Errors and events.** Use custom errors and events for every state change. The frontend decodes the order trail from events alone, via `utils/orders/trail.ts`.
- **HTS calls.** Check the response code. Settlement must never revert a sweep: `_retireNft` and `_pay` report failure through events and credits.
- **Scheduled calls.** Inside a scheduled call, `msg.sender == tx.origin == address(vault)`. Each schedule carries an epoch; a sweep with a stale epoch must return without touching orders. The vault pays for its own schedules, so every sweep must be charged to some order: routine checks to the batch, the final sweep to parking orders, superseded and empty runs to the order that caused them. The invariant tests enforce solvency and liveness (no funded order goes unchecked, no scheduled sweep reverts).
- **Scheduling cost.** `scheduleCall` is a fixed network fee of about 1.56 HBAR (≈ $0.12 on 2026-09-29) whatever the gas limit or delay. Reduce cost by scheduling fewer sweeps (`SweepParams`: `minInterval`, `maxInterval`, `maxMoveBpsPerHour`), not by tuning gas limits.
- **Costs.** Change them in `MarketConfig.costs()` and on-chain with `setCosts`. After changing the sweep path, run `forge test --match-contract GasMeasure --isolate -vv` (v1.0.1 vs this vault, each sweep in its own transaction) and fold the difference in. Never hard-code costs in the frontend.

### After deploy

`yarn foundry:deploy` writes ABIs and addresses to `packages/nextjs/contracts/deployedContracts.ts`. Third-party contracts go in `packages/nextjs/contracts/externalContracts.ts`.

## Frontend

- Pages: `app/page.tsx` (Trade, `?market=<id>`), `app/orders/page.tsx` (My orders) and `app/orders/[id]/page.tsx` (order detail and trail).
- `hooks/orders/`: vault reads (`useMarkets`, `useMyOrders`, `useOrder`, `useOrderTrail`, `useSweepStatus`, `useCheckDelays`), wallet setup (`useWallet`: associations, balances, allowances) and transaction state (`useVaultTx`).
- `utils/orders/budget.ts`: sizes a budget to an order's lifetime from the vault's `nextCheckDelay` and cost views.
- `components/orders/SweepStatusBanner.tsx`: the "Checks stopped" state with a restart button.
- `services/mirror.ts`: mirror-node queries. Topic-filtered log queries need a timestamp range under 7 days, so `fetchLogs` splits the range into windows.
- `utils/orders/units.ts`: the only place amounts and prices are converted. HBAR has 8 decimals as tinybar and 18 as weibar in the EVM `value`.
- `utils/orders/gas.ts`: explicit gas limits for every call that touches HTS or HSS. Pass them on every such write: the relay's gas estimate undercounts system-contract work and the transaction runs out of gas.
- `utils/orders/errors.ts`: maps vault custom errors to readable messages. Add an entry when you add an error.

Generic Scaffold-HBAR hooks live in `hooks/scaffold-hbar` (`useScaffoldReadContract`, `useScaffoldWriteContract`, `useDeployedContractInfo`, `useTransactor`). Web3 UI components come from `@scaffold-hbar-ui/components`.

UI rules: use DaisyUI classes, no motion, and every state must look right at 1440 and 390 in light and dark. Every UI state has a Playwright test in `e2e/orders.spec.ts`, backed by the mocks in `e2e/support/`.

## Style

| Style | Use |
| --- | --- |
| `UpperCamelCase` | types, components, contracts |
| `lowerCamelCase` | variables, functions |
| `CONSTANT_CASE` | constants |
| `UpperCamelCase.s.sol` | Foundry scripts (`Deploy.s.sol`, `PoolGap.s.sol`) |

Next.js imports use the `~~` alias. Prefer `type` over `interface`, and let TypeScript infer when it can. Solidity uses NatSpec on external functions and custom errors, not revert strings. Comments should add information.
