// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PriceMath } from "./PriceMath.sol";
import { Costs, SweepParams } from "../types/OrderTypes.sol";

/// @title The vault's cost and scheduling arithmetic.
/// @notice One copy of every number the vault charges or schedules by, shared by `OrderVault` (which acts on it)
///         and `OrderVaultLens` (which previews it). Internal functions only, so it is compiled into both and
///         adds no call overhead; a lens preview and the vault's own charge come from the same code.
/// @dev Gas figures come from `Costs` (measured on testnet, see `MarketConfig.costs()`); `rate` is tinybar per
///      `RATE_UNIT` tinycents from the 0x168 exchange-rate system contract, read once per call by the caller.
library SweepMath {
    /// @dev Tinycents converted per exchange-rate lookup.
    uint256 internal constant RATE_UNIT = 1e12;
    /// @dev Solo checks a new order must be able to pay for on top of its reserve.
    uint256 internal constant MIN_CHECKS_FUNDED = 6;
    /// @dev A sweep that has not fired this long after its expiry is treated as dead and may be restarted.
    uint256 internal constant SWEEP_GRACE = 120;

    /// @notice What the batch charge needs to know about one order in a sweep's batch.
    struct ChargeInput {
        bool live; // open, funded and not expired
        uint256 budget;
        uint256 reserve; // `reserve()` for the order's side
    }

    /// @notice Tinybar for `gas` at the configured gas price plus the safety margin.
    function gasToTinybar(Costs memory c, uint256 gas, uint256 rate) internal pure returns (uint256) {
        uint256 tinycents = gas * c.gasPriceTinycents;
        tinycents += (tinycents * c.safetyBps) / PriceMath.BPS;
        return (tinycents * rate) / RATE_UNIT;
    }

    /// @notice Per-order charge for one scheduled check: an even share of the sweep's fixed cost plus its own check.
    function sweepShare(Costs memory c, uint256 fundedOrders, uint256 rate) internal pure returns (uint256) {
        uint256 fixedGas = uint256(c.scheduleGas) + c.sweepBaseGas;
        return gasToTinybar(c, (fixedGas + fundedOrders - 1) / fundedOrders + c.checkGas, rate);
    }

    /// @notice Gas to fill and settle one order whose input is HBAR (`hbarIn`) or an HTS token.
    function fillGas(Costs memory c, bool hbarIn) internal pure returns (uint256) {
        return uint256(hbarIn ? c.fillGasHbarIn : c.fillGasTokenIn) + c.settleGas;
    }

    /// @notice The most one order can owe for the chain's final sweep: running it alone, with no reschedule.
    function tailGas(Costs memory c) internal pure returns (uint256) {
        return uint256(c.sweepBaseGas) + c.checkGas;
    }

    /// @notice Gas a sweep keeps back so it can always reach the reschedule.
    function finishGas(Costs memory c) internal pure returns (uint256) {
        return uint256(c.scheduleGas) + c.sweepBaseGas;
    }

    /// @notice Budget an order never spends on routine checks: its fill, plus its share of a final sweep.
    function reserve(Costs memory c, bool hbarIn, uint256 rate) internal pure returns (uint256) {
        return gasToTinybar(c, fillGas(c, hbarIn) + tailGas(c), rate);
    }

    /// @notice Smallest budget accepted at placement: the reserve plus `MIN_CHECKS_FUNDED` solo checks.
    function minBudget(Costs memory c, bool hbarIn, uint256 rate) internal pure returns (uint256) {
        return reserve(c, hbarIn, rate) + MIN_CHECKS_FUNDED * sweepShare(c, 1, rate);
    }

    /// @notice Gas limit for a sweep of a market with `openOrders` open orders: every order it will visit, and
    ///         as many fills as it may make, priced at the costlier token-in fill.
    function sweepGasLimit(Costs memory c, SweepParams memory sp, uint256 openOrders) internal pure returns (uint256) {
        uint256 orders = openOrders > sp.maxOrders ? sp.maxOrders : openOrders;
        if (orders == 0) orders = 1;
        uint256 fills = orders < sp.maxFills ? orders : sp.maxFills;
        return
            finishGas(c) + orders * (uint256(c.checkGas) + c.settleGas) + fills
                * (uint256(c.fillGasTokenIn) + c.settleGas);
    }

    /// @notice Seconds to wait before the next check of an order `distanceBps` from its trigger: as long as the
    ///         price could plausibly need to cover that distance, within the market's bounds, and never past the
    ///         order's expiry (so expired orders are refunded promptly).
    function delayFor(SweepParams memory sp, uint256 distanceBps, uint256 expiry, uint256 nowTs)
        internal
        pure
        returns (uint256 d)
    {
        d = (distanceBps * 1 hours) / sp.maxMoveBpsPerHour;
        if (d > sp.maxInterval) d = sp.maxInterval;
        uint256 untilExpiry = expiry > nowTs ? expiry - nowTs : 0;
        if (d > untilExpiry) d = untilExpiry;
        if (d < sp.minInterval) d = sp.minInterval;
    }

    /// @notice Whether a market's sweep chain has stopped: nothing pending, or the pending one is long overdue.
    function isDead(address pendingSchedule, uint256 nextSweepAt, uint256 nowTs) internal pure returns (bool) {
        return pendingSchedule == address(0) || nowTs > nextSweepAt + SWEEP_GRACE;
    }

    /// @notice Charges for one scheduled sweep of `orders`. `share` is each paying order's part: the fixed cost
    ///         split over the live orders that can afford it (recounted until stable) plus its own check. Orders
    ///         that can't afford it pay `parkFee` from their reserve: their own check, and when nobody can pay, an
    ///         even part of this final sweep too.
    function batchCharges(Costs memory c, uint256 rate, ChargeInput[] memory orders)
        internal
        pure
        returns (uint256 share, uint256 parkFee)
    {
        uint256 funded;
        for (uint256 i; i < orders.length; ++i) {
            if (orders[i].live) funded++;
        }
        uint256 payers = funded;
        while (payers > 0) {
            share = sweepShare(c, payers, rate);
            uint256 affordable;
            for (uint256 i; i < orders.length; ++i) {
                if (orders[i].live && orders[i].budget >= orders[i].reserve + share) affordable++;
            }
            if (affordable == payers) return (share, gasToTinybar(c, c.checkGas, rate));
            payers = affordable;
        }
        // Nobody can pay: this is the chain's last sweep. Price checks solo so every order parks.
        uint256 parkers = funded == 0 ? 1 : funded;
        return (
            sweepShare(c, 1, rate),
            gasToTinybar(c, (uint256(c.sweepBaseGas) + parkers - 1) / parkers + c.checkGas, rate)
        );
    }
}
