// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Price and amount conversions for base/quote markets.
/// @notice Prices are "quote per 1 base" with 8 decimals, the same scale as Chainlink USD feeds.
library PriceMath {
    /// @dev Prices carry 8 decimals.
    uint256 internal constant PRICE_SCALE = 1e8;
    /// @dev Basis points in 1.
    uint256 internal constant BPS = 10_000;
    /// @dev 27-decimal fixed point for the tick math.
    uint256 internal constant RAY = 1e27;
    /// @dev 1.0001 in RAY: the price ratio between adjacent Uniswap-v3 style ticks.
    uint256 internal constant TICK_BASE_RAY = 1_000_100_000_000_000_000_000_000_000;
    /// @dev Uniswap v3 tick bounds; pools never report a tick outside them.
    int24 internal constant MAX_TICK = 887_272;

    /// @notice A tick outside the Uniswap v3 range of plus or minus 887,272.
    /// @param tick The tick given.
    error TickOutOfRange(int24 tick);

    /// @notice 1.0001^exponent in RAY, by binary exponentiation (relative error below 1e-10 across the tick range).
    /// @param exponent The power, at most `MAX_TICK` in practice.
    /// @return result 1.0001^exponent, scaled by 1e27.
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
    /// @param cumulativeStart The tick cumulative at the start of the window.
    /// @param cumulativeEnd The tick cumulative at the end of the window.
    /// @param window The window, in seconds; non-zero.
    /// @return The mean tick.
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
    /// @param tick A pool tick, within plus or minus `MAX_TICK` (887,272).
    /// @param baseIsToken0 Whether the base is the pool's token0.
    /// @param baseDecimals The base token's decimals.
    /// @param quoteDecimals The quote token's decimals.
    /// @return Quote per 1 base, 8 decimals.
    /// @dev Reverts `TickOutOfRange` if `tick` is outside plus or minus `MAX_TICK`.
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
    /// @param baseUsd The base/USD answer.
    /// @param baseFeedDecimals The base feed's decimals.
    /// @param quoteUsd The quote/USD answer; non-zero.
    /// @param quoteFeedDecimals The quote feed's decimals.
    /// @return Quote per 1 base, 8 decimals.
    function crossPrice(uint256 baseUsd, uint8 baseFeedDecimals, uint256 quoteUsd, uint8 quoteFeedDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(baseUsd * PRICE_SCALE, 10 ** quoteFeedDecimals, quoteUsd * 10 ** baseFeedDecimals);
    }

    /// @notice Quote amount (raw units) worth `baseAmount` raw base at `price`.
    /// @param baseAmount Base amount, in raw units.
    /// @param price Quote per 1 base, 8 decimals.
    /// @param baseDecimals The base token's decimals.
    /// @param quoteDecimals The quote token's decimals.
    /// @return Quote amount, in raw units, rounded down.
    function baseToQuote(uint256 baseAmount, uint256 price, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(baseAmount, price * 10 ** quoteDecimals, PRICE_SCALE * 10 ** baseDecimals);
    }

    /// @notice Base amount (raw units) worth `quoteAmount` raw quote at `price`.
    /// @param quoteAmount Quote amount, in raw units.
    /// @param price Quote per 1 base, 8 decimals; non-zero.
    /// @param baseDecimals The base token's decimals.
    /// @param quoteDecimals The quote token's decimals.
    /// @return Base amount, in raw units, rounded down.
    function quoteToBase(uint256 quoteAmount, uint256 price, uint8 baseDecimals, uint8 quoteDecimals)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(quoteAmount, PRICE_SCALE * 10 ** baseDecimals, price * 10 ** quoteDecimals);
    }

    /// @notice |a - b| / reference, in basis points.
    /// @param a The value compared.
    /// @param b The reference; non-zero.
    /// @return The difference in bps of `b`, rounded down.
    function deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return Math.mulDiv(diff, BPS, b);
    }

    /// @notice How far `price` is from a trigger it has NOT met, in bps of `price`, and never less than 1. An order
    ///         type returns 0 only for a met trigger, because the vault fills on 0: `deviationBps` rounds down, so a
    ///         price a fraction of a basis point short of its trigger would otherwise read as met and fill early.
    /// @param trigger The trigger price.
    /// @param price The current price; non-zero.
    /// @return The distance in bps of `price`, at least 1.
    function distanceBps(uint256 trigger, uint256 price) internal pure returns (uint256) {
        uint256 d = deviationBps(trigger, price);
        return d == 0 ? 1 : d;
    }

    /// @notice `amount` reduced by `bps` basis points, rounded down.
    /// @param amount The amount.
    /// @param bps Basis points to take off, at most 10,000.
    /// @return The reduced amount.
    function lessBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, BPS - bps, BPS);
    }
}
