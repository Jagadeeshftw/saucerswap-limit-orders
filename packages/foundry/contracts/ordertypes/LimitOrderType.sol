// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOrderType } from "../interfaces/IOrderType.sol";
import { Side } from "../types/OrderTypes.sol";
import { PriceMath } from "../libraries/PriceMath.sol";

/// @title Limit order.
/// @notice Sell at or above a price, or buy at or below it. Stateless. Behaviour is identical to the original
///         fixed `Sell+AtOrAbove` / `Buy+AtOrBelow` logic, so existing orders and proofs are unchanged.
/// @dev `script/Deploy.s.sol` registers it as order type 0.
contract LimitOrderType is IOrderType {
    /// @notice Accepts either side with a non-zero amount and trigger price.
    /// @param amountIn Amount escrowed; greater than 0.
    /// @param param Trigger price, quote per 1 base with 8 decimals; greater than 0.
    /// @return Whether the parameters are valid.
    function validate(Side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        return amountIn > 0 && param > 0;
    }

    /// @notice Met when the price is at or above the trigger for a sell, at or below it for a buy.
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
        // A limit sell fires at or above its trigger; a limit buy fires at or below it.
        bool met = side == Side.SellBase ? oraclePrice >= param : oraclePrice <= param;
        distanceBps = met ? 0 : PriceMath.distanceBps(param, oraclePrice);
        newState = state; // stateless: unchanged, so the vault writes nothing
    }

    /// @notice No extra floor, so the vault's own Chainlink floor applies.
    /// @return Always 0.
    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0; // rely on the vault's Chainlink-priced floor
    }
}
