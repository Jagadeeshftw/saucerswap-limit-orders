// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console2 } from "forge-std/Script.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { MarketConfig } from "./MarketConfig.sol";
import { PriceMath } from "../contracts/libraries/PriceMath.sol";
import { Market } from "../contracts/types/OrderTypes.sol";

interface IPoolState {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
    function tickBitmap(int16 word) external view returns (uint256);
    function ticks(int24 tick) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool);
}

interface ISymbol {
    function symbol() external view returns (string memory);
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice How far a market's SaucerSwap V2 pool sits from Chainlink, and the swap that would close the gap.
/// @dev Read-only: run against a fork, nothing is broadcast.
///        forge script script/PoolGap.s.sol --fork-url https://testnet.hashio.io/api
///        MARKET=2 forge script script/PoolGap.s.sol --fork-url https://testnet.hashio.io/api
///      It walks the pool's initialized ticks with the concentrated-liquidity formulas
///      (token1 in: L x (sqrtB - sqrtA); token0 in: L x (1/sqrtA - 1/sqrtB)).
contract PoolGapScript is Script {
    using SafeCast for int256;
    using SafeCast for uint256;
    uint256 internal constant RAY = 1e27;
    int24 internal constant MAX_TICK = 887_272;

    function run() external view {
        Market memory m = vm.envOr("MARKET", uint256(1)) == 2 ? MarketConfig.usdcDai() : MarketConfig.hbarUsdc();
        IPoolState pool = IPoolState(address(m.pool));
        (, int24 tick,,,,,) = pool.slot0();
        int24 spacing = pool.tickSpacing();

        uint256 oracle = _oraclePrice(m);
        uint256 poolPrice = PriceMath.tickToPrice(tick, m.baseIsToken0, m.baseDecimals, m.quoteDecimals);
        int24 target = _tickAtPrice(m, oracle);
        console2.log("pool tick", int256(tick));
        console2.log("target tick", int256(target));
        console2.log("pool price (8 dp, quote per base)", poolPrice);
        console2.log("Chainlink price (8 dp)", oracle);
        uint256 deviation = PriceMath.deviationBps(poolPrice, oracle);
        console2.log("deviation bps", deviation);
        console2.log("guard limit bps", uint256(m.guard.maxDeviationBps));
        if (deviation <= m.guard.maxDeviationBps) {
            console2.log("Within the guard's limit: orders in this market can fill. Nothing to do.");
            return;
        }

        bool up = target > tick; // the tick rises when token1 goes in
        uint256 amount = _amountIn(pool, tick, target, spacing, up);
        address tokenIn = up ? (m.baseIsToken0 ? m.quote : m.base) : (m.baseIsToken0 ? m.base : m.quote);
        uint8 decimals = tokenIn == m.base ? m.baseDecimals : m.quoteDecimals;
        string memory symbol = tokenIn == m.base && m.baseIsHbar ? "WHBAR" : ISymbol(tokenIn).symbol();
        console2.log("To align it, sell this token into the pool:", symbol, tokenIn);
        console2.log("amount, whole units (before the pool fee)", amount / 10 ** decimals);
        console2.log("amount, raw", amount);
    }

    /// @dev Chainlink cross price, quote per base with 8 decimals, as the vault computes it.
    function _oraclePrice(Market memory m) internal view returns (uint256) {
        (, int256 baseUsd,,,) = IFeed(address(m.baseFeed)).latestRoundData();
        (, int256 quoteUsd,,,) = IFeed(address(m.quoteFeed)).latestRoundData();
        return PriceMath.crossPrice(baseUsd.toUint256(), 8, quoteUsd.toUint256(), 8);
    }

    /// @dev The tick whose price is closest to `price`, by binary search over the monotonic tickToPrice.
    function _tickAtPrice(Market memory m, uint256 price) internal pure returns (int24) {
        int24 lo = -MAX_TICK / 2;
        int24 hi = MAX_TICK / 2;
        bool rising = PriceMath.tickToPrice(1, m.baseIsToken0, m.baseDecimals, m.quoteDecimals)
            > PriceMath.tickToPrice(0, m.baseIsToken0, m.baseDecimals, m.quoteDecimals);
        while (hi - lo > 1) {
            int24 mid = int24((int256(lo) + int256(hi)) / 2);
            uint256 p = PriceMath.tickToPrice(mid, m.baseIsToken0, m.baseDecimals, m.quoteDecimals);
            if ((p < price) == rising) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// @dev Raw input needed to move the pool from `from` to `to`, crossing initialized ticks on the way.
    function _amountIn(IPoolState pool, int24 from, int24 to, int24 spacing, bool up)
        internal
        view
        returns (uint256 amount)
    {
        uint256 liquidity = pool.liquidity();
        int24 at = from;
        while (at != to) {
            int24 next = _nextInitialized(pool, at, to, spacing, up);
            amount += up ? _token1For(liquidity, at, next) : _token0For(liquidity, next, at);
            if (next == to) break;
            (, int128 net,,,,,,) = pool.ticks(next);
            // Crossing upward adds a tick's net liquidity; crossing downward removes it.
            int256 signed = up ? int256(net) : -int256(net);
            liquidity = (liquidity.toInt256() + signed).toUint256();
            at = up ? next : next - 1;
        }
    }

    /// @dev The next initialized tick strictly past `at` in the swap direction, or `to` if none comes first.
    function _nextInitialized(IPoolState pool, int24 at, int24 to, int24 spacing, bool up)
        internal
        view
        returns (int24)
    {
        int24 step = up ? spacing : -spacing;
        int24 candidate = _floorTo(at, spacing) + (up ? spacing : int24(0));
        if (!up && candidate == at) candidate -= spacing;
        while (up ? candidate < to : candidate > to) {
            int24 compressed = candidate / spacing;
            uint256 word = pool.tickBitmap(int256(compressed >> 8).toInt16());
            if (word >> int256(compressed & 255).toUint256() & 1 == 1) return candidate;
            candidate += step;
        }
        return to;
    }

    function _floorTo(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }

    function _token1For(uint256 liquidity, int24 lower, int24 upper) internal pure returns (uint256) {
        return Math.mulDiv(liquidity, _sqrtRay(upper) - _sqrtRay(lower), RAY);
    }

    function _token0For(uint256 liquidity, int24 lower, int24 upper) internal pure returns (uint256) {
        uint256 a = _sqrtRay(lower);
        uint256 b = _sqrtRay(upper);
        return Math.mulDiv(liquidity, Math.mulDiv(b - a, RAY, a), b);
    }

    /// @dev sqrt(1.0001^tick) in RAY.
    function _sqrtRay(int24 tick) internal pure returns (uint256) {
        uint256 n = uint256(int256(tick < 0 ? -tick : tick));
        uint256 p = PriceMath.powRay(n);
        if (tick < 0) p = Math.mulDiv(RAY, RAY, p);
        return Math.sqrt(p * RAY);
    }
}
