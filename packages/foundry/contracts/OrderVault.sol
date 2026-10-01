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
import { OrderCollection } from "./libraries/OrderCollection.sol";
import { Settlement } from "./libraries/Settlement.sol";
import { IOrderType } from "./interfaces/IOrderType.sol";
import {
    Costs,
    GuardParams,
    GuardReading,
    GuardState,
    HtsError,
    HtsOperation,
    Market,
    Order,
    PlaceParams,
    Side,
    Status,
    SweepParams,
    SweepState,
    SweepStatus
} from "./types/OrderTypes.sol";

/// @title OrderVault
/// @notice Limit and stop orders that execute on SaucerSwap V2 with no off-chain keeper.
/// @dev Each order is an HTS NFT minted by this vault; whoever holds it owns the order.
///      Each market runs one self-rescheduling sweep through the Hedera Schedule Service,
///      and the sweep's cost is split across the orders it checks. Scheduling a call is a fixed
///      network fee, so the next sweep waits as long as the nearest trigger allows. A fill needs the
///      pool's TWAP to agree with Chainlink, so a manipulated or stale market cannot drain an order.
contract OrderVault is Ownable2Step, ReentrancyGuard {
    using SafeCast for uint256;

    // ---------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------

    IHederaScheduleService internal constant HSS = IHederaScheduleService(address(0x16b));
    IHederaTokenService internal constant HTS = IHederaTokenService(address(0x167));
    address internal constant EXCHANGE_RATE = address(0x168);
    address internal constant HBAR = address(0);

    int64 internal constant HTS_SUCCESS = 22;
    int64 internal constant HTS_ALREADY_ASSOCIATED = 194;

    /// @dev HIP-1215 caps expiry 62 days ahead; the minimum is a few seconds past consensus time.
    uint256 internal constant MIN_SWEEP_INTERVAL = 30;
    uint256 internal constant MAX_SWEEP_INTERVAL = 1 days;
    uint256 internal constant MAX_HELD_STREAK = 8;
    uint256 internal constant CAPACITY_PROBES = 6;
    /// @dev A sweep that has not fired this long after its expiry is treated as dead and may be restarted.
    uint256 internal constant SWEEP_GRACE = 120;
    uint256 internal constant MAX_ORDER_LIFETIME = 90 days;
    uint256 internal constant MIN_CHECKS_FUNDED = 6;
    /// @dev Gas stipend for a strategy's `evaluate`; capped so a gas-burning strategy can't brick a sweep.
    uint256 internal constant EVAL_GAS = 100_000;
    uint256 internal constant PAYOUT_GAS = 30_000;
    uint256 internal constant SWAP_DEADLINE = 300;
    /// @dev Tinycents converted per exchange-rate lookup; every fee in one call is priced from a single lookup.
    uint256 internal constant RATE_UNIT = 1e12;

    ISaucerSwapV2Router public immutable ROUTER;
    address public immutable WHBAR;

    /// @dev Working state of one sweep: its prices and charges, and what it found.
    struct Pass {
        bool scheduled;
        bool held;
        GuardReading guard;
        uint256 rate;
        uint256 share;
        uint256 parkFee;
        uint256 reserveGas;
        uint256 next;
        uint256 checked;
        uint256 filled;
    }

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

    /// @notice The order-type strategy registry. `orderTypes[id]` is a view-only `IOrderType`; `orderTypeActive`
    ///         gates whether NEW orders may use it. Append-only ids, so an order's bound type never changes.
    mapping(uint8 id => address impl) public orderTypes;
    mapping(uint8 id => bool active) public orderTypeActive;
    uint8 public orderTypeCount;

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
        uint8 orderType,
        uint256 amountIn,
        uint256 typeParam,
        uint256 slippageBps,
        uint256 expiry,
        uint256 budget
    );
    event OrderTypeRegistered(uint8 indexed id, address impl);
    event OrderTypeActiveSet(uint8 indexed id, bool active);
    /// @notice A strategy returned new per-order state (e.g. a trailing stop raised its peak); the vault stored it.
    event OrderStateUpdated(uint256 indexed orderId, bytes32 state);
    /// @notice A strategy reverted or ran out of its gas stipend during a sweep; the order was skipped, not filled.
    event OrderEvalSkipped(uint256 indexed orderId);
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
    event SweepScheduled(uint256 indexed marketId, address schedule, uint256 executeAt, uint256 epoch);
    event SweepSuperseded(uint256 indexed marketId, uint256 epoch);
    /// @notice An order needed a check sooner than the pending sweep and paid for the superseded run.
    event SweepBroughtForward(uint256 indexed orderId, uint256 charged, uint256 budgetLeft);
    event SweepScheduleFailed(uint256 indexed marketId, int64 responseCode);
    event SweepExecuted(
        uint256 indexed marketId, bool scheduled, GuardState guard, uint256 checked, uint256 filled, uint256 openOrders
    );
    event Credited(address indexed account, address indexed token, uint256 amount);
    event Claimed(address indexed account, address indexed token, uint256 amount);
    event NftSettlementFailed(uint256 indexed orderId, int64 responseCode);
    event SurplusWithdrawn(address indexed to, uint256 amount);
    event Funded(address indexed from, uint256 amount);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    error AlreadyInitialized();
    error NotInitialized();
    error UnknownMarket(uint256 marketId);
    error MarketInactive(uint256 marketId);
    error InvalidMarket();
    error InvalidGuard();
    error InvalidSweep();
    error InvalidCosts();
    error InvalidAmount();
    error InvalidTrigger();
    error UnknownOrderType(uint8 id);
    error OrderTypeInactive(uint8 id);
    error InvalidOrderParams();
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
        (int64 rc, address created) = OrderCollection.create(name, symbol, msg.value);
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

    /// @notice Register a view-only order-type strategy and return its id. Append-only: ids are never reused, so
    ///         an order's bound type can never change under it. The new type is active for new orders at once.
    function registerOrderType(address impl) external onlyOwner returns (uint8 id) {
        if (impl == address(0)) revert InvalidOrderParams();
        id = orderTypeCount++;
        orderTypes[id] = impl;
        orderTypeActive[id] = true;
        emit OrderTypeRegistered(id, impl);
        emit OrderTypeActiveSet(id, true);
    }

    /// @notice Pause or resume an order type for NEW orders. Existing orders of that type keep running and can
    ///         always be cancelled; only placement is gated.
    function setOrderTypeActive(uint8 id, bool active) external onlyOwner {
        if (id >= orderTypeCount) revert UnknownOrderType(id);
        orderTypeActive[id] = active;
        emit OrderTypeActiveSet(id, active);
    }

    /// @notice Endow the vault with liquid HBAR to back the payer float, so its scheduled sweeps can always
    ///         pay their gas at execution. Anyone may fund it; only the owner may withdraw the surplus above
    ///         the float. Kept separate from `receive`, which only accepts swap proceeds from the router.
    function fund() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Withdraw HBAR the vault holds beyond escrow, budgets, credits and the payer float.
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
        if (p.orderType >= orderTypeCount) revert UnknownOrderType(p.orderType);
        if (!orderTypeActive[p.orderType]) revert OrderTypeInactive(p.orderType);
        if (
            !IOrderType(orderTypes[p.orderType]).validate(
                p.side, p.amountIn, p.typeParam, p.slippageBps, p.expiry, block.timestamp.toUint40()
            )
        ) revert InvalidOrderParams();
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
        uint256 rate = _rate();
        uint256 required = _minBudget(m, p.side, rate);
        if (budget < required) revert InsufficientBudget(budget, required);

        if (tokenIn != HBAR) _pullToken(tokenIn, msg.sender, p.amountIn);
        escrowed[tokenIn] += p.amountIn;
        totalBudgets += budget;

        orderId = _mintOrderNft(msg.sender);
        _orders[orderId] = Order({
            marketId: p.marketId,
            side: p.side,
            orderType: p.orderType,
            status: Status.Open,
            funded: true,
            slippageBps: p.slippageBps,
            createdAt: block.timestamp.toUint40(),
            expiry: p.expiry,
            amountIn: p.amountIn,
            typeParam: p.typeParam,
            budget: budget.toUint128(),
            typeState: bytes32(0)
        });
        _openOrders[p.marketId].push(orderId);
        _openIndexPlusOne[orderId] = _openOrders[p.marketId].length;
        sweeps[p.marketId].fundedOrders++;

        emit OrderPlaced(
            orderId,
            p.marketId,
            msg.sender,
            p.side,
            p.orderType,
            p.amountIn,
            p.typeParam,
            p.slippageBps,
            p.expiry,
            budget
        );

        _ensureSweep(orderId, _orders[orderId], m, rate);
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
        uint256 rate = _rate();
        if (!o.funded && o.budget >= _reserve(o, rate) + _sweepShare(1, rate)) {
            o.funded = true;
            sweeps[o.marketId].fundedOrders++;
        }
        emit BudgetToppedUp(orderId, msg.sender, msg.value, o.budget);
        if (o.funded) _ensureSweep(orderId, o, _markets[o.marketId], rate);
    }

    /// @notice Check one order now and fill or expire it if due. The caller pays gas; the budget is untouched.
    function executeOrder(uint256 orderId) external nonReentrant returns (bool settled) {
        Order storage o = _openOrder(orderId);
        if (block.timestamp >= o.expiry) {
            _expire(orderId, o);
            return true;
        }
        GuardReading memory g = guardReading(o.marketId);
        if (g.oraclePrice == 0) return false;
        (uint256 distance, bytes32 newState, bool ok) = _evaluate(o, g.oraclePrice);
        if (!ok || distance != 0) return false;
        if (newState != o.typeState) o.typeState = newState;
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
    /// @dev Scheduled calls arrive with msg.sender == this vault and carry the epoch they were scheduled
    ///      under; a stale epoch means an earlier sweep replaced this one, so it returns at once. Scheduled
    ///      calls debit each checked order's budget because the vault pays their fees. Manual calls are
    ///      paid by the caller, debit nothing and ignore `epoch`.
    function sweep(uint256 marketId, uint32 epoch) external nonReentrant {
        Market storage m = _market(marketId);
        SweepState storage s = sweeps[marketId];
        bool scheduled = msg.sender == address(this);
        if (scheduled) {
            if (epoch != s.epoch) {
                emit SweepSuperseded(marketId, epoch);
                return;
            }
            s.pendingSchedule = address(0);
        }

        Pass memory pass;
        pass.scheduled = scheduled;
        pass.guard = guardReading(marketId);
        pass.rate = _rate();
        uint256[] memory batch = _nextBatch(marketId, m.sweep.maxOrders);
        // Decided before the loop: orders that settle during it shrink the list, but the ones left out of this
        // batch still need the next sweep soon.
        bool rotating = _openOrders[marketId].length > batch.length;
        if (scheduled) (pass.share, pass.parkFee) = _batchCharges(batch, pass.rate);
        pass.reserveGas = _finishGas();
        pass.next = m.sweep.maxInterval;

        for (uint256 i; i < batch.length; ++i) {
            if (gasleft() < pass.reserveGas + costs.checkGas + costs.settleGas) {
                pass.next = m.sweep.minInterval;
                break;
            }
            _visit(batch[i], m, pass);
        }

        uint256 open = _openOrders[marketId].length;
        s.cursor = open == 0 ? 0 : ((s.cursor + batch.length) % open).toUint32();
        if (rotating) pass.next = m.sweep.minInterval;
        uint256 next = _backOff(m, s, pass.held, pass.next);
        emit SweepExecuted(marketId, scheduled, pass.guard.state, pass.checked, pass.filled, open);

        if (s.fundedOrders > 0 && (scheduled || _sweepIsDead(s))) _scheduleSweep(marketId, s, next);
    }

    /// @notice Restart a market's sweep chain if it stopped, e.g. because the vault could not pay a schedule.
    ///         Anyone may call it; the caller pays for scheduling the next sweep.
    function restartSweep(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        SweepState storage s = sweeps[marketId];
        if (s.fundedOrders == 0) revert NoFundedOrders(marketId);
        if (!_sweepIsDead(s)) revert SweepAlive(marketId, s.nextSweepAt);
        _scheduleSweep(marketId, s, m.sweep.minInterval);
    }

    /// @dev One order in a sweep: expire it, charge it (scheduled sweeps only), then fill it if its trigger is met
    ///      and the guard is open. Updates the pass's next wait: sooner for nearer triggers, back-off for holds.
    ///      Batches come from the open list, and only the current order settles in an iteration.
    function _visit(uint256 orderId, Market storage m, Pass memory pass) internal {
        Order storage o = _orders[orderId];
        if (block.timestamp >= o.expiry) {
            if (pass.scheduled) _debit(o, _gasToTinybar(costs.settleGas, pass.rate));
            _expire(orderId, o);
            return;
        }
        if (!o.funded) return;
        if (pass.scheduled && !_charge(orderId, o, pass.share, pass.parkFee, pass.rate)) return;
        pass.checked++;
        GuardReading memory g = pass.guard;
        uint256 distance;
        if (g.oraclePrice != 0) {
            (uint256 d, bytes32 newState, bool ok) = _evaluate(o, g.oraclePrice);
            if (!ok) {
                // A reverting or gas-starved strategy skips this order; keep checking soon so it recovers.
                emit OrderEvalSkipped(orderId);
                if (m.sweep.minInterval < pass.next) pass.next = m.sweep.minInterval;
                return;
            }
            if (newState != o.typeState) {
                o.typeState = newState; // e.g. a trailing stop raising its peak
                emit OrderStateUpdated(orderId, newState);
            }
            distance = d;
        }
        if (distance > 0) {
            uint256 wait = _delayFor(m, distance, o.expiry);
            if (wait < pass.next) pass.next = wait;
            return;
        }
        if (g.state != GuardState.Open) {
            pass.held = true;
            emit FillHeld(orderId, g.state, g.oraclePrice, g.poolPrice);
            return;
        }
        uint256 fillGas = _fillGas(m, o.side);
        if (pass.filled >= m.sweep.maxFills || gasleft() < pass.reserveGas + fillGas) {
            pass.next = m.sweep.minInterval;
            return;
        }
        if (pass.scheduled) _debit(o, _gasToTinybar(fillGas, pass.rate));
        if (_tryFill(orderId, g, gasleft() - pass.reserveGas)) pass.filled++;
        else pass.held = true;
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
        // The vault's own Chainlink-priced floor (value less the maker's slippage) always applies. A strategy's
        // minOut can only tighten it, never loosen it — so a hostile strategy cannot force a bad-price fill.
        uint256 minOut = PriceMath.lessBps(_valueAt(m, o.side, o.amountIn, oraclePrice), o.slippageBps);
        uint256 typeFloor = IOrderType(orderTypes[o.orderType]).minOut(o.side, o.amountIn, o.typeParam, oraclePrice);
        if (typeFloor > minOut) minOut = typeFloor;
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

    /// @notice HBAR (tinybar) charged to an order per scheduled check if it were the only funded order.
    function checkCost(uint256 marketId) public view returns (uint256) {
        _market(marketId);
        return _sweepShare(1, _rate());
    }

    /// @notice HBAR (tinybar) charged per check when `fundedOrders` orders share the sweep.
    function checkCostShared(uint256 fundedOrders) external view returns (uint256) {
        return _sweepShare(fundedOrders == 0 ? 1 : fundedOrders, _rate());
    }

    /// @notice HBAR (tinybar) an order always keeps back: its fill, plus its part of a final sweep.
    function fillCost(uint256 marketId, Side side) public view returns (uint256) {
        Market storage m = _market(marketId);
        return _gasToTinybar(_fillGas(m, side) + _tailGas(), _rate());
    }

    /// @notice Smallest budget accepted at placement: the reserve plus `MIN_CHECKS_FUNDED` solo checks.
    function minBudget(uint256 marketId, Side side) public view returns (uint256) {
        return _minBudget(_market(marketId), side, _rate());
    }

    /// @notice Seconds until an order of `orderType` with `typeParam` would next be checked, at today's price.
    /// @dev The same rule a sweep applies; the frontend uses it to size budgets. A fresh order carries no state,
    ///      so this reads the first-check delay. Held or triggered orders get `minInterval`.
    function nextCheckDelay(uint256 marketId, uint8 orderType, Side side, uint128 typeParam, uint256 expiry)
        external
        view
        returns (uint256)
    {
        Market storage m = _market(marketId);
        GuardReading memory g = guardReading(marketId);
        if (g.oraclePrice == 0 || orderType >= orderTypeCount) return m.sweep.minInterval;
        (uint256 distance,, bool ok) =
            _staticEvaluate(orderType, side, typeParam, bytes32(0), g.oraclePrice);
        return ok ? _delayFor(m, distance, expiry) : m.sweep.minInterval;
    }

    /// @dev `_evaluate` for an order that may not exist yet (nextCheckDelay for an unplaced order).
    function _staticEvaluate(uint8 orderType, Side side, uint128 typeParam, bytes32 state, uint256 oraclePrice)
        internal
        view
        returns (uint256 distance, bytes32 newState, bool ok)
    {
        try IOrderType(orderTypes[orderType]).evaluate{ gas: EVAL_GAS }(side, typeParam, state, oraclePrice) returns (
            uint256 d, bytes32 ns
        ) {
            return (d, ns, true);
        } catch {
            return (0, state, false);
        }
    }

    /// @notice Whether a market's checks are running. `Stalled` means funded orders are waiting but no
    ///         schedule will fire (the vault could not pay one, or it was missed); anyone may `restartSweep`.
    function sweepStatus(uint256 marketId) external view returns (SweepStatus status, uint256 nextSweepAt) {
        _market(marketId);
        SweepState storage s = sweeps[marketId];
        if (s.fundedOrders == 0) return (SweepStatus.Idle, 0);
        if (_sweepIsDead(s)) return (SweepStatus.Stalled, s.nextSweepAt);
        return (SweepStatus.Scheduled, s.nextSweepAt);
    }

    /// @notice Gas limit given to the next scheduled sweep: enough for the orders it will check today.
    /// @dev Hedera bills gas used, but the payer must hold gasLimit x price up front, so keep it tight.
    function sweepGasLimit(uint256 marketId) public view returns (uint256) {
        Market storage m = _market(marketId);
        uint256 orders = _openOrders[marketId].length;
        if (orders > m.sweep.maxOrders) orders = m.sweep.maxOrders;
        if (orders == 0) orders = 1;
        uint256 fills = orders < m.sweep.maxFills ? orders : m.sweep.maxFills;
        return _finishGas() + orders * (uint256(costs.checkGas) + costs.settleGas) + fills
            * (uint256(costs.fillGasTokenIn) + costs.settleGas);
    }

    /// @notice HBAR the vault keeps liquid to pay one scheduled sweep at execution, so a surplus withdrawal
    ///         can never leave a funded market unable to pay its own keeper. Sized to the costliest funded
    ///         market's sweep at the configured price. A residual stall (a gas-price spike past this reserve,
    ///         or HSS capacity saturation) is still possible and is what `restartSweep` recovers.
    function payerFloat() public view returns (uint256 float) {
        uint256 rate = _rate();
        uint256 n = marketCount;
        for (uint256 id = 1; id <= n; ++id) {
            if (sweeps[id].fundedOrders == 0) continue;
            uint256 need = _gasToTinybar(sweepGasLimit(id), rate);
            if (need > float) float = need;
        }
    }

    /// @notice HBAR the vault holds beyond what it owes: escrow, budgets, credits and the payer float.
    function surplus() public view returns (uint256) {
        uint256 owed = escrowed[HBAR] + totalBudgets + totalCredits[HBAR] + payerFloat();
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
        if (o.funded) {
            SweepState storage s = sweeps[o.marketId];
            // The last funded order leaving while a sweep is pending pays for that sweep's empty run.
            if (s.fundedOrders == 1 && !_sweepIsDead(s)) _debit(o, _gasToTinybar(costs.idleSweepGas, _rate()));
            s.fundedOrders--;
        }
        o.funded = false;
        budgetRefund = o.budget;
        o.budget = 0;
        totalBudgets -= budgetRefund;
        _removeOpen(o.marketId, orderId);
        _retireNft(orderId, holder);
        _pay(holder, HBAR, budgetRefund);
    }

    /// @dev Debit a scheduled check. When the budget would dip into the reserve, the order pays `parkFee`
    ///      (its part of this sweep, taken from the reserve) and is parked instead.
    function _charge(uint256 orderId, Order storage o, uint256 share, uint256 parkFee, uint256 rate)
        internal
        returns (bool)
    {
        if (o.budget < _reserve(o, rate) + share) {
            _debit(o, parkFee);
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

    /// @dev Budget an order never spends on routine checks: its fill, plus its share of a final sweep.
    function _reserve(Order storage o, uint256 rate) internal view returns (uint256) {
        return _gasToTinybar(_fillGas(_markets[o.marketId], o.side) + _tailGas(), rate);
    }

    /// @dev Ask an order's strategy for its distance-to-trigger and next state. View-only (staticcall, since
    ///      `evaluate` is pure), gas-capped and failure-tolerant: a strategy that reverts or burns its stipend
    ///      returns `ok == false`, so the sweep skips the order instead of bricking for everyone.
    function _evaluate(Order storage o, uint256 oraclePrice)
        internal
        view
        returns (uint256 distance, bytes32 newState, bool ok)
    {
        return _staticEvaluate(o.orderType, o.side, o.typeParam, o.typeState, oraclePrice);
    }

    /// @dev Distance only, for scheduling and views; a failed strategy reads as "far" (clamped so `_delayFor`'s
    ///      `distance * 1 hours` can't overflow), so it is scheduled at the market's longest interval.
    function _distanceOf(Order storage o, uint256 oraclePrice) internal view returns (uint256) {
        (uint256 d,, bool ok) = _evaluate(o, oraclePrice);
        return ok ? d : type(uint64).max;
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

    /// @dev Schedule the next sweep `delay` seconds out under a new epoch. The epoch only advances once
    ///      HSS accepts the schedule, so a failed attempt leaves any pending sweep valid.
    function _scheduleSweep(uint256 marketId, SweepState storage s, uint256 delay) internal {
        uint256 gasLimit = sweepGasLimit(marketId);
        uint256 at = _findCapacity(block.timestamp + delay, gasLimit);
        uint32 epoch = s.epoch + 1;
        (int64 rc, address schedule) =
            HSS.scheduleCall(address(this), at, gasLimit, 0, abi.encodeCall(this.sweep, (marketId, epoch)));
        if (rc != HTS_SUCCESS || schedule == address(0)) {
            emit SweepScheduleFailed(marketId, rc);
            return;
        }
        s.epoch = epoch;
        s.pendingSchedule = schedule;
        s.nextSweepAt = at.toUint40();
        emit SweepScheduled(marketId, schedule, at, epoch);
    }

    /// @dev Make sure a sweep looks at `o` in time: start the chain if it is dead, or bring it forward when
    ///      this order needs a check well before the pending one. The superseded sweep still fires and
    ///      returns at once; this order pays for that empty run. The caller pays the scheduling gas.
    function _ensureSweep(uint256 orderId, Order storage o, Market storage m, uint256 rate) internal {
        SweepState storage s = sweeps[o.marketId];
        GuardReading memory g = guardReading(o.marketId);
        uint256 delay = g.oraclePrice == 0 ? m.sweep.minInterval : _delayFor(m, _distanceOf(o, g.oraclePrice), o.expiry);
        bool dead = _sweepIsDead(s);
        if (!dead) {
            if (block.timestamp + delay + m.sweep.minInterval >= s.nextSweepAt) return;
            uint256 fee = _gasToTinybar(costs.idleSweepGas, rate);
            _debit(o, fee);
            emit SweepBroughtForward(orderId, fee, o.budget);
        }
        _scheduleSweep(o.marketId, s, delay);
    }

    /// @dev Wait until the price could plausibly have covered `distanceBps`, within the market's bounds and
    ///      never past the order's expiry (so expired orders are refunded promptly).
    function _delayFor(Market storage m, uint256 distanceBps, uint256 expiry) internal view returns (uint256 d) {
        d = (distanceBps * 1 hours) / m.sweep.maxMoveBpsPerHour;
        if (d > m.sweep.maxInterval) d = m.sweep.maxInterval;
        uint256 untilExpiry = expiry > block.timestamp ? expiry - block.timestamp : 0;
        if (d > untilExpiry) d = untilExpiry;
        if (d < m.sweep.minInterval) d = m.sweep.minInterval;
    }

    /// @dev A triggered order that could not fill (guard closed, or the swap failed) is retried after
    ///      minInterval x 2^streak, so a long guard closure doesn't burn budgets every few minutes.
    function _backOff(Market storage m, SweepState storage s, bool held, uint256 next) internal returns (uint256) {
        if (!held) {
            s.heldStreak = 0;
            return next;
        }
        if (s.heldStreak < MAX_HELD_STREAK) s.heldStreak++;
        uint256 wait = uint256(m.sweep.minInterval) << s.heldStreak;
        if (wait > m.sweep.maxInterval) wait = m.sweep.maxInterval;
        return wait < next ? wait : next;
    }

    /// @dev HIP-1215's suggested probe: exponential back-off with PRNG jitter so vaults don't stampede one second.
    function _findCapacity(uint256 target, uint256 gasLimit) internal view returns (uint256) {
        return Settlement.findCapacity(HSS, target, gasLimit, CAPACITY_PROBES);
    }

    function _sweepIsDead(SweepState storage s) internal view returns (bool) {
        return s.pendingSchedule == address(0) || block.timestamp > uint256(s.nextSweepAt) + SWEEP_GRACE;
    }

    /// @dev Charges for this scheduled sweep. `share` is each paying order's part: the fixed cost split over
    ///      the batch's orders that can afford it (recounted until stable) plus its own check. Orders that
    ///      can't afford it pay `parkFee` from their reserve: their own check, and when nobody can pay, an
    ///      even part of this final sweep too.
    function _batchCharges(uint256[] memory batch, uint256 rate)
        internal
        view
        returns (uint256 share, uint256 parkFee)
    {
        uint256 funded;
        for (uint256 i; i < batch.length; ++i) {
            if (_live(_orders[batch[i]])) funded++;
        }
        uint256 payers = funded;
        while (payers > 0) {
            share = _sweepShare(payers, rate);
            uint256 affordable;
            for (uint256 i; i < batch.length; ++i) {
                Order storage o = _orders[batch[i]];
                if (_live(o) && o.budget >= _reserve(o, rate) + share) affordable++;
            }
            if (affordable == payers) return (share, _gasToTinybar(costs.checkGas, rate));
            payers = affordable;
        }
        // Nobody can pay: this is the chain's last sweep. Price checks solo so every order parks.
        uint256 parkers = funded == 0 ? 1 : funded;
        return (
            _sweepShare(1, rate),
            _gasToTinybar((uint256(costs.sweepBaseGas) + parkers - 1) / parkers + costs.checkGas, rate)
        );
    }

    function _live(Order storage o) internal view returns (bool) {
        return o.status == Status.Open && o.funded && block.timestamp < o.expiry;
    }

    /// @dev Per-order charge for one scheduled check: an even share of the sweep's fixed cost plus its own check.
    function _sweepShare(uint256 fundedOrders, uint256 rate) internal view returns (uint256) {
        uint256 fixedGas = uint256(costs.scheduleGas) + costs.sweepBaseGas;
        return _gasToTinybar((fixedGas + fundedOrders - 1) / fundedOrders + costs.checkGas, rate);
    }

    function _minBudget(Market storage m, Side side, uint256 rate) internal view returns (uint256) {
        return _gasToTinybar(_fillGas(m, side) + _tailGas(), rate) + MIN_CHECKS_FUNDED * _sweepShare(1, rate);
    }

    /// @dev Gas a sweep keeps back so it can always reach the reschedule.
    function _finishGas() internal view returns (uint256) {
        return uint256(costs.scheduleGas) + costs.sweepBaseGas;
    }

    /// @dev The most one order can owe for the chain's final sweep: running it alone, with no reschedule.
    function _tailGas() internal view returns (uint256) {
        return uint256(costs.sweepBaseGas) + costs.checkGas;
    }

    function _fillGas(Market storage m, Side side) internal view returns (uint256) {
        (address tokenIn,) = _route(m, side);
        return uint256(tokenIn == HBAR ? costs.fillGasHbarIn : costs.fillGasTokenIn) + costs.settleGas;
    }

    /// @dev Tinybar for `gas` at the configured gas price plus the safety margin, using a cached `rate`.
    function _gasToTinybar(uint256 gas, uint256 rate) internal view returns (uint256) {
        uint256 tinycents = gas * costs.gasPriceTinycents;
        tinycents += (tinycents * costs.safetyBps) / PriceMath.BPS;
        return (tinycents * rate) / RATE_UNIT;
    }

    /// @dev Tinybar per RATE_UNIT tinycents from the 0x168 exchange-rate system contract. Read once per call.
    function _rate() internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            EXCHANGE_RATE.staticcall(abi.encodeCall(IExchangeRate.tinycentsToTinybars, (RATE_UNIT)));
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

    // The external-interaction layer (swap, HTS token/NFT ops, ERC-20 moves) lives in the Settlement library, so
    // the vault stays small and this code is linked rather than inlined. These are thin forwarders.
    function _swap(Market storage m, address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256)
    {
        return Settlement.swap(ROUTER, WHBAR, m.poolFee, tokenIn, tokenOut, amountIn, minOut);
    }

    // ---------------------------------------------------------------------------------------
    // Internal: tokens and NFTs
    // ---------------------------------------------------------------------------------------

    function _mintOrderNft(address to) internal returns (uint256 orderId) {
        return Settlement.mintNft(HTS, collection, to);
    }

    /// @dev Remove a settled order's NFT from circulation. Never reverts, so settlement can't be blocked.
    function _retireNft(uint256 orderId, address holder) internal {
        int64 rc = Settlement.retireNft(HTS, collection, orderId, holder);
        if (rc != HTS_SUCCESS) emit NftSettlementFailed(orderId, rc);
    }

    function _associate(address token) internal {
        Settlement.associate(HTS, token);
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        if (!Settlement.pullToken(token, from, address(this), amount)) revert TransferFailed();
    }

    function _transferToken(address token, address to, uint256 amount) internal returns (bool) {
        return Settlement.transferToken(token, to, amount);
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
        if (!MarketGuard.paramsValid(g, poolFee)) revert InvalidGuard();
    }

    function _validateSweep(SweepParams calldata p) internal pure {
        if (p.minInterval < MIN_SWEEP_INTERVAL || p.maxInterval > MAX_SWEEP_INTERVAL) revert InvalidSweep();
        if (p.minInterval > p.maxInterval || p.maxMoveBpsPerHour == 0) revert InvalidSweep();
        if (p.maxOrders == 0 || p.maxFills == 0 || p.maxFills > p.maxOrders) revert InvalidSweep();
    }

    /// @notice Receives HBAR the router unwraps when an order buys HBAR.
    receive() external payable {
        if (msg.sender != address(ROUTER)) revert NotRouter(msg.sender);
    }
}
