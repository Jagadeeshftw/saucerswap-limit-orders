// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHederaTokenService } from "../interfaces/IHederaTokenService.sol";
import { MarketGuard } from "./MarketGuard.sol";
import { Settlement } from "./Settlement.sol";
import { GuardParams, Market, SweepParams } from "../types/OrderTypes.sol";

/// @title MarketRegistry
/// @notice Listing and tuning markets: the owner-only, once-per-market work of validating a market's guard and
///         sweep settings, writing it to the vault's storage and associating the vault with its HTS tokens.
/// @dev An external library (delegatecalled, like `MarketGuard` and `Settlement`), so this cold admin code lives
///      outside `OrderVault` and no sweep, check or fill pays for it. The errors match the vault's, so callers see
///      the same `InvalidMarket` / `InvalidGuard` / `InvalidSweep` whichever contract raises them.
library MarketRegistry {
    IHederaTokenService internal constant HTS = IHederaTokenService(address(0x167));

    /// @dev HIP-1215 caps expiry 62 days ahead; the minimum is a few seconds past consensus time.
    uint256 internal constant MIN_SWEEP_INTERVAL = 30;
    uint256 internal constant MAX_SWEEP_INTERVAL = 1 days;

    error InvalidMarket();
    error InvalidGuard();
    error InvalidSweep();

    /// @notice Validate `market` and write it to the empty slot `m`, reading the feeds' decimals and the pool's
    ///         token order, then associate the vault with the market's HTS tokens.
    function list(Market storage m, Market calldata market) external {
        if (address(market.pool) == address(0) || market.base == address(0) || market.quote == address(0)) {
            revert InvalidMarket();
        }
        if (market.base == market.quote || (market.baseIsHbar && market.quoteIsHbar)) revert InvalidMarket();
        if (address(market.baseFeed) == address(0) || address(market.quoteFeed) == address(0)) revert InvalidMarket();
        _validate(market.guard, market.sweep, market.poolFee);

        m.base = market.base;
        m.quote = market.quote;
        m.baseDecimals = market.baseDecimals;
        m.quoteDecimals = market.quoteDecimals;
        m.baseIsHbar = market.baseIsHbar;
        m.quoteIsHbar = market.quoteIsHbar;
        m.baseFeed = market.baseFeed;
        m.quoteFeed = market.quoteFeed;
        m.baseFeedDecimals = market.baseFeed.decimals();
        m.quoteFeedDecimals = market.quoteFeed.decimals();
        m.pool = market.pool;
        m.poolFee = market.poolFee;
        m.baseIsToken0 = market.pool.token0() == market.base;
        m.active = true;
        m.guard = market.guard;
        m.sweep = market.sweep;
        if (!market.baseIsHbar) Settlement.associate(HTS, market.base);
        if (!market.quoteIsHbar) Settlement.associate(HTS, market.quote);
    }

    /// @notice Retune a listed market's guard and sweep, or pause it. The bounds keep the guard from being
    ///         switched off.
    function update(Market storage m, GuardParams calldata guard, SweepParams calldata sweep, bool active) external {
        _validate(guard, sweep, m.poolFee);
        m.guard = guard;
        m.sweep = sweep;
        m.active = active;
    }

    function _validate(GuardParams calldata g, SweepParams calldata p, uint24 poolFee) private pure {
        if (!MarketGuard.paramsValid(g, poolFee)) revert InvalidGuard();
        if (p.minInterval < MIN_SWEEP_INTERVAL || p.maxInterval > MAX_SWEEP_INTERVAL) revert InvalidSweep();
        if (p.minInterval > p.maxInterval || p.maxMoveBpsPerHour == 0) revert InvalidSweep();
        if (p.maxOrders == 0 || p.maxFills == 0 || p.maxFills > p.maxOrders) revert InvalidSweep();
    }
}
