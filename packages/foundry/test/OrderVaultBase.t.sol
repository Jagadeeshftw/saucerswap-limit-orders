// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultLens } from "../contracts/OrderVaultLens.sol";
import { PriceMath } from "../contracts/libraries/PriceMath.sol";
import { ISaucerSwapV2Router, ISaucerSwapV2Pool } from "../contracts/interfaces/ISaucerSwapV2.sol";
import { IAggregatorV3 } from "../contracts/interfaces/IAggregatorV3.sol";
import { Costs, Market, PlaceParams, Side, Trigger } from "../contracts/types/OrderTypes.sol";
import { LimitOrderType } from "../contracts/ordertypes/LimitOrderType.sol";
import { StopOrderType } from "../contracts/ordertypes/StopOrderType.sol";
import { TrailingStopType } from "../contracts/ordertypes/TrailingStopType.sol";
import { MarketConfig } from "../script/MarketConfig.sol";
import { MockExchangeRate, MockHss, MockHts, MockNftCollection } from "./mocks/MockHederaSystem.sol";
import { MockAggregator, MockPool, MockRouter, MockToken } from "./mocks/MockMarket.sol";

/// @notice Shared fixture: Hedera system contracts mocked at their real addresses and the two shipped markets
///         (HBAR/USDC and DAI/USDC) wired to mock feeds, pools and router at realistic testnet prices.
abstract contract OrderVaultBase is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HBAR_MARKET = 1;
    uint256 internal constant DAI_MARKET = 2;
    uint8 internal constant LIMIT = 0;
    uint8 internal constant STOP = 1;
    uint8 internal constant TRAILING = 2;

    /// @dev HBAR at 0.1116 USDC; the pool stores token1 (tinybar) per token0 (micro-USDC).
    int256 internal constant HBAR_USD = 11_160_000;
    int24 internal constant HBAR_TICK = 67_983;
    int256 internal constant DAI_USD = 99_980_000;
    int24 internal constant DAI_TICK = 46_056;

    OrderVault internal vault;
    OrderVaultLens internal lens;
    MockHss internal hss;
    MockHts internal hts;
    MockRouter internal router;
    MockToken internal whbar;
    MockToken internal usdc;
    MockToken internal dai;
    MockAggregator internal hbarFeed;
    MockAggregator internal usdcFeed;
    MockAggregator internal daiFeed;
    MockPool internal hbarPool;
    MockPool internal daiPool;
    MockNftCollection internal nft;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(1_790_700_000);
        vm.etch(address(0x167), address(new MockHts()).code);
        vm.etch(address(0x16b), address(new MockHss()).code);
        vm.etch(address(0x168), address(new MockExchangeRate()).code);
        hts = MockHts(address(0x167));
        hss = MockHss(address(0x16b));

        whbar = new MockToken("WHBAR", 8);
        usdc = new MockToken("USDC", 6);
        dai = new MockToken("DAI", 8);
        hbarFeed = new MockAggregator(8, HBAR_USD);
        usdcFeed = new MockAggregator(8, 100_000_000);
        daiFeed = new MockAggregator(8, DAI_USD);
        hbarPool = new MockPool(address(usdc), HBAR_TICK);
        daiPool = new MockPool(address(usdc), DAI_TICK);

        router = new MockRouter(address(whbar));
        router.setRate(address(whbar), address(usdc), RAY * 1116 / 1_000_000); // micro-USDC per tinybar
        router.setRate(address(usdc), address(whbar), RAY * 89_605 / 100); // tinybar per micro-USDC
        router.setRate(address(dai), address(usdc), RAY * 9998 / 1_000_000); // micro-USDC per DAI unit
        router.setRate(address(usdc), address(dai), RAY * 100_02 / 100); // DAI units per micro-USDC
        vm.deal(address(router), 1_000_000 ether);

        vault = new OrderVault(owner, ISaucerSwapV2Router(address(router)), address(whbar), MarketConfig.costs());
        vm.deal(owner, 1_000 ether);
        vm.startPrank(owner);
        vault.initialize{ value: 20 ether }("SaucerSwap Limit Order", "SSLO");
        vault.listMarket(_hbarMarket());
        vault.listMarket(_daiMarket());
        vault.registerOrderType(address(new LimitOrderType())); // id 0
        vault.registerOrderType(address(new StopOrderType())); // id 1
        vault.registerOrderType(address(new TrailingStopType())); // id 2
        vm.stopPrank();
        nft = MockNftCollection(vault.collection());
        lens = new OrderVaultLens(vault);

        for (uint256 i; i < 3; ++i) {
            address user = [alice, bob, keeper][i];
            vm.deal(user, 100_000 ether);
            nft.setAssociated(user, true);
            usdc.mint(user, 1_000_000e6);
            dai.mint(user, 1_000_000e8);
            vm.startPrank(user);
            usdc.approve(address(vault), type(uint256).max);
            dai.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _hbarMarket() internal view returns (Market memory m) {
        m = MarketConfig.hbarUsdc();
        m.base = address(whbar);
        m.quote = address(usdc);
        m.baseFeed = IAggregatorV3(address(hbarFeed));
        m.quoteFeed = IAggregatorV3(address(usdcFeed));
        m.pool = ISaucerSwapV2Pool(address(hbarPool));
    }

    function _daiMarket() internal view returns (Market memory m) {
        m = MarketConfig.usdcDai();
        m.base = address(dai);
        m.quote = address(usdc);
        m.baseFeed = IAggregatorV3(address(daiFeed));
        m.quoteFeed = IAggregatorV3(address(usdcFeed));
        m.pool = ISaucerSwapV2Pool(address(daiPool));
    }

    /// @dev Maps the legacy (side, trigger-direction) selector to the registered order-type id, so existing
    ///      tests keep expressing intent as AtOrAbove/AtOrBelow while placing through the plug-in registry.
    function _typeFor(Side side, Trigger kind) internal pure returns (uint8) {
        bool limit = side == Side.SellBase ? kind == Trigger.AtOrAbove : kind == Trigger.AtOrBelow;
        return limit ? LIMIT : STOP;
    }

    /// @dev Sell 250 HBAR when HBAR is at or above `trigger` (8 decimals, USDC).
    function _sellHbar(address maker, uint128 trigger, Trigger kind) internal returns (uint256 orderId) {
        uint128 amount = 250e8;
        uint256 budget = lens.minBudget(HBAR_MARKET, Side.SellBase);
        vm.prank(maker);
        orderId = vault.placeOrder{ value: amount + budget }(
            PlaceParams({
                marketId: uint32(HBAR_MARKET),
                side: Side.SellBase,
                orderType: _typeFor(Side.SellBase, kind),
                amountIn: amount,
                typeParam: trigger,
                slippageBps: 50,
                expiry: uint40(block.timestamp + 7 days)
            })
        );
    }

    /// @dev Spend 50 USDC on HBAR when HBAR is at or below `trigger`.
    function _buyHbar(address maker, uint128 trigger, Trigger kind) internal returns (uint256 orderId) {
        uint256 budget = lens.minBudget(HBAR_MARKET, Side.BuyBase);
        vm.prank(maker);
        orderId = vault.placeOrder{ value: budget }(
            PlaceParams({
                marketId: uint32(HBAR_MARKET),
                side: Side.BuyBase,
                orderType: _typeFor(Side.BuyBase, kind),
                amountIn: 50e6,
                typeParam: trigger,
                slippageBps: 50,
                expiry: uint40(block.timestamp + 7 days)
            })
        );
    }

    /// @dev Stop-loss: sell 1,000 DAI if DAI drops to `trigger` USDC or below.
    function _daiStop(address maker, uint128 trigger) internal returns (uint256 orderId) {
        uint256 budget = lens.minBudget(DAI_MARKET, Side.SellBase);
        vm.prank(maker);
        orderId = vault.placeOrder{ value: budget }(
            PlaceParams({
                marketId: uint32(DAI_MARKET),
                side: Side.SellBase,
                orderType: STOP,
                amountIn: 1_000e8,
                typeParam: trigger,
                slippageBps: 30,
                expiry: uint40(block.timestamp + 7 days)
            })
        );
    }

    /// @dev Run the latest schedule the way HSS does: at its expiry, from the vault, with its own gas limit and calldata.
    function _runScheduledSweep(uint256) internal {
        MockHss.Scheduled memory job = hss.last();
        vm.warp(job.expiry);
        vm.prank(address(vault));
        (bool ok, bytes memory ret) = address(vault).call{ gas: job.gasLimit }(job.callData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @dev Tinybar the vault charges for `gas`: the configured USD gas price plus margin, at the mock's testnet rate.
    /// @dev What the vault holds above escrow, budgets and credits, ignoring the payer float it earmarks.
    ///      Charges land here first; the float only decides how much of it `surplus()` will release.
    function _spare() internal view returns (uint256) {
        address hbar = address(0);
        uint256 owed = vault.escrowed(hbar) + vault.totalBudgets() + vault.totalCredits(hbar);
        return address(vault).balance > owed ? address(vault).balance - owed : 0;
    }

    function _tinybar(uint256 gas) internal pure returns (uint256) {
        Costs memory c = MarketConfig.costs();
        uint256 tinycents = gas * c.gasPriceTinycents;
        tinycents += tinycents * c.safetyBps / 10_000;
        return tinycents * (1e12 * uint256(30_000) / 231_199) / 1e12;
    }

    function _idleSweep() internal pure returns (uint256) {
        return _tinybar(MarketConfig.costs().idleSweepGas);
    }

    /// @dev The epoch the market's pending schedule was created under.
    function _epoch(uint256 marketId) internal view returns (uint32 epoch) {
        (,,,, epoch,) = vault.sweeps(marketId);
    }

    /// @dev Move HBAR's Chainlink price and the pool tick together so the guard stays open.
    function _setHbarPrice(int256 answer) internal {
        hbarFeed.set(answer, block.timestamp);
        hbarPool.setTick(_tickFor(uint256(answer)));
        router.setRate(address(whbar), address(usdc), RAY * uint256(answer) / 1e10);
        router.setRate(address(usdc), address(whbar), RAY * 1e10 / uint256(answer));
    }

    function _setDaiPrice(int256 answer) internal {
        daiFeed.set(answer, block.timestamp);
        daiPool.setTick(_tickFor(uint256(answer)));
        router.setRate(address(dai), address(usdc), RAY * uint256(answer) / 1e10);
        router.setRate(address(usdc), address(dai), RAY * 1e10 / uint256(answer));
    }

    /// @dev Tick at which a fixture pool (USDC as token0, an 8-dp base as token1) prices the base at `answer`.
    ///      Binary search, since the price falls as the tick rises.
    function _tickFor(uint256 answer) internal pure returns (int24) {
        int24 lo = 0;
        int24 hi = 200_000;
        while (lo < hi) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            if (PriceMath.tickToPrice(mid, false, 8, 6) > answer) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }
}
