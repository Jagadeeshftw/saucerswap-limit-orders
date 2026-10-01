// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultLegacy, PlaceParams as LegacyParams } from "./legacy/OrderVaultLegacy.sol";
import { ISaucerSwapV2Router } from "../contracts/interfaces/ISaucerSwapV2.sol";
import { MockHss, MockNftCollection } from "./mocks/MockHederaSystem.sol";
import { PlaceParams, Side, Status, Trigger } from "../contracts/types/OrderTypes.sol";
import { MarketConfig } from "../script/MarketConfig.sol";

/// @notice Drives the pre-refactor v1.0.1 vault (OrderVaultLegacy) and the refactored vault through the same
///         actions, one vault per transaction. Call k applies an action to the refactored vault and records it;
///         call k+1 replays it on the legacy vault. Each vault therefore starts every action from cold storage,
///         as a real scheduled sweep does: the two share the feeds, pools, router, tokens and system contracts,
///         so running both in one transaction would hand the second one warm accounts and cheaper gas.
/// @dev    Two properties are checked separately:
///         - Logic: every scheduled sweep runs with `SWEEP_HEADROOM` extra gas, so no gas-bounded branch (stop
///           checking, defer a fill to the next sweep) can fire, and every outcome must then match exactly.
///           Those branches depend on how much gas an implementation spends, not on its logic: at the exact
///           limit, a sweep that finds more orders than it was sized for can defer its last fill in one vault
///           and not the other. They are covered by the refactored vault's own unit and invariant tests.
///         - Gas: the refactored vault may spend at most `SWEEP_OVERHEAD` more per sweep and `FILL_OVERHEAD`
///           more per fill than v1.0.1 on the same sweep, which is what `MarketConfig.costs()` must cover. Each
///           check costs ~3.1k more (the strategy staticcall) but the batch charge no longer re-reads storage on
///           every recount, so from three orders up a sweep is cheaper than v1.0.1; a fill adds up to ~20k (the
///           Settlement delegatecalls and the strategy's `minOut`).
contract DifferentialHandler is OrderVaultBase {
    enum Kind {
        None,
        Place,
        Cancel,
        TopUp,
        Sweep
    }

    /// @dev An action applied to the refactored vault, waiting to be replayed on the legacy one.
    struct Pending {
        Kind kind;
        uint256 r;
        uint256 id; // the order acted on; for a placement, the id the refactored vault returned
        bool ok; // whether the refactored vault accepted it
        uint256 gasUsed; // a sweep's gas on the refactored vault
        uint256 orders; // open orders the sweep found
        uint256 fills; // orders it filled
    }

    uint256 internal constant SWEEP_HEADROOM = 10_000_000;
    uint256 internal constant SWEEP_OVERHEAD = 4_000;
    uint256 internal constant FILL_OVERHEAD = 25_000;

    OrderVaultLegacy public legacy;
    MockNftCollection internal legacyNft;
    uint256[] public ids; // order ids placed (serials are in lockstep across both vaults)
    Pending public pending;
    /// @notice Actions applied to both vaults in this run (price moves and time passing count once).
    uint256 public actions;

    constructor() {
        setUp();
        vm.startPrank(owner);
        legacy = new OrderVaultLegacy(owner, ISaucerSwapV2Router(address(router)), address(whbar), MarketConfig.costs());
        legacy.initialize{ value: 20 ether }("SaucerSwap Limit Order", "SSLO");
        legacy.listMarket(_hbarMarket());
        legacy.listMarket(_daiMarket());
        vm.stopPrank();
        legacyNft = MockNftCollection(legacy.collection());
        for (uint256 i; i < 3; ++i) {
            address user = [alice, bob, keeper][i];
            legacyNft.setAssociated(user, true);
            vm.startPrank(user);
            usdc.approve(address(legacy), type(uint256).max);
            dai.approve(address(legacy), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @notice The only fuzzed entry point. Replays a pending action on the legacy vault, or starts a new one.
    function step(uint256 r) external {
        if (pending.kind != Kind.None) return _replay();
        ++actions;
        uint256 action = r % 7;
        if (action <= 1) {
            _place(r);
        } else if (action == 2 && ids.length > 0) {
            _cancel(r);
        } else if (action == 3 && ids.length > 0) {
            _topUp(r);
        } else if (action == 4) {
            uint256 filledBefore = _filled();
            (uint256 gasUsed, uint256 orders) = _runLast(address(vault), 1 + ((r >> 8) % 2));
            pending = Pending(Kind.Sweep, r, 0, true, gasUsed, orders, _filled() - filledBefore);
        } else if (action == 5) {
            vm.warp(block.timestamp + 60 + ((r >> 8) % 3600)); // shared clock: applies to both at once
        } else {
            _move(r >> 8); // shared feeds and pools: applies to both at once
        }
    }

    /// @notice Finish a run whose last action is still waiting for its legacy half.
    function flush() external {
        if (pending.kind != Kind.None) _replay();
    }

    function orderCount() external view returns (uint256) {
        return ids.length;
    }

    // --- the refactored vault's half ---

    function _place(uint256 r) internal {
        (address maker, uint256 value, PlaceParams memory p,) = _placeArgs(r, true);
        vm.prank(maker);
        try vault.placeOrder{ value: value }(p) returns (uint256 id) {
            pending = Pending(Kind.Place, r, id, true, 0, 0, 0);
        } catch {
            pending = Pending(Kind.Place, r, 0, false, 0, 0, 0);
        }
    }

    function _cancel(uint256 r) internal {
        uint256 id = ids[(r >> 8) % ids.length];
        address holder = _holder(id, true);
        if (holder == address(0)) return;
        vm.prank(holder);
        try vault.cancel(id) {
            pending = Pending(Kind.Cancel, r, id, true, 0, 0, 0);
        } catch {
            pending = Pending(Kind.Cancel, r, id, false, 0, 0, 0);
        }
    }

    function _topUp(uint256 r) internal {
        uint256 id = ids[(r >> 8) % ids.length];
        if (uint8(vault.getOrder(id).status) != uint8(Status.Open)) return;
        uint256 amount = 1e8 + ((r >> 16) % 5e8);
        vm.deal(address(this), amount);
        try vault.topUp{ value: amount }(id) {
            pending = Pending(Kind.TopUp, r, id, true, 0, 0, 0);
        } catch {
            pending = Pending(Kind.TopUp, r, id, false, 0, 0, 0);
        }
    }

    // --- the legacy vault's half: the same action, which must have the same outcome ---

    function _replay() internal {
        Pending memory p = pending;
        delete pending;
        if (p.kind == Kind.Place) {
            (address maker, uint256 value,, LegacyParams memory lp) = _placeArgs(p.r, false);
            vm.prank(maker);
            try legacy.placeOrder{ value: value }(lp) returns (uint256 id) {
                assertTrue(p.ok, "refactored rejected a placement the legacy accepted");
                assertEq(id, p.id, "order ids diverged");
                ids.push(id);
            } catch {
                assertFalse(p.ok, "legacy rejected a placement the refactored accepted");
            }
        } else if (p.kind == Kind.Cancel) {
            address holder = _holder(p.id, false);
            assertTrue(holder != address(0), "order open on the refactored vault only");
            vm.prank(holder);
            try legacy.cancel(p.id) {
                assertTrue(p.ok, "refactored rejected a cancel the legacy accepted");
            } catch {
                assertFalse(p.ok, "legacy rejected a cancel the refactored accepted");
            }
        } else if (p.kind == Kind.TopUp) {
            uint256 amount = 1e8 + ((p.r >> 16) % 5e8);
            vm.deal(address(this), amount);
            try legacy.topUp{ value: amount }(p.id) {
                assertTrue(p.ok, "refactored rejected a top-up the legacy accepted");
            } catch {
                assertFalse(p.ok, "legacy rejected a top-up the refactored accepted");
            }
        } else {
            (uint256 gasUsed, uint256 orders) = _runLast(address(legacy), 1 + ((p.r >> 8) % 2));
            assertEq(orders, p.orders, "sweeps found different order counts");
            assertLe(p.gasUsed, gasUsed + SWEEP_OVERHEAD + p.fills * FILL_OVERHEAD, "sweep gas overhead");
        }
    }

    // --- helpers ---

    /// @dev One random placement, expressed for both APIs. It reads the target vault's own views, which agree
    ///      whenever the two vaults' states do.
    function _placeArgs(uint256 r, bool refactored)
        internal
        view
        returns (address maker, uint256 value, PlaceParams memory p, LegacyParams memory lp)
    {
        bool dai_ = (r >> 3) & 1 == 0;
        bool buy = (r >> 4) & 1 == 0;
        bool above = (r >> 5) & 1 == 0;
        uint8 market = dai_ ? 2 : 1;
        Side side = buy ? Side.BuyBase : Side.SellBase;
        uint256 oracle = refactored ? vault.guardReading(market).oraclePrice : legacy.guardReading(market).oraclePrice;
        if (oracle == 0) oracle = 10_000_000; // the feed is stale/invalid right now; use a fixed trigger for both
        uint128 trig = uint128(oracle / 2 + ((r >> 8) % oracle));
        uint128 amount = buy
            ? uint128(1e6 + ((r >> 72) % 50e6))
            : uint128(dai_ ? 1e8 + ((r >> 72) % 500e8) : 1e8 + ((r >> 72) % 2_000e8));
        maker = [alice, bob, keeper][(r >> 136) % 3];
        uint256 budget = refactored ? lens.minBudget(market, side) : legacy.minBudget(market, side);
        value = !dai_ && side == Side.SellBase ? amount + budget : budget;
        uint40 expiry = uint40(block.timestamp + 1 hours + ((r >> 144) % 30 days));
        uint16 slippage = buy ? 100 : (dai_ ? 30 : 100);
        uint8 orderType = (side == Side.SellBase) == above ? LIMIT : STOP; // limit vs stop
        p = PlaceParams(market, side, orderType, amount, trig, slippage, expiry);
        lp = LegacyParams(market, side, above ? Trigger.AtOrAbove : Trigger.AtOrBelow, amount, trig, slippage, expiry);
    }

    function _move(uint256 r) internal {
        if (r & 1 == 0) _setHbarPrice(int256(9_000_000 + ((r >> 1) % 4_000_000)));
        else _setDaiPrice(int256(90_000_000 + ((r >> 1) % 20_000_000)));
    }

    /// @dev The holder of an open order on one of the vaults, or zero if it is not open there.
    function _holder(uint256 id, bool refactored) internal view returns (address) {
        uint8 st = refactored ? uint8(vault.getOrder(id).status) : uint8(legacy.getOrder(id).status);
        if (st != uint8(Status.Open)) return address(0);
        return refactored ? vault.holderOf(id) : legacy.holderOf(id);
    }

    /// @dev Filled orders so far on the refactored vault.
    function _filled() internal view returns (uint256 n) {
        for (uint256 i; i < ids.length; ++i) {
            if (uint8(vault.getOrder(ids[i]).status) == uint8(Status.Filled)) n++;
        }
    }

    /// @dev Runs the vault's latest pending sweep for `market` the way HSS does (its expiry, sender, calldata), with
    ///      `SWEEP_HEADROOM` on top of its gas limit. Returns the gas it used and the open orders it found.
    function _runLast(address v, uint256 market) internal returns (uint256 gasUsed, uint256 orders) {
        bytes memory want = abi.encodeWithSelector(OrderVault.sweep.selector, market, uint32(0));
        uint256 c = hss.count();
        for (uint256 i = c; i > 0; --i) {
            MockHss.Scheduled memory j = hss.job(i - 1);
            if (j.to != v) continue;
            // match the market in the callData (first arg), ignoring the epoch
            if (j.callData.length >= 36 && bytes4(j.callData) == bytes4(want) && _firstArg(j.callData) == market) {
                if (j.expiry > block.timestamp) vm.warp(j.expiry);
                orders = v == address(vault) ? vault.openOrders(market).length : legacy.openOrders(market).length;
                vm.prank(v);
                uint256 start = gasleft();
                (bool ok,) = v.call{ gas: j.gasLimit + SWEEP_HEADROOM }(j.callData);
                gasUsed = start - gasleft();
                ok; // a failed scheduled sweep is itself part of the behaviour and must match; the state asserts catch divergence
                return (gasUsed, orders);
            }
        }
    }

    function _firstArg(bytes memory data) internal pure returns (uint256 a) {
        assembly {
            a := mload(add(data, 36))
        }
    }

    // --- the comparison the invariant runs whenever no action is half-applied ---

    function assertSame() external view {
        if (pending.kind != Kind.None) return;
        assertEq(vault.escrowed(address(usdc)), legacy.escrowed(address(usdc)), "usdc escrow");
        assertEq(vault.escrowed(address(dai)), legacy.escrowed(address(dai)), "dai escrow");
        assertEq(vault.escrowed(address(0)), legacy.escrowed(address(0)), "hbar escrow");
        assertEq(vault.totalBudgets(), legacy.totalBudgets(), "total budgets");
        assertEq(address(vault).balance, address(legacy).balance, "vault HBAR balance");
        assertEq(usdc.balanceOf(address(vault)), usdc.balanceOf(address(legacy)), "vault USDC balance");
        assertEq(dai.balanceOf(address(vault)), dai.balanceOf(address(legacy)), "vault DAI balance");
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            assertEq(uint8(vault.getOrder(id).status), uint8(legacy.getOrder(id).status), "status");
            assertEq(vault.getOrder(id).budget, legacy.getOrder(id).budget, "budget");
            assertEq(vault.getOrder(id).amountIn, legacy.getOrder(id).amountIn, "amountIn");
            assertEq(vault.getOrder(id).funded, legacy.getOrder(id).funded, "funded");
        }
    }

    receive() external payable { }
}

/// @notice Differential campaign: the v1.0.1 vault and the refactored vault run the SAME fuzzed sequences of limit
///         and stop-loss placements, cancels, top-ups, scheduled sweeps, price moves and the passage of time, each
///         vault in its own transaction. After every completed action their balances, escrow, budgets and every
///         order's state must match exactly. This proves the plug-in + Settlement refactor did not change
///         limit/stop behaviour, and bounds the gas it adds per sweep and per fill. (Trailing stop is new, so it is
///         out of scope here.) 256 runs x 100 calls per campaign, each run from a fresh fixture and its own random
///         sequence: about 16,000 paired actions, 4,900 orders and 1,200 fills.
contract OrderVaultDifferentialTest is StdInvariant, Test {
    DifferentialHandler internal handler;

    function setUp() public {
        handler = new DifferentialHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = DifferentialHandler.step.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// forge-config: default.gas_limit = 9223372036854775807
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_limitAndStopMatchV101() public view {
        handler.assertSame();
    }

    function afterInvariant() public {
        handler.flush();
        handler.assertSame();
    }
}
