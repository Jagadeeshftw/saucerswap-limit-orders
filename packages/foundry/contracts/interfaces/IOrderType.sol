// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Side } from "../types/OrderTypes.sol";

/// @title Pluggable order-type strategy.
/// @notice A stateless, view-only strategy for one kind of order (limit, stop-loss, trailing stop, …). The vault
///         owns all order state and all funds; a strategy only reads what the vault passes and returns decisions.
///         Because every function is `view` and the vault reaches it with `staticcall`, a strategy can never write
///         storage, move value, or reenter. The vault always enforces the guard and its own Chainlink-priced
///         slippage floor on top of whatever a strategy returns, so a buggy or hostile strategy cannot fill an
///         order at a bad price or past the guard — see `minOut`.
interface IOrderType {
    /// @notice Validate placement parameters for this type. Returns false (or reverts) if invalid.
    /// @param side       Sell the base, or buy it.
    /// @param amountIn   Amount escrowed.
    /// @param param      The type's parameter: a trigger price for limit/stop, a trail in bps for trailing.
    /// @param slippageBps Maker's slippage tolerance.
    /// @param expiry     Order expiry (unix seconds).
    /// @param nowTs      Current block timestamp, passed in so the strategy stays pure.
    function validate(Side side, uint128 amountIn, uint128 param, uint16 slippageBps, uint40 expiry, uint40 nowTs)
        external
        pure
        returns (bool ok);

    /// @notice The whole per-check decision, in one call so a check costs one staticcall.
    /// @param side        Sell or buy.
    /// @param param       The type parameter (see `validate`).
    /// @param state       This order's opaque per-type state (e.g. a trailing peak); zero for a new order.
    /// @param oraclePrice The Chainlink cross price for the market, in the market's price units.
    /// @return distanceBps 0 when the trigger is met (fill now); otherwise how far the price is from the trigger,
    ///         which the vault turns into the next-check delay.
    /// @return newState    The state to persist; the vault writes it only when it differs from `state`.
    function evaluate(Side side, uint128 param, bytes32 state, uint256 oraclePrice)
        external
        pure
        returns (uint256 distanceBps, bytes32 newState);

    /// @notice An optional extra minimum-out floor, priced from Chainlink only. The vault takes the MAXIMUM of
    ///         this and its own Chainlink floor (Chainlink value less the maker's slippage), so a strategy can
    ///         only ever ask for MORE protection, never less. Return 0 to rely entirely on the vault's floor.
    /// @param oraclePrice The Chainlink cross price for the market.
    function minOut(Side side, uint128 amountIn, uint128 param, uint256 oraclePrice) external pure returns (uint256);
}
