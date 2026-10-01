// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOrderType } from "../interfaces/IOrderType.sol";
import { Side } from "../types/OrderTypes.sol";
import { PriceMath } from "../libraries/PriceMath.sol";

/// @title Stop order.
/// @notice A stop-loss (sell at or below a price) or a stop-buy (buy at or above it). Stateless. Behaviour is
///         identical to the original fixed `Sell+AtOrBelow` / `Buy+AtOrAbove` logic.
contract StopOrderType is IOrderType {
    function validate(Side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        return amountIn > 0 && param > 0;
    }

    function evaluate(Side side, uint128 param, bytes32 state, uint256 oraclePrice)
        external
        pure
        returns (uint256 distanceBps, bytes32 newState)
    {
        // A stop-loss (sell) fires at or below its trigger; a stop-buy fires at or above it.
        bool met = side == Side.SellBase ? oraclePrice <= param : oraclePrice >= param;
        distanceBps = met ? 0 : PriceMath.deviationBps(param, oraclePrice);
        newState = state;
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}
