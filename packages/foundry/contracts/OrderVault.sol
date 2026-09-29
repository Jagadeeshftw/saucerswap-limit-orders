// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IHederaScheduleService } from "./interfaces/IHederaScheduleService.sol";
import { IHederaTokenService } from "./interfaces/IHederaTokenService.sol";
import { IExchangeRate } from "./interfaces/IExchangeRate.sol";
import { ISaucerSwapV2Router } from "./interfaces/ISaucerSwapV2.sol";
import { PriceMath } from "./libraries/PriceMath.sol";
import { MarketGuard } from "./libraries/MarketGuard.sol";
import {
    Costs,
    GuardParams,
    GuardReading,
    GuardState,
    Market,
    Order,
    PlaceParams,
    Side,
    Status,
    SweepParams,
    SweepState,
    Trigger
} from "./types/OrderTypes.sol";

/// @title OrderVault
/// @notice Limit and stop orders that execute on SaucerSwap V2 with no off-chain keeper.
/// @dev Each order is an HTS NFT minted by this vault; whoever holds it owns the order.
///      Each market runs one self-rescheduling sweep through the Hedera Schedule Service,
///      and the sweep's cost is split across the orders it checks. A fill needs the pool's
///      TWAP to agree with Chainlink, so a manipulated or stale market cannot drain an order.
contract OrderVault is Ownable2Step, ReentrancyGuard {
    using SafeCast for uint256;

    enum HtsOperation {
        CreateCollection,
        Mint,
        TransferNft,
        Associate
    }

    // ---------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------

    IHederaScheduleService internal constant HSS = IHederaScheduleService(address(0x16b));
    IHederaTokenService internal constant HTS = IHederaTokenService(address(0x167));
    address internal constant EXCHANGE_RATE = address(0x168);
    address internal constant HBAR = address(0);

    int64 internal constant HTS_SUCCESS = 22;
    int64 internal constant HTS_ALREADY_ASSOCIATED = 194;
    uint256 internal constant NFT_KEYS_SUPPLY_AND_WIPE = 16 | 8;
    int64 internal constant NFT_AUTO_RENEW_PERIOD = 7_776_000;

    /// @dev HIP-1215 caps expiry 62 days ahead; the minimum is a few seconds past consensus time.
    uint256 internal constant MIN_SWEEP_INTERVAL = 30;
    uint256 internal constant MAX_SWEEP_INTERVAL = 1 days;
    uint256 internal constant CAPACITY_PROBES = 6;
    /// @dev A sweep that has not fired this long after its expiry is treated as dead and may be restarted.
    uint256 internal constant SWEEP_GRACE = 120;
    uint256 internal constant MAX_ORDER_LIFETIME = 90 days;
    uint256 internal constant MIN_CHECKS_FUNDED = 6;
    uint256 internal constant MAX_GUARD_DEVIATION_BPS = 1_000;
    uint256 internal constant MAX_SLIPPAGE_BPS = 1_000;
    uint256 internal constant PAYOUT_GAS = 30_000;
    uint256 internal constant SWAP_DEADLINE = 300;

    ISaucerSwapV2Router public immutable ROUTER;
    address public immutable WHBAR;

    // ---------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------

    /// @notice HTS NFT collection whose serial numbers are order ids.
    address public collection;
    Costs public costs;
    uint32 public marketCount;

    mapping(uint256 marketId => Market) internal _markets;
    mapping(uint256 marketId => SweepState) public sweeps;
    mapping(uint256 marketId => uint256[]) internal _openOrders;
    mapping(uint256 orderId => uint256) internal _openIndexPlusOne;
    mapping(uint256 orderId => Order) internal _orders;

    /// @notice Tokens held on behalf of open orders, keyed by token (address(0) is HBAR).
    mapping(address token => uint256) public escrowed;
    /// @notice HBAR prepaid for scheduled checks and fills of open orders.
    uint256 public totalBudgets;
    /// @notice Payouts that could not be delivered and wait for `claim`.
    mapping(address account => mapping(address token => uint256)) public credits;
    mapping(address token => uint256) public totalCredits;

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    event CollectionCreated(address collection);
    event MarketListed(uint256 indexed marketId, address base, address quote, address pool, uint24 poolFee);
    event MarketUpdated(uint256 indexed marketId);
    event CostsUpdated(Costs costs);
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed maker,
        Side side,
        Trigger trigger,
        uint256 amountIn,
        uint256 triggerPrice,
        uint256 slippageBps,
        uint256 expiry,
        uint256 budget
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed holder,
        uint256 amountIn,
        uint256 amountOut,
        uint256 minAmountOut,
        uint256 oraclePrice,
        uint256 poolPrice,
        uint256 budgetRefund
    );
    event OrderCancelled(uint256 indexed orderId, address indexed holder, uint256 refund, uint256 budgetRefund);
    event OrderExpired(uint256 indexed orderId, address indexed holder, uint256 refund, uint256 budgetRefund);
    event OrderChecked(uint256 indexed orderId, uint256 charged, uint256 budgetLeft);
    event FillHeld(uint256 indexed orderId, GuardState reason, uint256 oraclePrice, uint256 poolPrice);
    event FillFailed(uint256 indexed orderId, bytes reason);
    event BudgetExhausted(uint256 indexed orderId, uint256 budgetLeft);
    event BudgetToppedUp(uint256 indexed orderId, address indexed from, uint256 amount, uint256 budget);
    event SweepScheduled(uint256 indexed marketId, address schedule, uint256 executeAt);
    event SweepScheduleFailed(uint256 indexed marketId, int64 responseCode);
    event SweepExecuted(
        uint256 indexed marketId, bool scheduled, GuardState guard, uint256 checked, uint256 filled, uint256 openOrders
    );
    event Credited(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed token, uint256 amount);
    event NftSettlementFailed(uint256 indexed orderId, int64 responseCode);
    event SurplusWithdrawn(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    error AlreadyInitialized();
    error NotInitialized();
    error HtsError(HtsOperation operation, int64 responseCode);
    error UnknownMarket(uint256 marketId);
    error MarketInactive(uint256 marketId);
    error InvalidMarket();
    error InvalidGuard();
    error InvalidSweep();
    error InvalidCosts();
    error InvalidAmount();
    error InvalidTrigger();
    error InvalidSlippage(uint256 slippageBps, uint256 minBps, uint256 maxBps);
    error InvalidExpiry(uint256 expiry);
    error InsufficientBudget(uint256 provided, uint256 required);
    error WrongValue(uint256 sent, uint256 expected);
    error OrderNotOpen(uint256 orderId);
    error NotHolder(uint256 orderId, address caller);
    error OnlySelf();
    error NothingToClaim();
    error TransferFailed();
    error SweepAlive(uint256 marketId, uint256 nextSweepAt);
    error NoFundedOrders(uint256 marketId);
    error NotRouter(address sender);

    // ---------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------

    /// @param router_ SaucerSwap V2 SwapRouter.
    /// @param whbar_ WHBAR HTS token, used as the HBAR leg of routes.
    constructor(address owner_, ISaucerSwapV2Router router_, address whbar_, Costs memory costs_) Ownable(owner_) {
        ROUTER = router_;
        WHBAR = whbar_;
        _setCosts(costs_);
    }

    /// @notice Create the order NFT collection. The vault is treasury and holds the supply and wipe keys.
    /// @dev Send the HTS creation fee as value (about 15 HBAR on testnet); any excess stays as surplus.
    function initialize(string calldata name, string calldata symbol) external payable onlyOwner {
        if (collection != address(0)) revert AlreadyInitialized();
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = IHederaTokenService.TokenKey({
            keyType: NFT_KEYS_SUPPLY_AND_WIPE,
            key: IHederaTokenService.KeyValue({
                inheritAccountKey: false,
                contractId: address(this),
                ed25519: "",
                ECDSA_secp256k1: "",
                delegatableContractId: address(0)
            })
        });
        IHederaTokenService.HederaToken memory token = IHederaTokenService.HederaToken({
            name: name,
            symbol: symbol,
            treasury: address(this),
            memo: "SaucerSwap limit and stop orders",
            tokenSupplyType: false,
            maxSupply: 0,
            freezeDefault: false,
            tokenKeys: keys,
            expiry: IHederaTokenService.Expiry({
                second: 0, autoRenewAccount: address(this), autoRenewPeriod: NFT_AUTO_RENEW_PERIOD
            })
        });
        (int64 rc, address created) = HTS.createNonFungibleToken{ value: msg.value }(token);
        if (rc != HTS_SUCCESS) revert HtsError(HtsOperation.CreateCollection, rc);
        collection = created;
        emit CollectionCreated(created);
    }

    /// @notice List a market and associate the vault with its HTS tokens.
    function listMarket(Market calldata market) external onlyOwner returns (uint256 marketId) {
        _validateMarket(market);
        marketId = ++marketCount;
        Market storage m = _markets[marketId];
        m.base = market.base;
        m.quote = market.quote;
        m.baseDecimals = market.baseDecimals;
        m.quoteDecimals = market.quoteDecimals;
        m.baseIsHbar = market.baseIsHbar;
        m.quoteIsHbar = market.quoteIsHbar;
        m.baseFeed = market.baseFeed;
        m.quoteFeed = market.quoteFeed;
        m.baseFeedDecimals = market.baseFeed.decimals();
        m.quoteFeedDecimals = market.quoteFeed.decimals();
        m.pool = market.pool;
        m.poolFee = market.poolFee;
        m.baseIsToken0 = market.pool.token0() == market.base;
        m.active = true;
        m.guard = market.guard;
        m.sweep = market.sweep;
        if (!market.baseIsHbar) _associate(market.base);
        if (!market.quoteIsHbar) _associate(market.quote);
        emit MarketListed(marketId, market.base, market.quote, address(market.pool), market.poolFee);
    }

    /// @notice Tune a market's guard and sweep. Bounds keep the guard from being switched off.
    function updateMarket(uint256 marketId, GuardParams calldata guard, SweepParams calldata sweepParams, bool active)
        external
        onlyOwner
    {
        Market storage m = _market(marketId);
        _validateGuard(guard, m.poolFee);
        _validateSweep(sweepParams);
        m.guard = guard;
        m.sweep = sweepParams;
        m.active = active;
        emit MarketUpdated(marketId);
    }

    function setCosts(Costs calldata costs_) external onlyOwner {
        _setCosts(costs_);
    }

    /// @notice Withdraw HBAR the vault holds beyond escrow, budgets and credits (e.g. leftover creation fee).
    function withdrawSurplus(address payable to) external onlyOwner nonReentrant {
        uint256 amount = surplus();
        if (amount == 0) revert InvalidAmount();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit SurplusWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Orders
    // ---------------------------------------------------------------------------------------

    /// @notice Escrow `amountIn`, mint the order NFT to the caller and make sure the market sweep is running.
    /// @dev msg.value is the check budget, plus `amountIn` when the input is HBAR.
    ///      The caller needs auto-association slots or an association with `collection`.
    function placeOrder(PlaceParams calldata p) external payable nonReentrant returns (uint256 orderId) {
        if (collection == address(0)) revert NotInitialized();
        Market storage m = _market(p.marketId);
        if (!m.active) revert MarketInactive(p.marketId);
        if (p.amountIn == 0) revert InvalidAmount();
        if (p.triggerPrice == 0) revert InvalidTrigger();
        uint256 minSlippage = uint256(m.poolFee) / 100;
        if (p.slippageBps <= minSlippage || p.slippageBps > m.guard.maxSlippageBps) {
            revert InvalidSlippage(p.slippageBps, minSlippage + 1, m.guard.maxSlippageBps);
        }
        if (p.expiry <= block.timestamp || p.expiry > block.timestamp + MAX_ORDER_LIFETIME) {
            revert InvalidExpiry(p.expiry);
        }

        (address tokenIn,) = _route(m, p.side);
        uint256 budget = msg.value;
        if (tokenIn == HBAR) {
            if (msg.value < p.amountIn) revert WrongValue(msg.value, p.amountIn);
            budget = msg.value - p.amountIn;
        }
        uint256 required = minBudget(p.marketId, p.side);
        if (budget < required) revert InsufficientBudget(budget, required);

        if (tokenIn != HBAR) _pullToken(tokenIn, msg.sender, p.amountIn);
        escrowed[tokenIn] += p.amountIn;
        totalBudgets += budget;

        orderId = _mintOrderNft(msg.sender);
        _orders[orderId] = Order({
            marketId: p.marketId,
            side: p.side,
            trigger: p.trigger,
            status: Status.Open,
            funded: true,
            slippageBps: p.slippageBps,
            createdAt: block.timestamp.toUint40(),
            expiry: p.expiry,
            amountIn: p.amountIn,
            triggerPrice: p.triggerPrice,
            budget: budget.toUint128()
        });
        _openOrders[p.marketId].push(orderId);
        _openIndexPlusOne[orderId] = _openOrders[p.marketId].length;
        sweeps[p.marketId].fundedOrders++;

        emit OrderPlaced(
            orderId,
            p.marketId,
            msg.sender,
            p.side,
            p.trigger,
            p.amountIn,
            p.triggerPrice,
            p.slippageBps,
            p.expiry,
            budget
        );

        SweepState storage s = sweeps[p.marketId];
        if (_sweepIsDead(s)) _scheduleSweep(p.marketId, m, s);
    }

    /// @notice Cancel an open order; escrow and unused budget go back to the NFT holder.
    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _openOrder(orderId);
        address holder = holderOf(orderId);
        if (holder != msg.sender) revert NotHolder(orderId, msg.sender);
        (uint256 refund, uint256 budgetRefund) = _close(orderId, o, Status.Cancelled, holder);
        emit OrderCancelled(orderId, holder, refund, budgetRefund);
    }

    /// @notice Add HBAR to an order's check budget. Anyone may top up any order.
    function topUp(uint256 orderId) external payable nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
        Order storage o = _openOrder(orderId);
        o.budget += msg.value.toUint128();
        totalBudgets += msg.value;
        if (!o.funded && o.budget >= _reserve(o) + checkCost(o.marketId)) {
            o.funded = true;
            sweeps[o.marketId].fundedOrders++;
        }
        emit BudgetToppedUp(orderId, msg.sender, msg.value, o.budget);
        SweepState storage s = sweeps[o.marketId];
        if (o.funded && _sweepIsDead(s)) _scheduleSweep(o.marketId, _markets[o.marketId], s);
    }

    /// @notice Check one order now and fill or expire it if due. The caller pays gas; the budget is untouched.
    function executeOrder(uint256 orderId) external nonReentrant returns (bool settled) {
        Order storage o = _openOrder(orderId);
        if (block.timestamp >= o.expiry) {
            _expire(orderId, o);
            return true;
        }
        GuardReading memory g = guardReading(o.marketId);
        if (g.oraclePrice == 0 || !_triggerMet(o, g.oraclePrice)) return false;
        if (g.state != GuardState.Open) {
            emit FillHeld(orderId, g.state, g.oraclePrice, g.poolPrice);
            return false;
        }
        return _tryFill(orderId, g, gasleft());
    }

    /// @notice Pull a payout that could not be delivered at settlement.
    function claim(address token) external nonReentrant {
        uint256 amount = credits[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        credits[msg.sender][token] = 0;
        totalCredits[token] -= amount;
        if (token == HBAR) {
            (bool ok,) = msg.sender.call{ value: amount }("");
            if (!ok) revert TransferFailed();
        } else {
            if (!_transferToken(token, msg.sender, amount)) revert TransferFailed();
        }
        emit Claimed(msg.sender, token, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Sweep
    // ---------------------------------------------------------------------------------------

    /// @notice Check up to `maxOrders` open orders of a market, fill the ones whose trigger is met,
    ///         and, when called by the Hedera Schedule Service, schedule the next sweep.
    /// @dev Scheduled calls arrive with msg.sender == this vault. They debit each checked order's
    ///      budget because the vault pays their fees. Manual calls are paid by the caller and debit nothing.
    function sweep(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        SweepState storage s = sweeps[marketId];
        bool scheduled = msg.sender == address(this);
        if (scheduled) s.pendingSchedule = address(0);

        GuardReading memory g = guardReading(marketId);
        uint256[] memory batch = _nextBatch(marketId, m.sweep.maxOrders);
        uint256 share = scheduled ? _batchShare(batch) : 0;
        uint256 reserveGas = _finishGas();
        uint256 checked;
        uint256 filled;

        for (uint256 i; i < batch.length; ++i) {
            if (gasleft() < reserveGas + costs.checkGas + costs.settleGas) break;
            uint256 orderId = batch[i];
            Order storage o = _orders[orderId];
            if (o.status != Status.Open) continue;
            if (block.timestamp >= o.expiry) {
                if (scheduled) _debit(o, _gasToTinybar(costs.settleGas));
                _expire(orderId, o);
                continue;
            }
            if (!o.funded) continue;
            if (scheduled && !_charge(orderId, o, share)) continue;
            checked++;
            if (g.oraclePrice == 0 || !_triggerMet(o, g.oraclePrice)) continue;
            if (g.state != GuardState.Open) {
                emit FillHeld(orderId, g.state, g.oraclePrice, g.poolPrice);
                continue;
            }
            if (filled >= m.sweep.maxFills || gasleft() < reserveGas + _fillGas(m, o.side)) continue;
            if (scheduled) _debit(o, fillCost(o.marketId, o.side));
            if (_tryFill(orderId, g, gasleft() - reserveGas)) filled++;
        }

        uint256 open = _openOrders[marketId].length;
        s.cursor = open == 0 ? 0 : ((s.cursor + batch.length) % open).toUint32();
        emit SweepExecuted(marketId, scheduled, g.state, checked, filled, open);

        if (s.fundedOrders > 0 && (scheduled || _sweepIsDead(s))) _scheduleSweep(marketId, m, s);
    }

    /// @notice Restart a market's sweep chain if it stopped, e.g. because a schedule was saturated.
    function restartSweep(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        SweepState storage s = sweeps[marketId];
        if (s.fundedOrders == 0) revert NoFundedOrders(marketId);
        if (!_sweepIsDead(s)) revert SweepAlive(marketId, s.nextSweepAt);
        _scheduleSweep(marketId, m, s);
    }

    /// @notice Settle a fill. Only callable by the vault itself, so a failed swap can be caught.
    function fillFromVault(uint256 orderId, uint256 oraclePrice, uint256 poolPrice)
        external
        returns (uint256 amountOut)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        Order storage o = _orders[orderId];
        Market storage m = _markets[o.marketId];
        (address tokenIn, address tokenOut) = _route(m, o.side);
        uint256 minOut = PriceMath.lessBps(_valueAt(m, o.side, o.amountIn, oraclePrice), o.slippageBps);
        uint256 amountIn = o.amountIn;

        escrowed[tokenIn] -= amountIn;
        amountOut = _swap(m, tokenIn, tokenOut, amountIn, minOut);

        address holder = holderOf(orderId);
        uint256 budgetRefund = _finish(orderId, o, Status.Filled, holder);
        _pay(holder, tokenOut, amountOut);
        emit OrderFilled(orderId, holder, amountIn, amountOut, minOut, oraclePrice, poolPrice, budgetRefund);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return _market(marketId);
    }

    function getCosts() external view returns (Costs memory) {
        return costs;
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function openOrders(uint256 marketId) external view returns (uint256[] memory) {
        return _openOrders[marketId];
    }

    /// @notice Current holder of an order's NFT: the account that can cancel it and receives its proceeds.
    function holderOf(uint256 orderId) public view returns (address) {
        return IERC721(collection).ownerOf(orderId);
    }

    /// @notice Chainlink price, pool TWAP price and the guard verdict for a market.
    function guardReading(uint256 marketId) public view returns (GuardReading memory) {
        return MarketGuard.read(_market(marketId));
    }

    /// @notice Output an order would get at `price`, before slippage.
    function valueAt(uint256 marketId, Side side, uint256 amountIn, uint256 price) external view returns (uint256) {
        return _valueAt(_market(marketId), side, amountIn, price);
    }

    /// @notice HBAR (tinybar) charged to an order per scheduled check if it were the only funded order.
    function checkCost(uint256 marketId) public view returns (uint256) {
        _market(marketId);
        return _sweepShare(1);
    }

    /// @notice HBAR (tinybar) charged per check when `fundedOrders` orders share the sweep.
    function checkCostShared(uint256 fundedOrders) external view returns (uint256) {
        return _sweepShare(fundedOrders == 0 ? 1 : fundedOrders);
    }

    /// @notice HBAR (tinybar) held back from checks so a fill can always be paid for.
    function fillCost(uint256 marketId, Side side) public view returns (uint256) {
        return _gasToTinybar(_fillGas(_market(marketId), side));
    }

    /// @notice Smallest budget accepted at placement: a fill plus `MIN_CHECKS_FUNDED` solo checks.
    function minBudget(uint256 marketId, Side side) public view returns (uint256) {
        return fillCost(marketId, side) + MIN_CHECKS_FUNDED * checkCost(marketId);
    }

    /// @notice Gas limit given to each scheduled sweep.
    function sweepGasLimit(uint256 marketId) public view returns (uint256) {
        Market storage m = _market(marketId);
        return _finishGas() + uint256(m.sweep.maxOrders) * (uint256(costs.checkGas) + costs.settleGas)
            + uint256(m.sweep.maxFills) * (uint256(costs.fillGasTokenIn) + costs.settleGas);
    }

    /// @notice HBAR the vault holds beyond what it owes: escrow, budgets and credits.
    function surplus() public view returns (uint256) {
        uint256 owed = escrowed[HBAR] + totalBudgets + totalCredits[HBAR];
        return address(this).balance > owed ? address(this).balance - owed : 0;
    }

    // ---------------------------------------------------------------------------------------
    // Internal: orders
    // ---------------------------------------------------------------------------------------

    /// @dev The external self-call lets a failed swap revert on its own; `gasCap` keeps enough gas to reschedule.
    function _tryFill(uint256 orderId, GuardReading memory g, uint256 gasCap) internal returns (bool) {
        try this.fillFromVault{ gas: gasCap }(orderId, g.oraclePrice, g.poolPrice) returns (uint256) {
            return true;
        } catch (bytes memory reason) {
            emit FillFailed(orderId, reason);
            return false;
        }
    }

    function _expire(uint256 orderId, Order storage o) internal {
        address holder = holderOf(orderId);
        (uint256 refund, uint256 budgetRefund) = _close(orderId, o, Status.Expired, holder);
        emit OrderExpired(orderId, holder, refund, budgetRefund);
    }

    /// @dev Cancel or expire: return escrow and budget to the holder.
    function _close(uint256 orderId, Order storage o, Status status, address holder)
        internal
        returns (uint256 refund, uint256 budgetRefund)
    {
        (address tokenIn,) = _route(_markets[o.marketId], o.side);
        refund = o.amountIn;
        escrowed[tokenIn] -= refund;
        budgetRefund = _finish(orderId, o, status, holder);
        _pay(holder, tokenIn, refund);
    }

    /// @dev Shared settlement: mark closed, release the budget, remove from the open list, retire the NFT.
    function _finish(uint256 orderId, Order storage o, Status status, address holder)
        internal
        returns (uint256 budgetRefund)
    {
        o.status = status;
        if (o.funded) sweeps[o.marketId].fundedOrders--;
        o.funded = false;
        budgetRefund = o.budget;
        o.budget = 0;
        totalBudgets -= budgetRefund;
        _removeOpen(o.marketId, orderId);
        _retireNft(orderId, holder);
        _pay(holder, HBAR, budgetRefund);
    }

    /// @dev Debit a scheduled check. Returns false (and parks the order) when the budget would dip into the fill reserve.
    function _charge(uint256 orderId, Order storage o, uint256 share) internal returns (bool) {
        uint256 reserve = _reserve(o);
        if (o.budget < reserve + share) {
            o.funded = false;
            sweeps[o.marketId].fundedOrders--;
            emit BudgetExhausted(orderId, o.budget);
            return false;
        }
        o.budget -= share.toUint128();
        totalBudgets -= share;
        emit OrderChecked(orderId, share, o.budget);
        return true;
    }

    /// @dev Take up to `amount` from an order's budget for work the vault is paying for.
    function _debit(Order storage o, uint256 amount) internal {
        uint256 taken = amount < o.budget ? amount : o.budget;
        o.budget -= taken.toUint128();
        totalBudgets -= taken;
    }

    function _reserve(Order storage o) internal view returns (uint256) {
        return fillCost(o.marketId, o.side);
    }

    function _triggerMet(Order storage o, uint256 price) internal view returns (bool) {
        return o.trigger == Trigger.AtOrAbove ? price >= o.triggerPrice : price <= o.triggerPrice;
    }

    function _openOrder(uint256 orderId) internal view returns (Order storage o) {
        o = _orders[orderId];
        if (o.status != Status.Open) revert OrderNotOpen(orderId);
    }

    function _removeOpen(uint256 marketId, uint256 orderId) internal {
        uint256[] storage list = _openOrders[marketId];
        uint256 index = _openIndexPlusOne[orderId] - 1;
        uint256 last = list[list.length - 1];
        list[index] = last;
        _openIndexPlusOne[last] = index + 1;
        list.pop();
        delete _openIndexPlusOne[orderId];
    }

    function _nextBatch(uint256 marketId, uint256 maxOrders) internal view returns (uint256[] memory batch) {
        uint256[] storage list = _openOrders[marketId];
        uint256 n = list.length;
        uint256 size = n < maxOrders ? n : maxOrders;
        batch = new uint256[](size);
        uint256 start = n == 0 ? 0 : sweeps[marketId].cursor % n;
        for (uint256 i; i < size; ++i) {
            batch[i] = list[(start + i) % n];
        }
    }

    // ---------------------------------------------------------------------------------------
    // Internal: scheduling and costs
    // ---------------------------------------------------------------------------------------

    function _scheduleSweep(uint256 marketId, Market storage m, SweepState storage s) internal {
        uint256 gasLimit = sweepGasLimit(marketId);
        uint256 target = block.timestamp + m.sweep.interval;
        uint256 at = _findCapacity(target, gasLimit);
        (int64 rc, address schedule) =
            HSS.scheduleCall(address(this), at, gasLimit, 0, abi.encodeCall(this.sweep, (marketId)));
        if (rc != HTS_SUCCESS || schedule == address(0)) {
            s.pendingSchedule = address(0);
            emit SweepScheduleFailed(marketId, rc);
            return;
        }
        s.pendingSchedule = schedule;
        s.nextSweepAt = at.toUint40();
        emit SweepScheduled(marketId, schedule, at);
    }

    /// @dev HIP-1215's suggested probe: exponential back-off with PRNG jitter so vaults don't stampede one second.
    function _findCapacity(uint256 target, uint256 gasLimit) internal view returns (uint256) {
        if (HSS.hasScheduleCapacity(target, gasLimit)) return target;
        bytes32 seed = bytes32(block.prevrandao);
        for (uint256 i; i < CAPACITY_PROBES; ++i) {
            uint256 backoff = 2 ** i;
            uint256 candidate = target + backoff + (uint256(keccak256(abi.encodePacked(seed, i))) % backoff);
            if (HSS.hasScheduleCapacity(candidate, gasLimit)) return candidate;
        }
        return target;
    }

    function _sweepIsDead(SweepState storage s) internal view returns (bool) {
        return s.pendingSchedule == address(0) || block.timestamp > uint256(s.nextSweepAt) + SWEEP_GRACE;
    }

    /// @dev Charge per order for this scheduled sweep. The fixed cost is split over the batch's orders that
    ///      can actually pay; recounting until stable means every counted order covers its share.
    function _batchShare(uint256[] memory batch) internal view returns (uint256 share) {
        uint256 payers;
        for (uint256 i; i < batch.length; ++i) {
            Order storage o = _orders[batch[i]];
            if (o.status == Status.Open && o.funded && block.timestamp < o.expiry) payers++;
        }
        while (payers > 0) {
            share = _sweepShare(payers);
            uint256 affordable;
            for (uint256 i; i < batch.length; ++i) {
                Order storage o = _orders[batch[i]];
                if (o.status != Status.Open || !o.funded || block.timestamp >= o.expiry) continue;
                if (o.budget >= _reserve(o) + share) affordable++;
            }
            if (affordable == payers) return share;
            payers = affordable;
        }
        // Nobody in the batch can pay even a shared check: price it solo so `_charge` parks them.
        return _sweepShare(1);
    }

    /// @dev Per-order charge for one scheduled check: an even share of the sweep's fixed cost plus its own check.
    function _sweepShare(uint256 fundedOrders) internal view returns (uint256) {
        uint256 fixedGas = uint256(costs.scheduleGas) + costs.sweepBaseGas;
        uint256 gas = (fixedGas + fundedOrders - 1) / fundedOrders + costs.checkGas;
        return _gasToTinybar(gas);
    }

    /// @dev Gas a sweep keeps back so it can always reach the reschedule.
    function _finishGas() internal view returns (uint256) {
        return uint256(costs.scheduleGas) + costs.sweepBaseGas;
    }

    function _fillGas(Market storage m, Side side) internal view returns (uint256) {
        (address tokenIn,) = _route(m, side);
        return uint256(tokenIn == HBAR ? costs.fillGasHbarIn : costs.fillGasTokenIn) + costs.settleGas;
    }

    function _gasToTinybar(uint256 gas) internal view returns (uint256) {
        uint256 tinycents = gas * costs.gasPriceTinycents;
        return _tinycentsToTinybars(tinycents + (tinycents * costs.safetyBps) / PriceMath.BPS);
    }

    /// @dev Static call so views can price fees with the network's own exchange rate.
    function _tinycentsToTinybars(uint256 tinycents) internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            EXCHANGE_RATE.staticcall(abi.encodeCall(IExchangeRate.tinycentsToTinybars, (tinycents)));
        if (!ok || ret.length != 32) revert InvalidCosts();
        return abi.decode(ret, (uint256));
    }

    function _setCosts(Costs memory c) internal {
        if (c.scheduleGas == 0 || c.checkGas == 0 || c.fillGasHbarIn == 0 || c.fillGasTokenIn == 0) {
            revert InvalidCosts();
        }
        if (c.gasPriceTinycents == 0 || c.safetyBps > PriceMath.BPS) revert InvalidCosts();
        costs = c;
        emit CostsUpdated(c);
    }

    // ---------------------------------------------------------------------------------------
    // Internal: prices and swaps
    // ---------------------------------------------------------------------------------------

    function _valueAt(Market storage m, Side side, uint256 amountIn, uint256 price) internal view returns (uint256) {
        return side == Side.SellBase
            ? PriceMath.baseToQuote(amountIn, price, m.baseDecimals, m.quoteDecimals)
            : PriceMath.quoteToBase(amountIn, price, m.baseDecimals, m.quoteDecimals);
    }

    /// @dev Input and output tokens for a side; address(0) stands for HBAR.
    function _route(Market storage m, Side side) internal view returns (address tokenIn, address tokenOut) {
        address base = m.baseIsHbar ? HBAR : m.base;
        address quote = m.quoteIsHbar ? HBAR : m.quote;
        return side == Side.SellBase ? (base, quote) : (quote, base);
    }

    function _swap(Market storage m, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        ISaucerSwapV2Router.ExactInputSingleParams memory params = ISaucerSwapV2Router.ExactInputSingleParams({
            tokenIn: tokenIn == HBAR ? WHBAR : tokenIn,
            tokenOut: tokenOut == HBAR ? WHBAR : tokenOut,
            fee: m.poolFee,
            recipient: tokenOut == HBAR ? address(ROUTER) : address(this),
            deadline: block.timestamp + SWAP_DEADLINE,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        if (tokenIn != HBAR) {
            if (!IERC20(tokenIn).approve(address(ROUTER), amountIn)) revert TransferFailed();
        }
        uint256 value = tokenIn == HBAR ? amountIn : 0;
        if (tokenOut == HBAR) {
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(ISaucerSwapV2Router.exactInputSingle, (params));
            calls[1] = abi.encodeCall(ISaucerSwapV2Router.unwrapWHBAR, (minOut, address(this)));
            bytes[] memory results = ROUTER.multicall{ value: value }(calls);
            amountOut = abi.decode(results[0], (uint256));
        } else {
            amountOut = ROUTER.exactInputSingle{ value: value }(params);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Internal: tokens and NFTs
    // ---------------------------------------------------------------------------------------

    function _mintOrderNft(address to) internal returns (uint256 orderId) {
        bytes[] memory metadata = new bytes[](1);
        metadata[0] = bytes("saucerswap-limit-order");
        (int64 rc,, int64[] memory serials) = HTS.mintToken(collection, 0, metadata);
        if (rc != HTS_SUCCESS) revert HtsError(HtsOperation.Mint, rc);
        rc = HTS.transferNFT(collection, address(this), to, serials[0]);
        if (rc != HTS_SUCCESS) revert HtsError(HtsOperation.TransferNft, rc);
        orderId = uint256(uint64(serials[0]));
    }

    /// @dev Remove a settled order's NFT from circulation. Never reverts, so settlement can't be blocked.
    function _retireNft(uint256 orderId, address holder) internal {
        int64[] memory serials = new int64[](1);
        // Serials are HTS int64 values that were minted by this vault.
        // forge-lint: disable-next-line(unsafe-typecast)
        serials[0] = int64(uint64(orderId));
        int64 rc;
        if (holder == address(this)) {
            (rc,) = HTS.burnToken(collection, 0, serials);
        } else {
            rc = HTS.wipeTokenAccountNFT(collection, holder, serials);
        }
        if (rc != HTS_SUCCESS) emit NftSettlementFailed(orderId, rc);
    }

    function _associate(address token) internal {
        int64 rc = HTS.associateToken(address(this), token);
        if (rc != HTS_SUCCESS && rc != HTS_ALREADY_ASSOCIATED) revert HtsError(HtsOperation.Associate, rc);
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _transferToken(address token, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @dev Deliver a payout, or credit it for `claim` if the recipient can't take it right now
    ///      (not associated, or a contract that rejects HBAR). Payout gas is capped so a holder can't stall a sweep.
    function _pay(address to, address token, uint256 amount) internal {
        if (amount == 0) return;
        bool delivered;
        if (to != address(this)) {
            if (token == HBAR) {
                (delivered,) = to.call{ value: amount, gas: PAYOUT_GAS }("");
            } else {
                delivered = _transferToken(token, to, amount);
            }
        }
        if (!delivered) {
            credits[to][token] += amount;
            totalCredits[token] += amount;
            emit Credited(to, token, amount);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Internal: validation
    // ---------------------------------------------------------------------------------------

    function _market(uint256 marketId) internal view returns (Market storage m) {
        m = _markets[marketId];
        if (address(m.pool) == address(0)) revert UnknownMarket(marketId);
    }

    function _validateMarket(Market calldata market) internal pure {
        if (address(market.pool) == address(0) || market.base == address(0) || market.quote == address(0)) {
            revert InvalidMarket();
        }
        if (market.base == market.quote || (market.baseIsHbar && market.quoteIsHbar)) revert InvalidMarket();
        if (address(market.baseFeed) == address(0) || address(market.quoteFeed) == address(0)) revert InvalidMarket();
        _validateGuard(market.guard, market.poolFee);
        _validateSweep(market.sweep);
    }

    function _validateGuard(GuardParams calldata g, uint24 poolFee) internal pure {
        if (g.twapWindow == 0 || g.maxOracleAge == 0) revert InvalidGuard();
        if (g.maxDeviationBps == 0 || g.maxDeviationBps > MAX_GUARD_DEVIATION_BPS) revert InvalidGuard();
        if (g.maxSlippageBps <= poolFee / 100 || g.maxSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidGuard();
    }

    function _validateSweep(SweepParams calldata p) internal pure {
        if (p.interval < MIN_SWEEP_INTERVAL || p.interval > MAX_SWEEP_INTERVAL) revert InvalidSweep();
        if (p.maxOrders == 0 || p.maxFills == 0 || p.maxFills > p.maxOrders) revert InvalidSweep();
    }

    /// @notice Receives HBAR the router unwraps when an order buys HBAR.
    receive() external payable {
        if (msg.sender != address(ROUTER)) revert NotRouter(msg.sender);
    }
}
