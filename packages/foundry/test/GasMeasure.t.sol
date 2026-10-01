// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { OrderVaultLegacy, PlaceParams as LegacyParams } from "./legacy/OrderVaultLegacy.sol";
import { ISaucerSwapV2Router } from "../contracts/interfaces/ISaucerSwapV2.sol";
import { MockHss, MockNftCollection } from "./mocks/MockHederaSystem.sol";
import { PlaceParams, Side, Trigger } from "../contracts/types/OrderTypes.sol";
import { MarketConfig } from "../script/MarketConfig.sol";

/// @notice The before/after gas report: the gas one scheduled sweep uses on the v1.0.1 vault and on this vault,
///         scenario by scenario, plus the trailing stop's own checks. Run it with `--isolate`, so every placement
///         and every sweep is its own transaction and pays cold-access gas as a scheduled sweep does on Hedera:
///
///             forge test --match-contract GasMeasure --isolate -vv
///
///         The mocks stand in for HTS, HSS and SaucerSwap, so absolute figures are lower than on testnet (see
///         `MarketConfig.costs()` for those); the difference between the two vaults is EVM work and carries over.
contract GasMeasureTest is OrderVaultBase {
    uint128 internal constant FAR = 12_500_000; // ~12% above HBAR spot: checked, not filled
    uint40 internal constant WEEK = 7 days;

    OrderVaultLegacy internal legacy;

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        legacy = new OrderVaultLegacy(owner, ISaucerSwapV2Router(address(router)), address(whbar), MarketConfig.costs());
        legacy.initialize{ value: 20 ether }("SaucerSwap Limit Order", "SSLO");
        legacy.listMarket(_hbarMarket());
        legacy.listMarket(_daiMarket());
        vm.stopPrank();
        MockNftCollection legacyNft = MockNftCollection(legacy.collection());
        for (uint256 i; i < 3; ++i) {
            address user = [alice, bob, keeper][i];
            legacyNft.setAssociated(user, true);
            vm.startPrank(user);
            usdc.approve(address(legacy), type(uint256).max);
            dai.approve(address(legacy), type(uint256).max);
            vm.stopPrank();
        }
    }

    // --- scenarios: each places on one vault, then runs that vault's scheduled sweep ---

    // Each scenario runs on v1.0.1, the state is rolled back, then it runs on this vault: both start from the
    // same storage, so neither inherits the other's nonzero balances in the shared mock tokens and router.

    function test_gas_check1() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _checks(false, 1);
        vm.revertToState(snap);
        _report("check, 1 order", before, _checks(true, 1));
    }

    function test_gas_check5() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _checks(false, 5);
        vm.revertToState(snap);
        _report("check, 5 orders", before, _checks(true, 5));
    }

    function test_gas_check20() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _checks(false, 20);
        vm.revertToState(snap);
        _report("check, 20 orders", before, _checks(true, 20));
    }

    function test_gas_daiFill() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _fill(false, 2);
        vm.revertToState(snap);
        _report("DAI fill (token in)", before, _fill(true, 2));
    }

    function test_gas_hbarFill() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _fill(false, 1);
        vm.revertToState(snap);
        _report("HBAR fill (HBAR in)", before, _fill(true, 1));
    }

    function test_gas_fillAndReschedule() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _fillAndReschedule(false);
        vm.revertToState(snap);
        _report("DAI fill + reschedule", before, _fillAndReschedule(true));
    }

    function test_gas_expire() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _expire(false);
        vm.revertToState(snap);
        _report("expiry", before, _expire(true));
    }

    /// @notice The last order leaves while a sweep is pending, so that sweep fires with nothing to check: the run
    ///         `idleSweepGas` prices (the leaving order pays it).
    function test_gas_emptyRun() public {
        uint256 snap = vm.snapshotState();
        uint256 before = _emptyRun(false);
        vm.revertToState(snap);
        _report("empty run (last order left)", before, _emptyRun(true));
    }

    function _emptyRun(bool refactored) internal returns (uint256) {
        _place(refactored, alice, 2, Side.SellBase, Trigger.AtOrBelow, 50_000_000, 1_000e8, WEEK);
        uint256 id = refactored ? vault.openOrders(2)[0] : legacy.openOrders(2)[0];
        vm.prank(alice);
        if (refactored) vault.cancel(id);
        else legacy.cancel(id);
        return _run(_vault(refactored));
    }

    /// @notice A trailing stop's first check stores its peak (a zero-to-nonzero write); later checks only write
    ///         when the peak rises.
    function test_gas_trailing() public {
        _placeNew(alice, 2, Side.SellBase, TRAILING, 200, 1_000e8, WEEK);
        emit log_named_uint("trailing, first check (stores the peak)", _run(address(vault)));
        _setDaiPrice(101_000_000);
        emit log_named_uint("trailing, check that raises the peak", _run(address(vault)));
        emit log_named_uint("trailing, check with no new peak", _run(address(vault)));
    }

    // --- helpers ---

    function _checks(bool refactored, uint256 n) internal returns (uint256) {
        for (uint256 i; i < n; ++i) {
            _place(refactored, [alice, bob, keeper][i % 3], 1, Side.SellBase, Trigger.AtOrAbove, FAR, 250e8, WEEK);
        }
        return _run(_vault(refactored));
    }

    /// @dev One order whose trigger is met at once: on the DAI market a stop-loss, on HBAR a limit sell.
    function _fill(bool refactored, uint256 market) internal returns (uint256) {
        if (market == 2) _place(refactored, alice, 2, Side.SellBase, Trigger.AtOrBelow, 99_990_000, 1_000e8, WEEK);
        else _place(refactored, alice, 1, Side.SellBase, Trigger.AtOrAbove, 11_000_000, 250e8, WEEK);
        return _run(_vault(refactored));
    }

    function _fillAndReschedule(bool refactored) internal returns (uint256) {
        _place(refactored, bob, 2, Side.SellBase, Trigger.AtOrBelow, 50_000_000, 1_000e8, WEEK); // stays open
        _place(refactored, alice, 2, Side.SellBase, Trigger.AtOrBelow, 99_990_000, 1_000e8, WEEK); // fills
        return _run(_vault(refactored));
    }

    function _expire(bool refactored) internal returns (uint256) {
        _place(refactored, alice, 2, Side.SellBase, Trigger.AtOrBelow, 50_000_000, 1_000e8, 1 hours);
        return _run(_vault(refactored));
    }

    function _place(
        bool refactored,
        address maker,
        uint256 market,
        Side side,
        Trigger kind,
        uint128 trigger,
        uint128 amount,
        uint40 life
    ) internal {
        if (refactored) {
            return _placeNew(maker, market, side, _typeFor(side, kind), trigger, amount, life);
        }
        uint256 budget = legacy.minBudget(market, side);
        uint256 value = market == 1 && side == Side.SellBase ? amount + budget : budget;
        uint40 expiry = uint40(block.timestamp + life);
        vm.prank(maker);
        legacy.placeOrder{ value: value }(
            LegacyParams(uint32(market), side, kind, amount, trigger, market == 2 ? 30 : 50, expiry)
        );
    }

    function _placeNew(
        address maker,
        uint256 market,
        Side side,
        uint8 orderType,
        uint128 param,
        uint128 amount,
        uint40 life
    ) internal {
        uint256 budget = lens.minBudget(market, side);
        uint256 value = market == 1 && side == Side.SellBase ? amount + budget : budget;
        uint40 expiry = uint40(block.timestamp + life);
        vm.prank(maker);
        vault.placeOrder{ value: value }(
            PlaceParams(uint32(market), side, orderType, amount, param, market == 2 ? 30 : 50, expiry)
        );
    }

    function _vault(bool refactored) internal view returns (address) {
        return refactored ? address(vault) : address(legacy);
    }

    /// @dev Runs `v`'s latest schedule the way HSS does and returns the gas it used.
    function _run(address v) internal returns (uint256 used) {
        MockHss.Scheduled memory job;
        for (uint256 i = hss.count(); i > 0; --i) {
            job = hss.job(i - 1);
            if (job.to == v) break;
        }
        if (job.expiry > block.timestamp) vm.warp(job.expiry);
        vm.prank(v);
        uint256 start = gasleft();
        (bool ok,) = v.call{ gas: job.gasLimit }(job.callData);
        used = start - gasleft();
        require(ok, "sweep reverted");
    }

    function _report(string memory scenario, uint256 before, uint256 after_) internal {
        emit log_named_uint(string.concat(scenario, " | v1.0.1"), before);
        emit log_named_uint(string.concat(scenario, " | v1.1"), after_);
        emit log_named_int(string.concat(scenario, " | delta"), int256(after_) - int256(before));
    }
}
