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

/// @notice Rejects HBAR, like a contract holder without a payable fallback.
contract OrderVaultTest is OrderVaultBase {
    uint128 internal constant ABOVE_MARKET = 12_500_000; // 0.125 USDC per HBAR
    uint128 internal constant BELOW_MARKET = 10_000_000; // 0.100 USDC per HBAR

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
        assertEq(vault.checkCost(HBAR_MARKET), _tinybar(gas));
        // The mock exchange rate is testnet's (30,000 HBAR per 231,199 cents); one lookup prices a whole call.
        assertApproxEqAbs(vault.checkCost(HBAR_MARKET), tinycents * 30_000 / 231_199, 1);
    }

    function test_checkCostShared_fallsWithMoreOrders() public view {
        assertLt(vault.checkCostShared(10), vault.checkCostShared(1));
        assertEq(vault.checkCostShared(0), vault.checkCostShared(1));
    }

    function test_minBudget_isFillPlusSixSoloChecks() public view {
        assertEq(
            vault.minBudget(HBAR_MARKET, Side.SellBase),
            vault.fillCost(HBAR_MARKET, Side.SellBase) + 6 * vault.checkCost(HBAR_MARKET)
        );
        assertGt(vault.fillCost(HBAR_MARKET, Side.BuyBase), vault.fillCost(HBAR_MARKET, Side.SellBase));
    }

    // ------------------------------------------------------------------ placing orders

    function test_placeOrder_hbarIn_escrowsMintsAndSchedules() public {
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.SellBase);
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
        assertEq(next.gasLimit, vault.sweepGasLimit(HBAR_MARKET));
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
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.SellBase);
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.expectEmit(address(vault));
        emit OrderVault.OrderPlaced(
            1, HBAR_MARKET, alice, Side.SellBase, LIMIT, 250e8, ABOVE_MARKET, 50, block.timestamp + 7 days, budget
        );
        vm.prank(alice);
        vault.placeOrder{ value: 250e8 + budget }(p);
    }

    function test_placeOrder_rejectsBudgetBelowMinimum() public {
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.SellBase);
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

    // ------------------------------------------------------------------ scheduled sweep

    function test_sweep_scheduled_chargesAndReschedules() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget;
        _runScheduledSweep(HBAR_MARKET);

        uint256 share = vault.checkCost(HBAR_MARKET);
        assertEq(vault.getOrder(orderId).budget, budget - share);
        assertEq(vault.totalBudgets(), budget - share);
        assertEq(hss.count(), 2, "rescheduled");
        assertEq(hss.last().expiry, block.timestamp + 17_280, "the price hasn't moved, so the same wait");
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
    }

    function test_sweep_scheduled_splitsFixedCostAcrossOrders() public {
        uint256 a = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 b = _sellHbar(bob, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budgetA = vault.getOrder(a).budget;
        uint256 budgetB = vault.getOrder(b).budget;
        _runScheduledSweep(HBAR_MARKET);

        uint256 share = vault.checkCostShared(2);
        assertEq(vault.getOrder(a).budget, budgetA - share);
        assertEq(vault.getOrder(b).budget, budgetB - share);
        assertLt(share, vault.checkCost(HBAR_MARKET));
    }

    function test_sweep_fillsSellWhenTriggerMet() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        _setHbarPrice(13_000_000); // HBAR rallies to 0.13 USDC
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 hbarBefore = alice.balance;

        _runScheduledSweep(HBAR_MARKET);

        Order memory o = vault.getOrder(orderId);
        assertEq(uint8(o.status), uint8(Status.Filled));
        assertEq(usdc.balanceOf(alice) - usdcBefore, 32_500_000, "250 HBAR * 0.13 USDC");
        assertGt(alice.balance, hbarBefore, "unused budget refunded");
        assertEq(vault.escrowed(address(0)), 0);
        assertEq(vault.totalBudgets(), 0);
        assertEq(nft.ownerOf(orderId), address(0));
        assertEq(hss.count(), 1, "no reschedule once nothing is open");
    }

    function test_sweep_fillsBuyWithHbarOut() public {
        uint256 orderId = _buyHbar(alice, BELOW_MARKET, Trigger.AtOrBelow);
        _setHbarPrice(9_500_000); // HBAR dips to 0.095 USDC
        uint256 before = alice.balance;

        _runScheduledSweep(HBAR_MARKET);

        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        // 50 USDC / 0.095 = 526.3157 HBAR, plus the refunded budget
        assertGt(alice.balance - before, 526_31_000_000);
        assertEq(vault.escrowed(address(usdc)), 0);
    }

    function test_sweep_fillsDaiDepegStopLoss() public {
        uint256 orderId = _daiStop(alice, 99_500_000); // sell DAI at or below 0.995
        _setDaiPrice(99_000_000);
        uint256 before = usdc.balanceOf(alice);
        _runScheduledSweep(DAI_MARKET);

        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        assertEq(usdc.balanceOf(alice) - before, 990e6);
    }

    function test_sweep_stopLossDoesNotFireAboveTrigger() public {
        uint256 orderId = _sellHbar(alice, BELOW_MARKET, Trigger.AtOrBelow);
        _runScheduledSweep(HBAR_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
    }

    function test_sweep_holdsFillWhenPoolDeviatesFromOracle() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 at = hss.last().expiry;
        vm.warp(at);
        hbarFeed.set(13_000_000, at); // Chainlink moves to 0.13, the pool stays at 0.1116

        vm.expectEmit(true, false, false, false, address(vault));
        emit OrderVault.FillHeld(orderId, GuardState.DeviationTooHigh, 0, 0);
        _runScheduledSweep(HBAR_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
    }

    function test_sweep_holdsFillWhenOracleStale() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        _setHbarPrice(13_000_000);
        uint256 at = hss.last().expiry;
        hbarFeed.set(13_000_000, at - 90_001); // older than maxOracleAge when the sweep runs
        _runScheduledSweep(HBAR_MARKET);

        GuardReading memory g = vault.guardReading(HBAR_MARKET);
        assertEq(uint8(g.state), uint8(GuardState.OracleStale));
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
    }

    function test_guard_reportsInvalidOracleAndMissingTwap() public {
        hbarFeed.set(0, block.timestamp);
        assertEq(uint8(vault.guardReading(HBAR_MARKET).state), uint8(GuardState.OracleInvalid));
        hbarFeed.set(HBAR_USD, block.timestamp);
        hbarFeed.setBroken(true);
        assertEq(uint8(vault.guardReading(HBAR_MARKET).state), uint8(GuardState.OracleInvalid));
        hbarFeed.setBroken(false);
        hbarPool.setUnavailable(true);
        assertEq(uint8(vault.guardReading(HBAR_MARKET).state), uint8(GuardState.TwapUnavailable));
    }

    function test_guard_readsFixturePrices() public view {
        GuardReading memory g = vault.guardReading(HBAR_MARKET);
        assertEq(uint8(g.state), uint8(GuardState.Open));
        assertEq(g.oraclePrice, uint256(HBAR_USD));
        assertLt(g.deviationBps, 2);
    }

    function test_sweep_swapFailureLeavesOrderOpen() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        _setHbarPrice(13_000_000);
        router.setRate(address(whbar), address(usdc), RAY * 12_000_000 / 1e10); // executes 7.7% under the oracle
        _runScheduledSweep(HBAR_MARKET);

        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
        assertEq(vault.escrowed(address(0)), 250e8, "escrow untouched after a failed swap");
        assertEq(hss.count(), 2, "sweep chain survives the failure");
    }

    function test_sweep_expiresOrderAndRefunds() public {
        uint256 orderId = _buyHbar(alice, BELOW_MARKET, Trigger.AtOrBelow);
        uint256 before = usdc.balanceOf(alice);
        vm.warp(block.timestamp + 7 days); // the scheduled sweep fires late
        vm.prank(address(vault));
        vault.sweep(HBAR_MARKET, _epoch(HBAR_MARKET));

        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Expired));
        assertEq(usdc.balanceOf(alice), before + 50e6);
        assertEq(vault.escrowed(address(usdc)), 0);
        assertEq(vault.totalBudgets(), 0);
    }

    function test_sweep_parksOrderWhenBudgetRunsOut() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        for (uint256 i; i < 6; ++i) {
            _runScheduledSweep(HBAR_MARKET);
        }
        assertTrue(vault.getOrder(orderId).funded, "six checks are prepaid");
        uint256 before = vault.getOrder(orderId).budget;
        uint256 surplusBefore = _spare();
        _runScheduledSweep(HBAR_MARKET);
        Order memory o = vault.getOrder(orderId);
        assertFalse(o.funded);
        Costs memory c = MarketConfig.costs();
        // The chain's last sweep is paid from the order's reserve, not the vault's spare HBAR.
        assertEq(before - o.budget, _tinybar(uint256(c.sweepBaseGas) + c.checkGas), "pays for its final sweep");
        assertEq(_spare() - surplusBefore, before - o.budget);
        assertGe(o.budget, _tinybar(uint256(c.fillGasHbarIn) + c.settleGas), "the fill is still covered");
        assertEq(hss.count(), 7, "the chain stops once no order is funded");
    }

    function test_topUp_revivesParkedOrderAndRestartsSweep() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        for (uint256 i; i < 7; ++i) {
            _runScheduledSweep(HBAR_MARKET);
        }
        assertFalse(vault.getOrder(orderId).funded);
        vm.prank(alice);
        vault.topUp{ value: 10e8 }(orderId);
        assertTrue(vault.getOrder(orderId).funded);
        assertEq(hss.count(), 8);
    }

    function test_sweep_capsFillsPerSweep() public {
        for (uint256 i; i < 4; ++i) {
            _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        }
        _setHbarPrice(13_000_000);
        _runScheduledSweep(HBAR_MARKET);
        assertEq(vault.openOrders(HBAR_MARKET).length, 1, "maxFills is 3");
        _runScheduledSweep(HBAR_MARKET);
        assertEq(vault.openOrders(HBAR_MARKET).length, 0);
    }

    function test_sweep_manualCallDebitsNothingAndKeepsSchedule() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget;
        vm.prank(keeper);
        vault.sweep(HBAR_MARKET, 0);
        assertEq(vault.getOrder(orderId).budget, budget);
        assertEq(hss.count(), 1);
    }

    function test_sweep_rotatesCursorAcrossLargeBooks() public {
        Market memory m = vault.getMarket(HBAR_MARKET);
        m.sweep.maxOrders = 2;
        m.sweep.maxFills = 1;
        vm.prank(owner);
        vault.updateMarket(HBAR_MARKET, m.guard, m.sweep, true);
        uint256 a = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 b = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 c = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budgetC = vault.getOrder(c).budget;

        _runScheduledSweep(HBAR_MARKET);
        assertEq(vault.getOrder(c).budget, budgetC, "third order waits for the next sweep");
        assertLt(vault.getOrder(a).budget, budgetC);
        assertLt(vault.getOrder(b).budget, budgetC);
        _runScheduledSweep(HBAR_MARKET);
        assertLt(vault.getOrder(c).budget, budgetC, "cursor reached it");
    }

    function test_sweep_scheduleFailureCanBeRestarted() public {
        hss.forceCode(355); // SCHEDULE_EXPIRY_IS_BUSY
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.SellBase);
        PlaceParams memory p = _params(HBAR_MARKET, Side.SellBase, 250e8);
        vm.expectEmit(address(vault));
        emit OrderVault.SweepScheduleFailed(HBAR_MARKET, 355);
        vm.prank(alice);
        vault.placeOrder{ value: 250e8 + budget }(p);
        (address pending,,,,,) = vault.sweeps(HBAR_MARKET);
        assertEq(pending, address(0));

        hss.forceCode(0);
        vm.prank(keeper);
        vault.restartSweep(HBAR_MARKET);
        (pending,,,,,) = vault.sweeps(HBAR_MARKET);
        assertTrue(pending != address(0));
    }

    function test_restartSweep_revertsWhileAlive() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        (, uint40 at,,,,) = vault.sweeps(HBAR_MARKET);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.SweepAlive.selector, HBAR_MARKET, uint256(at)));
        vault.restartSweep(HBAR_MARKET);
    }

    function test_restartSweep_worksAfterMissedExpiry() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        vm.warp(hss.last().expiry + 121); // the scheduled sweep never fired
        vault.restartSweep(HBAR_MARKET);
        assertEq(hss.count(), 2);
    }

    function test_restartSweep_revertsWithoutFundedOrders() public {
        vm.expectRevert(abi.encodeWithSelector(OrderVault.NoFundedOrders.selector, HBAR_MARKET));
        vault.restartSweep(HBAR_MARKET);
    }

    function test_sweep_findsCapacityOrFallsBack() public {
        hss.setNoCapacity(true);
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        assertEq(hss.last().expiry, block.timestamp + 17_280, "falls back to the target second");
    }

    // ------------------------------------------------------------------ manual execution

    function test_executeOrder_fillsWithoutCheckDebit() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget;
        _setHbarPrice(13_000_000);
        uint256 before = alice.balance;

        vm.prank(keeper);
        assertTrue(vault.executeOrder(orderId));
        // The keeper paid for the check; the order only pays for the pending sweep it leaves behind.
        assertEq(alice.balance, before + budget - _idleSweep(), "budget refunded");
    }

    function test_executeOrder_returnsFalseWhenTriggerNotMet() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        assertFalse(vault.executeOrder(orderId));
    }

    function test_executeOrder_heldByGuard() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        hbarFeed.set(13_000_000, block.timestamp);
        vm.expectEmit(true, false, false, false, address(vault));
        emit OrderVault.FillHeld(orderId, GuardState.DeviationTooHigh, 0, 0);
        assertFalse(vault.executeOrder(orderId));
    }

    function test_executeOrder_expires() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        vm.warp(block.timestamp + 7 days);
        assertTrue(vault.executeOrder(orderId));
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Expired));
    }

    function test_fillFromVault_onlySelf() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        vm.expectRevert(OrderVault.OnlySelf.selector);
        vault.fillFromVault(orderId, 1, 1);
    }

    // ------------------------------------------------------------------ payouts

    function test_fill_creditsUnassociatedHolderAndClaimLater() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        _setHbarPrice(13_000_000);
        usdc.setBlocked(alice, true);
        _runScheduledSweep(HBAR_MARKET);

        assertEq(vault.credits(alice, address(usdc)), 32_500_000);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));

        usdc.setBlocked(alice, false);
        vm.prank(alice);
        vault.claim(address(usdc));
        assertEq(vault.credits(alice, address(usdc)), 0);
        assertEq(vault.totalCredits(address(usdc)), 0);
    }

    function test_claim_revertsWhenNothingOwed() public {
        vm.prank(alice);
        vm.expectRevert(OrderVault.NothingToClaim.selector);
        vault.claim(address(0));
    }

    function test_receive_onlyFromRouter() public {
        vm.prank(alice);
        (bool ok,) = address(vault).call{ value: 1 }("");
        assertFalse(ok);
    }

    function test_withdrawSurplus_neverTouchesOwedFunds() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 float = vault.payerFloat();
        assertGt(float, 0, "a funded market reserves a float");
        uint256 owed = vault.escrowed(address(0)) + vault.totalBudgets() + vault.totalCredits(address(0)) + float;
        vm.deal(address(vault), owed + 3e8); // e.g. HTS creation fee change on top of everything owed
        assertEq(vault.surplus(), 3e8);
        uint256 before = owner.balance;
        vm.prank(owner);
        vault.withdrawSurplus(payable(owner));
        assertEq(owner.balance, before + 3e8);
        // The vault keeps the float liquid, so it can still pay its own keeper after the owner withdraws.
        assertEq(address(vault).balance, owed);
    }

    function test_fund_backsTheFloatAndIsWithdrawableAboveIt() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 float = vault.payerFloat();
        assertGt(float, 0);
        uint256 spareBefore = _spare();
        vm.deal(alice, 10e8);
        vm.prank(alice);
        vault.fund{ value: 10e8 }(); // anyone may keep the vault's keeper alive
        assertEq(_spare(), spareBefore + 10e8, "the endowment is spare HBAR");
        // The float stays put; only the endowment above it is withdrawable surplus.
        assertEq(vault.surplus(), spareBefore + 10e8 - float);
    }

    function test_fund_emitsFunded() public {
        vm.deal(alice, 5e8);
        vm.expectEmit(true, false, false, true, address(vault));
        emit OrderVault.Funded(alice, 5e8);
        vm.prank(alice);
        vault.fund{ value: 5e8 }();
    }

    function test_payerFloat_zeroWithoutFundedOrders() public view {
        assertEq(vault.payerFloat(), 0, "no funded market, nothing to reserve");
        assertEq(vault.surplus(), 0);
    }

    function test_surplus_withholdsPayerFloat() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        // The float covers one full scheduled sweep of the funded market at the configured price.
        uint256 float = vault.payerFloat();
        assertEq(float, _tinybar(vault.sweepGasLimit(HBAR_MARKET)), "float is one sweep at the configured price");
        // Give the vault exactly the float above what it owes: nothing is withdrawable.
        uint256 owed = vault.escrowed(address(0)) + vault.totalBudgets() + vault.totalCredits(address(0));
        vm.deal(address(vault), owed + float);
        assertEq(vault.surplus(), 0, "the float is not surplus");
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidAmount.selector);
        vault.withdrawSurplus(payable(owner));
    }

    function test_withdrawSurplus_revertsWhenNone() public {
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidAmount.selector);
        vault.withdrawSurplus(payable(owner));
    }

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
