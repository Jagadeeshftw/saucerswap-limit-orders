// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Costs, GuardParams, Market, SweepParams } from "../contracts/types/OrderTypes.sol";
import { IAggregatorV3 } from "../contracts/interfaces/IAggregatorV3.sol";
import { ISaucerSwapV2Pool } from "../contracts/interfaces/ISaucerSwapV2.sol";

/// @title Hedera testnet addresses and measured costs for the shipped markets.
/// @notice Every figure here was read or measured on Hedera testnet on 2026-09-29; see "What an order costs" in the README.
library MarketConfig {
    uint256 internal constant HEDERA_TESTNET = 296;

    // SaucerSwap V2 (docs.saucerswap.finance/developers/contracts)
    address internal constant SWAP_ROUTER = 0x0000000000000000000000000000000000159398; // 0.0.1414040
    address internal constant WHBAR = 0x0000000000000000000000000000000000003aD2; // token 0.0.15058
    address internal constant USDC = 0x0000000000000000000000000000000000001549; // token 0.0.5449, 6 decimals
    address internal constant DAI = 0x0000000000000000000000000000000000001599; // token 0.0.5529, 8 decimals
    address internal constant POOL_HBAR_USDC = 0x914B98992d7eD602D1f5d9084ECe8160Fc0e741a; // 0.3%
    address internal constant POOL_USDC_DAI = 0xb431866114B634F611774ec0d094BF11cb91c7E4; // 0.05%

    // Chainlink data feeds on Hedera testnet (8 decimals, 24h heartbeat, 0.5% deviation)
    address internal constant FEED_HBAR_USD = 0x59bC155EB6c6C415fE43255aF66EcF0523c92B4a;
    address internal constant FEED_USDC_USD = 0xb632a7e7e02d76c0Ce99d9C62c7a2d1B5F92B6B5;
    address internal constant FEED_DAI_USD = 0xdA2aBF7C90aDC73CDF5cA8d720B87bD5F5863389;

    /// @notice Gas per unit of work, calibrated from scheduled sweeps of the reference vault on testnet:
    ///         a held check with reschedule used ~1,579k gas and a DAI fill without reschedule ~1,029k.
    ///         852 tinycents per gas is Hedera's USD gas price (~110 tinybar at the testnet rate).
    ///         scheduleGas is the network's fixed ~$0.12 ScheduleCreate fee: 1,410,346 gas measured in
    ///         isolation, the same for any gas limit, delay or calldata size.
    function costs() internal pure returns (Costs memory) {
        return Costs({
            scheduleGas: 1_425_000,
            sweepBaseGas: 95_000,
            checkGas: 60_000,
            fillGasHbarIn: 450_000,
            fillGasTokenIn: 750_000,
            settleGas: 125_000,
            idleSweepGas: 95_000,
            gasPriceTinycents: 852,
            safetyBps: 1_000
        });
    }

    /// @notice HBAR priced in USDC on the public 0.3% pool. On testnet this pool sits far from Chainlink,
    ///         so the guard holds fills; on an arbitraged network the same market fills normally.
    function hbarUsdc() internal pure returns (Market memory m) {
        m.base = WHBAR;
        m.quote = USDC;
        m.baseDecimals = 8;
        m.quoteDecimals = 6;
        m.baseIsHbar = true;
        m.baseFeed = IAggregatorV3(FEED_HBAR_USD);
        m.quoteFeed = IAggregatorV3(FEED_USDC_USD);
        m.pool = ISaucerSwapV2Pool(POOL_HBAR_USDC);
        m.poolFee = 3000;
        m.guard = GuardParams({ twapWindow: 1800, maxDeviationBps: 200, maxOracleAge: 90_000, maxSlippageBps: 300 });
        // HBAR can move a few percent in an hour; a limit 10% away is checked about every 4 h.
        m.sweep =
            SweepParams({ minInterval: 300, maxInterval: 6 hours, maxMoveBpsPerHour: 250, maxOrders: 20, maxFills: 3 });
    }

    /// @notice DAI priced in USDC on the 0.05% pool, which tracks Chainlink closely: the depeg stop-loss market.
    function usdcDai() internal pure returns (Market memory m) {
        m.base = DAI;
        m.quote = USDC;
        m.baseDecimals = 8;
        m.quoteDecimals = 6;
        m.baseFeed = IAggregatorV3(FEED_DAI_USD);
        m.quoteFeed = IAggregatorV3(FEED_USDC_USD);
        m.pool = ISaucerSwapV2Pool(POOL_USDC_DAI);
        m.poolFee = 500;
        m.guard = GuardParams({ twapWindow: 1800, maxDeviationBps: 100, maxOracleAge: 90_000, maxSlippageBps: 100 });
        // A stablecoin drifts slowly until it depegs; a stop 50 bps away is checked about every 2 h.
        m.sweep =
            SweepParams({ minInterval: 300, maxInterval: 6 hours, maxMoveBpsPerHour: 25, maxOrders: 20, maxFills: 3 });
    }
}
