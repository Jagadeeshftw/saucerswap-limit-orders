// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Test.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { PriceMath } from "../contracts/libraries/PriceMath.sol";
import { Order, PlaceParams, Side, Status, Trigger } from "../contracts/types/OrderTypes.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";

/// @notice Property tests over amounts, decimals, budgets, triggers and execution prices.
contract OrderVaultFuzzTest is OrderVaultBase {
    struct Case {
        uint256 marketId;
        Side side;
        Trigger trigger;
        uint256 amount;
        uint256 budget;
        uint256 triggerPrice;
        uint16 slippage;
        uint256 lifetime;
    }

    // ------------------------------------------------------------------ placing

    function testFuzz_placeOrder_escrowsAndFundsAnyValidOrder(
        bool dai,
        bool buy,
        bool above,
        uint256 amountSeed,
        uint256 extra,
        uint256 triggerSeed,
        uint256 lifetime
    ) public {
        Case memory c = _case(dai, buy, above, amountSeed, extra, triggerSeed, lifetime);
        uint256 orderId = _place(alice, c);

        Order memory o = vault.getOrder(orderId);
        assertEq(uint8(o.status), uint8(Status.Open));
        assertTrue(o.funded);
        assertEq(o.amountIn, c.amount);
        assertEq(o.budget, c.budget);
        assertEq(vault.escrowed(_tokenIn(c)), c.amount);
        assertEq(vault.totalBudgets(), c.budget);
        assertEq(vault.holderOf(orderId), alice);
        assertEq(hss.count(), 1, "the market's sweep starts");
        uint256 wait = hss.last().expiry - block.timestamp;
        assertGe(wait, 300);
        assertLe(wait, 6 hours);
        _assertSolvent();
    }

    function testFuzz_placeOrder_rejectsSlippageOutsideTheMarketsRange(uint16 slippage, bool dai) public {
        Case memory c = _case(dai, false, true, 1e8, 0, 0, 1 days);
        uint256 minBps = dai ? 5 : 30;
        uint256 maxBps = dai ? 100 : 300;
        vm.assume(slippage <= minBps || slippage > maxBps);
        c.slippage = slippage;
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InvalidSlippage.selector, slippage, minBps + 1, maxBps));
        _place(alice, c);
    }

    function testFuzz_placeOrder_rejectsExpiryOutsideLifetime(uint256 lifetime) public {
        lifetime = bound(lifetime, 90 days + 1, 10 * 365 days);
        Case memory c = _case(false, false, true, 10e8, 0, 0, 1 days);
        c.lifetime = lifetime;
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InvalidExpiry.selector, block.timestamp + lifetime));
        _place(alice, c);
    }

    // ------------------------------------------------------------------ cancel and top up

    function testFuzz_cancel_returnsEscrowAndBudgetToTheHolder(
        bool dai,
        bool buy,
        uint256 amountSeed,
        uint256 extra,
        bool transferFirst
    ) public {
        Case memory c = _case(dai, buy, true, amountSeed, extra, 0, 7 days);
        uint256 orderId = _place(alice, c);
        address holder = alice;
        if (transferFirst) {
            vm.prank(alice);
            nft.transferFrom(alice, bob, orderId);
            holder = bob;
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(OrderVault.NotHolder.selector, orderId, alice));
            vault.cancel(orderId);
        }
        address tokenIn = _tokenIn(c);
        uint256 tokenBefore = tokenIn == address(0) ? 0 : _balance(tokenIn, holder);
        uint256 hbarBefore = holder.balance;

        vm.prank(holder);
        vault.cancel(orderId);

        uint256 budgetBack = c.budget - _idleSweep();
        if (tokenIn == address(0)) {
            assertEq(holder.balance - hbarBefore, c.amount + budgetBack);
        } else {
            assertEq(_balance(tokenIn, holder) - tokenBefore, c.amount);
            assertEq(holder.balance - hbarBefore, budgetBack);
        }
        assertEq(vault.escrowed(tokenIn), 0);
        assertEq(vault.totalBudgets(), 0);
        assertEq(nft.ownerOf(orderId), address(0));
        _assertSolvent();
    }

    function testFuzz_topUp_revivesOnlyWhenACheckIsAffordable(uint256 amount) public {
        Case memory c = _case(false, false, true, 250e8, 0, 0, 7 days);
        c.triggerPrice = 12_500_000;
        uint256 orderId = _place(alice, c);
        for (uint256 i; i < 7; ++i) {
            _runScheduledSweep(HBAR_MARKET);
        }
        assertFalse(vault.getOrder(orderId).funded, "parked after its prepaid checks");
        uint256 schedules = hss.count();

        amount = bound(amount, 1, 10e8);
        uint256 budget = vault.getOrder(orderId).budget + amount;
        vm.prank(bob);
        vault.topUp{ value: amount }(orderId);

        bool affordable = budget >= vault.fillCost(HBAR_MARKET, Side.SellBase) + vault.checkCost(HBAR_MARKET);
        assertEq(vault.getOrder(orderId).funded, affordable);
        assertEq(hss.count(), affordable ? schedules + 1 : schedules, "checks resume only for a funded order");
        assertEq(vault.getOrder(orderId).budget, budget);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ sweeps

    function testFuzz_scheduledSweep_chargesEveryOrderTheSameShare(uint8 count, uint256 seed) public {
        uint256 n = bound(count, 1, 8);
        uint256[] memory ids = new uint256[](n);
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 extra = uint256(keccak256(abi.encode(seed, i))) % 50e8;
            Case memory c = _case(false, false, true, 10e8, extra, 0, 7 days);
            c.triggerPrice = 12_500_000;
            ids[i] = _place(i % 2 == 0 ? alice : bob, c);
            before[i] = vault.getOrder(ids[i]).budget;
        }
        uint256 surplusBefore = _spare();
        _runScheduledSweep(HBAR_MARKET);

        uint256 share = vault.checkCostShared(n);
        for (uint256 i; i < n; ++i) {
            Order memory o = vault.getOrder(ids[i]);
            assertEq(before[i] - o.budget, share, "every order pays the same share");
            assertGe(o.budget, vault.fillCost(HBAR_MARKET, Side.SellBase), "the reserve is untouched");
        }
        assertEq(_spare() - surplusBefore, n * share, "the vault keeps exactly what it charged");
        // Each share rounds its slice of the fixed gas up by at most one gas.
        assertLe(
            share * n,
            vault.checkCost(HBAR_MARKET) + (n - 1) * _tinybar(60_000) + n * (_tinybar(1) + 1),
            "sharing never costs more than one sweep"
        );
    }

    function testFuzz_fill_neverPaysLessThanTheSlippageBound(
        bool dai,
        bool buy,
        uint256 amountSeed,
        uint256 slippageSeed,
        uint256 execBps
    ) public {
        Case memory c = _case(dai, buy, !buy, amountSeed, 0, 0, 7 days);
        c.slippage = uint16(bound(slippageSeed, dai ? 6 : 31, dai ? 100 : 300));
        uint256 price = vault.guardReading(c.marketId).oraclePrice;
        // Limit orders one percent from the market, then the market moves two percent through them.
        c.triggerPrice = buy ? price * 99 / 100 : price * 101 / 100;
        uint256 orderId = _place(alice, c);
        uint256 moved = buy ? price * 98 / 100 : price * 102 / 100;
        if (dai) _setDaiPrice(int256(moved));
        else _setHbarPrice(int256(moved));

        execBps = bound(execBps, 0, 2 * uint256(c.slippage));
        (address tokenIn, address tokenOut) = _route(c);
        router.setRate(tokenIn, tokenOut, router.rateRay(tokenIn, tokenOut) * (10_000 - execBps) / 10_000);

        vm.recordLogs();
        _runScheduledSweep(c.marketId);
        (bool filled, uint256 amountOut, uint256 minOut) = _filled(orderId);

        uint256 fair = buy ? PriceMath.quoteToBase(c.amount, moved, 8, 6) : PriceMath.baseToQuote(c.amount, moved, 8, 6);
        if (execBps <= c.slippage && fair * (10_000 - execBps) / 10_000 >= PriceMath.lessBps(fair, c.slippage)) {
            assertTrue(filled, "fills within slippage");
        }
        if (filled) {
            assertEq(minOut, PriceMath.lessBps(fair, c.slippage), "min out comes from Chainlink, not the pool");
            assertGe(amountOut, minOut);
            assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Filled));
        } else {
            assertEq(uint8(vault.getOrder(orderId).status), uint8(Status.Open));
            assertEq(vault.escrowed(tokenIn == address(whbar) ? address(0) : tokenIn), c.amount, "escrow kept");
        }
        _assertSolvent();
    }

    function testFuzz_nextCheckDelay_isBoundedAndGrowsWithDistance(uint256 a, uint256 b, bool above, uint256 lifetime)
        public
        view
    {
        uint256 price = vault.guardReading(HBAR_MARKET).oraclePrice;
        lifetime = bound(lifetime, 1, 90 days);
        uint256 expiry = block.timestamp + lifetime;
        uint256 near;
        uint256 far;
        if (above) {
            near = bound(a, price, price * 10);
            far = bound(b, near, price * 10);
        } else {
            near = bound(a, price / 10, price);
            far = bound(b, price / 10, near);
        }
        Trigger t = above ? Trigger.AtOrAbove : Trigger.AtOrBelow;
        uint256 dNear = vault.nextCheckDelay(HBAR_MARKET, t, near, expiry);
        uint256 dFar = vault.nextCheckDelay(HBAR_MARKET, t, far, expiry);
        assertLe(dNear, dFar, "a farther trigger never waits less");
        assertGe(dNear, 300);
        assertLe(dFar, 6 hours);
        assertLe(dFar, lifetime > 300 ? lifetime : 300, "never past expiry");
    }

    // ------------------------------------------------------------------ helpers

    function _case(
        bool dai,
        bool buy,
        bool above,
        uint256 amountSeed,
        uint256 extra,
        uint256 triggerSeed,
        uint256 lifetime
    ) internal view returns (Case memory c) {
        c.marketId = dai ? DAI_MARKET : HBAR_MARKET;
        c.side = buy ? Side.BuyBase : Side.SellBase;
        c.trigger = above ? Trigger.AtOrAbove : Trigger.AtOrBelow;
        if (buy) c.amount = bound(amountSeed, 1, 500_000e6);
        else c.amount = bound(amountSeed, 1, dai ? 500_000e8 : 50_000e8);
        c.budget = vault.minBudget(c.marketId, c.side) + bound(extra, 0, 1_000e8);
        uint256 price = vault.guardReading(c.marketId).oraclePrice;
        c.triggerPrice = bound(triggerSeed, price / 2, price * 2);
        c.slippage = dai ? 30 : 100;
        c.lifetime = bound(lifetime, 1, 90 days);
    }

    function _place(address maker, Case memory c) internal returns (uint256) {
        uint256 value = _tokenIn(c) == address(0) ? c.amount + c.budget : c.budget;
        vm.prank(maker);
        return vault.placeOrder{ value: value }(
            PlaceParams({
                marketId: uint32(c.marketId),
                side: c.side,
                trigger: c.trigger,
                amountIn: uint128(c.amount),
                triggerPrice: uint128(c.triggerPrice),
                slippageBps: c.slippage,
                expiry: uint40(block.timestamp + c.lifetime)
            })
        );
    }

    /// @dev Input token as the vault books it: address(0) for HBAR.
    function _tokenIn(Case memory c) internal view returns (address) {
        if (c.side == Side.BuyBase) return address(usdc);
        return c.marketId == DAI_MARKET ? address(dai) : address(0);
    }

    /// @dev Router legs as SaucerSwap sees them: WHBAR for HBAR.
    function _route(Case memory c) internal view returns (address tokenIn, address tokenOut) {
        address base = c.marketId == DAI_MARKET ? address(dai) : address(whbar);
        return c.side == Side.SellBase ? (base, address(usdc)) : (address(usdc), base);
    }

    function _balance(address token, address account) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(ok, "balanceOf");
        return abi.decode(ret, (uint256));
    }

    function _filled(uint256 orderId) internal view returns (bool filled, uint256 amountOut, uint256 minOut) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != OrderVault.OrderFilled.selector) continue;
            if (uint256(logs[i].topics[1]) != orderId) continue;
            (, amountOut, minOut,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            return (true, amountOut, minOut);
        }
    }

    function _assertSolvent() internal view {
        assertGe(
            address(vault).balance, vault.escrowed(address(0)) + vault.totalBudgets() + vault.totalCredits(address(0))
        );
    }
}
