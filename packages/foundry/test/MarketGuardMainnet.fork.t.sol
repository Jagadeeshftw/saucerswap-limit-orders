// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console2 } from "forge-std/Test.sol";
import { MarketGuard } from "../contracts/libraries/MarketGuard.sol";
import { GuardParams, GuardReading, GuardState, Market } from "../contracts/types/OrderTypes.sol";
import { IAggregatorV3 } from "../contracts/interfaces/IAggregatorV3.sol";
import { ISaucerSwapV2Pool } from "../contracts/interfaces/ISaucerSwapV2.sol";

contract MainnetGuardHarness {
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
}

/// @notice The counterpart to `MarketGuard.fork.t.sol`: on testnet the only HBAR/USDC pool trades ~19x from
///         Chainlink, so the guard correctly HOLDS; on a mainnet fork the pool is arbitraged, so the guard
///         OPENS. Reading the real mainnet pool + Chainlink feeds shows the fill path works where liquidity is
///         real, which testnet cannot.
/// @dev Opt-in: set `MAINNET_FORK=true` (which `yarn foundry:fork-guard` does). Without it the test skips with a
///      message, so the default suite and the testnet `foundry:test:fork` run are unaffected. No HTS is needed:
///      this reads Chainlink and the pool's TWAP only — it does not swap.
contract MarketGuardMainnetForkTest is Test {
    // SaucerSwap V2 WHBAR/USDC(native) pool, fee tier 0.15% (the deepest HBAR/USDC pool on mainnet).
    address internal constant POOL = 0xC5B707348dA504E9Be1bD4E21525459830e7B11d; // 0.0.3964804
    address internal constant WHBAR = 0x0000000000000000000000000000000000163B5a; // 0.0.1456986, 8 dp
    address internal constant USDC = 0x000000000000000000000000000000000006f89a; // 0.0.456858 (native), 6 dp
    address internal constant FEED_HBAR_USD = 0xAF685FB45C12b92b5054ccb9313e135525F9b5d5; // 8 dp
    address internal constant FEED_USDC_USD = 0x2b358642c7C37b6e400911e4FE41770424a7349F; // 8 dp

    modifier onlyMainnetFork() {
        if (!vm.envOr("MAINNET_FORK", false)) {
            emit log("skipped: set MAINNET_FORK=true (needs a Hedera mainnet RPC) to run the mainnet guard fork test");
            vm.skip(true);
            return;
        }
        if (!_forkMainnet()) {
            emit log("skipped: could not reach the Hedera mainnet RPC (hedera_mainnet)");
            vm.skip(true);
            return;
        }
        _;
    }

    function _forkMainnet() internal returns (bool) {
        try vm.createSelectFork("hedera_mainnet") returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev A generous but meaningful guard: a well-arbitraged pool sits within ~1% of Chainlink, so a 3% band
    ///      opens reliably against live data; a real mainnet market would tune this to the feeds' heartbeat.
    function _mainnetHbarUsdc() internal pure returns (Market memory m) {
        m.base = WHBAR;
        m.quote = USDC;
        m.baseDecimals = 8;
        m.quoteDecimals = 6;
        m.baseIsHbar = true;
        m.baseFeed = IAggregatorV3(FEED_HBAR_USD);
        m.quoteFeed = IAggregatorV3(FEED_USDC_USD);
        m.pool = ISaucerSwapV2Pool(POOL);
        m.poolFee = 1500;
        m.guard = GuardParams({ twapWindow: 1800, maxDeviationBps: 300, maxOracleAge: 93_600, maxSlippageBps: 300 });
    }

    function test_fork_mainnetHbarUsdcGuardOpens() public onlyMainnetFork {
        MainnetGuardHarness h = new MainnetGuardHarness(_mainnetHbarUsdc());
        GuardReading memory r = h.read();
        console2.log("mainnet HBAR/USDC oracle", r.oraclePrice, "pool TWAP", r.poolPrice);
        console2.log("deviation bps", r.deviationBps);
        assertGt(r.oraclePrice, 0, "Chainlink HBAR/USD x USDC/USD returned a price");
        assertGt(r.poolPrice, 0, "the pool TWAP was read");
        assertEq(uint8(r.state), uint8(GuardState.Open), "the arbitraged mainnet HBAR/USDC pool passes the guard");
    }
}
