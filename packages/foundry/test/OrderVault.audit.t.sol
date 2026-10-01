// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { IOrderType } from "../contracts/interfaces/IOrderType.sol";
import { PriceMath } from "../contracts/libraries/PriceMath.sol";
import { MarketConfig } from "../script/MarketConfig.sol";
import { GuardParams, PlaceParams, Side, Status, SweepParams } from "../contracts/types/OrderTypes.sol";
import { RevertingType } from "./OrderVault.plugins.t.sol";

/// A strategy that is met at once and asks for a floor `param` bps above the Chainlink value of a DAI sell.
contract FloorType is IOrderType {
    function validate(Side, uint128, uint128, uint16, uint40, uint40) external pure returns (bool) {
        return true;
    }

    function evaluate(Side, uint128, bytes32 state, uint256) external pure returns (uint256, bytes32) {
        return (0, state);
    }

    /// @dev Chainlink value of a DAI sell (8 dp in, 6 dp out) plus `param` bps.
    function minOut(Side, uint128 amountIn, uint128 param, uint256 oraclePrice) external pure returns (uint256) {
        uint256 fair = PriceMath.baseToQuote(amountIn, oraclePrice, 8, 6);
        return fair + (fair * param) / 10_000;
    }
}

/// A strategy that is met at once and hands back new state when it is.
contract StatefulFillType is IOrderType {
    function validate(Side, uint128, uint128, uint16, uint40, uint40) external pure returns (bool) {
        return true;
    }

    function evaluate(Side, uint128, bytes32, uint256) external pure returns (uint256, bytes32) {
        return (0, bytes32(uint256(7)));
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Audit pass over the code the plug-in refactor added or moved: the order-type registry, the strategy's
///         floor, the trailing stop's fill, the lens's per-order preview and the market bounds in MarketRegistry.
contract OrderVaultAuditTest is OrderVaultBase {
    function _register(address impl) internal returns (uint8 id) {
        vm.prank(owner);
        id = vault.registerOrderType(impl);
    }

    function _placeDai(uint8 orderType, uint128 typeParam, uint16 slippageBps) internal returns (uint256 orderId) {
        uint256 budget = lens.minBudget(DAI_MARKET, Side.SellBase);
        vm.prank(alice);
        orderId = vault.placeOrder{ value: budget }(
            PlaceParams(
                uint32(DAI_MARKET),
                Side.SellBase,
                orderType,
                1_000e8,
                typeParam,
                slippageBps,
                uint40(block.timestamp + 7 days)
            )
        );
    }

    // --- registry ---

    function test_registry_rejectsZeroAddressAndUnknownIds() public {
        vm.startPrank(owner);
        vm.expectRevert(OrderVault.InvalidOrderParams.selector);
        vault.registerOrderType(address(0));
        vm.expectRevert(abi.encodeWithSelector(OrderVault.UnknownOrderType.selector, uint8(3)));
        vault.setOrderTypeActive(3, false);
        vm.stopPrank();
        uint256 budget = lens.minBudget(DAI_MARKET, Side.SellBase);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.UnknownOrderType.selector, uint8(3)));
        vault.placeOrder{ value: budget }(
            PlaceParams(uint32(DAI_MARKET), Side.SellBase, 3, 1_000e8, 1, 30, uint40(block.timestamp + 1 days))
        );
    }

    // --- a strategy can only tighten the floor ---

    /// @notice A floor the pool can meet is used as the fill's minimum out, above the vault's own.
    function test_strategyFloor_tightensTheFill() public {
        uint8 id = _register(address(new FloorType()));
        uint256 orderId = _placeDai(id, 1, 30); // a floor 1 bp above Chainlink value
        router.setRate(address(dai), address(usdc), RAY * 10_001 / 1_000_000); // the pool pays 1.0001 per DAI
        vm.recordLogs();
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        uint256 fair = PriceMath.baseToQuote(1_000e8, uint256(DAI_USD), 8, 6);
        assertEq(_minOutOfFill(orderId), fair + fair / 10_000, "the strategy's floor, not the vault's, applied");
    }

    /// @notice A floor the pool can't meet makes the swap fail; the order stays open and nothing moves.
    function test_strategyFloor_tooTightHoldsTheOrder() public {
        uint8 id = _register(address(new FloorType()));
        uint256 orderId = _placeDai(id, 100, 30); // 1% above Chainlink value: the pool pays only the fair price
        uint256 escrow = vault.escrowed(address(dai));
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
        assertEq(vault.escrowed(address(dai)), escrow);
    }

    // --- executeOrder with type state ---

    /// @notice A manual execution stores the state the strategy returns with a met trigger, then fills.
    function test_executeOrder_storesStateThenFills() public {
        uint8 id = _register(address(new StatefulFillType()));
        uint256 orderId = _placeDai(id, 0, 30);
        vm.recordLogs();
        assertTrue(vault.executeOrder(orderId));
        assertEq(uint256(vault.getOrder(orderId).typeState), 7);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
    }

    /// @notice With the oracle down there is no price to act on: nothing happens.
    function test_executeOrder_doesNothingWithoutAPrice() public {
        uint256 orderId = _placeDai(STOP, 99_990_000, 30);
        daiFeed.set(0, block.timestamp);
        assertFalse(vault.executeOrder(orderId));
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
    }

    // --- trailing stop, end to end ---

    /// @notice A trailing stop rides DAI up through scheduled sweeps, then fills on the pullback: the fill uses
    ///         the vault's Chainlink floor (the trailing type asks for no extra) at the price it fell to.
    function test_trailingStop_ridesUpThenFillsOnPullback() public {
        uint256 orderId = _placeDai(TRAILING, 200, 30); // 2% trail
        _setDaiPrice(100_500_000);
        _runScheduledSweep(DAI_MARKET);
        _setDaiPrice(102_000_000); // new high: peak 1.02, trigger 0.9996
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint256(vault.getOrder(orderId).typeState), 102_000_000);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));

        _setDaiPrice(99_900_000); // pulls back below 1.02 x 0.98
        uint256 before = usdc.balanceOf(alice);
        vm.recordLogs();
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        uint256 fair = PriceMath.baseToQuote(1_000e8, 99_900_000, 8, 6);
        assertEq(_minOutOfFill(orderId), PriceMath.lessBps(fair, 30), "the vault's Chainlink floor");
        assertEq(usdc.balanceOf(alice) - before, fair, "filled at the pulled-back price");
    }

    // --- lens: the per-order preview's fallbacks ---

    function test_lens_orderNextCheckDelay_fallsBackToMinInterval() public {
        SweepParams memory sp = MarketConfig.usdcDai().sweep;
        // a closed order
        uint256 closed = _placeDai(STOP, 50_000_000, 30);
        vm.prank(alice);
        vault.cancel(closed);
        assertEq(lens.orderNextCheckDelay(closed), sp.minInterval, "closed");
        // a failing strategy
        uint8 bad = _register(address(new RevertingType()));
        uint256 failing = _placeDai(bad, 0, 30);
        assertEq(lens.orderNextCheckDelay(failing), sp.minInterval, "strategy reverts");
        // no oracle price
        uint256 open = _placeDai(STOP, 50_000_000, 30);
        daiFeed.set(0, block.timestamp);
        assertEq(lens.orderNextCheckDelay(open), sp.minInterval, "oracle down");
    }

    // --- MarketRegistry: the sweep bounds the edge test does not cover ---

    function test_updateMarket_boundsSweepIntervals() public {
        SweepParams memory s = MarketConfig.hbarUsdc().sweep;
        GuardParams memory g = MarketConfig.hbarUsdc().guard;
        SweepParams[3] memory bad = [s, s, s];
        bad[0].minInterval = 29; // below HSS's practical minimum
        bad[1].minInterval = s.maxInterval + 1; // min above max
        bad[2].maxMoveBpsPerHour = 0; // would divide by zero in the delay
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(OrderVault.InvalidSweep.selector);
            vault.updateMarket(HBAR_MARKET, g, bad[i], true);
        }
    }

    // --- helpers ---

    function _minOutOfFill(uint256 orderId) internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == OrderVault.OrderFilled.selector && uint256(logs[i].topics[1]) == orderId) {
                (,, uint256 minOut,,,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                return minOut;
            }
        }
        revert("no OrderFilled");
    }
}
