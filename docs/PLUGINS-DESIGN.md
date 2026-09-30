# Pluggable order types — design

Status: **proposal for review.** No plug-in code is written yet. This document is the contract for the STEP 2
refactor: it turns the fixed limit/stop logic into pluggable order types, with a trailing stop as the first new
plug-in. The existing limit and stop-loss become plug-ins with behaviour unchanged.

## Goals and constraints

- One order type = one small, **stateless strategy**. The vault keeps owning all state and all funds.
- Add a type **after deploy** without redeploying the vault (so a type cannot be a linked library).
- **No new trust in the strategy code**: a buggy or hostile allowlisted type must not be able to move funds,
  corrupt storage, reenter, or force a bad fill past the guard.
- Stay under 24,576 bytes with **≥ 3 KB headroom** after the refactor (today: 24,242, 334 B free — see README
  "Extending the vault").
- Keep the cost per check within a few thousand gas of today's, and keep distance-aware scheduling working.

## The interface

An order type is an external contract implementing a **view-only** strategy. The vault holds the order; the
strategy only reads what the vault passes and returns decisions and the next state. Because every method is
`view` and reached by `staticcall`, a strategy cannot write storage, send value, or reenter.

```solidity
interface IOrderType {
    /// Placement-time validation. Reverts (or returns false + reason) if params are invalid for this type.
    /// e.g. trailing requires sell-side and a trail in [MIN_TRAIL_BPS, MAX_TRAIL_BPS].
    function validate(OrderInit calldata init) external view returns (bool ok, string memory reason);

    /// The whole per-check decision in one call, so a check costs one staticcall.
    /// `st` is this order's opaque per-type state (e.g. the trailing peak); the vault stores it verbatim.
    /// Returns: distanceBps (0 == trigger met, drives both the fill and the next-check delay),
    ///          newState (the vault writes it only if it changed), and an event code for the trail.
    function evaluate(OrderView calldata o, Prices calldata p, bytes32 st)
        external view returns (uint256 distanceBps, bytes32 newState, uint8 evt);

    /// Slippage floor for the fill, priced from Chainlink (never from the pool), so a type cannot widen slippage.
    function minOut(OrderView calldata o, uint256 amountIn, Prices calldata p) external view returns (uint256);
}
```

`OrderView` is a read-only projection of the order (side, amountIn, the type param, slippageBps, createdAt).
`Prices` is the `GuardReading` the vault already computes once per sweep (Chainlink cross price, pool TWAP,
guard state). `OrderInit` is the placement params. The vault, not the strategy, decides whether the guard is
open, whether there is budget, and whether gas remains — the strategy only answers "is the trigger met, how far
away is it, and what is the slippage floor."

## Dispatch: external contract, not library or delegatecall

Three options were considered:

1. **Linked library** — shares the vault's storage, cheapest call. Rejected: libraries are linked at deploy, so
   a new type could never be added to a live vault, which defeats the point.
2. **Delegatecall to an allowlisted logic contract** — lets a type keep its own per-order storage. Rejected:
   delegatecall runs foreign code in the vault's storage and context, so a bad type could collide storage slots,
   move funds, or reenter. That is exactly the trust we refuse to add.
3. **Staticcall to an allowlisted view contract** (chosen) — the type is pure logic over data the vault passes.
   It cannot write, cannot reenter, cannot touch funds. The vault owns every SSTORE. The cost is one cold
   `staticcall` per check (~2,600 gas + a cheap view body) and passing state in and out.

The vault keeps a small registry:

```solidity
mapping(uint8 => address) public orderTypes;   // id -> strategy contract
uint8 public orderTypeCount;
function registerOrderType(address impl) external onlyOwner returns (uint8 id);  // append-only
function setOrderTypeActive(uint8 id, bool active) external onlyOwner;            // pause a type for new orders
```

Only the **owner** can register or pause a type, so the allowlist is the trust boundary. Registration is
append-only and existing orders keep their type id forever, so a type a live order depends on can be paused for
*new* placements but never swapped out from under an open order.

### Why a hostile allowlisted type still cannot hurt an order

- It is `view` (`staticcall`): no writes, no value, no reentrancy.
- `distanceBps` is advisory. Even at `distanceBps == 0`, the vault still requires the **guard open** and still
  floors the swap with its own Chainlink-priced `minOut` — it takes `max(vault floor, type minOut)`, so a type
  can only ask for *more* protection, never less.
- `newState` is opaque bytes the vault stores and hands back; it can't alias another order's storage.
- A type that reverts or runs long is contained: the evaluate call is given a fixed gas stipend, and a failure
  is treated as "not this check" (the order is skipped, like an unfunded one), never as a fill.

## Storage layout

Per order, replace the fixed `Trigger trigger` + reuse of `triggerPrice` with a type id, a type parameter, and
one opaque state word:

```solidity
struct Order {
    uint32 marketId; Side side; uint8 orderType; Status status; bool funded; uint16 slippageBps;
    uint40 createdAt; uint40 expiry; uint128 amountIn; uint128 typeParam; uint128 budget;
    bytes32 typeState;   // NEW slot: e.g. the trailing peak; zero for stateless types
}
```

- `orderType` (1 byte) replaces the `Trigger` enum and packs into the existing first slot, so no new slot there.
- `typeParam` reuses the `triggerPrice` field: for limit/stop it is the trigger price; for trailing it is the
  trail in bps.
- `typeState` is one new 32-byte slot. It is zero for limit and stop (they carry no per-check state), so those
  orders pay nothing extra to store, and Solidity won't write a zero slot. Only trailing orders touch it.

## The three shipped types (behaviour unchanged for the first two)

- **Limit** (`LimitOrderType`): `distanceBps == 0` when, for a sell, `oraclePrice ≥ typeParam` (`AtOrAbove`); for
  a buy, `oraclePrice ≤ typeParam` (`AtOrBelow`). Exactly today's `Sell+AtOrAbove` / `Buy+AtOrBelow`. Stateless.
- **Stop** (`StopOrderType`): the mirror — sell fires `AtOrBelow`, buy `AtOrAbove`. Exactly today's stop-loss /
  stop-buy. Stateless.
- **Trailing stop** (`TrailingStopType`): stateful, below.

Limit and stop keep bit-identical trigger maths, so every existing test and the deployed proofs still describe
them correctly.

## Trailing stop semantics

A sell-side trailing stop rides the price up and fires on a pullback:

- **State:** `typeState` holds the **peak** — the highest Chainlink cross price the order has seen at a check.
- **On each check** (`evaluate`): `peak' = max(peak, oraclePrice)`; the effective trigger is
  `peak' × (1 − trail)`. `distanceBps` is 0 when `oraclePrice ≤ trigger`, else the deviation from `oraclePrice`
  down to `trigger`. When `peak' > peak`, `evt = PEAK_RAISED` and the vault writes the new peak and emits a trail
  event; otherwise nothing is written.
- **Trail** is `typeParam` in bps (e.g. 250 = 2.5%), bounded `[MIN_TRAIL_BPS, MAX_TRAIL_BPS]` (proposed 50–5000,
  i.e. 0.5%–50%) at `validate`.
- **Seed:** the peak starts at the placement-time Chainlink price, so a trailing stop placed above the current
  price behaves sensibly from the first check.

**The limitation, stated plainly.** The peak is the maximum of the oracle **sampled at scheduled checks**, not
the true continuous high. A spike that rises and falls back entirely between two checks is not captured, so the
trail can lock in less than a hypothetical continuous trail would. This is inherent to an on-chain,
pay-per-check design and is documented for the user. Distance-aware scheduling reduces it — as the price nears
the trigger the checks get closer together — but does not remove it. A maker who needs a tighter guarantee funds
a smaller `maxMoveBpsPerHour` (more frequent checks, higher cost) or a shorter `minInterval`.

**Interaction with distance-aware scheduling.** The scheduler already turns `distanceBps` into a wait
(`wait = distanceBps × 3600 / maxMoveBpsPerHour`, clamped). For a trailing stop the distance is measured to the
*moving* trigger `peak × (1 − trail)`, so when price sits far above the trigger the checks are sparse (and the
peak is climbing slowly relative to the gap), and as price falls toward the trigger the checks tighten — exactly
the behaviour you want, with no new scheduling code.

**Cost per check.** Same as a limit/stop check plus, only when the peak rises, one SSTORE of `typeState`
(~5,000 gas warm) and a trail event. In a steady up-trend most checks raise the peak; flat or falling markets
write nothing. The type's `evaluate` body is a handful of comparisons.

**Buy-side.** The mirror (track the **trough**, fire when price rises `trail` above it) is the same contract
with `min` instead of `max`, so it is near-zero extra size and cost. It will ship in the same `TrailingStopType`
unless the size budget is tight at build time, in which case sell-only ships first.

## Gas per check: before vs after

- **Before:** `_distance` is an internal pure call, a few hundred gas.
- **After:** one `staticcall` to the strategy's `evaluate` (~2,600 gas cold + a small view body), replacing
  `_distance`; for trailing, one extra SSTORE (~5,000 gas) on checks that raise the peak. Net: roughly
  **+3,000 gas** per check for limit/stop, **+8,000 gas** on a trailing check that raises the peak. `checkGas`
  in `MarketConfig.costs()` is bumped to match and re-measured on testnet, so budgets stay honest; the fixed
  ~$0.12 `scheduleCall` fee still dominates a check, so the effect on what an order costs is small.

## Size plan (≥ 3 KB headroom)

The refactor **removes** the per-type trigger branching and `_distance` from the vault and **adds** the small
registry plus the staticcall dispatch. On its own that is roughly size-neutral, so to reach ≥ 3 KB headroom the
refactor also moves the read-only cost/status views (`checkCost`, `fillCost`, `minBudget`, `sweepStatus`,
`nextCheckDelay`, `sweepGasLimit`) into a separate **`OrderVaultLens`** contract that reads the vault's storage.
Those views exist only for the frontend and are the largest easily-removable chunk. Target after STEP 2:
**OrderVault ≤ ~21.5 KB, ≥ 3 KB free**, verified by `forge build --sizes` in the size report. If the lens alone
is not enough, the pricing/cost internals (`_gasToTinybar`, `_reserve`, the share maths) move into a library
next, the same way `MarketGuard` already did.

## What STEP 2 delivers against this design

- `IOrderType` + `OrderView`/`Prices`/`OrderInit` types; `LimitOrderType`, `StopOrderType`, `TrailingStopType`.
- The registry (`registerOrderType`, `setOrderTypeActive`, `orderTypes`), the storage change, and the dispatch.
- `OrderVaultLens` for the views.
- Fuzz + invariant coverage **per order type** (including trailing peak monotonicity and "a trailing stop never
  fires above its trigger"), all existing tests still green, and a coverage + size report.
