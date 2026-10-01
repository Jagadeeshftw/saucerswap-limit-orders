// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOrderType } from "../interfaces/IOrderType.sol";
import { Side } from "../types/OrderTypes.sol";
import { PriceMath } from "../libraries/PriceMath.sol";

/// @title Trailing stop (sell-side).
/// @notice Rides the price up and fires on a pullback: it tracks the highest Chainlink price the order has seen
///         at a check (the "peak"), and the trigger is `peak × (1 − trail)`. As the peak rises the trigger rises
///         with it; it never moves down.
/// @dev The peak is the maximum of the oracle **sampled at scheduled checks**, not the true continuous high, so a
///      spike that reverses entirely between two checks is not captured. This is inherent to a pay-per-check,
///      on-chain design and is stated in the UI and docs. Per-order state is the peak, returned to the vault which
///      stores it; this contract is pure and cannot itself write anything.
contract TrailingStopType is IOrderType {
    uint256 internal constant BPS = 10_000;
    uint128 public constant MIN_TRAIL_BPS = 50; // 0.5%
    uint128 public constant MAX_TRAIL_BPS = 5000; // 50%

    /// @dev Sell-side only, with the trail in [MIN_TRAIL_BPS, MAX_TRAIL_BPS].
    function validate(Side side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        return side == Side.SellBase && amountIn > 0 && param >= MIN_TRAIL_BPS && param <= MAX_TRAIL_BPS;
    }

    function evaluate(Side, uint128 param, bytes32 state, uint256 oraclePrice)
        external
        pure
        returns (uint256 distanceBps, bytes32 newState)
    {
        // Seed the peak at the first observed price, then ratchet it up; it never falls.
        uint256 peak = state == bytes32(0) ? oraclePrice : uint256(state);
        if (oraclePrice > peak) peak = oraclePrice;
        uint256 trigger = (peak * (BPS - param)) / BPS;
        distanceBps = oraclePrice <= trigger ? 0 : PriceMath.distanceBps(trigger, oraclePrice);
        newState = bytes32(peak);
    }

    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}
