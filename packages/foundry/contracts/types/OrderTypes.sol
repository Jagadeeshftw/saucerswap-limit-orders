// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAggregatorV3 } from "../interfaces/IAggregatorV3.sol";
import { ISaucerSwapV2Pool } from "../interfaces/ISaucerSwapV2.sol";

// Types shared by OrderVault, MarketGuard, the deploy script and the tests.

/// @notice Which way an order trades.
/// @param SellBase Sell `amountIn` of the base token for the quote token.
/// @param BuyBase Spend `amountIn` of the quote token on the base token.
enum Side {
    SellBase,
    BuyBase
}

/// @notice Not used by the vault or the shipped order types since v1.1, where the order type encodes the
///         direction; kept for the tests that drive the earlier fixed-trigger vault.
/// @dev Sell + AtOrAbove is a limit sell, Sell + AtOrBelow a stop-loss,
///      Buy + AtOrBelow a limit buy, Buy + AtOrAbove a stop-buy.
/// @param AtOrAbove Fires when the price is at or above the trigger.
/// @param AtOrBelow Fires when the price is at or below the trigger.
enum Trigger {
    AtOrAbove,
    AtOrBelow
}

/// @notice An order's lifecycle state.
/// @param None No order with this id.
/// @param Open Escrowed and waiting for its trigger.
/// @param Filled Swapped; the output was paid to the NFT holder (or credited for `claim`).
/// @param Cancelled Cancelled by its holder; escrow and unused budget refunded.
/// @param Expired Reached its expiry unfilled; escrow and unused budget refunded.
enum Status {
    None,
    Open,
    Filled,
    Cancelled,
    Expired
}

/// @notice Which HTS operation failed, for the shared `HtsError`.
/// @param CreateCollection Creating the order NFT collection in `initialize`.
/// @param Mint Minting an order NFT in `placeOrder`.
/// @param TransferNft Moving a newly minted order NFT from the vault to the maker.
/// @param Associate Associating the vault with a market's HTS token in `listMarket`.
enum HtsOperation {
    CreateCollection,
    Mint,
    TransferNft,
    Associate
}

/// @notice An HTS system-contract call returned a non-success response code. Shared by the vault and the
///         Settlement library so both can revert and callers can catch the same error.
/// @param operation The HTS operation that failed.
/// @param responseCode The HTS response code it returned (22 is success).
error HtsError(HtsOperation operation, int64 responseCode);

/// @notice The guard's verdict on a market, from `MarketGuard.read`. Only `Open` lets an order fill.
/// @param Open Both feeds are valid and fresh and the pool TWAP is within `maxDeviationBps` of Chainlink.
/// @param OracleInvalid A feed reverted, answered zero or less, or reported a zero or future update time.
/// @param OracleStale The older feed update is more than `maxOracleAge` seconds old.
/// @param TwapUnavailable The pool could not report a TWAP over `twapWindow` (too little observation history).
/// @param DeviationTooHigh The pool TWAP is more than `maxDeviationBps` away from the Chainlink cross price.
enum GuardState {
    Open,
    OracleInvalid,
    OracleStale,
    TwapUnavailable,
    DeviationTooHigh
}

/// @notice A tradable pair. Prices are quote per 1 base, 8 decimals.
/// @param base Base token address (an HTS token; the WHBAR token when `baseIsHbar`). Non-zero, distinct from `quote`.
/// @param quote Quote token address (an HTS token; the WHBAR token when `quoteIsHbar`). Non-zero.
/// @param baseDecimals The base token's decimals (8 for HBAR).
/// @param quoteDecimals The quote token's decimals.
/// @param baseIsHbar The base leg is native HBAR: escrow and payouts in HBAR, routed through WHBAR.
/// @param quoteIsHbar The quote leg is native HBAR. At most one of the two legs may be HBAR.
/// @param baseFeed Chainlink base/USD feed. Non-zero.
/// @param quoteFeed Chainlink quote/USD feed. Non-zero.
/// @param baseFeedDecimals Read from `baseFeed.decimals()` by `listMarket`; the value passed in is ignored.
/// @param quoteFeedDecimals Read from `quoteFeed.decimals()` by `listMarket`; the value passed in is ignored.
/// @param pool SaucerSwap V2 pool for the pair, used for the TWAP and the swap. Non-zero.
/// @param poolFee The pool's fee in hundredths of a basis point (3000 = 0.30%); `poolFee / 100` is the
///        slippage floor, in bps, that every order must exceed.
/// @param baseIsToken0 Set by `listMarket` from `pool.token0()`; the value passed in is ignored.
/// @param active Whether new orders may be placed. `listMarket` sets it to true (the value passed in is ignored);
///        `updateMarket` changes it.
/// @param guard The guard's bounds; see `GuardParams`.
/// @param sweep The sweep's schedule and batch limits; see `SweepParams`.
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

/// @notice A market's guard settings. `MarketGuard.paramsValid` bounds every field so the guard can't be switched off.
/// @param twapWindow Seconds of pool TWAP compared with Chainlink: 300 to 86,400 (5 minutes to 1 day).
/// @param maxDeviationBps Largest TWAP-to-Chainlink gap, in bps, at which a fill may proceed: 1 to 1,000.
/// @param maxOracleAge Oldest acceptable feed update, in seconds: 60 to 93,600 (26 hours).
/// @param maxSlippageBps Largest slippage an order may set, in bps: above `poolFee / 100` and at most 1,000.
struct GuardParams {
    uint32 twapWindow;
    uint16 maxDeviationBps;
    uint32 maxOracleAge;
    uint16 maxSlippageBps;
}

/// @notice How often a market's sweep runs. The next sweep waits roughly as long as the price would need to reach
///         the nearest trigger at `maxMoveBpsPerHour`, clamped to [minInterval, maxInterval].
/// @param minInterval Shortest wait between sweeps, in seconds: at least 30 and at most `maxInterval`.
/// @param maxInterval Longest wait between sweeps, in seconds: at most 86,400 (1 day).
/// @param maxMoveBpsPerHour The price move per hour, in bps, the schedule assumes. Greater than 0.
/// @param maxOrders Open orders one sweep visits, from a rotating cursor. Greater than 0.
/// @param maxFills Fills one sweep may make: 1 to `maxOrders`.
struct SweepParams {
    uint32 minInterval;
    uint32 maxInterval;
    uint16 maxMoveBpsPerHour;
    uint16 maxOrders;
    uint8 maxFills;
}

/// @notice A market's sweep chain, as stored by the vault (`sweeps(marketId)`).
/// @param pendingSchedule The HSS schedule of the next sweep; zero when none is pending.
/// @param nextSweepAt When the pending sweep is due (unix seconds).
/// @param cursor Index in the market's open-order list where the next batch starts.
/// @param fundedOrders Open orders whose budget still pays for checks; the chain keeps running while it is above 0.
/// @param epoch Bumped on every new schedule; a scheduled sweep carrying an older epoch has been superseded.
/// @param heldStreak Consecutive sweeps where a triggered order could not fill (at most 8); drives the back-off.
struct SweepState {
    address pendingSchedule;
    uint40 nextSweepAt;
    uint32 cursor;
    uint32 fundedOrders;
    uint32 epoch;
    uint8 heldStreak;
}

/// @notice What `OrderVaultLens.sweepStatus` reports for a market.
/// @param Idle No funded orders, so no sweep is needed.
/// @param Scheduled A sweep is pending and not overdue.
/// @param Stalled Funded orders are waiting but no sweep will fire; anyone may call `restartSweep`.
enum SweepStatus {
    Idle,
    Scheduled,
    Stalled
}

/// @notice Gas used by each piece of work, measured on Hedera testnet, and the network gas price.
/// @param scheduleGas The HSS scheduling fee, as gas. Non-zero.
/// @param sweepBaseGas A sweep's fixed gas besides scheduling and its orders.
/// @param checkGas Gas to check one order. Non-zero.
/// @param fillGasHbarIn Gas to fill an order whose input is HBAR, before settlement. Non-zero.
/// @param fillGasTokenIn Gas to fill an order whose input is an HTS token, before settlement. Non-zero.
/// @param settleGas Gas to settle one order (payouts and retiring its NFT); added to every fill and expiry.
/// @param idleSweepGas A sweep that finds nothing to do: superseded by an earlier one, or left with no funded orders.
/// @param gasPriceTinycents Hedera prices gas in USD; converted to tinybar through the 0x168 exchange-rate contract.
///        Non-zero.
/// @param safetyBps Margin added to every gas-to-HBAR conversion, in bps: 0 to 10,000.
struct Costs {
    uint32 scheduleGas;
    uint32 sweepBaseGas;
    uint32 checkGas;
    uint32 fillGasHbarIn;
    uint32 fillGasTokenIn;
    uint32 settleGas;
    uint32 idleSweepGas;
    uint32 gasPriceTinycents;
    uint16 safetyBps;
}

/// @notice One order, as stored by the vault (`getOrder(orderId)`). The order id is its NFT serial number.
/// @param marketId The market it trades on.
/// @param side Sell the base, or buy it.
/// @param orderType Index into the vault's order-type registry (limit, stop, trailing, …).
/// @param status Lifecycle state.
/// @param funded Whether its budget still pays for scheduled checks. A parked order is not checked until `topUp`.
/// @param slippageBps The maker's slippage tolerance, in bps.
/// @param createdAt Placement time (unix seconds).
/// @param expiry Expiry time (unix seconds); the order is refunded at the first check at or after it.
/// @param amountIn Escrowed input amount, in the input token's raw units (tinybar for HBAR).
/// @param typeParam The type's parameter: a trigger price for limit/stop, a trail in bps for trailing.
/// @param budget Unspent HBAR (tinybar) prepaid for checks and the fill.
/// @param typeState The type's opaque per-order state (e.g. a trailing peak); zero for stateless types.
struct Order {
    uint32 marketId;
    Side side;
    uint8 orderType;
    Status status;
    bool funded;
    uint16 slippageBps;
    uint40 createdAt;
    uint40 expiry;
    uint128 amountIn;
    uint128 typeParam;
    uint128 budget;
    bytes32 typeState;
}

/// @notice The arguments of `placeOrder`.
/// @param marketId A listed, active market.
/// @param side Sell the base, or buy it. The input token is the base for `SellBase` and the quote for `BuyBase`.
/// @param orderType A registered, active order-type id. The deploy script registers limit as 0, stop as 1 and
///        trailing stop as 2.
/// @param amountIn Amount to escrow, in the input token's raw units (tinybar for HBAR). Greater than 0.
/// @param typeParam For limit and stop orders, the trigger price (quote per 1 base, 8 decimals), greater than 0.
///        For a trailing stop (sell-side only), the trail in bps, 50 to 5,000.
/// @param slippageBps Slippage tolerance, in bps: above the market's `poolFee / 100` and at most its
///        `guard.maxSlippageBps`.
/// @param expiry Expiry time (unix seconds): after the current block and at most 90 days ahead.
struct PlaceParams {
    uint32 marketId;
    Side side;
    uint8 orderType;
    uint128 amountIn;
    uint128 typeParam;
    uint16 slippageBps;
    uint40 expiry;
}

/// @notice A market's guard reading, from `guardReading(marketId)`.
/// @param state The verdict; only `Open` lets an order fill.
/// @param oraclePrice Chainlink cross price, quote per 1 base with 8 decimals; 0 when the state is `OracleInvalid`.
/// @param poolPrice Pool TWAP price in the same units; 0 unless the TWAP was read.
/// @param deviationBps Gap between `poolPrice` and `oraclePrice`, in bps of `oraclePrice`; 0 unless computed.
/// @param oracleUpdatedAt The older of the two feeds' update times (unix seconds); 0 when the state is `OracleInvalid`.
struct GuardReading {
    GuardState state;
    uint256 oraclePrice;
    uint256 poolPrice;
    uint256 deviationBps;
    uint256 oracleUpdatedAt;
}
