// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOrderType } from "../interfaces/IOrderType.sol";
import { Side } from "../types/OrderTypes.sol";
import { PriceMath } from "../libraries/PriceMath.sol";

/// @title Stop order.
/// @notice A stop-loss (sell at or below a price) or a stop-buy (buy at or above it). Stateless. Behaviour is
///         identical to the original fixed `Sell+AtOrBelow` / `Buy+AtOrAbove` logic.
/// @dev `script/Deploy.s.sol` registers it as order type 1.
contract StopOrderType is IOrderType {
    /// @notice Accepts either side with a non-zero amount and trigger price.
    /// @param amountIn Amount escrowed; greater than 0.
    /// @param param Trigger price, quote per 1 base with 8 decimals; greater than 0.
    /// @return Whether the parameters are valid.
    function validate(Side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        return amountIn > 0 && param > 0;
    }

    /// @notice Met when the price is at or below the trigger for a sell, at or above it for a buy.
    /// @param side Sell or buy.
    /// @param param Trigger price (quote per 1 base, 8 decimals).
    /// @param state Returned unchanged: the type is stateless.
    /// @param oraclePrice The Chainlink cross price for the market.
    /// @return distanceBps 0 when the trigger is met; otherwise the gap in bps of the price, at least 1.
    /// @return newState `state`, unchanged.
    function evaluate(Side side, uint128 param, bytes32 state, uint256 oraclePrice)
        external
        pure
        returns (uint256 distanceBps, bytes32 newState)
    {
        // A stop-loss (sell) fires at or below its trigger; a stop-buy fires at or above it.
        bool met = side == Side.SellBase ? oraclePrice <= param : oraclePrice >= param;
        distanceBps = met ? 0 : PriceMath.distanceBps(param, oraclePrice);
        newState = state;
    }

    /// @notice No extra floor, so the vault's own Chainlink floor applies.
    /// @return Always 0.
    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}
