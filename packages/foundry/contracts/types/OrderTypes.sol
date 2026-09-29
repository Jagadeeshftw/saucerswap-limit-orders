// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { ISaucerSwapV2Pool } from "../interfaces/ISaucerSwapV2.sol";

// Types shared by OrderVault, MarketGuard, the deploy script and the tests.

enum Side {
    SellBase,
    BuyBase
}

/// @dev Sell + AtOrAbove is a limit sell, Sell + AtOrBelow a stop-loss,
///      Buy + AtOrBelow a limit buy, Buy + AtOrAbove a stop-buy.
enum Trigger {
    AtOrAbove,
    AtOrBelow
}

enum Status {
    None,
    Open,
    Filled,
    Cancelled,
    Expired
}

enum GuardState {
    Open,
    OracleInvalid,
    OracleStale,
    TwapUnavailable,
    DeviationTooHigh
}

/// @notice A tradable pair. Prices are quote per 1 base, 8 decimals.
struct Market {
    address base;
    address quote;
    uint8 baseDecimals;
    uint8 quoteDecimals;
    bool baseIsHbar;
    bool quoteIsHbar;
    IAggregatorV3 baseFeed;
    IAggregatorV3 quoteFeed;
    uint8 baseFeedDecimals;
    uint8 quoteFeedDecimals;
    ISaucerSwapV2Pool pool;
    uint24 poolFee;
    bool baseIsToken0;
    bool active;
    GuardParams guard;
    SweepParams sweep;
}

struct GuardParams {
    uint32 twapWindow;
    uint16 maxDeviationBps;
    uint32 maxOracleAge;
    uint16 maxSlippageBps;
}

struct SweepParams {
    uint32 interval;
    uint16 maxOrders;
    uint8 maxFills;
}

struct SweepState {
    address pendingSchedule;
    uint40 nextSweepAt;
    uint32 cursor;
    uint32 fundedOrders;
}

/// @notice Gas used by each piece of work, measured on Hedera testnet, and the network gas price.
struct Costs {
    uint32 scheduleGas;
    uint32 sweepBaseGas;
    uint32 checkGas;
    uint32 fillGasHbarIn;
    uint32 fillGasTokenIn;
    uint32 settleGas;
    /// @dev Hedera prices gas in USD; converted to tinybar through the 0x168 exchange-rate contract.
    uint32 gasPriceTinycents;
    uint16 safetyBps;
}

struct Order {
    uint32 marketId;
    Side side;
    Trigger trigger;
    Status status;
    bool funded;
    uint16 slippageBps;
    uint40 createdAt;
    uint40 expiry;
    uint128 amountIn;
    uint128 triggerPrice;
    uint128 budget;
}

struct PlaceParams {
    uint32 marketId;
    Side side;
    Trigger trigger;
    uint128 amountIn;
    uint128 triggerPrice;
    uint16 slippageBps;
    uint40 expiry;
}

struct GuardReading {
    GuardState state;
    uint256 oraclePrice;
    uint256 poolPrice;
    uint256 deviationBps;
    uint256 oracleUpdatedAt;
}
