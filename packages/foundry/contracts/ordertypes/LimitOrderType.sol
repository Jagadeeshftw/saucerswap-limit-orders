// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOrderType } from "../interfaces/IOrderType.sol";
import { Side } from "../types/OrderTypes.sol";
import { PriceMath } from "../libraries/PriceMath.sol";

/// @title Limit order.
/// @notice Sell at or above a price, or buy at or below it. Stateless. Behaviour is identical to the original
///         fixed `Sell+AtOrAbove` / `Buy+AtOrBelow` logic, so existing orders and proofs are unchanged.
contract LimitOrderType is IOrderType {
    function validate(Side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        return amountIn > 0 && param > 0;
    }

    function evaluate(Side side, uint128 param, bytes32 state, uint256 oraclePrice)
        external
        pure
        returns (uint256 distanceBps, bytes32 newState)
    {
        // A limit sell fires at or above its trigger; a limit buy fires at or below it.
        bool met = side == Side.SellBase ? oraclePrice >= param : oraclePrice <= param;
        distanceBps = met ? 0 : PriceMath.deviationBps(param, oraclePrice);
        newState = state; // stateless: unchanged, so the vault writes nothing
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0; // rely on the vault's Chainlink-priced floor
    }
}
