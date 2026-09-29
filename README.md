# saucerswap-limit-orders

> Work in progress: this is the template skeleton. The use case, integration and full documentation land in the next iteration.

A [Scaffold-HBAR](https://docs.hedera.com/solutions/tools/scaffold-hbar) template: a Next.js frontend plus Foundry contracts in a `packages/` monorepo, targeting Hedera testnet.

## Create a project

```bash
npm create scaffold-hbar@latest my-app -- --template Jagadeeshftw/saucerswap-limit-orders
```

The `--` matters. Without it, npm keeps `--template` for itself and the CLI never sees it.

## Prerequisites

- Node.js >= 20.18.3
- Git with `user.name` and `user.email` configured (the CLI makes the first commit)
- Yarn (via `corepack enable`) or npm
- Foundry (`forge`, `cast`, `anvil`) >= 1.4

## Run it locally

```bash
yarn foundry:chain
yarn foundry:deploy --network localhost
yarn next:dev                               # http://localhost:3000
```

## Template gate check

`scripts/gate-check.mjs` reproduces the bounty eligibility gate against this repository using the real `create-scaffold-hbar` CLI. It scaffolds with each package manager (npm and yarn) into a temp directory, then runs install, lint, type-check, build, contract tests, dev and production boot with route checks, gitleaks, licence and manifest checks, and a mirror-node lookup for the recorded testnet transactions.

```bash
node scripts/gate-check.mjs                 # scaffold from GitHub (what a stranger gets)
node scripts/gate-check.mjs --local         # scaffold from the working tree before pushing
node scripts/gate-check.mjs --help
```

## Licence

MIT. See [LICENSE](LICENSE).
