// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { MarketGuard } from "../contracts/libraries/MarketGuard.sol";
import { GuardReading, GuardState, Market } from "../contracts/types/OrderTypes.sol";
import { MarketConfig } from "../script/MarketConfig.sol";

contract GuardHarness {
    Market internal market;

    constructor(Market memory m) {
        market = m;
        market.baseFeedDecimals = m.baseFeed.decimals();
        market.quoteFeedDecimals = m.quoteFeed.decimals();
        market.baseIsToken0 = m.pool.token0() == m.base;
    }

    function read() external view returns (GuardReading memory) {
        return MarketGuard.read(market);
    }

    function baseIsToken0() external view returns (bool) {
        return market.baseIsToken0;
    }
}

/// @notice Reads the real Hedera testnet pools and Chainlink feeds the template ships with.
/// @dev Opt in with `FORK_TESTS=true yarn foundry:test:fork`. Swaps are not forked: SaucerSwap moves HTS
///      tokens, and HTS system contracts do not exist in a local fork.
contract MarketGuardForkTest is Test {
    modifier onlyFork() {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
        }
        vm.createSelectFork("hedera_testnet");
        _;
    }

    function test_fork_hbarUsdcPoolIsHeldByGuard() public onlyFork {
        GuardHarness h = new GuardHarness(MarketConfig.hbarUsdc());
        GuardReading memory r = h.read();
        console2.log("HBAR/USDC oracle", r.oraclePrice, "pool TWAP", r.poolPrice);
        console2.log("deviation bps", r.deviationBps);
        assertFalse(h.baseIsToken0(), "USDC (0.0.5449) sorts before WHBAR (0.0.15058)");
        assertGt(r.oraclePrice, 0);
        assertEq(uint8(r.state), uint8(GuardState.DeviationTooHigh), "testnet pool is not arbitraged");
    }

    function test_fork_daiUsdcPoolPassesGuard() public onlyFork {
        GuardHarness h = new GuardHarness(MarketConfig.usdcDai());
        GuardReading memory r = h.read();
        console2.log("DAI/USDC oracle", r.oraclePrice, "pool TWAP", r.poolPrice);
        console2.log("deviation bps", r.deviationBps);
        assertEq(uint8(r.state), uint8(GuardState.Open));
        assertApproxEqRel(r.poolPrice, 1e8, 0.02e18, "DAI trades near 1 USDC");
    }

    function test_fork_configuredContractsExist() public onlyFork {
        address[7] memory contracts = [
            MarketConfig.SWAP_ROUTER,
            MarketConfig.POOL_HBAR_USDC,
            MarketConfig.POOL_USDC_DAI,
            MarketConfig.FEED_HBAR_USD,
            MarketConfig.FEED_USDC_USD,
            MarketConfig.FEED_DAI_USD,
            MarketConfig.USDC
        ];
        for (uint256 i; i < contracts.length; ++i) {
            assertGt(contracts[i].code.length, 0);
        }
    }
}
