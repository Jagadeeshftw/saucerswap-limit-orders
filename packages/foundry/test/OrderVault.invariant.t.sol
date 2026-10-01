// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, Vm, console2 } from "forge-std/Test.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { PriceMath } from "../contracts/libraries/PriceMath.sol";
import { Market, Order, PlaceParams, Side, Status, Trigger } from "../contracts/types/OrderTypes.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { MockAggregator, MockPool, MockRouter, MockToken } from "./mocks/MockMarket.sol";
import { MockHss, MockNftCollection } from "./mocks/MockHederaSystem.sol";

/// @notice Drives random sequences of user, keeper, market and scheduler actions against the vault.
contract VaultHandler is Test {
    uint256 internal constant RAY = 1e27;

    OrderVault internal immutable vault;
    MockNftCollection internal immutable nft;
    MockRouter internal immutable router;
    MockToken internal immutable whbar;
    MockToken internal immutable usdc;
    MockToken internal immutable dai;
    MockAggregator[3] internal feeds; // index 0 unused, 1 HBAR, 2 DAI
    MockPool[3] internal pools;
    address[] public actors;
    uint256[] public orderIds;

    MockHss internal constant HSS = MockHss(address(0x16b));
    mapping(uint256 jobIndex => bool) internal ran;
    /// @notice Scheduled sweeps that reverted. HSS would drop them silently, killing the market's checks.
    uint256 public failedJobs;
    uint256 public jobsRun;
    /// @notice When a scheduled sweep last looked at each order (or when it was placed or revived).
    mapping(uint256 orderId => uint256) public lastLooked;

    constructor(
        OrderVault vault_,
        MockRouter router_,
        MockToken[3] memory tokens,
        MockAggregator hbarFeed,
        MockAggregator daiFeed,
        MockPool hbarPool,
        MockPool daiPool,
        address[] memory actors_
    ) {
        vault = vault_;
        nft = MockNftCollection(vault_.collection());
        router = router_;
        whbar = tokens[0];
        usdc = tokens[1];
        dai = tokens[2];
        feeds[1] = hbarFeed;
        feeds[2] = daiFeed;
        pools[1] = hbarPool;
        pools[2] = daiPool;
        actors = actors_;
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function place(
        uint256 actorSeed,
        bool daiMarket,
        bool buy,
        bool above,
        uint256 amountSeed,
        uint256 priceSeed,
        uint256 extra
    ) external {
        address maker = actors[actorSeed % actors.length];
        uint256 marketId = daiMarket ? 2 : 1;
        Side side = buy ? Side.BuyBase : Side.SellBase;
        uint256 current = vault.guardReading(marketId).oraclePrice;
        if (current == 0) return;
        uint256 trigger = bound(priceSeed, current * 97 / 100, current * 103 / 100);
        uint256 amount = side == Side.SellBase
            ? bound(amountSeed, daiMarket ? 1e8 : 10e8, daiMarket ? 5_000e8 : 2_000e8)
            : bound(amountSeed, 1e6, 500e6);
        uint256 budget = vault.minBudget(marketId, side) + bound(extra, 0, 20e8);
        bool hbarIn = !daiMarket && side == Side.SellBase;
        vm.prank(maker);
        try vault.placeOrder{ value: hbarIn ? amount + budget : budget }(
            PlaceParams({
                marketId: uint32(marketId),
                side: side,
                // limit = sell at-or-above / buy at-or-below (type 0); stop = the mirror (type 1)
                orderType: ((side == Side.SellBase) == above) ? 0 : 1,
                amountIn: uint128(amount),
                typeParam: uint128(trigger),
                slippageBps: daiMarket ? 30 : 100,
                expiry: uint40(block.timestamp + bound(amountSeed, 1 hours, 7 days))
            })
        ) returns (
            uint256 orderId
        ) {
            orderIds.push(orderId);
            lastLooked[orderId] = block.timestamp;
        } catch { }
    }

    /// @dev Only one call in four cancels, so most orders live long enough to fill or expire.
    function cancel(uint256 seed) external {
        if (orderIds.length == 0 || seed % 4 != 0) return;
        uint256 orderId = orderIds[seed % orderIds.length];
        address holder = nft.ownerOf(orderId);
        if (holder == address(0)) return;
        vm.prank(holder);
        try vault.cancel(orderId) { } catch { }
    }

    function topUp(uint256 seed, uint256 amount) external {
        if (orderIds.length == 0) return;
        uint256 orderId = orderIds[seed % orderIds.length];
        bool wasFunded = vault.getOrder(orderId).funded;
        vm.prank(actors[seed % actors.length]);
        try vault.topUp{ value: bound(amount, 1, 30e8) }(orderId) { } catch { }
        if (!wasFunded && vault.getOrder(orderId).funded) lastLooked[orderId] = block.timestamp;
    }

    function transferNft(uint256 seed, uint256 toSeed) external {
        if (orderIds.length == 0) return;
        uint256 orderId = orderIds[seed % orderIds.length];
        address holder = nft.ownerOf(orderId);
        if (holder == address(0)) return;
        address to = actors[toSeed % actors.length];
        vm.prank(holder);
        try nft.transferFrom(holder, to, orderId) { } catch { }
    }

    /// @dev Move a market up or down by up to 6%. One move in five leaves the pool behind, opening a gap the
    ///      guard must catch; the others move pool and router with the oracle.
    function movePrice(bool daiMarket, uint256 moveSeed) external {
        uint256 id = daiMarket ? 2 : 1;
        (, int256 answer,,,) = feeds[id].latestRoundData();
        uint256 next = bound(moveSeed, uint256(answer) * 94 / 100, uint256(answer) * 106 / 100);
        if (next == 0) return;
        feeds[id].set(int256(next), block.timestamp);
        if (moveSeed % 5 == 0) return;
        pools[id].setTick(_tickFor(next));
        MockToken base = daiMarket ? dai : whbar;
        router.setRate(address(base), address(usdc), RAY * next / 1e10);
        router.setRate(address(usdc), address(base), RAY * 1e10 / next);
    }

    /// @dev Let HSS run the next schedule that is due, jumping the clock to it.
    function scheduledSweep() external {
        (uint256 index, uint256 at) = _earliestPending();
        if (index == type(uint256).max) return;
        if (at > block.timestamp) vm.warp(at);
        _runJob(index);
    }

    /// @dev Every schedule HSS accepted, superseded ones included, runs at its second with its own gas limit.
    function _runDueUntil(uint256 until) internal {
        while (true) {
            (uint256 index, uint256 at) = _earliestPending();
            if (index == type(uint256).max || at > until) break;
            if (at > block.timestamp) vm.warp(at);
            _runJob(index);
        }
        if (until > block.timestamp) vm.warp(until);
    }

    function _earliestPending() internal view returns (uint256 index, uint256 at) {
        index = type(uint256).max;
        at = type(uint256).max;
        for (uint256 i; i < HSS.count(); ++i) {
            if (ran[i]) continue;
            uint256 expiry = HSS.job(i).expiry;
            if (expiry < at) (index, at) = (i, expiry);
        }
    }

    function _runJob(uint256 index) internal {
        ran[index] = true;
        MockHss.Scheduled memory job = HSS.job(index);
        vm.recordLogs();
        vm.prank(address(vault));
        (bool ok,) = job.to.call{ gas: job.gasLimit }(job.callData);
        jobsRun++;
        if (!ok) failedJobs++;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault) || logs[i].topics.length < 2) continue;
            bytes32 t = logs[i].topics[0];
            if (
                t == OrderVault.OrderChecked.selector || t == OrderVault.BudgetExhausted.selector
                    || t == OrderVault.FillHeld.selector || t == OrderVault.FillFailed.selector
                    || t == OrderVault.OrderFilled.selector || t == OrderVault.OrderExpired.selector
            ) lastLooked[uint256(logs[i].topics[1])] = block.timestamp;
        }
    }

    function manualExecute(uint256 seed, uint256 actorSeed) external {
        if (orderIds.length == 0) return;
        vm.prank(actors[actorSeed % actors.length]);
        try vault.executeOrder(orderIds[seed % orderIds.length]) { } catch { }
    }

    function restart(bool daiMarket) external {
        try vault.restartSweep(daiMarket ? 2 : 1) { } catch { }
    }

    /// @dev Time passes; HSS runs whatever falls due on the way.
    function warp(uint256 seconds_) external {
        _runDueUntil(block.timestamp + bound(seconds_, 1, 6 hours));
    }

    function blockUsdc(uint256 actorSeed, bool blocked) external {
        usdc.setBlocked(actors[actorSeed % actors.length], blocked);
    }

    function claim(uint256 actorSeed, uint256 tokenSeed) external {
        address[3] memory tokens = [address(0), address(usdc), address(dai)];
        vm.prank(actors[actorSeed % actors.length]);
        try vault.claim(tokens[tokenSeed % 3]) { } catch { }
    }

    function _tickFor(uint256 answer) internal pure returns (int24) {
        int24 lo = 0;
        int24 hi = 200_000;
        while (lo < hi) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (_price(mid) > answer) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    function _price(int24 tick) internal pure returns (uint256) {
        return PriceMath.tickToPrice(tick, false, 8, 6);
    }
}

contract OrderVaultInvariantTest is OrderVaultBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = keeper;
        handler = new VaultHandler(vault, router, [whbar, usdc, dai], hbarFeed, daiFeed, hbarPool, daiPool, actors);
        targetContract(address(handler));
    }

    /// @notice Escrow per token equals the inputs of open orders; budgets equal open budgets.
    function invariant_escrowAndBudgetsMatchOpenOrders() public view {
        uint256 hbar;
        uint256 usdcIn;
        uint256 daiIn;
        uint256 budgets;
        for (uint256 i; i < handler.orderCount(); ++i) {
            Order memory o = vault.getOrder(handler.orderIds(i));
            if (o.status != Status.Open) {
                assertEq(o.budget, 0, "closed orders hold no budget");
                continue;
            }
            budgets += o.budget;
            if (o.marketId == HBAR_MARKET && o.side == Side.SellBase) hbar += o.amountIn;
            else if (o.side == Side.BuyBase) usdcIn += o.amountIn;
            else daiIn += o.amountIn;
        }
        assertEq(vault.escrowed(address(0)), hbar, "HBAR escrow");
        assertEq(vault.escrowed(address(usdc)), usdcIn, "USDC escrow");
        assertEq(vault.escrowed(address(dai)), daiIn, "DAI escrow");
        assertEq(vault.totalBudgets(), budgets, "budgets");
    }

    /// @notice The vault always holds at least what it owes, in every asset.
    function invariant_solvent() public view {
        assertGe(
            address(vault).balance,
            vault.escrowed(address(0)) + vault.totalBudgets() + vault.totalCredits(address(0)),
            "HBAR"
        );
        assertGe(usdc.balanceOf(address(vault)), vault.escrowed(address(usdc)) + vault.totalCredits(address(usdc)));
        assertGe(dai.balanceOf(address(vault)), vault.escrowed(address(dai)) + vault.totalCredits(address(dai)));
    }

    /// @notice Credit totals match the per-account credits.
    function invariant_creditsAddUp() public view {
        address[3] memory tokens = [address(0), address(usdc), address(dai)];
        for (uint256 t; t < 3; ++t) {
            uint256 sum;
            for (uint256 a; a < handler.actorCount(); ++a) {
                sum += vault.credits(handler.actors(a), tokens[t]);
            }
            assertEq(vault.totalCredits(tokens[t]), sum);
        }
    }

    /// @notice Open lists, funded counters and NFTs agree with order state.
    function invariant_bookkeepingConsistent() public view {
        for (uint256 m = 1; m <= 2; ++m) {
            uint256[] memory open = vault.openOrders(m);
            uint256 funded;
            for (uint256 i; i < open.length; ++i) {
                Order memory o = vault.getOrder(open[i]);
                assertEq(uint8(o.status), uint8(Status.Open), "listed orders are open");
                assertEq(o.marketId, m);
                assertTrue(nft.ownerOf(open[i]) != address(0), "open orders have a holder");
                if (o.funded) funded++;
            }
            (,,, uint32 fundedOrders,,) = vault.sweeps(m);
            assertEq(fundedOrders, funded, "funded counter");
            uint256 openCount;
            for (uint256 i; i < handler.orderCount(); ++i) {
                Order memory o = vault.getOrder(handler.orderIds(i));
                if (o.status == Status.Open && o.marketId == m) openCount++;
            }
            assertEq(open.length, openCount, "every open order is listed");
        }
    }

    /// @notice Liveness: every funded open order is looked at by a scheduled sweep within its market's longest
    ///         wait (plus rotation when more orders are open than one sweep checks), and no scheduled sweep reverts.
    function invariant_fundedOrdersAreChecked() public view {
        assertEq(handler.failedJobs(), 0, "a scheduled sweep reverted");
        for (uint256 i; i < handler.orderCount(); ++i) {
            uint256 id = handler.orderIds(i);
            Order memory o = vault.getOrder(id);
            if (o.status != Status.Open || !o.funded) continue;
            Market memory market = vault.getMarket(o.marketId);
            uint256 open = vault.openOrders(o.marketId).length;
            uint256 limit = uint256(market.sweep.maxInterval) + (open / market.sweep.maxOrders + 2)
                * uint256(market.sweep.minInterval) + 250;
            assertLe(block.timestamp - handler.lastLooked(id), limit, "funded order went unchecked");
            (, uint40 nextSweepAt,,,,) = vault.sweeps(o.marketId);
            assertGe(uint256(nextSweepAt) + 120, block.timestamp, "a funded market has a live schedule");
        }
    }

    /// @notice Per-run summary, so a green run can be checked for real fills, cancels and expiries.
    function afterInvariant() external view {
        uint256[5] memory byStatus;
        for (uint256 i; i < handler.orderCount(); ++i) {
            byStatus[uint8(vault.getOrder(handler.orderIds(i)).status)]++;
        }
        console2.log("open, filled, cancelled, expired", byStatus[1], byStatus[2], byStatus[3]);
        console2.log("  expired", byStatus[4]);
        console2.log("  scheduled sweeps run", handler.jobsRun());
    }

    /// @notice A settled order's NFT is gone.
    function invariant_settledOrdersHaveNoNft() public view {
        for (uint256 i; i < handler.orderCount(); ++i) {
            uint256 id = handler.orderIds(i);
            if (vault.getOrder(id).status != Status.Open) assertEq(nft.ownerOf(id), address(0));
        }
    }
}
