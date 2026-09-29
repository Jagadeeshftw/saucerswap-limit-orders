// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { PriceMath } from "./PriceMath.sol";
import { GuardReading, GuardState, Market } from "../types/OrderTypes.sol";

/// @title MarketGuard
/// @notice Decides whether a market is safe to fill: both Chainlink feeds must be valid and fresh, and the
///         pool's TWAP must sit within the market's deviation limit of the Chainlink cross price.
/// @dev An external library so the check is linked rather than inlined, keeping OrderVault under 24 KiB.
library MarketGuard {
    using SafeCast for int256;

    function read(Market storage m) external view returns (GuardReading memory r) {
        (uint256 baseUsd, uint256 baseUpdated) = readFeed(m.baseFeed);
        (uint256 quoteUsd, uint256 quoteUpdated) = readFeed(m.quoteFeed);
        if (baseUsd == 0 || quoteUsd == 0) {
            r.state = GuardState.OracleInvalid;
            return r;
        }
        r.oracleUpdatedAt = baseUpdated < quoteUpdated ? baseUpdated : quoteUpdated;
        r.oraclePrice = PriceMath.crossPrice(baseUsd, m.baseFeedDecimals, quoteUsd, m.quoteFeedDecimals);
        if (block.timestamp - r.oracleUpdatedAt > m.guard.maxOracleAge) {
            r.state = GuardState.OracleStale;
            return r;
        }

        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = m.guard.twapWindow;
        try m.pool.observe(secondsAgo) returns (int56[] memory cumulatives, uint160[] memory) {
            int24 tick = PriceMath.meanTick(cumulatives[0], cumulatives[1], m.guard.twapWindow);
            r.poolPrice = PriceMath.tickToPrice(tick, m.baseIsToken0, m.baseDecimals, m.quoteDecimals);
        } catch {
            // The pool has too little observation history for the window (or no pool code at all).
            r.state = GuardState.TwapUnavailable;
            return r;
        }
        r.deviationBps = PriceMath.deviationBps(r.poolPrice, r.oraclePrice);
        r.state = r.deviationBps > m.guard.maxDeviationBps ? GuardState.DeviationTooHigh : GuardState.Open;
    }

    /// @notice A feed's answer and update time, or zeros when the answer is unusable.
    function readFeed(IAggregatorV3 feed) internal view returns (uint256 answer, uint256 updatedAt) {
        try feed.latestRoundData() returns (uint80, int256 a, uint256, uint256 u, uint80) {
            if (a <= 0 || u == 0 || u > block.timestamp) return (0, 0);
            return (a.toUint256(), u);
        } catch {
            return (0, 0);
        }
    }
}
