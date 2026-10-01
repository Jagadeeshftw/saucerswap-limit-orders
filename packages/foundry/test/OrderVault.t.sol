// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVault } from "../contracts/OrderVault.sol";
import {
    Costs,
    GuardParams,
    GuardReading,
    GuardState,
    HtsError,
    HtsOperation,
    Market,
    Order,
    PlaceParams,
    Side,
    Status,
    SweepParams,
    Trigger
} from "../contracts/types/OrderTypes.sol";
import { MarketConfig } from "../script/MarketConfig.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { MockHss } from "./mocks/MockHederaSystem.sol";
import { HbarRejecter } from "./mocks/Actors.sol";

/// @dev Constants and helpers shared by the OrderVault unit suites. The suites are split across two files
///      (this one and OrderVault.sweep.t.sol) so neither test contract outgrows solc's jump-tag space under
///      via-IR, which newer Foundry releases hit with a single 68-test contract.
abstract contract OrderVaultUnitBase is OrderVaultBase {
    uint128 internal constant ABOVE_MARKET = 12_500_000; // 0.125 USDC per HBAR
    uint128 internal constant BELOW_MARKET = 10_000_000; // 0.100 USDC per HBAR

    // ------------------------------------------------------------------ helpers

    function _params(uint256 marketId, Side side, uint128 amount) internal view returns (PlaceParams memory) {
        return PlaceParams({
            marketId: uint32(marketId),
            side: side,
            orderType: LIMIT,
            amountIn: amount,
            typeParam: ABOVE_MARKET,
            slippageBps: 50,
            expiry: uint40(block.timestamp + 7 days)
        });
    }
}

/// @notice Setup and admin, costs, placing, cancelling and topping up orders.
contract OrderVaultTest is OrderVaultUnitBase {
    // ------------------------------------------------------------------ setup and admin

    function test_initialize_createsContractOwnedCollection() public view {
        assertTrue(vault.collection() != address(0));
        assertEq(hts.lastCreateValue(), 20 ether);
        assertEq(hts.treasuryOf(vault.collection()), address(vault));
    }

    function test_initialize_revertsWhenCalledTwice() public {
        vm.prank(owner);
        vm.expectRevert(OrderVault.AlreadyInitialized.selector);
        vault.initialize("x", "x");
    }

    function test_initialize_revertsOnHtsFailure() public {
        OrderVault fresh = new OrderVault(owner, vault.ROUTER(), address(whbar), MarketConfig.costs());
        hts.forceCreateCode(7);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HtsError.selector, HtsOperation.CreateCollection, int64(7)));
        fresh.initialize("x", "x");
    }

    function test_listMarket_associatesTokensAndDerivesPoolOrder() public view {
        assertTrue(hts.associations(address(vault), address(usdc)));
        assertTrue(hts.associations(address(vault), address(dai)));
        assertFalse(hts.associations(address(vault), address(whbar)), "HBAR leg needs no association");
        assertFalse(vault.getMarket(HBAR_MARKET).baseIsToken0, "USDC is token0 in the HBAR pool");
    }

    function test_listMarket_rejectsGuardThatCannotCoverPoolFee() public {
        Market memory m = _hbarMarket();
        m.guard.maxSlippageBps = 30; // the 0.3% pool fee alone is 30 bps, so no order could ever fill
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidGuard.selector);
        vault.listMarket(m);
    }

    function test_listMarket_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.listMarket(_hbarMarket());
    }

    function test_updateMarket_boundsDeviation() public {
        GuardParams memory g = vault.getMarket(HBAR_MARKET).guard;
        SweepParams memory s = vault.getMarket(HBAR_MARKET).sweep;
        g.maxDeviationBps = 1_001;
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidGuard.selector);
        vault.updateMarket(HBAR_MARKET, g, s, true);
    }

    function test_updateMarket_boundsSweepInterval() public {
        GuardParams memory g = vault.getMarket(HBAR_MARKET).guard;
        SweepParams memory s = vault.getMarket(HBAR_MARKET).sweep;
        s.minInterval = 29;
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidSweep.selector);
        vault.updateMarket(HBAR_MARKET, g, s, true);

        s.minInterval = 7 hours; // above maxInterval
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidSweep.selector);
        vault.updateMarket(HBAR_MARKET, g, s, true);

        s.minInterval = 300;
        s.maxMoveBpsPerHour = 0;
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidSweep.selector);
        vault.updateMarket(HBAR_MARKET, g, s, true);
    }

    function test_setCosts_rejectsZeroGasPrice() public {
        Costs memory c = MarketConfig.costs();
        c.gasPriceTinycents = 0;
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidCosts.selector);
        vault.setCosts(c);
    }

    // ------------------------------------------------------------------ costs

    function test_checkCost_convertsGasThroughExchangeRate() public view {
        Costs memory c = MarketConfig.costs();
        uint256 gas = uint256(c.scheduleGas) + c.sweepBaseGas + c.checkGas;
        uint256 tinycents = gas * c.gasPriceTinycents;
        tinycents += tinycents * c.safetyBps / 10_000;
        assertEq(lens.checkCost(HBAR_MARKET), _tinybar(gas));
        // The mock exchange rate is testnet's (30,000 HBAR per 231,199 cents); one lookup prices a whole call.
        assertApproxEqAbs(lens.checkCost(HBAR_MARKET), tinycents * 30_000 / 231_199, 1);
    }

    function test_checkCostShared_fallsWithMoreOrders() public view {
        assertLt(lens.checkCostShared(10), lens.checkCostShared(1));
        assertEq(lens.checkCostShared(0), lens.checkCostShared(1));
    }

    function test_minBudget_isFillPlusSixSoloChecks() public view {
        assertEq(
            lens.minBudget(HBAR_MARKET, Side.SellBase),
            lens.fillCost(HBAR_MARKET, Side.SellBase) + 6 * lens.checkCost(HBAR_MARKET)
        );
        assertGt(lens.fillCost(HBAR_MARKET, Side.BuyBase), lens.fillCost(HBAR_MARKET, Side.SellBase));
    }

    // ------------------------------------------------------------------ placing orders

    function test_placeOrder_hbarIn_escrowsMintsAndSchedules() public {
        uint256 budget = lens.minBudget(HBAR_MARKET, Side.SellBase);
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);

        Order memory o = vault.getOrder(orderId);
        assertEq(uint8(o.status), uint8(Status.Open));
        assertEq(o.amountIn, 250e8);
        assertEq(o.budget, budget);
        assertEq(vault.escrowed(address(0)), 250e8);
        assertEq(vault.totalBudgets(), budget);
        assertEq(vault.holderOf(orderId), alice);
        assertEq(hss.count(), 1);
        MockHss.Scheduled memory next = hss.last();
        assertEq(next.to, address(vault));
        // 0.125 is 12.0% above 0.1116; at 250 bps/h the price needs ~4.8 h to get there.
        assertEq(next.expiry, block.timestamp + 17_280);
        assertEq(next.gasLimit, lens.sweepGasLimit(HBAR_MARKET));
        assertEq(next.callData, abi.encodeCall(OrderVault.sweep, (HBAR_MARKET, uint32(1))));
    }

    function test_placeOrder_secondOrderReusesRunningSweep() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        _sellHbar(bob, ABOVE_MARKET, Trigger.AtOrAbove);
        assertEq(hss.count(), 1);
        assertEq(vault.openOrders(HBAR_MARKET).length, 2);
    }

    function test_placeOrder_tokenIn_pullsTokens() public {
        uint256 before = usdc.balanceOf(alice);
        uint256 orderId = _buyHbar(alice, BELOW_MARKET, Trigger.AtOrBelow);
        assertEq(usdc.balanceOf(alice), before - 50e6);
        assertEq(vault.escrowed(address(usdc)), 50e6);
        assertEq(vault.getOrder(orderId).amountIn, 50e6);
    }

    function test_placeOrder_emitsFullOrder() public {
        uint256 budget = lens.minBudget(HBAR_MARKET, Side.SellBase);
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.expectEmit(address(vault));
        emit OrderVault.OrderPlaced(
            1, HBAR_MARKET, alice, Side.SellBase, LIMIT, 250e8, ABOVE_MARKET, 50, block.timestamp + 7 days, budget
        );
        vm.prank(alice);
        vault.placeOrder{ value: 250e8 + budget }(p);
    }

    function test_placeOrder_rejectsBudgetBelowMinimum() public {
        uint256 budget = lens.minBudget(HBAR_MARKET, Side.SellBase);
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InsufficientBudget.selector, budget - 1, budget));
        vault.placeOrder{ value: 250e8 + budget - 1 }(p);
    }

    function test_placeOrder_rejectsValueBelowHbarAmount() public {
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.WrongValue.selector, 1e8, 250e8));
        vault.placeOrder{ value: 1e8 }(p);
    }

    function test_placeOrder_rejectsSlippageAtOrBelowPoolFee() public {
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        p.slippageBps = 30;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InvalidSlippage.selector, 30, 31, 300));
        vault.placeOrder{ value: 300e8 }(p);
    }

    function test_placeOrder_rejectsSlippageAboveMarketCap() public {
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        p.slippageBps = 301;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InvalidSlippage.selector, 301, 31, 300));
        vault.placeOrder{ value: 300e8 }(p);
    }

    function test_placeOrder_rejectsExpiryOutsideWindow() public {
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        p.expiry = uint40(block.timestamp);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InvalidExpiry.selector, block.timestamp));
        vault.placeOrder{ value: 300e8 }(p);

        p.expiry = uint40(block.timestamp + 90 days + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InvalidExpiry.selector, block.timestamp + 90 days + 1));
        vault.placeOrder{ value: 300e8 }(p);
    }

    function test_placeOrder_rejectsZeroAmountAndTrigger() public {
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 0);
        vm.prank(alice);
        vm.expectRevert(OrderVault.InvalidAmount.selector);
        vault.placeOrder{ value: 300e8 }(p);

        p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        p.typeParam = 0; // a limit order with no trigger price: the strategy's validate rejects it
        vm.prank(alice);
        vm.expectRevert(OrderVault.InvalidOrderParams.selector);
        vault.placeOrder{ value: 300e8 }(p);
    }

    function test_placeOrder_rejectsUnknownAndInactiveMarkets() public {
        PlaceParams memory p = _params(9, Side.SellBase, 250e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.UnknownMarket.selector, 9));
        vault.placeOrder{ value: 300e8 }(p);

        Market memory m = vault.getMarket(HBAR_MARKET);
        vm.prank(owner);
        vault.updateMarket(HBAR_MARKET, m.guard, m.sweep, false);
        p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.MarketInactive.selector, HBAR_MARKET));
        vault.placeOrder{ value: 300e8 }(p);
    }

    function test_placeOrder_revertsWhenMakerCannotReceiveNft() public {
        nft.setAssociated(alice, false);
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HtsError.selector, HtsOperation.TransferNft, int64(184)));
        vault.placeOrder{ value: 300e8 }(p);
    }

    function test_placeOrder_revertsBeforeInitialize() public {
        OrderVault fresh = new OrderVault(owner, vault.ROUTER(), address(whbar), MarketConfig.costs());
        vm.prank(alice);
        vm.expectRevert(OrderVault.NotInitialized.selector);
        fresh.placeOrder{ value: 300e8 }(_params(HBAR_MARKET, Side.SellBase, 250e8));
    }

    // ------------------------------------------------------------------ cancel and top-up

    function test_cancel_refundsEscrowAndBudgetAndWipesNft() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        // The last funded order leaving pays for the pending sweep's empty run.
        uint256 budget = vault.getOrder(orderId).budget - _idleSweep();
        uint256 before = alice.balance;

        vm.expectEmit(address(vault));
        emit OrderVault.OrderCancelled(orderId, alice, 250e8, budget);
        vm.prank(alice);
        vault.cancel(orderId);

        assertEq(alice.balance, before + 250e8 + budget);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Cancelled));
        assertEq(vault.escrowed(address(0)), 0);
        assertEq(vault.totalBudgets(), 0);
        assertEq(nft.ownerOf(orderId), address(0));
        assertEq(vault.openOrders(HBAR_MARKET).length, 0);
    }

    function test_cancel_refundsTokenEscrow() public {
        uint256 orderId = _buyHbar(alice, BELOW_MARKET, Trigger.AtOrBelow);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.cancel(orderId);
        assertEq(usdc.balanceOf(alice), before + 50e6);
    }

    function test_cancel_followsNftHolder() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        vm.prank(alice);
        nft.transferFrom(alice, bob, orderId);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.NotHolder.selector, orderId, alice));
        vault.cancel(orderId);

        uint256 before = bob.balance;
        vm.prank(bob);
        vault.cancel(orderId);
        assertGt(bob.balance, before + 250e8);
    }

    function test_cancel_revertsWhenNotOpen() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        vm.startPrank(alice);
        vault.cancel(orderId);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.OrderNotOpen.selector, orderId));
        vault.cancel(orderId);
        vm.stopPrank();
    }

    function test_cancel_creditsHolderThatRejectsHbar() public {
        HbarRejecter holder = new HbarRejecter();
        holder.associate(address(nft));
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget - _idleSweep();
        vm.prank(alice);
        nft.transferFrom(alice, address(holder), orderId);

        holder.cancel(vault, orderId);
        assertEq(vault.credits(address(holder), address(0)), 250e8 + budget);
        assertEq(vault.totalCredits(address(0)), 250e8 + budget);
    }

    function test_topUp_addsBudgetFromAnyone() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget;
        vm.prank(bob);
        vault.topUp{ value: 5e8 }(orderId);
        assertEq(vault.getOrder(orderId).budget, budget + 5e8);
        assertEq(vault.totalBudgets(), budget + 5e8);
    }

    function test_topUp_revertsOnZero() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        vm.expectRevert(OrderVault.InvalidAmount.selector);
        vault.topUp(orderId);
    }
}
