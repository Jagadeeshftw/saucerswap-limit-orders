# Agent instructions

Briefing for coding agents in this app (Cursor, Claude Code, Codex). Claude Code loads it through `CLAUDE.md`.

This is a Scaffold-HBAR dApp: Next.js App Router, wallet connect, Debug Contracts, and Hedera networks (testnet, mainnet, local fork).

Use the package manager this project was created with (`packageManager` in the root `package.json`, or the lockfile). Examples use `yarn`; if the app was created with npm, swap `yarn <script>` for `npm run <script>`.

## Packages

- `packages/foundry`: contracts, Forge scripts and tests
- `packages/nextjs`: the frontend (App Router, RainbowKit, Wagmi, Viem, DaisyUI)

## Commands

Package-prefixed scripts for package-specific work. Keep only truly cross-workspace commands unprefixed.

```bash
# Local chain + deploy + frontend (separate terminals)
yarn foundry:chain    # Anvil from the Foundry package
yarn foundry:deploy
yarn next:start       # http://localhost:3000

# Frontend only
yarn next:dev

# Quality / build
yarn lint
yarn format
yarn next:build
yarn foundry:compile

# Live networks
yarn foundry:deploy --network hedera_testnet  # or hedera_mainnet
yarn foundry:verify:testnet

# Deployer account
yarn foundry:account:generate
yarn foundry:account:import
yarn foundry:account
```

## Layout

### Foundry

- Contracts: `packages/foundry/contracts/`
- Deploy scripts: `packages/foundry/script/` (`Deploy.s.sol`, `DeployHederaToken.s.sol`, `DeployHtsTokenCreator.s.sol`)
- Tests: `packages/foundry/test/`
- Config: `packages/foundry/foundry.toml`
- One contract: `yarn foundry:deploy --file DeployHederaToken.s.sol`

### After deploy

ABIs and addresses are written to `packages/nextjs/contracts/deployedContracts.ts`. Put third-party contracts in `packages/nextjs/contracts/externalContracts.ts`.

Sample contracts on this starter: `HederaToken` (ERC-20) and `HtsTokenCreator` (HTS precompile at `0x167`).

## Frontend contract interaction

Hooks live in `packages/nextjs/hooks/scaffold-hbar`. Use the names that exist in the codebase:

- `useScaffoldReadContract` — not `useScaffoldContractRead`
- `useScaffoldWriteContract` — not `useScaffoldContractWrite`

Also: `useScaffoldWatchContractEvent`, `useScaffoldEventHistory`, `useDeployedContractInfo`, `useScaffoldContract`, `useTransactor`.

```typescript
const { data: balance } = useScaffoldReadContract({
  contractName: "HederaToken",
  functionName: "balanceOf",
  args: [connectedAddress],
});

const { writeContractAsync, isPending } = useScaffoldWriteContract({
  contractName: "HederaToken",
});

await writeContractAsync({
  functionName: "mint",
  args: [connectedAddress, parseEther("1")],
});
```

`HederaToken.mint` is `onlyOwner`. For HTS creation, `HtsTokenCreator.createToken` is payable (HTS fee via `msg.value`) and emits `TokenCreated`.

### UI

Use `@scaffold-hbar-ui/components` for web3 UI: `Address`, `AddressInput`, `Balance`, `EtherInput`, `IntegerInput`.

Use DaisyUI classes, not raw Tailwind when a DaisyUI component exists:

```tsx
<button className="btn btn-primary">Connect</button>
```

### Networks

- Foundry: `packages/foundry/foundry.toml` (`hedera_testnet`, `hedera_mainnet`)
- Next.js: `packages/nextjs/scaffold.config.ts` (target networks, polling, RPC overrides, WalletConnect)

## Style

| Style | Use |
| --- | --- |
| `UpperCamelCase` | types, components |
| `lowerCamelCase` | variables, functions |
| `CONSTANT_CASE` | constants |
| `snake_case` | Foundry scripts |

Next.js imports use the `~~` alias:

```tsx
import { useTargetNetwork } from "~~/hooks/scaffold-hbar";
```

App Router pages live under `packages/nextjs/app/`. Add `"use client"` when the page uses hooks.

Prefer `type` over `interface`. No `T` prefix on types. Let TypeScript infer when it can. Comments should add information.
