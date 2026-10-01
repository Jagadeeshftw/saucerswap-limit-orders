# FAQ

**Why is there no keeper bot?**
Because the vault schedules its own checks through the Hedera Schedule Service (HIP-1215). When a sweep runs it
books the next one, so the chain of checks continues with nothing off-chain staying online. The only "operator"
cost is the HBAR budget each order prepays.

**What happens if the checks stop?**
A market can stall if the Schedule Service's per-second capacity is full when a sweep tries to rebook, or if a
gas-price spike outruns the cost model's margin. The market then reads `Stalled`, the UI shows "Checks stopped",
and anyone can call `restartSweep` to resume it — it is permissionless and costs only the scheduling fee. See
"A residual stall is recoverable, not preventable" in [ARCHITECTURE.md](ARCHITECTURE.md#known-limits).

**Why doesn't an HBAR/USDC order fill on testnet?**
The only testnet HBAR/USDC pool trades ~19× away from Chainlink, so the guard correctly refuses the fill — that
is the guard doing its job, not a bug. The DAI/USDC pool tracks Chainlink (~23 bps), so DAI stop-losses fill.
On a mainnet fork the HBAR/USDC pool is arbitraged and the same guard opens (`yarn foundry:fork-guard`).

**What does an order cost?**
A fixed `scheduleCall` network fee of about 1.17 HBAR (≈ $0.12 on 2026-10-01) per scheduled check dominates; gas is the rest. You prepay a
budget in HBAR sized to the order's expected number of checks; unused budget is refunded when the order fills or
is cancelled. The Trade page shows the budget and an upper-bound fee before you place. See "What an order costs"
in the README.

**Can I add a new market or a new order type?**
A new market is a config entry plus `listMarket` (README "Extending the vault"). Pluggable order types (with a
trailing stop as the example) are designed in [PLUGINS-DESIGN.md](PLUGINS-DESIGN.md).

**Is it audited? Can I use it on mainnet?**
It is a template, not an audited production system — treat it as a starting point. Before mainnet, work through
[MAINNET-CHECKLIST.md](MAINNET-CHECKLIST.md) (mainnet addresses, feed heartbeats, a real WalletConnect id, cost
recalibration, an audit).

**Do I need to run an indexer or a backend?**
No. Reads come from the public mirror node and the JSON-RPC relay; the frontend is static. The only thing that
must exist is the deployed vault.

**Who can cancel or collect an order?**
Whoever holds the order NFT. Transferring the NFT transfers the right to cancel and the fill proceeds. If you
send the NFT to the vault itself, the order becomes unclaimable — don't.

**Why ECDSA keys, not ED25519?**
The EVM tooling (relay, browser wallet, deploy scripts) signs with an ECDSA (secp256k1) key, which has a
matching `0x` EVM address. ED25519 accounts work on Hedera but not through this EVM path.

**There's no local chain — how do I test?**
Anvil has none of Hedera's system contracts (`0x16b`, `0x167`, `0x168`), so the unit/fuzz/invariant suites etch
mocks of them, and the fork suites read the real testnet (and, opt-in, mainnet) contracts. See the README
"Tests" section.
