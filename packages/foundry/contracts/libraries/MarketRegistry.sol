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
    /// @dev The HTS system contract.
    IHederaTokenService internal constant HTS = IHederaTokenService(address(0x167));

    /// @dev Shortest `minInterval`. HIP-1215 caps expiry 62 days ahead; the minimum is a few seconds past
    ///      consensus time.
    uint256 internal constant MIN_SWEEP_INTERVAL = 30;
    /// @dev Longest `maxInterval`.
    uint256 internal constant MAX_SWEEP_INTERVAL = 1 days;

    /// @notice A zero pool, token or feed address, the same token twice, or two HBAR legs.
    error InvalidMarket();
    /// @notice Guard settings outside the `MarketGuard.paramsValid` bounds.
    error InvalidGuard();
    /// @notice Sweep settings outside the `SweepParams` bounds.
    error InvalidSweep();

    /// @notice Validate `market` and write it to the empty slot `m`, reading the feeds' decimals and the pool's
    ///         token order, then associate the vault with the market's HTS tokens.
    /// @param m The vault's empty storage slot for the new market.
    /// @param market The market to list; `Market` gives each field's bounds.
    /// @dev Reverts `InvalidMarket`, `InvalidGuard` or `InvalidSweep` on a bad market.
    /// @dev Reverts `HtsError` (`Associate`) if the vault cannot associate with a market token.
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
    /// @param m The listed market, in the vault's storage.
    /// @param guard New guard settings, checked against the market's stored `poolFee`.
    /// @param sweep New sweep settings.
    /// @param active Whether new orders may be placed.
    /// @dev Reverts `InvalidGuard` or `InvalidSweep` on bad settings.
    function update(Market storage m, GuardParams calldata guard, SweepParams calldata sweep, bool active) external {
        _validate(guard, sweep, m.poolFee);
        m.guard = guard;
        m.sweep = sweep;
        m.active = active;
    }

    /// @notice The bounds `list` and `update` enforce: the guard passes `MarketGuard.paramsValid`; `minInterval` is at
    ///         least 30 s and at most `maxInterval`, which is at most 1 day; `maxMoveBpsPerHour` and `maxOrders` are
    ///         non-zero; and `maxFills` is 1 to `maxOrders`.
    /// @param g Guard settings.
    /// @param p Sweep settings.
    /// @param poolFee The market pool's fee, in hundredths of a basis point.
    /// @dev Reverts `InvalidGuard` or `InvalidSweep` when a bound is broken.
    function _validate(GuardParams calldata g, SweepParams calldata p, uint24 poolFee) private pure {
        if (!MarketGuard.paramsValid(g, poolFee)) revert InvalidGuard();
        if (p.minInterval < MIN_SWEEP_INTERVAL || p.maxInterval > MAX_SWEEP_INTERVAL) revert InvalidSweep();
        if (p.minInterval > p.maxInterval || p.maxMoveBpsPerHour == 0) revert InvalidSweep();
        if (p.maxOrders == 0 || p.maxFills == 0 || p.maxFills > p.maxOrders) revert InvalidSweep();
    }
}
