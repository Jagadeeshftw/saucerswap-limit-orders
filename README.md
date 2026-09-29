# saucerswap-limit-orders

Limit and stop orders for SaucerSwap V2 on Hedera, with no keeper bot. A [Scaffold-HBAR](https://docs.hedera.com/solutions/tools/scaffold-hbar) template: Foundry contracts plus a Next.js frontend, targeting Hedera testnet.

You escrow tokens in `OrderVault` along with a small HBAR budget. The vault mints you an HTS NFT that *is* the order, then asks the Hedera Schedule Service to call it back. Every few minutes the network itself runs a sweep over each market. It fills orders whose trigger is met, but only while a guard confirms the pool's TWAP agrees with Chainlink. When the budget runs out, the order stops being checked. Nothing off-chain has to stay online.

| Hedera service | What it does here |
| --- | --- |
| Schedule Service, `0x16b` (HIP-1215) | Schedules each market's next sweep from inside the contract. The vault pays for it, so no bot or cron is involved. |
| Token Service, `0x167` | Each order is an NFT in a collection the vault controls. Whoever holds the NFT can cancel, top up and receive the fill. |
| Exchange rate, `0x168` | Converts gas priced in USD cents to tinybar, so check budgets track the live HBAR rate. |
| Mirror node | The frontend reads the order history, NFT holdings and associations from it, with no indexer to run. |

## Live on testnet

| | |
| --- | --- |
| OrderVault | [0.0.10779995](https://hashscan.io/testnet/contract/0.0.10779995) (`0xF50e10ab7b6B9b71d4D74464A5df2E0d764353D1`) |
| Order NFT collection | [0.0.10779996](https://hashscan.io/testnet/token/0.0.10779996) |
| Order #1 placed: 3 DAI escrowed, NFT minted, sweep scheduled | [1790702932.905295104](https://hashscan.io/testnet/transaction/1790702932.905295104) |
| Order #1 filled 300 s later by the scheduled sweep, NFT wiped | [1790703232.028766192](https://hashscan.io/testnet/transaction/1790703232.028766192) |
| Order #2 placed: 20 HBAR limit sell, then held by the guard on every scheduled check | [1790702953.305146694](https://hashscan.io/testnet/transaction/1790702953.305146694) |

The frontend ships pointed at this deployment, so `yarn next:dev` works without deploying anything.

## Create a project

```bash
npm create scaffold-hbar@latest my-app -- --template Jagadeeshftw/saucerswap-limit-orders
```

Keep the `--`. Without it, npm swallows `--template` and the CLI never sees it. The CLI asks which package manager to use (yarn or npm); pass `--package-manager yarn` or `--package-manager npm` to skip the prompt.

### Prerequisites

- Node.js >= 20.18.3
- Git, with `user.name` and `user.email` set (the CLI makes the first commit)
- Yarn (`corepack enable`) or npm
- Foundry >= 1.4, for contracts and tests

## Run it

```bash
yarn next:dev            # http://localhost:3000, against the live testnet vault
```

Connect a wallet on Hedera testnet (chain 296) with some testnet HBAR from the [portal faucet](https://portal.hedera.com/faucet). The Trade page takes you through the rest: associating the NFT collection and output token, approving the input token, then placing the order.

### Deploy your own vault

```bash
yarn foundry:account:import      # or foundry:account:generate, then fund it
yarn foundry:deploy              # Hedera testnet; ~25 HBAR, mostly the HTS collection fee
```

This deploys `OrderVault`, creates its NFT collection, lists both markets and rewrites `packages/nextjs/contracts/deployedContracts.ts`. There is no local-chain option: Anvil has no Schedule Service or Token Service, so the vault only runs on Hedera.

## How an order runs

1. **Place.** `placeOrder` escrows the input (HBAR as value, or a token via allowance), takes the check budget, and mints the order NFT to you. If the market's sweep isn't scheduled yet, it schedules it.
2. **Sweep.** Every `interval` seconds the Schedule Service calls `sweep(marketId)`. It walks up to `maxOrders` funded orders and charges each one its share of the sweep's gas. For any order whose trigger is met, it runs the guard and fills up to `maxFills` of them on the SaucerSwap V2 router. It reschedules itself only while some order is still funded.
3. **Guard.** A fill needs both Chainlink feeds to be fresh (`maxOracleAge`), plus a pool TWAP over `twapWindow` within `maxDeviationBps` of the Chainlink cross price. The trigger is checked against Chainlink, and slippage is bounded against it too. If any check fails, the order is *held by the guard* and tried again on the next sweep.
4. **Settle.** Output goes to whoever holds the NFT, and the NFT is wiped. If a transfer can't be delivered (the recipient isn't associated, for example), it is credited and claimable. An expired order refunds its escrow and leftover budget.

| Market | Pool | TWAP | Max deviation | Max slippage | Sweep |
| --- | --- | --- | --- | --- | --- |
| HBAR / USDC | 0.3% | 1800 s | 200 bps | 300 bps | every 300 s, 20 orders, 3 fills |
| DAI / USDC | 0.05% | 1800 s | 100 bps | 100 bps | every 300 s, 20 orders, 3 fills |

On testnet, the HBAR/USDC pool trades about 17× away from Chainlink, so its guard stays closed and orders there are held, never filled. That is the guard doing its job. The DAI/USDC pool tracks Chainlink, so orders there fill, which makes it a working stablecoin depeg stop-loss. Both markets use the same code.

### What a check costs

The vault prices costs in gas and converts them through the exchange-rate system contract. These are values read from the live vault on 30 Sep 2026:

| | HBAR |
| --- | --- |
| Check, one funded order in the sweep | 1.8977 |
| Check, shared by 5 / 10 / 20 funded orders | 0.4372 / 0.2546 / 0.1634 |
| Reserved for the fill: HBAR sell / token sell | 0.6906 / 1.0510 |
| Minimum budget at placement (fill reserve plus 6 solo checks) | 12.0771 to 12.4375 |

The frontend reads these numbers from the contract (`checkCost`, `checkCostShared`, `fillCost`, `minBudget`); nothing is hard-coded. The owner can recalibrate them with `setCosts`.

## Tests

```bash
yarn foundry:test          # unit, fuzz and invariant tests against mocked Hedera system contracts
yarn foundry:test:fork     # guard reads against the real testnet pools and feeds
yarn next:test             # frontend units: amounts, prices, status and order-trail decoding
yarn next:test:e2e         # Playwright, desktop 1440 and mobile 390, every UI state
```

The e2e suite runs against a production build with a mocked RPC relay, mirror node and injected wallet. That makes it deterministic and it never signs anything.

## Layout

```
packages/foundry/
  contracts/OrderVault.sol          orders, sweep, fills, settlement
  contracts/libraries/MarketGuard.sol   Chainlink vs TWAP guard (external library)
  contracts/libraries/PriceMath.sol     tick math, cross prices, bps
  script/MarketConfig.sol           testnet addresses, markets, calibrated costs
  script/Deploy.s.sol
  test/                             unit, fuzz, invariant, fork
packages/nextjs/
  app/                              Trade (/), My orders (/orders), order detail (/orders/[id])
  components/orders/                ticket, market panel, status and guard banners
  hooks/orders/                     vault reads, mirror-node queries, wallet setup, tx state
  utils/orders/units.ts             every amount and price conversion
  e2e/                              Playwright specs and network mocks
```

## Template gate check

`scripts/gate-check.mjs` reproduces the bounty eligibility gate against this repository using the real `create-scaffold-hbar` CLI. It scaffolds with npm and with yarn, then for each runs:

- install, lint, type-check and build;
- the contract tests;
- a production boot and a dev boot, with route checks;
- gitleaks, licence and manifest checks;
- a mirror-node lookup of the recorded testnet transactions.

```bash
node scripts/gate-check.mjs           # scaffold from GitHub (what a stranger gets)
node scripts/gate-check.mjs --local   # scaffold from the working tree
```

## Licence

MIT. See [LICENSE](LICENSE).
