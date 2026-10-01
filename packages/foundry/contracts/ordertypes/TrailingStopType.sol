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
///      stores it; this contract is pure and cannot itself write anything. `script/Deploy.s.sol` registers it as
///      order type 2.
contract TrailingStopType is IOrderType {
    uint256 internal constant BPS = 10_000;
    /// @notice Smallest trail accepted, in bps (0.5%).
    uint128 public constant MIN_TRAIL_BPS = 50;
    /// @notice Largest trail accepted, in bps (50%).
    uint128 public constant MAX_TRAIL_BPS = 5000;

    /// @notice Accepts a sell with a non-zero amount and a trail of 50 to 5,000 bps.
    /// @dev Sell-side only, with the trail in [MIN_TRAIL_BPS, MAX_TRAIL_BPS].
    /// @param side Must be `SellBase`.
    /// @param amountIn Amount escrowed; greater than 0.
    /// @param param The trail, in bps: `MIN_TRAIL_BPS` (50) to `MAX_TRAIL_BPS` (5,000).
    /// @return Whether the parameters are valid.
    function validate(Side side, uint128 amountIn, uint128 param, uint16, uint40, uint40) external pure returns (bool) {
        return side == Side.SellBase && amountIn > 0 && param >= MIN_TRAIL_BPS && param <= MAX_TRAIL_BPS;
    }

    /// @notice Raises the peak to the current price if higher, then is met when the price is at or below
    ///         `peak × (1 − trail)`.
    /// @param param The trail, in bps.
    /// @param state The peak price so far, as bytes32; zero before the first check.
    /// @param oraclePrice The Chainlink cross price for the market.
    /// @return distanceBps 0 when the trigger is met; otherwise the gap in bps of the price, at least 1.
    /// @return newState The new peak, as bytes32.
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

    /// @notice No extra floor, so the vault's own Chainlink floor applies.
    /// @return Always 0.
    function minOut(Side, uint128, uint128, uint256) external pure returns (uint256) {
        return 0;
    }
}
