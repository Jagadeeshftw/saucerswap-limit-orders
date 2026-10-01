// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Price and amount conversions for base/quote markets.
/// @notice Prices are "quote per 1 base" with 8 decimals, the same scale as Chainlink USD feeds.
library PriceMath {
    uint256 internal constant PRICE_SCALE = 1e8;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY = 1e27;
    /// @dev 1.0001 in RAY: the price ratio between adjacent Uniswap-v3 style ticks.
    uint256 internal constant TICK_BASE_RAY = 1_000_100_000_000_000_000_000_000_000;
    /// @dev Uniswap v3 tick bounds; pools never report a tick outside them.
    int24 internal constant MAX_TICK = 887_272;

    error TickOutOfRange(int24 tick);

    /// @notice 1.0001^exponent in RAY, by binary exponentiation (relative error below 1e-10 across the tick range).
    function powRay(uint256 exponent) internal pure returns (uint256 result) {
        uint256 base = TICK_BASE_RAY;
        result = RAY;
        while (exponent != 0) {
            if (exponent & 1 == 1) result = Math.mulDiv(result, base, RAY);
            base = Math.mulDiv(base, base, RAY);
            exponent >>= 1;
        }
    }

    /// @notice Arithmetic-mean tick between two cumulative readings, rounded towards negative infinity.
    function meanTick(int56 cumulativeStart, int56 cumulativeEnd, uint32 window) internal pure returns (int24) {
        int56 delta = cumulativeEnd - cumulativeStart;
        int56 span = int56(uint56(window));
        int56 mean = delta / span;
        if (delta < 0 && delta % span != 0) mean--;
        // A mean of in-range ticks is itself in range, so the narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(mean);
    }

    /// @notice Pool price as "quote per 1 base" (8 decimals) from a tick, which prices token1 in token0.
    /// @dev Raw quote per raw base is 1.0001^tick when base is token0 and 1.0001^-tick otherwise. Picking the
    ///      sign first means one division at full precision. A price too small to represent returns 0,
    ///      which the guard treats as maximal deviation.
    function tickToPrice(int24 tick, bool baseIsToken0, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        if (tick > MAX_TICK || tick < -MAX_TICK) revert TickOutOfRange(tick);
        int256 exponent = baseIsToken0 ? int256(tick) : -int256(tick);
        uint256 numerator = PRICE_SCALE * 10 ** baseDecimals;
        uint256 denominator = 10 ** quoteDecimals;
        if (exponent >= 0) {
            // exponent is non-negative and at most MAX_TICK.
            // forge-lint: disable-next-line(unsafe-typecast)
            return Math.mulDiv(powRay(uint256(exponent)), numerator, RAY * denominator);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 power = powRay(uint256(-exponent));
        if (power > type(uint256).max / denominator) return 0;
        return Math.mulDiv(numerator, RAY, power * denominator);
    }

    /// @notice Cross price of base in quote (8 decimals) from two USD feeds.
    function crossPrice(uint256 baseUsd, uint8 baseFeedDecimals, uint256 quoteUsd, uint8 quoteFeedDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(baseUsd * PRICE_SCALE, 10 ** quoteFeedDecimals, quoteUsd * 10 ** baseFeedDecimals);
    }

    /// @notice Quote amount (raw units) worth `baseAmount` raw base at `price`.
    function baseToQuote(uint256 baseAmount, uint256 price, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(baseAmount, price * 10 ** quoteDecimals, PRICE_SCALE * 10 ** baseDecimals);
    }

    /// @notice Base amount (raw units) worth `quoteAmount` raw quote at `price`.
    function quoteToBase(uint256 quoteAmount, uint256 price, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(quoteAmount, PRICE_SCALE * 10 ** baseDecimals, price * 10 ** quoteDecimals);
    }

    /// @notice |a - b| / reference, in basis points.
    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return Math.mulDiv(diff, BPS, b);
    }

    /// @notice How far `price` is from a trigger it has NOT met, in bps of `price`, and never less than 1. An order
    ///         type returns 0 only for a met trigger, because the vault fills on 0: `deviationBps` rounds down, so a
    ///         price a fraction of a basis point short of its trigger would otherwise read as met and fill early.
    function distanceBps(uint256 trigger, uint256 price) internal pure returns (uint256) {
        uint256 d = deviationBps(trigger, price);
        return d == 0 ? 1 : d;
    }

    /// @notice `amount` reduced by `bps` basis points, rounded down.
    function lessBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, BPS - bps, BPS);
    }
}
