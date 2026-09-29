// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PriceMath } from "../contracts/libraries/PriceMath.sol";

contract PriceMathTest is Test {
    uint256 internal constant RAY = 1e27;

    function test_powRay_knownValues() public pure {
        assertEq(PriceMath.powRay(0), RAY);
        assertEq(PriceMath.powRay(1), 1.0001e27);
        // 1.0001^10000 = e^(10000 ln 1.0001) ~ 2.718145926825
        assertApproxEqRel(PriceMath.powRay(10_000), 2.718145926825e27, 1e9);
    }

    function test_tickToPrice_revertsOutsideTickBounds() public {
        vm.expectRevert(abi.encodeWithSelector(PriceMath.TickOutOfRange.selector, int24(887_273)));
        this.tickToPrice(887_273, true, 8, 8);
    }

    function testFuzz_tickToPrice_sidesAreReciprocal(int24 tick) public pure {
        tick = int24(bound(tick, -400_000, 400_000));
        uint256 asToken0 = PriceMath.tickToPrice(tick, true, 8, 8);
        uint256 asToken1 = PriceMath.tickToPrice(tick, false, 8, 8);
        vm.assume(asToken0 > 1e4 && asToken1 > 1e4); // stay where 8-decimal prices are meaningful
        assertApproxEqRel(asToken0 * asToken1, 1e16, 1e14); // within 0.01%
    }

    function testFuzz_tickToPrice_monotonicInTick(int24 tick) public pure {
        tick = int24(bound(tick, -200_000, 200_000));
        assertGe(PriceMath.tickToPrice(tick + 1, true, 8, 8), PriceMath.tickToPrice(tick, true, 8, 8));
        assertLe(PriceMath.tickToPrice(tick + 1, false, 8, 8), PriceMath.tickToPrice(tick, false, 8, 8));
    }

    function test_tickToPrice_returnsZeroInsteadOfOverflowing() public pure {
        assertEq(PriceMath.tickToPrice(887_272, false, 18, 18), 0);
    }

    /// @dev Live reading from 2026-09-29: the testnet HBAR/USDC 0.3% pool at tick 39004 prices HBAR at ~2.023 USDC.
    function test_tickToPrice_matchesTestnetPoolReading() public pure {
        uint256 price = PriceMath.tickToPrice(39_004, false, 8, 6);
        assertApproxEqRel(price, 202_300_000, 1e15);
    }

    function test_tickToPrice_baseAsToken0() public pure {
        // base token0 with equal decimals: price is token1 per token0 directly
        assertEq(PriceMath.tickToPrice(0, true, 6, 6), 1e8);
        assertApproxEqRel(PriceMath.tickToPrice(6932, true, 6, 6), 2e8, 1e14); // 1.0001^6932 ~ 2
    }

    function test_meanTick_roundsTowardsNegativeInfinity() public pure {
        assertEq(PriceMath.meanTick(0, 3000, 1800), 1);
        assertEq(PriceMath.meanTick(0, -3000, 1800), -2);
        assertEq(PriceMath.meanTick(0, -3600, 1800), -2);
        assertEq(PriceMath.meanTick(100, 100, 60), 0);
    }

    function test_crossPrice_scalesFeedDecimals() public pure {
        assertEq(PriceMath.crossPrice(11_160_000, 8, 100_000_000, 8), 11_160_000);
        assertEq(PriceMath.crossPrice(2e18, 18, 1e8, 8), 2e8);
    }

    function test_baseToQuote_hbarToUsdc() public pure {
        // 250 HBAR (tinybar) at 0.13 USDC -> 32.5 USDC (6 dp)
        assertEq(PriceMath.baseToQuote(250e8, 13_000_000, 8, 6), 32_500_000);
    }

    function test_quoteToBase_usdcToHbar() public pure {
        // 50 USDC at 0.095 -> 526.315789 HBAR
        assertEq(PriceMath.quoteToBase(50e6, 9_500_000, 8, 6), 52_631_578_947);
    }

    function testFuzz_roundTrip_losesAtMostRounding(uint96 amount, uint64 price) public pure {
        price = uint64(bound(price, 1e4, 1e14));
        amount = uint96(bound(amount, 1e8, 1e24));
        uint256 quote = PriceMath.baseToQuote(amount, price, 8, 6);
        uint256 back = PriceMath.quoteToBase(quote, price, 8, 6);
        assertLe(back, amount);
        // Rounding loses less than one quote unit's worth of base.
        assertLe(amount - back, PriceMath.quoteToBase(1, price, 8, 6) + 1);
    }

    function test_deviationBps() public pure {
        assertEq(PriceMath.deviationBps(102, 100), 200);
        assertEq(PriceMath.deviationBps(98, 100), 200);
        assertEq(PriceMath.deviationBps(202_296_600, 11_104_036), 172_182);
    }

    function testFuzz_lessBps_neverExceedsInput(uint128 amount, uint16 bps) public pure {
        bps = uint16(bound(bps, 0, 10_000));
        uint256 out = PriceMath.lessBps(amount, bps);
        assertLe(out, amount);
        assertEq(PriceMath.lessBps(amount, 0), amount);
    }

    function tickToPrice(int24 tick, bool baseIsToken0, uint8 baseDecimals, uint8 quoteDecimals)
        external
        pure
        returns (uint256)
    {
        return PriceMath.tickToPrice(tick, baseIsToken0, baseDecimals, quoteDecimals);
    }
}
