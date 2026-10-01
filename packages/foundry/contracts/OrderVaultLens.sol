// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVault } from "./OrderVault.sol";
import { IOrderType } from "./interfaces/IOrderType.sol";
import { IExchangeRate } from "./interfaces/IExchangeRate.sol";
import { SweepMath } from "./libraries/SweepMath.sol";
import { Costs, GuardReading, Market, Order, Side, Status, SweepParams, SweepStatus } from "./types/OrderTypes.sol";

/// @title OrderVaultLens
/// @notice Read-only previews of what an `OrderVault` will charge and when it will check, for the frontend and
///         the Debug page. It holds no state and no funds; every figure is computed from the vault's raw state
///         with `SweepMath`, the same code the vault charges and schedules by, so a preview and the vault's own
///         number cannot drift apart. Kept out of the vault so the vault stays well under the 24 KB limit.
contract OrderVaultLens {
    address internal constant EXCHANGE_RATE = address(0x168);
    address internal constant HBAR = address(0);
    /// @dev The vault's gas stipend for a strategy's `evaluate`, applied here too so a preview fails where a
    ///      sweep would.
    uint256 internal constant EVAL_GAS = 100_000;

    /// @notice The vault this lens reads.
    OrderVault public immutable VAULT;

    /// @notice The exchange-rate system contract did not answer; the same error the vault raises for it.
    error InvalidCosts();

    /// @param vault_ The `OrderVault` to read.
    constructor(OrderVault vault_) {
        VAULT = vault_;
    }

    // ---------------------------------------------------------------------------------------
    // Costs
    // ---------------------------------------------------------------------------------------

    /// @notice HBAR (tinybar) charged to an order per scheduled check if it were the only funded order.
    /// @param marketId A listed market.
    /// @return Tinybar per check.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function checkCost(uint256 marketId) external view returns (uint256) {
        VAULT.getMarket(marketId); // reverts UnknownMarket
        return SweepMath.sweepShare(_costs(), 1, _rate());
    }

    /// @notice HBAR (tinybar) charged per check when `fundedOrders` orders share the sweep.
    /// @param fundedOrders Orders sharing the sweep's fixed cost; 0 is treated as 1.
    /// @return Tinybar per check.
    function checkCostShared(uint256 fundedOrders) external view returns (uint256) {
        return SweepMath.sweepShare(_costs(), fundedOrders == 0 ? 1 : fundedOrders, _rate());
    }

    /// @notice HBAR (tinybar) an order always keeps back: its fill, plus its part of a final sweep.
    /// @param marketId A listed market.
    /// @param side The order's side, which decides whether its input is HBAR.
    /// @return The reserve, in tinybar.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function fillCost(uint256 marketId, Side side) external view returns (uint256) {
        return SweepMath.reserve(_costs(), _hbarIn(VAULT.getMarket(marketId), side), _rate());
    }

    /// @notice Smallest budget `placeOrder` accepts: the reserve plus `MIN_CHECKS_FUNDED` solo checks.
    /// @param marketId A listed market.
    /// @param side The order's side, which decides whether its input is HBAR.
    /// @return The minimum budget, in tinybar.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function minBudget(uint256 marketId, Side side) external view returns (uint256) {
        return SweepMath.minBudget(_costs(), _hbarIn(VAULT.getMarket(marketId), side), _rate());
    }

    /// @notice Gas limit the vault gives a market's next scheduled sweep, at today's open orders.
    /// @param marketId A listed market.
    /// @return The gas limit.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function sweepGasLimit(uint256 marketId) public view returns (uint256) {
        Market memory m = VAULT.getMarket(marketId);
        return SweepMath.sweepGasLimit(_costs(), m.sweep, VAULT.openOrders(marketId).length);
    }

    /// @notice HBAR the vault keeps liquid so a scheduled sweep can always pay its gas: the costliest funded
    ///         market's sweep at the configured price.
    /// @return float The float, in tinybar.
    function payerFloat() public view returns (uint256 float) {
        Costs memory c = _costs();
        uint256 rate = _rate();
        uint256 n = VAULT.marketCount();
        for (uint256 id = 1; id <= n; ++id) {
            (,,, uint32 fundedOrders,,) = VAULT.sweeps(id);
            if (fundedOrders == 0) continue;
            uint256 need = SweepMath.gasToTinybar(c, sweepGasLimit(id), rate);
            if (need > float) float = need;
        }
    }

    /// @notice HBAR `withdrawSurplus` would pay out now: the balance beyond escrow, budgets, credits and the float.
    /// @return The surplus, in tinybar.
    function surplus() external view returns (uint256) {
        uint256 owed = VAULT.escrowed(HBAR) + VAULT.totalBudgets() + VAULT.totalCredits(HBAR) + payerFloat();
        uint256 balance = address(VAULT).balance;
        return balance > owed ? balance - owed : 0;
    }

    /// @notice What a scheduled sweep of `marketId` would charge if it ran now: `share` per paying order, and
    ///         `parkFee` for an order whose budget can no longer cover a check (it is parked instead).
    /// @param marketId A listed market.
    /// @return share Tinybar charged to each order that can pay.
    /// @return parkFee Tinybar charged to each order that is parked.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function previewCharges(uint256 marketId) external view returns (uint256 share, uint256 parkFee) {
        Market memory m = VAULT.getMarket(marketId);
        uint256[] memory batch = nextBatch(marketId);
        Costs memory c = _costs();
        uint256 rate = _rate();
        SweepMath.ChargeInput[] memory orders = new SweepMath.ChargeInput[](batch.length);
        for (uint256 i; i < batch.length; ++i) {
            Order memory o = VAULT.getOrder(batch[i]);
            if (o.status == Status.Open && o.funded && block.timestamp < o.expiry) {
                orders[i] = SweepMath.ChargeInput(true, o.budget, SweepMath.reserve(c, _hbarIn(m, o.side), rate));
            }
        }
        return SweepMath.batchCharges(c, rate, orders);
    }

    // ---------------------------------------------------------------------------------------
    // Scheduling
    // ---------------------------------------------------------------------------------------

    /// @notice The orders the next sweep of `marketId` will visit, in order: up to `maxOrders`, starting at the
    ///         market's rotating cursor.
    /// @param marketId A listed market.
    /// @return batch The order ids, in visiting order.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function nextBatch(uint256 marketId) public view returns (uint256[] memory batch) {
        Market memory m = VAULT.getMarket(marketId);
        uint256[] memory list = VAULT.openOrders(marketId);
        (,, uint32 cursor,,,) = VAULT.sweeps(marketId);
        uint256 n = list.length;
        uint256 size = n < m.sweep.maxOrders ? n : m.sweep.maxOrders;
        batch = new uint256[](size);
        uint256 start = n == 0 ? 0 : cursor % n;
        for (uint256 i; i < size; ++i) {
            batch[i] = list[(start + i) % n];
        }
    }

    /// @notice Seconds until an order of `orderType` with `typeParam` would next be checked, at today's price.
    /// @dev The rule a sweep applies, for an order not placed yet (no per-type state); the frontend sizes budgets
    ///      with it. Held or triggered orders, and an unknown or failing type, get `minInterval`.
    /// @param marketId A listed market.
    /// @param orderType The order-type id.
    /// @param side The order's side.
    /// @param typeParam The type's parameter (trigger price or trail), as in `PlaceParams`.
    /// @param expiry The order's expiry (unix seconds); the delay never runs past it.
    /// @return Seconds until the check, within the market's `minInterval` and `maxInterval`.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function nextCheckDelay(uint256 marketId, uint8 orderType, Side side, uint128 typeParam, uint256 expiry)
        external
        view
        returns (uint256)
    {
        SweepParams memory sp = VAULT.getMarket(marketId).sweep;
        GuardReading memory g = VAULT.guardReading(marketId);
        if (g.oraclePrice == 0 || orderType >= VAULT.orderTypeCount()) return sp.minInterval;
        (uint256 distance, bool ok) = _distance(orderType, side, typeParam, bytes32(0), g.oraclePrice);
        return ok ? SweepMath.delayFor(sp, distance, expiry, block.timestamp) : sp.minInterval;
    }

    /// @notice Seconds until a placed order would next be checked at today's price, using its live per-type
    ///         state (e.g. a trailing stop's peak). Not open, or a failing strategy: `minInterval`.
    /// @param orderId The order.
    /// @return Seconds until the check.
    /// @dev Reverts `UnknownMarket` (from the vault) for an unknown order id, whose market id reads as 0.
    function orderNextCheckDelay(uint256 orderId) external view returns (uint256) {
        Order memory o = VAULT.getOrder(orderId);
        SweepParams memory sp = VAULT.getMarket(o.marketId).sweep;
        if (o.status != Status.Open) return sp.minInterval;
        GuardReading memory g = VAULT.guardReading(o.marketId);
        if (g.oraclePrice == 0) return sp.minInterval;
        (uint256 distance, bool ok) = _distance(o.orderType, o.side, o.typeParam, o.typeState, g.oraclePrice);
        return ok ? SweepMath.delayFor(sp, distance, o.expiry, block.timestamp) : sp.minInterval;
    }

    /// @notice Whether a market's checks are running. `Stalled` means funded orders are waiting but no
    ///         schedule will fire (the vault could not pay one, or it was missed); anyone may `restartSweep`.
    /// @param marketId A listed market.
    /// @return status Idle, Scheduled or Stalled.
    /// @return nextSweepAt When the pending (or missed) sweep is due (unix seconds); 0 when Idle.
    /// @dev Reverts `UnknownMarket` (from the vault) if the market is not listed.
    function sweepStatus(uint256 marketId) external view returns (SweepStatus status, uint256 nextSweepAt) {
        VAULT.getMarket(marketId);
        (address pending, uint40 at,, uint32 fundedOrders,,) = VAULT.sweeps(marketId);
        if (fundedOrders == 0) return (SweepStatus.Idle, 0);
        if (SweepMath.isDead(pending, at, block.timestamp)) return (SweepStatus.Stalled, at);
        return (SweepStatus.Scheduled, at);
    }

    // ---------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------

    function _distance(uint8 orderType, Side side, uint128 typeParam, bytes32 state, uint256 oraclePrice)
        internal
        view
        returns (uint256 distance, bool ok)
    {
        try IOrderType(VAULT.orderTypes(orderType)).evaluate{ gas: EVAL_GAS }(
            side, typeParam, state, oraclePrice
        ) returns (
            uint256 d, bytes32
        ) {
            return (d, true);
        } catch {
            return (0, false);
        }
    }

    function _costs() internal view returns (Costs memory c) {
        (
            c.scheduleGas,
            c.sweepBaseGas,
            c.checkGas,
            c.fillGasHbarIn,
            c.fillGasTokenIn,
            c.settleGas,
            c.idleSweepGas,
            c.gasPriceTinycents,
            c.safetyBps
        ) = VAULT.costs();
    }

    /// @dev Whether the order's input leg is HBAR (selling an HBAR base, or buying with an HBAR quote).
    function _hbarIn(Market memory m, Side side) internal pure returns (bool) {
        return side == Side.SellBase ? m.baseIsHbar : m.quoteIsHbar;
    }

    /// @dev Tinybar per `SweepMath.RATE_UNIT` tinycents, read from the exchange-rate system contract as the vault does.
    function _rate() internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            EXCHANGE_RATE.staticcall(abi.encodeCall(IExchangeRate.tinycentsToTinybars, (SweepMath.RATE_UNIT)));
        if (!ok || ret.length != 32) revert InvalidCosts();
        return abi.decode(ret, (uint256));
    }
}
