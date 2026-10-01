// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { IOrderType } from "../contracts/interfaces/IOrderType.sol";
import { TrailingStopType } from "../contracts/ordertypes/TrailingStopType.sol";
import { PlaceParams, Side, Status } from "../contracts/types/OrderTypes.sol";

/// A strategy that always says "fill now" and asks for no slippage protection — the worst-case plug-in.
contract AlwaysFillType is IOrderType {
    function validate(Side, uint128, uint128, uint16, uint40, uint40) external pure returns (bool) {
        return true;
    }

    function evaluate(Side, uint128, bytes32, uint256) external pure returns (uint256, bytes32) {
        return (0, bytes32(0)); // distance 0 == trigger met, every check
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0; // tries to waive the floor; the vault must ignore this
    }
}

/// A strategy whose evaluate always reverts.
contract RevertingType is IOrderType {
    function validate(Side, uint128, uint128, uint16, uint40, uint40) external pure returns (bool) {
        return true;
    }

    function evaluate(Side, uint128, bytes32, uint256) external pure returns (uint256, bytes32) {
        revert("boom");
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// A strategy whose evaluate burns unbounded gas.
contract GasBurnerType is IOrderType {
    function validate(Side, uint128, uint128, uint16, uint40, uint40) external pure returns (bool) {
        return true;
    }

    function evaluate(Side, uint128, bytes32 s, uint256) external pure returns (uint256 d, bytes32 out) {
        out = s;
        for (uint256 i; i < type(uint256).max; ++i) {
            out = keccak256(abi.encode(out, i)); // never terminates within the gas stipend
        }
        d = 0;
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract OrderVaultPluginsTest is OrderVaultBase {
    uint8 internal always_;
    uint8 internal reverting_;
    uint8 internal burner_;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        always_ = vault.registerOrderType(address(new AlwaysFillType()));
        reverting_ = vault.registerOrderType(address(new RevertingType()));
        burner_ = vault.registerOrderType(address(new GasBurnerType()));
        vm.stopPrank();
    }

    function _placeDai(address maker, uint8 orderType, uint128 amount) internal returns (uint256) {
        uint256 budget = lens.minBudget(DAI_MARKET, Side.SellBase);
        vm.prank(maker);
        return vault.placeOrder{ value: budget }(
            PlaceParams({
                marketId: uint32(DAI_MARKET),
                side: Side.SellBase,
                orderType: orderType,
                amountIn: amount,
                typeParam: 99_000_000, // ignored by the malicious types; valid for others
                slippageBps: 30,
                expiry: uint40(block.timestamp + 7 days)
            })
        );
    }

    // 1. A hostile plug-in (always-fill, minOut 0) cannot make the vault fill below its own Chainlink floor.
    function test_maliciousPlugin_cannotFillBelowVaultFloor() public {
        uint256 id = _placeDai(alice, always_, 1_000e8);
        // Guard is open (DAI pool tracks the feed), but the swap pays ~5% under Chainlink — below the 30 bps floor.
        router.setRate(address(dai), address(usdc), RAY * 9_500 / 1_000_000);
        _runScheduledSweep(DAI_MARKET);
        // The vault's minOut floor made the swap revert, caught as a failed fill: the order is NOT filled.
        assertEq(uint8(vault.getOrder(id).status), uint8(Status.Open), "not filled below the floor");
    }

    // The same hostile plug-in cannot fill while the guard is closed.
    function test_maliciousPlugin_cannotFillWhenGuardClosed() public {
        uint256 id = _placeDai(alice, always_, 1_000e8);
        daiFeed.set(DAI_USD, 1); // a feed updated long ago: the guard goes stale and closes
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(id).status), uint8(Status.Open), "guard still blocks the fill");
    }

    // 2. Pausing a plug-in blocks NEW orders only; existing ones keep working and can be cancelled.
    function test_allowlist_pauseBlocksNewOrdersNotExisting() public {
        uint256 id = _daiStop(alice, 99_000_000); // a normal STOP order
        vm.prank(owner);
        vault.setOrderTypeActive(STOP, false);

        // New STOP placement is rejected.
        uint256 budget = lens.minBudget(DAI_MARKET, Side.SellBase);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.OrderTypeInactive.selector, STOP));
        vault.placeOrder{ value: budget }(
            PlaceParams(uint32(DAI_MARKET), Side.SellBase, STOP, 10e8, 99_000_000, 30, uint40(block.timestamp + 1 days))
        );

        // The existing order is still checked by a sweep and can be cancelled by its holder.
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(id).status), uint8(Status.Open), "existing order still live");
        vm.prank(alice);
        vault.cancel(id);
        assertEq(uint8(vault.getOrder(id).status), uint8(Status.Cancelled), "holder can always cancel");
    }

    // 3. A reverting or gas-burning plug-in is skipped with an event; the sweep keeps checking other orders.
    function test_badPlugin_skipsOrderNotSweep() public {
        uint256 bad = _placeDai(alice, reverting_, 1_000e8);
        uint256 burn = _placeDai(bob, burner_, 1_000e8);
        uint256 good = _daiStop(keeper, 90_000_000); // a far STOP: checked, not filled
        uint256 goodBudgetBefore = vault.getOrder(good).budget;

        vm.expectEmit(true, false, false, false, address(vault));
        emit OrderVault.OrderEvalSkipped(bad);
        _runScheduledSweep(DAI_MARKET); // must not revert

        assertEq(uint8(vault.getOrder(bad).status), uint8(Status.Open), "bad order survives, just skipped");
        assertEq(uint8(vault.getOrder(burn).status), uint8(Status.Open), "gas-burner order survives too");
        assertEq(uint8(vault.getOrder(good).status), uint8(Status.Open), "good order still open");
        assertLt(vault.getOrder(good).budget, goodBudgetBefore, "the good order was still checked and charged");
    }

    // 4. Trailing stop: the trigger never moves down, and a fill only happens at or below peak x (1 - trail).
    TrailingStopType internal trailType = new TrailingStopType();

    function testFuzz_trailingStop_triggerNeverFallsAndFiresBelowPeak(uint128 trailSeed, uint256[8] memory priceSeed)
        public
        view
    {
        TrailingStopType t = trailType;
        uint128 trail = uint128(bound(trailSeed, t.MIN_TRAIL_BPS(), t.MAX_TRAIL_BPS()));
        bytes32 state = bytes32(0);
        uint256 peak;
        uint256 lastTrigger;
        for (uint256 i; i < priceSeed.length; ++i) {
            uint256 price = bound(priceSeed[i], 1e6, 1e12);
            (uint256 distance, bytes32 next) = t.evaluate(Side.SellBase, trail, state, price);
            uint256 newPeak = uint256(next);
            // The peak only ever rises.
            assertGe(newPeak, peak, "peak never falls");
            peak = newPeak;
            uint256 trigger = (peak * (10_000 - trail)) / 10_000;
            // The trigger (peak x (1 - trail)) never moves down.
            assertGe(trigger, lastTrigger, "trigger never falls");
            lastTrigger = trigger;
            // A fill (distance 0) happens only at or below the trigger.
            if (distance == 0) assertLe(price, trigger, "fires only at or below peak x (1 - trail)");
            state = next;
        }
    }
}
