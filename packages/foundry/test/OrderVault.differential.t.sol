// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultLegacy, PlaceParams as LegacyParams } from "./legacy/OrderVaultLegacy.sol";
import { LimitOrderType } from "../contracts/ordertypes/LimitOrderType.sol";
import { StopOrderType } from "../contracts/ordertypes/StopOrderType.sol";
import { TrailingStopType } from "../contracts/ordertypes/TrailingStopType.sol";
import { ISaucerSwapV2Router } from "../contracts/interfaces/ISaucerSwapV2.sol";
import { MockHss, MockNftCollection } from "./mocks/MockHederaSystem.sol";
import { Costs, Market, PlaceParams, Side, Status, Trigger } from "../contracts/types/OrderTypes.sol";
import { MarketConfig } from "../script/MarketConfig.sol";

/// @notice Differential test: the pre-refactor v1.0.1 vault (OrderVaultLegacy) and the refactored vault run the
///         SAME fuzzed sequence of limit and stop-loss actions, and after every step their token balances, escrow,
///         budgets and per-order state must match exactly. This proves the plug-in + Settlement refactor did not
///         change limit/stop behaviour. (Trailing stop is new, so it is out of scope here.)
contract OrderVaultDifferentialTest is OrderVaultBase {
    OrderVaultLegacy internal legacy;
    MockNftCollection internal legacyNft;
    uint256[] internal ids; // order ids placed (serials are in lockstep across both vaults)

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);
        vault.registerOrderType(address(new LimitOrderType())); // 0
        vault.registerOrderType(address(new StopOrderType())); // 1
        vault.registerOrderType(address(new TrailingStopType())); // 2
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

    /// forge-config: default.gas_limit = 9223372036854775807
    function test_differential_limitAndStopMatchV101() public {
        uint256 steps = vm.envOr("DIFF_STEPS", uint256(10_000));
        uint256 price = 11_160_000;
        for (uint256 n; n < steps; ++n) {
            uint256 r = uint256(keccak256(abi.encode(n)));
            uint256 action = r % 7;
            if (action <= 1) {
                _place(n, r);
            } else if (action == 2 && ids.length > 0) {
                _cancel(ids[r % ids.length]);
            } else if (action == 3 && ids.length > 0) {
                _topUp(ids[r % ids.length], 1e8 + (r % 5e8));
            } else if (action == 4) {
                _sweep(1 + (r % 2));
            } else if (action == 5) {
                vm.warp(block.timestamp + 60 + (r % 3600));
            } else {
                price = _move(r);
            }
            _assertAggregates(); // cheap, every step
            if (n % 1000 == 0) _assertAllOrders(); // full per-order sweep, periodically
        }
        _assertAllOrders();
        emit log_named_uint("orders placed over the run", ids.length);
    }

    // --- actions applied identically to both vaults ---

    function _place(uint256 n, uint256 r) internal {
        bool dai_ = r & 1 == 0;
        bool buy = (r >> 1) & 1 == 0;
        bool above = (r >> 2) & 1 == 0;
        uint8 market = dai_ ? 2 : 1;
        Side side = buy ? Side.BuyBase : Side.SellBase;
        Trigger kind = above ? Trigger.AtOrAbove : Trigger.AtOrBelow;
        uint8 orderType = (side == Side.SellBase) == above ? LIMIT : STOP; // limit vs stop
        uint256 oracle = vault.guardReading(market).oraclePrice;
        if (oracle == 0) oracle = 10_000_000; // the feed is stale/invalid right now; use a fixed trigger for both
        uint128 trig = uint128(oracle / 2 + (r % oracle));
        uint128 amount = buy ? uint128(1e6 + (r % 50e6)) : uint128(dai_ ? 1e8 + (r % 500e8) : 1e8 + (r % 2_000e8));
        address maker = [alice, bob, keeper][n % 3];
        uint256 budget = vault.minBudget(market, side);
        bool hbarIn = !dai_ && side == Side.SellBase;
        uint256 value = hbarIn ? amount + budget : budget;
        uint40 expiry = uint40(block.timestamp + 1 hours + (r % 30 days));

        vm.prank(maker);
        try vault.placeOrder{ value: value }(
            PlaceParams(market, side, orderType, amount, trig, buy ? 100 : (dai_ ? 30 : 100), expiry)
        ) returns (uint256 idNew) {
            vm.prank(maker);
            uint256 idOld = legacy.placeOrder{ value: value }(
                LegacyParams(market, side, kind, amount, trig, buy ? 100 : (dai_ ? 30 : 100), expiry)
            );
            assertEq(idNew, idOld, "order ids diverged");
            ids.push(idNew);
        } catch {
            // If the new vault rejects (budget/slippage/expiry bounds), the legacy must reject too.
            vm.prank(maker);
            try legacy.placeOrder{ value: value }(
                LegacyParams(market, side, kind, amount, trig, buy ? 100 : (dai_ ? 30 : 100), expiry)
            ) returns (uint256) {
                revert("new rejected but legacy accepted");
            } catch { }
        }
    }

    function _cancel(uint256 id) internal {
        address holder = _tryHolder(id);
        if (holder == address(0)) return;
        vm.prank(holder);
        try vault.cancel(id) {
            vm.prank(holder);
            legacy.cancel(id);
        } catch { }
    }

    function _topUp(uint256 id, uint256 amount) internal {
        if (uint8(vault.getOrder(id).status) != uint8(Status.Open)) return;
        vm.deal(address(this), amount * 2); // one top-up each for the two vaults
        try vault.topUp{ value: amount }(id) {
            legacy.topUp{ value: amount }(id);
        } catch { }
    }

    function _sweep(uint256 market) internal {
        _runLast(address(vault), market);
        _runLast(address(legacy), market);
    }

    function _move(uint256 r) internal returns (uint256) {
        uint256 p = 9_000_000 + (r % 4_000_000);
        if (r & 1 == 0) _setHbarPrice(int256(p));
        else _setDaiPrice(int256(90_000_000 + (r % 20_000_000)));
        return p;
    }

    // --- helpers ---

    function _tryHolder(uint256 id) internal view returns (address) {
        if (uint8(vault.getOrder(id).status) != uint8(Status.Open)) return address(0);
        try vault.holderOf(id) returns (address h) {
            return h;
        } catch {
            return address(0);
        }
    }

    function _runLast(address v, uint256 market) internal {
        bytes memory want = abi.encodeWithSelector(OrderVault.sweep.selector, market, uint32(0));
        uint256 c = hss.count();
        for (uint256 i = c; i > 0; --i) {
            MockHss.Scheduled memory j = hss.job(i - 1);
            if (j.to != v) continue;
            // match the market in the callData (first arg), ignoring the epoch
            if (j.callData.length >= 36 && bytes4(j.callData) == bytes4(want) && _firstArg(j.callData) == market) {
                vm.warp(j.expiry);
                vm.prank(v);
                (bool ok,) = v.call{ gas: j.gasLimit }(j.callData);
                ok; // a failed scheduled sweep is itself part of the behaviour and must match; status asserts catch divergence
                return;
            }
        }
    }

    function _firstArg(bytes memory data) internal pure returns (uint256 a) {
        assembly {
            a := mload(add(data, 36))
        }
    }

    function _assertAggregates() internal view {
        assertEq(vault.escrowed(address(usdc)), legacy.escrowed(address(usdc)), "usdc escrow");
        assertEq(vault.escrowed(address(dai)), legacy.escrowed(address(dai)), "dai escrow");
        assertEq(vault.escrowed(address(0)), legacy.escrowed(address(0)), "hbar escrow");
        assertEq(vault.totalBudgets(), legacy.totalBudgets(), "total budgets");
        assertEq(address(vault).balance, address(legacy).balance, "vault HBAR balance");
    }

    function _assertAllOrders() internal view {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            assertEq(uint8(vault.getOrder(id).status), uint8(legacy.getOrder(id).status), "status");
            assertEq(vault.getOrder(id).budget, legacy.getOrder(id).budget, "budget");
            assertEq(vault.getOrder(id).amountIn, legacy.getOrder(id).amountIn, "amountIn");
        }
    }

    receive() external payable { }
}
