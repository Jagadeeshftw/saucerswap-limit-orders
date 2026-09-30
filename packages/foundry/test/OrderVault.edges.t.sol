// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { MarketGuard } from "../contracts/libraries/MarketGuard.sol";
import {
    Costs,
    GuardParams,
    Market,
    Order,
    PlaceParams,
    Side,
    Status,
    SweepParams,
    SweepStatus,
    Trigger
} from "../contracts/types/OrderTypes.sol";
import { IAggregatorV3 } from "../contracts/interfaces/IAggregatorV3.sol";
import { ISaucerSwapV2Pool } from "../contracts/interfaces/ISaucerSwapV2.sol";
import { MarketConfig } from "../script/MarketConfig.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { HbarRejecter } from "./mocks/Actors.sol";
import { MockExchangeRate, MockHss } from "./mocks/MockHederaSystem.sol";

/// @notice Scheduling policy, stalled sweeps, parameter bounds and every failure path of the vault.
contract OrderVaultEdgeTest is OrderVaultBase {
    uint128 internal constant FAR = 12_500_000; // 12.0% above 0.1116: ~4.8 h at 250 bps/h
    uint128 internal constant NEAR = 11_300_000; // 1.25% above: 30 min
    uint256 internal constant FAR_DELAY = 17_280;

    // ------------------------------------------------------------------ scheduling policy

    function test_nextCheckDelay_followsDistanceWithinBounds() public {
        uint256 expiry = block.timestamp + 7 days;
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, FAR, expiry), FAR_DELAY);
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, NEAR, expiry), 1_800);
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, 20_000_000, expiry), 6 hours, "capped");
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, 11_170_000, expiry), 300, "floored");
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, 10_000_000, expiry), 300, "already met");
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrBelow, 10_000_000, expiry), 14_961, "stop 10.4% down");
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, FAR, block.timestamp + 1_000), 1_000, "expiry");
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, FAR, block.timestamp + 100), 300);
        hbarFeed.set(0, block.timestamp);
        assertEq(vault.nextCheckDelay(HBAR_MARKET, Trigger.AtOrAbove, FAR, expiry), 300, "no price: check soon");
    }

    function test_placeOrder_nearTriggerSupersedesPendingSweep() public {
        uint256 far = _sellHbar(alice, FAR, Trigger.AtOrAbove);
        assertEq(hss.last().expiry, block.timestamp + FAR_DELAY);
        uint256 farBudget = vault.getOrder(far).budget;

        vm.recordLogs();
        uint256 near = _sellHbar(bob, NEAR, Trigger.AtOrAbove);
        assertTrue(_emitted(OrderVault.SweepBroughtForward.selector), "the trail shows why the budget dipped");
        assertEq(hss.count(), 2, "an earlier sweep was scheduled");
        assertEq(hss.last().expiry, block.timestamp + 1_800);
        assertEq(_epoch(HBAR_MARKET), 2);
        assertEq(
            vault.getOrder(near).budget,
            vault.minBudget(HBAR_MARKET, Side.SellBase) - _idleSweep(),
            "the order that brought the sweep forward pays for the superseded run"
        );

        // HSS still fires the superseded schedule: it returns without touching any order.
        MockHss.Scheduled memory stale = hss.job(0);
        vm.warp(stale.expiry);
        vm.expectEmit(address(vault));
        emit OrderVault.SweepSuperseded(HBAR_MARKET, 1);
        vm.prank(address(vault));
        (bool ok,) = address(vault).call{ gas: stale.gasLimit }(stale.callData);
        assertTrue(ok);
        assertEq(vault.getOrder(far).budget, farBudget);
        assertEq(hss.count(), 2, "no reschedule from a stale sweep");
    }

    function test_placeOrder_doesNotSupersedeWhenPendingSweepIsSoonEnough() public {
        _sellHbar(alice, NEAR, Trigger.AtOrAbove);
        _sellHbar(bob, FAR, Trigger.AtOrAbove);
        assertEq(hss.count(), 1);
        assertEq(_epoch(HBAR_MARKET), 1);
    }

    function test_sweep_nextWaitComesFromNearestTrigger() public {
        _sellHbar(alice, FAR, Trigger.AtOrAbove);
        _sellHbar(bob, 20_000_000, Trigger.AtOrAbove);
        _runScheduledSweep(HBAR_MARKET);
        assertEq(hss.last().expiry, block.timestamp + FAR_DELAY, "the nearer of the two triggers sets the pace");
    }

    function test_sweep_backsOffWhileGuardHoldsThenResets() public {
        uint256 orderId = _placeSellHbar(alice, FAR, 60e8);
        hbarFeed.set(13_000_000, block.timestamp); // Chainlink above the trigger, pool left behind: held
        uint256[8] memory expected = [uint256(600), 1_200, 2_400, 4_800, 9_600, 19_200, 21_600, 21_600];
        for (uint256 i; i < expected.length; ++i) {
            MockHss.Scheduled memory job = hss.last();
            vm.warp(job.expiry);
            hbarFeed.set(13_000_000, job.expiry);
            usdcFeed.set(1e8, job.expiry);
            _runScheduledSweep(HBAR_MARKET);
            assertEq(hss.last().expiry - block.timestamp, expected[i]);
        }
        (,,,,, uint8 streak) = vault.sweeps(HBAR_MARKET);
        assertEq(streak, 8, "streak is capped");

        vm.warp(hss.last().expiry);
        usdcFeed.set(1e8, block.timestamp);
        _setHbarPrice(13_000_000); // the pool catches up: the guard opens
        _runScheduledSweep(HBAR_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        (,,,,, streak) = vault.sweeps(HBAR_MARKET);
        assertEq(streak, 0);
    }

    function test_sweep_rechecksSoonWhenGasRunsShort() public {
        for (uint256 i; i < 5; ++i) {
            _sellHbar(alice, FAR, Trigger.AtOrAbove);
        }
        MockHss.Scheduled memory job = hss.last();
        vm.warp(job.expiry);
        Costs memory c = MarketConfig.costs();
        // Enough to start the loop but not to check all five and still keep the reschedule reserve.
        uint256 gas = uint256(c.scheduleGas) + c.sweepBaseGas + c.checkGas + c.settleGas + 20_000;
        vm.prank(address(vault));
        (bool ok,) = address(vault).call{ gas: gas }(job.callData);
        assertTrue(ok, "a short sweep still finishes");
        assertEq(hss.last().expiry, block.timestamp + 300, "unchecked orders are picked up at minInterval");
    }

    function test_findCapacity_movesPastBusySeconds() public {
        hss.setBusyUntil(block.timestamp + FAR_DELAY + 1);
        _sellHbar(alice, FAR, Trigger.AtOrAbove);
        assertEq(hss.last().expiry, block.timestamp + FAR_DELAY + 1);
    }

    function test_sweepGasLimit_sizesForTheBook() public {
        Costs memory c = MarketConfig.costs();
        uint256 perOrder = uint256(c.checkGas) + c.settleGas;
        uint256 perFill = uint256(c.fillGasTokenIn) + c.settleGas;
        uint256 finish = uint256(c.scheduleGas) + c.sweepBaseGas;
        assertEq(vault.sweepGasLimit(DAI_MARKET), finish + perOrder + perFill, "an empty book is sized for one");
        for (uint256 i; i < 4; ++i) {
            _sellHbar(alice, FAR, Trigger.AtOrAbove);
        }
        assertEq(vault.sweepGasLimit(HBAR_MARKET), finish + 4 * perOrder + 3 * perFill, "fills cap at maxFills");
    }

    // ------------------------------------------------------------------ stalled sweeps

    function test_sweepStatus_reportsIdleScheduledAndStalled() public {
        (SweepStatus status, uint256 at) = vault.sweepStatus(HBAR_MARKET);
        assertEq(uint8(status), uint8(SweepStatus.Idle));
        assertEq(at, 0);

        _sellHbar(alice, FAR, Trigger.AtOrAbove);
        (status, at) = vault.sweepStatus(HBAR_MARKET);
        assertEq(uint8(status), uint8(SweepStatus.Scheduled));
        assertEq(at, hss.last().expiry);

        vm.warp(at + 121); // HSS never ran it, e.g. the vault could not pay
        (status,) = vault.sweepStatus(HBAR_MARKET);
        assertEq(uint8(status), uint8(SweepStatus.Stalled));

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vault.restartSweep(HBAR_MARKET);
        (status, at) = vault.sweepStatus(HBAR_MARKET);
        assertEq(uint8(status), uint8(SweepStatus.Scheduled));
        assertEq(at, block.timestamp + 300);
    }

    // ------------------------------------------------------------------ budgets

    function test_parkedOrder_paysOnlyItsCheckWhileOthersPay() public {
        uint256 small = _sellHbar(alice, FAR, Trigger.AtOrAbove);
        uint256 big = _placeSellHbar(bob, FAR, 100e8);
        uint256 before;
        for (uint256 i; i < 40 && vault.getOrder(small).funded; ++i) {
            before = vault.getOrder(small).budget;
            _runScheduledSweep(HBAR_MARKET);
        }
        assertFalse(vault.getOrder(small).funded);
        assertEq(before - vault.getOrder(small).budget, _tinybar(MarketConfig.costs().checkGas));

        uint256 parked = vault.getOrder(small).budget;
        uint256 bigBefore = vault.getOrder(big).budget;
        _runScheduledSweep(HBAR_MARKET);
        assertEq(vault.getOrder(small).budget, parked, "a parked order is skipped");
        assertEq(bigBefore - vault.getOrder(big).budget, vault.checkCost(HBAR_MARKET), "the payer carries the sweep");
    }

    function test_lastOrderLeaving_payingAllOfItsIdleCostLeavesNoRefund() public {
        Costs memory c = MarketConfig.costs();
        c.idleSweepGas = type(uint32).max;
        vm.prank(owner);
        vault.setCosts(c);
        uint256 orderId = _buyHbar(alice, 10_000_000, Trigger.AtOrBelow);
        vm.expectEmit(address(vault));
        emit OrderVault.OrderCancelled(orderId, alice, 50e6, 0);
        vm.prank(alice);
        vault.cancel(orderId);
    }

    // ------------------------------------------------------------------ parameter bounds

    function test_updateMarket_boundsTwapWindow() public {
        _expectGuardRejected(_guardWith(299, 90_000));
        _expectGuardRejected(_guardWith(1 days + 1, 90_000));
        _expectGuardAccepted(_guardWith(300, 90_000));
        _expectGuardAccepted(_guardWith(1 days, 90_000));
    }

    function test_updateMarket_boundsOracleAge() public {
        _expectGuardRejected(_guardWith(1_800, 59));
        _expectGuardRejected(_guardWith(1_800, 26 hours + 1));
        _expectGuardAccepted(_guardWith(1_800, 60));
        _expectGuardAccepted(_guardWith(1_800, 26 hours));
    }

    function test_guardParamsValid_rejectsUnboundedDeviationAndSlippage() public pure {
        GuardParams memory g = MarketConfig.hbarUsdc().guard;
        g.maxDeviationBps = 0;
        assertFalse(MarketGuard.paramsValid(g, 3_000));
        g.maxDeviationBps = 200;
        g.maxSlippageBps = 1_001;
        assertFalse(MarketGuard.paramsValid(g, 3_000));
        g.maxSlippageBps = 300;
        assertTrue(MarketGuard.paramsValid(g, 3_000));
    }

    function test_updateMarket_boundsSweepShape() public {
        SweepParams memory s = MarketConfig.hbarUsdc().sweep;
        GuardParams memory g = MarketConfig.hbarUsdc().guard;
        SweepParams[4] memory bad = [s, s, s, s];
        bad[0].maxInterval = 1 days + 1;
        bad[1].maxOrders = 0;
        bad[2].maxFills = 0;
        bad[3].maxFills = 21; // more fills than orders checked
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(OrderVault.InvalidSweep.selector);
            vault.updateMarket(HBAR_MARKET, g, bad[i], true);
        }
    }

    function test_listMarket_rejectsIncompleteMarkets() public {
        Market[6] memory bad;
        for (uint256 i; i < bad.length; ++i) {
            bad[i] = _daiMarket();
        }
        bad[0].pool = ISaucerSwapV2Pool(address(0));
        bad[1].base = address(0);
        bad[2].quote = address(0);
        bad[3].quote = bad[3].base;
        bad[4].baseIsHbar = true;
        bad[4].quoteIsHbar = true;
        bad[5].quoteFeed = IAggregatorV3(address(0));
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(OrderVault.InvalidMarket.selector);
            vault.listMarket(bad[i]);
        }
    }

    function test_listMarket_revertsWhenAssociationFails() public {
        hts.forceAssociateCode(15);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.HtsError.selector, OrderVault.HtsOperation.Associate, 15));
        vault.listMarket(_daiMarket());
    }

    function test_setCosts_rejectsMissingGas() public {
        Costs memory base = MarketConfig.costs();
        Costs[5] memory bad = [base, base, base, base, base];
        bad[0].scheduleGas = 0;
        bad[1].checkGas = 0;
        bad[2].fillGasHbarIn = 0;
        bad[3].fillGasTokenIn = 0;
        bad[4].safetyBps = 10_001;
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(OrderVault.InvalidCosts.selector);
            vault.setCosts(bad[i]);
        }
    }

    function test_costViews_revertWhenExchangeRateIsDown() public {
        vm.etch(address(0x168), hex"fe");
        vm.expectRevert(OrderVault.InvalidCosts.selector);
        vault.checkCost(HBAR_MARKET);
        vm.etch(address(0x168), address(new MockExchangeRate()).code);
        assertGt(vault.checkCost(HBAR_MARKET), 0);
    }

    // ------------------------------------------------------------------ failure paths

    function test_placeOrder_revertsWhenMintFails() public {
        hts.forceMintCode(21);
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.SellBase);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.HtsError.selector, OrderVault.HtsOperation.Mint, 21));
        vault.placeOrder{ value: 250e8 + budget }(_sellParams(FAR));
    }

    function test_placeOrder_revertsWhenTokenPullReturnsFalse() public {
        usdc.setRefuses(true);
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.BuyBase);
        PlaceParams memory p = _sellParams(10_000_000);
        p.side = Side.BuyBase;
        p.trigger = Trigger.AtOrBelow;
        p.amountIn = 50e6;
        vm.prank(alice);
        vm.expectRevert(OrderVault.TransferFailed.selector);
        vault.placeOrder{ value: budget }(p);
    }

    function test_fill_failsCleanlyWhenApproveReturnsFalse() public {
        uint256 orderId = _daiStop(alice, 99_500_000);
        dai.setRefuses(true);
        _setDaiPrice(99_000_000);
        vm.expectEmit(true, false, false, false, address(vault));
        emit OrderVault.FillFailed(orderId, "");
        _runScheduledSweep(DAI_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
        assertEq(vault.escrowed(address(dai)), 1_000e8);
    }

    function test_settlement_carriesOnWhenWipeFails() public {
        uint256 orderId = _sellHbar(alice, FAR, Trigger.AtOrAbove);
        hts.forceWipeCode(237);
        vm.expectEmit(address(vault));
        emit OrderVault.NftSettlementFailed(orderId, 237);
        vm.prank(alice);
        vault.cancel(orderId);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Cancelled));
        assertEq(vault.escrowed(address(0)), 0);
    }

    function test_settlement_burnsAnNftSentToTheVault() public {
        uint256 orderId = _sellHbar(alice, FAR, Trigger.AtOrAbove);
        uint256 budget = vault.getOrder(orderId).budget;
        vm.prank(alice);
        nft.transferFrom(alice, address(vault), orderId);
        vm.warp(block.timestamp + 7 days);
        assertTrue(vault.executeOrder(orderId));
        assertEq(nft.ownerOf(orderId), address(0), "burned from the treasury");
        // Nobody can claim for the vault itself: sending it the NFT gives the order up.
        assertEq(vault.credits(address(vault), address(0)), 250e8 + budget);
    }

    function test_claim_hbarCreditWaitsUntilTheHolderAccepts() public {
        HbarRejecter holder = new HbarRejecter();
        holder.associate(address(nft));
        uint256 orderId = _sellHbar(alice, FAR, Trigger.AtOrAbove);
        vm.prank(alice);
        nft.transferFrom(alice, address(holder), orderId);
        holder.cancel(vault, orderId);
        uint256 owed = vault.credits(address(holder), address(0));
        assertGt(owed, 250e8);

        vm.expectRevert(OrderVault.TransferFailed.selector);
        holder.claim(vault, address(0));
        holder.setAccepts(true);
        holder.claim(vault, address(0));
        assertEq(address(holder).balance, owed);
        assertEq(vault.totalCredits(address(0)), 0);
    }

    function test_claim_tokenCreditRevertsWhileStillBlocked() public {
        uint256 orderId = _sellHbar(alice, FAR, Trigger.AtOrAbove);
        usdc.setBlocked(alice, true);
        _setHbarPrice(13_000_000);
        _runScheduledSweep(HBAR_MARKET);
        assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        vm.prank(alice);
        vm.expectRevert(OrderVault.TransferFailed.selector);
        vault.claim(address(usdc));
    }

    function test_withdrawSurplus_revertsWhenRecipientRejects() public {
        _sellHbar(alice, FAR, Trigger.AtOrAbove);
        _runScheduledSweep(HBAR_MARKET); // the check fee becomes surplus once the vault has paid it
        assertGt(vault.surplus(), 0);
        HbarRejecter rejecter = new HbarRejecter();
        vm.prank(owner);
        vm.expectRevert(OrderVault.TransferFailed.selector);
        vault.withdrawSurplus(payable(address(rejecter)));
    }

    // ------------------------------------------------------------------ helpers

    function _emitted(bytes32 topic) internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _sellParams(uint128 trigger) internal view returns (PlaceParams memory) {
        return PlaceParams({
            marketId: uint32(HBAR_MARKET),
            side: Side.SellBase,
            trigger: Trigger.AtOrAbove,
            amountIn: 250e8,
            triggerPrice: trigger,
            slippageBps: 50,
            expiry: uint40(block.timestamp + 7 days)
        });
    }

    function _placeSellHbar(address maker, uint128 trigger, uint256 extraBudget) internal returns (uint256) {
        uint256 budget = vault.minBudget(HBAR_MARKET, Side.SellBase) + extraBudget;
        vm.prank(maker);
        return vault.placeOrder{ value: 250e8 + budget }(_sellParams(trigger));
    }

    function _guardWith(uint32 twapWindow, uint32 maxOracleAge) internal pure returns (GuardParams memory g) {
        g = MarketConfig.hbarUsdc().guard;
        g.twapWindow = twapWindow;
        g.maxOracleAge = maxOracleAge;
    }

    function _expectGuardRejected(GuardParams memory g) internal {
        SweepParams memory s = vault.getMarket(HBAR_MARKET).sweep;
        vm.prank(owner);
        vm.expectRevert(OrderVault.InvalidGuard.selector);
        vault.updateMarket(HBAR_MARKET, g, s, true);
    }

    function _expectGuardAccepted(GuardParams memory g) internal {
        SweepParams memory s = vault.getMarket(HBAR_MARKET).sweep;
        vm.prank(owner);
        vault.updateMarket(HBAR_MARKET, g, s, true);
        assertEq(vault.getMarket(HBAR_MARKET).guard.twapWindow, g.twapWindow);
    }
}
