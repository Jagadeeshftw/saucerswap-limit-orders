// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { MockHss } from "./mocks/MockHederaSystem.sol";
import { Order, PlaceParams, Side, SweepStatus } from "../contracts/types/OrderTypes.sol";

/// @notice The lens's previews are what the vault actually does: the budget `placeOrder` demands, the gas limit
///         it schedules, the delay to the next check, what each order in a sweep is charged (paying or parked),
///         and the surplus `withdrawSurplus` pays out.
contract OrderVaultLensTest is OrderVaultBase {
    uint128 internal constant FAR_ABOVE = 20_000_000; // 0.20 USDC per HBAR: far from spot, so nothing fills

    function _place(address maker, uint256 marketId, Side side, uint8 orderType, uint128 typeParam, uint256 extra)
        internal
        returns (uint256 orderId)
    {
        bool dai_ = marketId == DAI_MARKET;
        uint128 amount = side == Side.BuyBase ? 50e6 : (dai_ ? 1_000e8 : 250e8);
        uint256 budget = lens.minBudget(marketId, side) + extra;
        bool hbarIn = !dai_ && side == Side.SellBase;
        vm.prank(maker);
        orderId = vault.placeOrder{ value: hbarIn ? amount + budget : budget }(
            PlaceParams({
                marketId: uint32(marketId),
                side: side,
                orderType: orderType,
                amountIn: amount,
                typeParam: typeParam,
                slippageBps: dai_ ? 30 : 50,
                expiry: uint40(block.timestamp + 30 days)
            })
        );
    }

    function _runSweep() internal {
        MockHss.Scheduled memory job = hss.last();
        vm.warp(job.expiry);
        vm.prank(address(vault));
        (bool ok,) = address(vault).call{ gas: job.gasLimit }(job.callData);
        assertTrue(ok, "scheduled sweep reverted");
    }

    /// @notice `minBudget` is exactly the smallest budget `placeOrder` accepts, on every market and side.
    function testFuzz_minBudget_isWhatPlaceOrderRequires(bool dai_, bool buy) public {
        uint256 marketId = dai_ ? DAI_MARKET : HBAR_MARKET;
        Side side = buy ? Side.BuyBase : Side.SellBase;
        uint256 required = lens.minBudget(marketId, side);
        uint128 amount = buy ? 50e6 : 100e8;
        bool hbarIn = !dai_ && !buy;
        PlaceParams memory p =
            PlaceParams(uint32(marketId), side, LIMIT, amount, buy ? 1 : FAR_ABOVE * 100, dai_ ? 30 : 50, 0);
        p.expiry = uint40(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.InsufficientBudget.selector, required - 1, required));
        vault.placeOrder{ value: (hbarIn ? amount : 0) + required - 1 }(p);
        vm.prank(alice);
        uint256 orderId = vault.placeOrder{ value: (hbarIn ? amount : 0) + required }(p);
        assertEq(vault.getOrder(orderId).budget, required);
    }

    /// @notice `sweepGasLimit` is the gas limit the vault books its next sweep with, as orders come and go.
    function testFuzz_sweepGasLimit_isWhatTheVaultSchedules(uint8 n) public {
        n = uint8(bound(n, 1, 25)); // past maxOrders (20), where the limit stops growing
        for (uint256 i; i < n; ++i) {
            _place([alice, bob, keeper][i % 3], HBAR_MARKET, Side.SellBase, LIMIT, FAR_ABOVE, 0);
            // A placement only reschedules when it starts a chain or brings it forward, so compare on the
            // next routine sweep, which always books the limit for the orders open now.
        }
        _runSweep();
        assertEq(hss.last().gasLimit, lens.sweepGasLimit(HBAR_MARKET));
    }

    /// @notice What `previewCharges` reports is what the sweep then takes from each order in its batch: `share`
    ///         from every order that can pay, `parkFee` (capped at what is left) from every order that can't.
    function testFuzz_previewCharges_matchSweepCharges(uint256 seed) public {
        uint256 n = 2 + (seed % 8);
        uint256[] memory ids = new uint256[](n);
        uint256 solo = lens.checkCost(HBAR_MARKET);
        for (uint256 i; i < n; ++i) {
            // Budgets differ by up to three solo checks, so orders exhaust them and park at different sweeps.
            uint256 extra = uint256(keccak256(abi.encode(seed, i))) % (3 * solo);
            ids[i] = _place([alice, bob, keeper][i % 3], HBAR_MARKET, Side.SellBase, LIMIT, FAR_ABOVE, extra);
        }
        // Sweep until every order has parked and the chain ends.
        for (uint256 round; round < 120; ++round) {
            MockHss.Scheduled memory job = hss.last();
            vm.warp(job.expiry);
            (uint256 share, uint256 parkFee) = lens.previewCharges(HBAR_MARKET);
            uint256[] memory before = new uint256[](n);
            bool[] memory wasFunded = new bool[](n);
            for (uint256 i; i < n; ++i) {
                before[i] = vault.getOrder(ids[i]).budget;
                wasFunded[i] = vault.getOrder(ids[i]).funded;
            }
            vm.prank(address(vault));
            (bool ok,) = address(vault).call{ gas: job.gasLimit }(job.callData);
            assertTrue(ok, "scheduled sweep reverted");
            for (uint256 i; i < n; ++i) {
                Order memory o = vault.getOrder(ids[i]);
                if (!wasFunded[i]) {
                    assertEq(o.budget, before[i], "an unfunded order was charged");
                } else if (o.funded) {
                    assertEq(before[i] - o.budget, share, "a paying order was charged other than share");
                } else {
                    uint256 fee = parkFee < before[i] ? parkFee : before[i];
                    assertEq(before[i] - o.budget, fee, "a parked order was charged other than parkFee");
                }
            }
            (SweepStatus status,) = lens.sweepStatus(HBAR_MARKET);
            if (status != SweepStatus.Scheduled) break; // every order parked: the chain ended
        }
    }

    /// @notice The solo `checkCost` is what a lone order is charged per scheduled check.
    function test_checkCost_isTheSoloCharge() public {
        uint256 orderId = _place(alice, DAI_MARKET, Side.SellBase, STOP, 50_000_000, 0);
        uint256 before = vault.getOrder(orderId).budget;
        _runSweep();
        assertEq(before - vault.getOrder(orderId).budget, lens.checkCost(DAI_MARKET));
    }

    /// @notice `nextCheckDelay` for an unplaced order is the delay the vault books when that order starts the
    ///         chain; `orderNextCheckDelay` agrees once it is placed.
    function testFuzz_nextCheckDelay_isTheScheduledDelay(uint128 trigger) public {
        trigger = uint128(bound(trigger, 11_200_000, 40_000_000)); // above spot (0.1116): a limit sell waits
        uint256 expiry = block.timestamp + 30 days;
        uint256 predicted = lens.nextCheckDelay(HBAR_MARKET, LIMIT, Side.SellBase, trigger, expiry);
        uint256 orderId = _place(alice, HBAR_MARKET, Side.SellBase, LIMIT, trigger, 0);
        assertEq(hss.last().expiry - block.timestamp, predicted, "scheduled delay");
        assertEq(lens.orderNextCheckDelay(orderId), predicted, "per-order delay");
    }

    /// @notice A trailing stop's per-order preview uses its live peak: after the peak rises and the price falls
    ///         back toward the trigger, the lens predicts the delay the vault then books.
    function test_orderNextCheckDelay_tracksTrailingPeak() public {
        uint256 orderId = _place(alice, DAI_MARKET, Side.SellBase, TRAILING, 200, 0); // 2% trail
        _setDaiPrice(103_000_000); // a new high: the next check raises the peak
        _runSweep();
        assertEq(uint256(vault.getOrder(orderId).typeState), 103_000_000, "peak raised");
        _setDaiPrice(101_500_000); // pulls back, still above 103 x 0.98 = 100.94
        uint256 predicted = lens.orderNextCheckDelay(orderId);
        _runSweep();
        assertEq(hss.last().expiry - block.timestamp, predicted);
    }

    /// @notice `surplus` is what `withdrawSurplus` pays out, and the payer float stays behind.
    function test_surplus_isWhatWithdrawSurplusPays() public {
        _place(alice, HBAR_MARKET, Side.SellBase, LIMIT, FAR_ABOVE, 0);
        vm.deal(address(vault), address(vault).balance + 7e8); // a stray donation becomes surplus
        uint256 preview = lens.surplus();
        address payable to = payable(makeAddr("treasury"));
        vm.prank(owner);
        vault.withdrawSurplus(to);
        assertEq(to.balance, preview);
        assertEq(lens.surplus(), 0);
        assertGe(address(vault).balance, lens.payerFloat(), "float kept");
    }

    /// @notice `nextBatch` is the rotation the sweep visits: after a capped sweep the cursor moves on.
    function test_nextBatch_followsTheCursor() public {
        for (uint256 i; i < 22; ++i) {
            _place([alice, bob, keeper][i % 3], HBAR_MARKET, Side.SellBase, LIMIT, FAR_ABOVE, 0);
        }
        uint256[] memory first = lens.nextBatch(HBAR_MARKET);
        assertEq(first.length, 20);
        assertEq(first[0], vault.openOrders(HBAR_MARKET)[0]);
        _runSweep();
        uint256[] memory second = lens.nextBatch(HBAR_MARKET);
        assertEq(second[0], vault.openOrders(HBAR_MARKET)[20 % 22]);
    }

    /// @notice Unknown markets revert the same way they do on the vault.
    function test_unknownMarket_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(OrderVault.UnknownMarket.selector, 9));
        lens.minBudget(9, Side.SellBase);
        vm.expectRevert(abi.encodeWithSelector(OrderVault.UnknownMarket.selector, 9));
        lens.sweepStatus(9);
    }
}
