# Write your own order type

Limit, stop-loss and trailing stop are three small contracts behind one interface. This guide adds a fourth: a
**bracket order** that sells when the price reaches a take-profit *or* falls to a stop-loss, whichever comes first.
It covers the contract, its tests, registering it on a vault, and the frontend. It needs v1.1 or later (order-type
plug-ins arrived in v1.1). The code below compiles and its tests pass against this repo as it is, and a fresh
developer followed this page end to end to add the bracket as type 3, frontend included. Nothing in the vault, the
lens or the sweep changes.

How the pieces fit is in [PLUGINS-DESIGN.md](PLUGINS-DESIGN.md); this page is the how-to.

## What an order type can and cannot do

An order type implements `IOrderType` (`packages/foundry/contracts/interfaces/IOrderType.sol`):

| Function | Called | Returns |
| --- | --- | --- |
| `validate(side, amountIn, param, slippageBps, expiry, nowTs)` | once, in `placeOrder` | `true` to accept the order; `false` rejects it with `InvalidOrderParams`, and a revert rejects it with your own error |
| `evaluate(side, param, state, oraclePrice)` | at every scheduled check | `distanceBps` (0 = fill now) and the order's next `state` |
| `minOut(side, amountIn, param, oraclePrice)` | before a fill | an extra minimum output, or 0 to rely on the vault's floor |

The rules the vault enforces, whatever your contract does:

- **Pure logic only.** All three functions are `pure` and the vault calls them with `staticcall`, so a type can't
  write storage, hold funds, send value or reenter.
- **Gas cap.** `evaluate` gets `EVAL_GAS` (100,000 gas). If it reverts or runs out, the vault skips that order for
  this check (`OrderEvalSkipped`), schedules the next check soon, and carries on with the other orders.
- **`distanceBps` must never be 0 for an unmet trigger.** The vault fills on 0. Compute distances with
  `PriceMath.distanceBps`, which rounds a gap under one basis point up to 1. The vault turns the distance into
  the wait before the next check, so the nearer the trigger, the sooner the next check.
- **The guard and the floor still apply.** A fill also needs the guard open, and the swap's minimum output is
  `max(vault floor, your minOut)`: Chainlink's value less the maker's slippage, or more if you ask for more. A type
  can only ask for more protection, never less.
- **State is one `bytes32` per order.** The vault passes the stored `typeState` in and stores the returned one when
  it changes (emitting `OrderStateUpdated`). It starts at zero. Stateless types return `state` unchanged.
- **One parameter.** `typeParam` is a `uint128`. If your type needs more than one number, pack them (below).

## 1. Write the contract

Create `packages/foundry/contracts/ordertypes/BracketOrderType.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOrderType } from "../interfaces/IOrderType.sol";
import { Side } from "../types/OrderTypes.sol";
import { PriceMath } from "../libraries/PriceMath.sol";

/// @title Bracket order (sell-side): a take-profit and a stop-loss in one order.
/// @notice Sells when Chainlink reaches the upper price (take profit) or falls to the lower price (stop loss),
///         whichever comes first. Stateless.
/// @dev `param` packs both prices, 8 decimals each: `upper << 64 | lower`. Build it with `pack`.
contract BracketOrderType is IOrderType {
    uint256 internal constant LOW_MASK = type(uint64).max;

    /// @notice `upper << 64 | lower`, the value to pass as `typeParam`.
    function pack(uint64 upper, uint64 lower) external pure returns (uint128) {
        return (uint128(upper) << 64) | lower;
    }

    /// @dev Sell-side only, with 0 < lower < upper.
    function validate(Side side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        (uint256 upper, uint256 lower) = _unpack(param);
        return side == Side.SellBase && amountIn > 0 && lower > 0 && lower < upper;
    }

    function evaluate(Side, uint128 param, bytes32 state, uint256 oraclePrice)
        external
        pure
        returns (uint256 distanceBps, bytes32 newState)
    {
        (uint256 upper, uint256 lower) = _unpack(param);
        newState = state;
        if (oraclePrice >= upper || oraclePrice <= lower) return (0, newState);
        // Unmet: report the nearer leg, so checks speed up as the price approaches either one.
        uint256 toUpper = PriceMath.distanceBps(upper, oraclePrice);
        uint256 toLower = PriceMath.distanceBps(lower, oraclePrice);
        distanceBps = toUpper < toLower ? toUpper : toLower;
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }

    function _unpack(uint128 param) internal pure returns (uint256 upper, uint256 lower) {
        upper = uint256(param) >> 64;
        lower = uint256(param) & LOW_MASK;
    }
}
```

Things to copy from it:

- `validate` rejects everything the type can't handle (here: buys, and a lower leg at or above the upper one).
  The vault already checks the market, the amount, the slippage range, the expiry and the budget.
- `evaluate` reports the **nearer** leg's distance, so checks speed up as the price approaches either one.
- Two prices fit in one `uint128` because 8-decimal prices fit in 64 bits. The `pack` helper is a `pure`
  function, so scripts and the frontend can build `typeParam` exactly as the contract reads it.

## 2. Test it

Create `packages/foundry/test/BracketOrderType.t.sol`. `OrderVaultBase` deploys a vault with mocked Hedera system
contracts, a DAI/USDC and an HBAR/USDC market, funded users (`alice`, `bob`) who have approved the vault, and
helpers such as `_runScheduledSweep` (runs the latest schedule the way the Schedule Service does) and `_setDaiPrice`
(moves Chainlink, the pool and the router together so the guard stays open). `_runScheduledSweep` ignores its
argument and runs the most recent schedule of *any* market (`hss.last()`), so in a test that touches both markets,
run the sweep right after the action on the market you mean.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { BracketOrderType } from "../contracts/ordertypes/BracketOrderType.sol";
import { PlaceParams, Side, Status } from "../contracts/types/OrderTypes.sol";

contract BracketOrderTypeTest is OrderVaultBase {
    BracketOrderType internal bracket;
    uint8 internal BRACKET;

    function setUp() public override {
        super.setUp();
        bracket = new BracketOrderType();
        vm.prank(owner);
        BRACKET = vault.registerOrderType(address(bracket)); // 3: after limit, stop and trailing
    }

    // The strategy on its own: pure, so it is tested by calling it directly.
    function test_evaluate_firesOnEitherLeg() public view {
        uint128 param = bracket.pack(101_000_000, 99_000_000); // take profit 1.01, stop loss 0.99
        (uint256 d,) = bracket.evaluate(Side.SellBase, param, bytes32(0), 101_000_000);
        assertEq(d, 0, "take profit met");
        (d,) = bracket.evaluate(Side.SellBase, param, bytes32(0), 98_000_000);
        assertEq(d, 0, "stop loss met");
        (d,) = bracket.evaluate(Side.SellBase, param, bytes32(0), 100_000_000);
        assertEq(d, 100, "1% from the nearer leg");
    }

    function test_validate_rejectsBuysAndInvertedLegs() public view {
        assertFalse(bracket.validate(Side.BuyBase, 1, bracket.pack(2, 1), 30, 0, 0));
        assertFalse(bracket.validate(Side.SellBase, 1, bracket.pack(1, 2), 30, 0, 0));
        assertTrue(bracket.validate(Side.SellBase, 1, bracket.pack(2, 1), 30, 0, 0));
    }

    // Through the vault: placed, checked by a scheduled sweep, filled when the stop-loss leg is hit.
    function test_fillsThroughTheVault() public {
        uint256 budget = lens.minBudget(DAI_MARKET, Side.SellBase);
        uint128 legs = bracket.pack(101_000_000, 99_500_000); // before the prank: it is an external call too
        vm.prank(alice);
        uint256 id = vault.placeOrder{ value: budget }(
            PlaceParams({
                marketId: uint32(DAI_MARKET),
                side: Side.SellBase,
                orderType: BRACKET,
                amountIn: 1_000e8,
                typeParam: legs,
                slippageBps: 30,
                expiry: uint40(block.timestamp + 7 days)
            })
        );
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(id).status), uint8(Status.Open), "between the legs: still open");

        _setDaiPrice(99_400_000); // DAI slips under the stop-loss leg
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(id).status), uint8(Status.Filled), "stop-loss leg filled it");
    }
}
```

Run it:

```bash
cd packages/foundry
forge test --match-contract BracketOrderTypeTest -vv
```

Watch for one trap: `vm.prank` applies to the next external call, and `bracket.pack(...)` is an external call. Build
`typeParam` before the prank, as the test does, or the order is placed by the test contract instead of `alice`.

Before you ship a type, also:

- Fuzz `evaluate` for the property that matters (for this one: it returns 0 exactly when the price is outside the
  legs). `testFuzz_trailingStop_triggerNeverFallsAndFiresBelowPeak` in `test/OrderVault.plugins.t.sol` is the one
  to copy from.
- Check its gas stays well under `EVAL_GAS`: `forge test --match-contract BracketOrderTypeTest --gas-report`.
- Run the whole suite, `yarn foundry:test`. The vault's own invariants don't depend on which types exist, but a
  type that never fills or always fills shows up in your integration tests.

## 3. Register it on a vault

Only the vault's owner can register a type. Registration is append-only: the first new type gets id 3 (after limit
0, stop 1 and trailing 2), and an order keeps its type id forever. The owner can pause a type for new orders with
`setOrderTypeActive(id, false)`; existing orders keep running and stay cancellable.

**On your own deployment**, edit `packages/foundry/script/Deploy.s.sol`:

1. import it next to the shipped three: `import { BracketOrderType } from "../contracts/ordertypes/BracketOrderType.sol";`
2. register it after them: `_register(vault, address(new BracketOrderType()), 3);` (`_register` reverts if the
   vault hands out a different id);
3. add `deployments.push(Deployment({ name: "BracketOrderType", addr: vault.orderTypes(3) }));` like theirs, so the
   ABI export writes it into `packages/nextjs/contracts/deployedContracts.ts` and the Debug page lists it;
4. update the script's doc comment, which says it registers three types.

Then deploy as usual (`yarn foundry:deploy`). `deployedContracts.ts` only gains `BracketOrderType` after a real
deploy; the frontend's e2e mock reads the type contracts from that file (step 4).

**On a vault that is already live**, deploy the type and register it with the owner's key:

```bash
cd packages/foundry
forge create contracts/ordertypes/BracketOrderType.sol:BracketOrderType \
  --rpc-url https://testnet.hashio.io/api --account <owner keystore> --broadcast
cast send <vault address> "registerOrderType(address)(uint8)" <BracketOrderType address> \
  --rpc-url https://testnet.hashio.io/api --account <owner keystore>
cast call <vault address> "orderTypeCount()(uint8)" --rpc-url https://testnet.hashio.io/api   # now 4
```

The sweep picks the new type up on its next run; no redeploy, no migration.

The lens needs nothing: `OrderVaultLens.nextCheckDelay(market, orderType, side, typeParam, expiry)` already asks
the type for its distance, so the ticket's budget estimate works for the new type as soon as it is registered.

## 4. Show it in the frontend

The app reads orders generically: the lens prices and schedules any registered type, so the budget, coverage
and fee lines work unchanged. What names and draws the types:

1. **`packages/nextjs/utils/orders/orders.ts`**, the order vocabulary. Add `Bracket = 3` to `OrderType` and
   `"bracket"` to the ticket's `OrderKind` union and `orderTypeFor`. Then give each helper a bracket case:
   - `directionOf`: return `Trigger.AtOrBelow` (it only gets the side and type, so treat a bracket like a
     stop-loss);
   - `currentTrigger` / `triggerMet`: met when the price is at or above the upper leg or at or below the lower one
     (this drives the "Held" chip);
   - `orderKind` ("Bracket"; `sideTypeLabel` derives from it), `placeLabel` ("Place bracket order"),
     `triggerSummary` ("≥ 1.0100 or ≤ 0.9950"), `paramText` (the trail's "Placed" row) and `fireCondition`
     (the sentence under the order's title);
   - add `packBracket(upper, lower)` and `bracketLegs(typeParam)` mirroring the contract's `pack`
     (`(upper << 64n) | lower`). Reject legs of 2^64 or more: the contract's `pack(uint64, uint64)` would revert,
     but a JavaScript shift silently corrupts the upper leg.

   Add cases to `orders.test.ts`.
2. **`packages/nextjs/components/orders/OrderTicket.tsx`**: add a segment (the row becomes `grid-cols-4`) and a
   `KIND_NOTE` entry; disable it on Buy and switch a buy back to Limit, as the trailing segment does (the type is
   sell-only); show two price fields and suggest both legs in the effect that suggests a trigger; validate the
   legs (`0 < lower < upper < 2^64`); feed a single price into the expected-output figure (the lower leg is the
   conservative one) and into `triggeredNow`, which sizes the budget of an order whose trigger is already met;
   build `typeParam` with `packBracket`; write its summary sentence. `useCheckDelays` already passes the type and
   its parameter to the lens.
3. **`packages/nextjs/utils/orders/trail.ts`**: only for a type that keeps state. `OrderStateUpdated` rows are
   decoded per type (the trailing stop shows "Peak raised to … · Trigger now …"); a stateless type needs nothing
   here, because the "Placed" row already uses `paramText`.
4. **`packages/nextjs/e2e/support/mockNetwork.ts`**, the mocked relay. `ORDER_TYPES` lists the type contracts
   from `deployedContracts.ts`, and the `orderTypeCount`, `orderTypes` and `orderTypeActive` answers and
   `checkDelay`'s "unknown type" guard all follow that list. After a redeploy, append `contracts.BracketOrderType`;
   before one, append an entry with the bracket's ABI (from `packages/foundry/out`) and any unused address. Then
   port the bracket's distance rule next to the trailing stop's in the mock's `evaluate`. Then cover the ticket in
   `e2e/orders.spec.ts`: the button label, and the placed calldata's `orderType` and packed `typeParam`.

Then run `yarn lint`, `yarn next:check-types`, `yarn next:test` and `yarn next:test:e2e`.

## Checklist

- [ ] `validate` rejects every parameter the type can't honour.
- [ ] `evaluate` never returns 0 for an unmet trigger (`PriceMath.distanceBps`), and stays far under 100,000 gas.
- [ ] State, if any, fits in one `bytes32` and starts at zero.
- [ ] `minOut` returns 0 unless the type genuinely needs a tighter floor than Chainlink less slippage.
- [ ] Unit tests call the strategy directly; one integration test fills an order through `OrderVaultBase`.
- [ ] `validate` returns false for bad input rather than reverting, unless you want callers to see your own error.
- [ ] Registered by the owner; `orders.ts` names it and builds its `typeParam`; the ticket draws it; the e2e mock
      knows its rule.
