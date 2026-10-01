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
import { OrderVaultUnitBase } from "./OrderVault.t.sol";
import { MockHss } from "./mocks/MockHederaSystem.sol";
import { HbarRejecter } from "./mocks/Actors.sol";

/// @notice Scheduled sweeps, manual execution and payouts.
contract OrderVaultSweepTest is OrderVaultUnitBase {
    // ------------------------------------------------------------------ scheduled sweep

    function test_sweep_scheduled_chargesAndReschedules() public {
        uint256 orderId = _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget;
        _runScheduledSweep(HBAR_MARKET);

        uint256 share = lens.checkCost(HBAR_MARKET);
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

        uint256 share = lens.checkCostShared(2);
        assertEq(vault.getOrder(a).budget, budgetA - share);
        assertEq(vault.getOrder(b).budget, budgetB - share);
        assertLt(share, lens.checkCost(HBAR_MARKET));
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
        uint256 budget = lens.minBudget(HBAR_MARKET, Side.SellBase);
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
        uint256 float = lens.payerFloat();
        assertGt(float, 0, "a funded market reserves a float");
        uint256 owed = vault.escrowed(address(0)) + vault.totalBudgets() + vault.totalCredits(address(0)) + float;
        vm.deal(address(vault), owed + 3e8); // e.g. HTS creation fee change on top of everything owed
        assertEq(lens.surplus(), 3e8);
        uint256 before = owner.balance;
        vm.prank(owner);
        vault.withdrawSurplus(payable(owner));
        assertEq(owner.balance, before + 3e8);
        // The vault keeps the float liquid, so it can still pay its own keeper after the owner withdraws.
        assertEq(address(vault).balance, owed);
    }

    function test_fund_backsTheFloatAndIsWithdrawableAboveIt() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        uint256 float = lens.payerFloat();
        assertGt(float, 0);
        uint256 spareBefore = _spare();
        vm.deal(alice, 10e8);
        vm.prank(alice);
        vault.fund{ value: 10e8 }(); // anyone may keep the vault's keeper alive
        assertEq(_spare(), spareBefore + 10e8, "the endowment is spare HBAR");
        // The float stays put; only the endowment above it is withdrawable surplus.
        assertEq(lens.surplus(), spareBefore + 10e8 - float);
    }

    function test_fund_emitsFunded() public {
        vm.deal(alice, 5e8);
        vm.expectEmit(true, false, false, true, address(vault));
        emit OrderVault.Funded(alice, 5e8);
        vm.prank(alice);
        vault.fund{ value: 5e8 }();
    }

    function test_payerFloat_zeroWithoutFundedOrders() public view {
        assertEq(lens.payerFloat(), 0, "no funded market, nothing to reserve");
        assertEq(lens.surplus(), 0);
    }

    function test_surplus_withholdsPayerFloat() public {
        _sellHbar(alice, ABOVE_MARKET, Trigger.AtOrAbove);
        // The float covers one full scheduled sweep of the funded market at the configured price.
        uint256 float = lens.payerFloat();
        assertEq(float, _tinybar(lens.sweepGasLimit(HBAR_MARKET)), "float is one sweep at the configured price");
        // Give the vault exactly the float above what it owes: nothing is withdrawable.
        uint256 owed = vault.escrowed(address(0)) + vault.totalBudgets() + vault.totalCredits(address(0));
        vm.deal(address(vault), owed + float);
        assertEq(lens.surplus(), 0, "the float is not surplus");
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidAmount.selector);
        vault.withdrawSurplus(payable(owner));
    }

    function test_withdrawSurplus_revertsWhenNone() public {
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidAmount.selector);
        vault.withdrawSurplus(payable(owner));
    }
}
