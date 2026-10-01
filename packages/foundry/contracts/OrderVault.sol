// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IHederaScheduleService } from "./interfaces/IHederaScheduleService.sol";
import { IHederaTokenService } from "./interfaces/IHederaTokenService.sol";
import { IExchangeRate } from "./interfaces/IExchangeRate.sol";
import { ISaucerSwapV2Router } from "./interfaces/ISaucerSwapV2.sol";
import { PriceMath } from "./libraries/PriceMath.sol";
import { MarketGuard } from "./libraries/MarketGuard.sol";
import { MarketRegistry } from "./libraries/MarketRegistry.sol";
import { OrderCollection } from "./libraries/OrderCollection.sol";
import { Settlement } from "./libraries/Settlement.sol";
import { SweepMath } from "./libraries/SweepMath.sol";
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
    SweepState
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

    uint256 internal constant MAX_HELD_STREAK = 8;
    uint256 internal constant CAPACITY_PROBES = 6;
    uint256 internal constant MAX_ORDER_LIFETIME = 90 days;
    /// @dev Gas stipend for a strategy's `evaluate`; capped so a gas-burning strategy can't brick a sweep.
    uint256 internal constant EVAL_GAS = 100_000;
    uint256 internal constant PAYOUT_GAS = 30_000;
    uint256 internal constant SWAP_DEADLINE = 300;

    /// @notice The SaucerSwap V2 SwapRouter every fill swaps through.
    ISaucerSwapV2Router public immutable ROUTER;
    /// @notice The WHBAR HTS token, used as the HBAR leg of swap routes.
    address public immutable WHBAR;

    /// @dev Working state of one sweep: its prices and charges, and what it found.
    struct Pass {
        bool scheduled;
        bool held;
        GuardReading guard;
        Costs c;
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
    /// @notice Gas figures and gas price the vault charges and schedules by; see `Costs`.
    Costs public costs;
    /// @notice Number of listed markets. Market ids run from 1 to `marketCount`.
    uint32 public marketCount;

    mapping(uint256 marketId => Market) internal _markets;
    /// @notice Each market's sweep chain; see `SweepState`.
    mapping(uint256 marketId => SweepState) public sweeps;
    mapping(uint256 marketId => uint256[]) internal _openOrders;
    mapping(uint256 orderId => uint256) internal _openIndexPlusOne;
    mapping(uint256 orderId => Order) internal _orders;

    /// @notice The order-type strategy registry. `orderTypes[id]` is a view-only `IOrderType`; `orderTypeActive`
    ///         gates whether NEW orders may use it. Append-only ids, so an order's bound type never changes.
    mapping(uint8 id => address impl) public orderTypes;
    /// @notice Whether new orders may use order type `id`.
    mapping(uint8 id => bool active) public orderTypeActive;
    /// @notice Number of registered order types. Ids run from 0 to `orderTypeCount - 1`.
    uint8 public orderTypeCount;

    /// @notice Tokens held on behalf of open orders, keyed by token (address(0) is HBAR).
    mapping(address token => uint256) public escrowed;
    /// @notice HBAR prepaid for scheduled checks and fills of open orders.
    uint256 public totalBudgets;
    /// @notice Payouts that could not be delivered and wait for `claim`.
    mapping(address account => mapping(address token => uint256)) public credits;
    /// @notice Sum of all accounts' `credits` in a token.
    mapping(address token => uint256) public totalCredits;

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    /// @notice `initialize` created the order NFT collection.
    /// @param collection The collection's token address.
    event CollectionCreated(address collection);
    /// @notice The owner listed a market.
    /// @param marketId The new market's id.
    /// @param base Base token address.
    /// @param quote Quote token address.
    /// @param pool The SaucerSwap V2 pool it trades on.
    /// @param poolFee The pool's fee, in hundredths of a basis point.
    event MarketListed(uint256 indexed marketId, address base, address quote, address pool, uint24 poolFee);
    /// @notice The owner changed a market's guard, sweep or active flag.
    /// @param marketId The market.
    event MarketUpdated(uint256 indexed marketId);
    /// @notice The costs were set, at deployment or by `setCosts`.
    /// @param costs The new costs.
    event CostsUpdated(Costs costs);
    /// @notice An order was placed and its NFT minted to the maker.
    /// @param orderId The order id (its NFT serial number).
    /// @param marketId The market.
    /// @param maker The caller, who received the order NFT.
    /// @param side Sell the base, or buy it.
    /// @param orderType The order-type id.
    /// @param amountIn Escrowed input, in the input token's raw units.
    /// @param typeParam The type's parameter (trigger price or trail).
    /// @param slippageBps Slippage tolerance, in bps.
    /// @param expiry Expiry time (unix seconds).
    /// @param budget Check budget in tinybar: msg.value, less `amountIn` for an HBAR input.
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
    /// @notice The owner registered an order type.
    /// @param id The type's id.
    /// @param impl The `IOrderType` implementation.
    event OrderTypeRegistered(uint8 indexed id, address impl);
    /// @notice An order type was enabled or disabled for new orders (registration also emits it, as enabled).
    /// @param id The type's id.
    /// @param active Whether new orders may use it.
    event OrderTypeActiveSet(uint8 indexed id, bool active);
    /// @notice A strategy returned new per-order state (e.g. a trailing stop raised its peak); the vault stored it.
    /// @dev Emitted by sweeps; `executeOrder` stores a new state without this event.
    /// @param orderId The order.
    /// @param state The stored state.
    event OrderStateUpdated(uint256 indexed orderId, bytes32 state);
    /// @notice A strategy reverted or ran out of its gas stipend during a sweep; the order was skipped, not filled.
    /// @param orderId The skipped order.
    event OrderEvalSkipped(uint256 indexed orderId);
    /// @notice An order filled.
    /// @param orderId The order.
    /// @param holder The NFT holder, who received the output.
    /// @param amountIn Input swapped, in the input token's raw units.
    /// @param amountOut Output received, in the output token's raw units.
    /// @param minAmountOut The floor the swap had to meet.
    /// @param oraclePrice Chainlink cross price at the fill (quote per 1 base, 8 decimals).
    /// @param poolPrice Pool TWAP price at the fill, same units.
    /// @param budgetRefund Unspent budget returned to the holder, in tinybar.
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
    /// @notice The holder cancelled an order.
    /// @param orderId The order.
    /// @param holder The NFT holder, who received the refunds.
    /// @param refund Escrow returned, in the input token's raw units.
    /// @param budgetRefund Unspent budget returned, in tinybar.
    event OrderCancelled(uint256 indexed orderId, address indexed holder, uint256 refund, uint256 budgetRefund);
    /// @notice An order reached its expiry unfilled and was refunded.
    /// @param orderId The order.
    /// @param holder The NFT holder, who received the refunds.
    /// @param refund Escrow returned, in the input token's raw units.
    /// @param budgetRefund Unspent budget returned, in tinybar.
    event OrderExpired(uint256 indexed orderId, address indexed holder, uint256 refund, uint256 budgetRefund);
    /// @notice A scheduled sweep charged an order for its check.
    /// @param orderId The order.
    /// @param charged Tinybar taken from its budget.
    /// @param budgetLeft Budget remaining, in tinybar.
    event OrderChecked(uint256 indexed orderId, uint256 charged, uint256 budgetLeft);
    /// @notice An order's trigger was met but the guard was not open, so it was not filled.
    /// @param orderId The order.
    /// @param reason The guard's verdict.
    /// @param oraclePrice Chainlink cross price (quote per 1 base, 8 decimals).
    /// @param poolPrice Pool TWAP price, same units.
    event FillHeld(uint256 indexed orderId, GuardState reason, uint256 oraclePrice, uint256 poolPrice);
    /// @notice A fill's swap reverted (for example, output below the floor); the order stays open.
    /// @param orderId The order.
    /// @param reason The revert data.
    event FillFailed(uint256 indexed orderId, bytes reason);
    /// @notice An order's budget can no longer pay for a check, so it was parked until a `topUp`.
    /// @param orderId The order.
    /// @param budgetLeft Budget remaining after the park fee, in tinybar.
    event BudgetExhausted(uint256 indexed orderId, uint256 budgetLeft);
    /// @notice HBAR was added to an order's budget.
    /// @param orderId The order.
    /// @param from Who paid.
    /// @param amount Tinybar added.
    /// @param budget The new budget, in tinybar.
    event BudgetToppedUp(uint256 indexed orderId, address indexed from, uint256 amount, uint256 budget);
    /// @notice The vault scheduled a market's next sweep with the Hedera Schedule Service.
    /// @param marketId The market.
    /// @param schedule The schedule's address.
    /// @param executeAt When it is due (unix seconds).
    /// @param epoch The epoch it carries.
    event SweepScheduled(uint256 indexed marketId, address schedule, uint256 executeAt, uint256 epoch);
    /// @notice A scheduled sweep carried an outdated epoch and returned without work.
    /// @param marketId The market.
    /// @param epoch The outdated epoch it carried.
    event SweepSuperseded(uint256 indexed marketId, uint256 epoch);
    /// @notice An order needed a check sooner than the pending sweep and paid for the superseded run.
    /// @param orderId The order.
    /// @param charged Tinybar taken from its budget.
    /// @param budgetLeft Budget remaining, in tinybar.
    event SweepBroughtForward(uint256 indexed orderId, uint256 charged, uint256 budgetLeft);
    /// @notice The Hedera Schedule Service refused a sweep schedule; any pending sweep stays valid.
    /// @param marketId The market.
    /// @param responseCode The response code returned.
    event SweepScheduleFailed(uint256 indexed marketId, int64 responseCode);
    /// @notice A sweep ran.
    /// @param marketId The market.
    /// @param scheduled True for a scheduled sweep, false for a manual call.
    /// @param guard The guard's verdict during the sweep.
    /// @param checked Orders checked.
    /// @param filled Orders filled.
    /// @param openOrders Open orders left in the market.
    event SweepExecuted(
        uint256 indexed marketId, bool scheduled, GuardState guard, uint256 checked, uint256 filled, uint256 openOrders
    );
    /// @notice A payout could not be delivered and was credited for `claim`.
    /// @param account The recipient.
    /// @param token The token; address(0) for HBAR.
    /// @param amount Amount credited, in the token's raw units.
    event Credited(address indexed account, address indexed token, uint256 amount);
    /// @notice An account claimed its credit.
    /// @param account The claimer.
    /// @param token The token; address(0) for HBAR.
    /// @param amount Amount paid out, in the token's raw units.
    event Claimed(address indexed account, address indexed token, uint256 amount);
    /// @notice Retiring a settled order's NFT failed; the settlement itself went through.
    /// @param orderId The order.
    /// @param responseCode The HTS response code.
    event NftSettlementFailed(uint256 indexed orderId, int64 responseCode);
    /// @notice The owner withdrew surplus HBAR.
    /// @param to The recipient.
    /// @param amount Tinybar sent.
    event SurplusWithdrawn(address indexed to, uint256 amount);
    /// @notice Someone endowed the vault through `fund`.
    /// @param from Who paid.
    /// @param amount Tinybar received.
    event Funded(address indexed from, uint256 amount);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    /// @notice `initialize` was called after the collection already exists.
    error AlreadyInitialized();
    /// @notice An order was placed before `initialize` created the collection.
    error NotInitialized();
    /// @notice No market is listed under this id.
    /// @param marketId The id asked for.
    error UnknownMarket(uint256 marketId);
    /// @notice The market is paused for new orders.
    /// @param marketId The market.
    error MarketInactive(uint256 marketId);
    /// @notice `listMarket` got a zero pool, token or feed address, the same token twice, or two HBAR legs.
    /// @dev Raised by `MarketRegistry` when listing or tuning a market; declared here so the vault's ABI decodes them.
    error InvalidMarket();
    /// @notice Guard settings outside the `GuardParams` bounds (raised by `MarketRegistry`).
    error InvalidGuard();
    /// @notice Sweep settings outside the `SweepParams` bounds (raised by `MarketRegistry`).
    error InvalidSweep();
    /// @notice Costs failing the `setCosts` checks, or the 0x168 exchange-rate system contract did not answer.
    error InvalidCosts();
    /// @notice A zero `amountIn`, a `topUp` with no value, or a `withdrawSurplus` with no surplus.
    error InvalidAmount();
    /// @notice Not raised by this vault; declared so its ABI still decodes the earlier fixed-trigger vault's error
    ///         for a zero trigger price.
    error InvalidTrigger();
    /// @notice No order type is registered under this id.
    /// @param id The id asked for.
    error UnknownOrderType(uint8 id);
    /// @notice The order type is disabled for new orders.
    /// @param id The type's id.
    error OrderTypeInactive(uint8 id);
    /// @notice The order type's `validate` rejected the parameters, or `registerOrderType` got the zero address.
    error InvalidOrderParams();
    /// @notice The order's slippage is outside the market's bounds.
    /// @param slippageBps The slippage given, in bps.
    /// @param minBps The smallest accepted: the pool fee in bps (`poolFee / 100`) plus 1.
    /// @param maxBps The largest accepted: the market's `guard.maxSlippageBps`.
    error InvalidSlippage(uint256 slippageBps, uint256 minBps, uint256 maxBps);
    /// @notice The expiry is not after the current block, or more than 90 days ahead.
    /// @param expiry The expiry given.
    error InvalidExpiry(uint256 expiry);
    /// @notice The check budget is below the minimum (`OrderVaultLens.minBudget`).
    /// @param provided The budget sent, in tinybar.
    /// @param required The minimum, in tinybar.
    error InsufficientBudget(uint256 provided, uint256 required);
    /// @notice An HBAR-input order sent less value than its `amountIn`.
    /// @param sent msg.value, in tinybar.
    /// @param expected The order's `amountIn`.
    error WrongValue(uint256 sent, uint256 expected);
    /// @notice The order is not open (unknown, filled, cancelled or expired).
    /// @param orderId The order.
    error OrderNotOpen(uint256 orderId);
    /// @notice The caller does not hold the order's NFT.
    /// @param orderId The order.
    /// @param caller The caller.
    error NotHolder(uint256 orderId, address caller);
    /// @notice `fillFromVault` was called by someone other than the vault.
    error OnlySelf();
    /// @notice The caller has no credit in this token.
    error NothingToClaim();
    /// @notice An HBAR send or a token transfer failed.
    error TransferFailed();
    /// @notice `restartSweep` was called while a sweep is still pending.
    /// @param marketId The market.
    /// @param nextSweepAt When the pending sweep is due (unix seconds).
    error SweepAlive(uint256 marketId, uint256 nextSweepAt);
    /// @notice `restartSweep` was called for a market with no funded orders.
    /// @param marketId The market.
    error NoFundedOrders(uint256 marketId);
    /// @notice HBAR arrived through `receive` from someone other than the router; use `fund` instead.
    /// @param sender The sender.
    error NotRouter(address sender);

    // ---------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------

    /// @notice Deploy the vault. `initialize` must create the order NFT collection before orders can be placed.
    /// @param owner_ Initial owner (`Ownable2Step`). Non-zero.
    /// @param router_ SaucerSwap V2 SwapRouter.
    /// @param whbar_ WHBAR HTS token, used as the HBAR leg of routes.
    /// @param costs_ Initial costs; same bounds as `setCosts`.
    /// @dev Reverts `OwnableInvalidOwner` if `owner_` is zero.
    /// @dev Reverts `InvalidCosts` if `costs_` fails the `setCosts` checks.
    constructor(address owner_, ISaucerSwapV2Router router_, address whbar_, Costs memory costs_) Ownable(owner_) {
        ROUTER = router_;
        WHBAR = whbar_;
        _setCosts(costs_);
    }

    /// @notice Create the order NFT collection. The vault is treasury and holds the supply and wipe keys.
    /// @dev Send the HTS creation fee as value (about 15 HBAR on testnet); any excess stays as surplus.
    /// @param name Collection name.
    /// @param symbol Collection symbol.
    /// @dev Reverts `AlreadyInitialized` if the collection already exists.
    /// @dev Reverts `HtsError` (`CreateCollection`) if HTS refuses to create it.
    function initialize(string calldata name, string calldata symbol) external payable onlyOwner {
        if (collection != address(0)) revert AlreadyInitialized();
        (int64 rc, address created) = OrderCollection.create(name, symbol, msg.value);
        if (rc != HTS_SUCCESS) revert HtsError(HtsOperation.CreateCollection, rc);
        collection = created;
        emit CollectionCreated(created);
    }

    /// @notice List a market and associate the vault with its HTS tokens. Validation and the storage write live
    ///         in `MarketRegistry`; the bounds keep a market's guard from being switched off.
    /// @param market The market; `Market`, `GuardParams` and `SweepParams` give each field's bounds.
    /// @return marketId The new market's id; ids start at 1.
    /// @dev Reverts `InvalidMarket` for a zero pool, token or feed address, the same token twice, or two HBAR legs.
    /// @dev Reverts `InvalidGuard` or `InvalidSweep` when the guard or sweep settings are out of bounds.
    /// @dev Reverts `HtsError` (`Associate`) if the vault cannot associate with a market token.
    function listMarket(Market calldata market) external onlyOwner returns (uint256 marketId) {
        marketId = ++marketCount;
        MarketRegistry.list(_markets[marketId], market);
        emit MarketListed(marketId, market.base, market.quote, address(market.pool), market.poolFee);
    }

    /// @notice Tune a market's guard and sweep. Bounds keep the guard from being switched off.
    /// @param marketId A listed market.
    /// @param guard New guard settings (bounds in `GuardParams`); the slippage floor uses the stored `poolFee`.
    /// @param sweepParams New sweep settings (bounds in `SweepParams`).
    /// @param active Whether new orders may be placed. Open orders keep being checked either way.
    /// @dev Reverts `UnknownMarket` if the market is not listed.
    /// @dev Reverts `InvalidGuard` or `InvalidSweep` when the settings are out of bounds.
    function updateMarket(uint256 marketId, GuardParams calldata guard, SweepParams calldata sweepParams, bool active)
        external
        onlyOwner
    {
        MarketRegistry.update(_market(marketId), guard, sweepParams, active);
        emit MarketUpdated(marketId);
    }

    /// @notice Replace the gas figures and gas price the vault charges and schedules by.
    /// @param costs_ New costs: `scheduleGas`, `checkGas`, `fillGasHbarIn`, `fillGasTokenIn` and `gasPriceTinycents`
    ///        non-zero, and `safetyBps` at most 10,000.
    /// @dev Reverts `InvalidCosts` if any of those checks fails.
    function setCosts(Costs calldata costs_) external onlyOwner {
        _setCosts(costs_);
    }

    /// @notice Register a view-only order-type strategy and return its id. Append-only: ids are never reused, so
    ///         an order's bound type can never change under it. The new type is active for new orders at once.
    /// @param impl The `IOrderType` implementation. Non-zero.
    /// @return id The new type's id: the previous `orderTypeCount`. The uint8 counter allows 255 types (ids 0 to 254).
    /// @dev Reverts `InvalidOrderParams` if `impl` is the zero address.
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
    /// @param id A registered order-type id.
    /// @param active Whether new orders may use it.
    /// @dev Reverts `UnknownOrderType` if `id` is not registered.
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
    /// @param to Recipient of the surplus (`OrderVaultLens.surplus` previews the amount).
    /// @dev Reverts `InvalidAmount` when there is no surplus.
    /// @dev Reverts `TransferFailed` if `to` does not accept the HBAR.
    function withdrawSurplus(address payable to) external onlyOwner nonReentrant {
        uint256 amount = _surplus();
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
    ///      The caller needs auto-association slots or an association with `collection`. A token input needs an
    ///      allowance of `amountIn` to the vault.
    /// @param p The order; `PlaceParams` gives each field's bounds.
    /// @return orderId The new order's id, which is its NFT serial number.
    /// @dev Reverts `NotInitialized` before `initialize`.
    /// @dev Reverts `UnknownMarket` or `MarketInactive` if the market is not listed or is paused.
    /// @dev Reverts `InvalidAmount` if `amountIn` is 0.
    /// @dev Reverts `UnknownOrderType` or `OrderTypeInactive` if the type is not registered or is disabled.
    /// @dev Reverts `InvalidOrderParams` if the type's `validate` rejects the parameters.
    /// @dev Reverts `InvalidSlippage` unless `slippageBps` is above `poolFee / 100` and at most `guard.maxSlippageBps`.
    /// @dev Reverts `InvalidExpiry` unless the expiry is after the current block and at most 90 days ahead.
    /// @dev Reverts `WrongValue` if msg.value is below `amountIn` for an HBAR input.
    /// @dev Reverts `InsufficientBudget` if the budget is below `OrderVaultLens.minBudget`.
    /// @dev Reverts `TransferFailed` if pulling the input token fails.
    /// @dev Reverts `HtsError` (`Mint` or `TransferNft`) if minting the order NFT or sending it to the caller fails.
    function placeOrder(PlaceParams calldata p) external payable nonReentrant returns (uint256 orderId) {
        if (collection == address(0)) revert NotInitialized();
        Market storage m = _market(p.marketId);
        if (!m.active) revert MarketInactive(p.marketId);
        if (p.amountIn == 0) revert InvalidAmount();
        if (p.orderType >= orderTypeCount) revert UnknownOrderType(p.orderType);
        if (!orderTypeActive[p.orderType]) revert OrderTypeInactive(p.orderType);
        IOrderType impl = IOrderType(orderTypes[p.orderType]);
        uint40 now_ = block.timestamp.toUint40();
        if (!impl.validate(p.side, p.amountIn, p.typeParam, p.slippageBps, p.expiry, now_)) {
            revert InvalidOrderParams();
        }
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
        Costs memory c = costs;
        uint256 rate = _rate();
        uint256 required = SweepMath.minBudget(c, tokenIn == HBAR, rate);
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

        _ensureSweep(orderId, _orders[orderId], m, c, rate);
    }

    /// @notice Cancel an open order; escrow and unused budget go back to the NFT holder.
    /// @param orderId An open order whose NFT the caller holds.
    /// @dev Reverts `OrderNotOpen` if the order is not open.
    /// @dev Reverts `NotHolder` if the caller does not hold the order's NFT.
    /// @custom:access The order NFT's holder.
    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _openOrder(orderId);
        address holder = holderOf(orderId);
        if (holder != msg.sender) revert NotHolder(orderId, msg.sender);
        (uint256 refund, uint256 budgetRefund) = _close(orderId, o, Status.Cancelled, holder);
        emit OrderCancelled(orderId, holder, refund, budgetRefund);
    }

    /// @notice Add HBAR to an order's check budget. Anyone may top up any order.
    /// @dev msg.value is added to the budget. A parked order counts as funded again once its budget covers its
    ///      reserve plus one solo check; for a funded order, the market's sweep is started or brought forward
    ///      if needed.
    /// @param orderId An open order.
    /// @dev Reverts `InvalidAmount` if msg.value is 0.
    /// @dev Reverts `OrderNotOpen` if the order is not open.
    function topUp(uint256 orderId) external payable nonReentrant {
        if (msg.value == 0) revert InvalidAmount();
        Order storage o = _openOrder(orderId);
        o.budget += msg.value.toUint128();
        totalBudgets += msg.value;
        Costs memory c = costs;
        uint256 rate = _rate();
        if (!o.funded && o.budget >= _reserve(o, c, rate) + SweepMath.sweepShare(c, 1, rate)) {
            o.funded = true;
            sweeps[o.marketId].fundedOrders++;
        }
        emit BudgetToppedUp(orderId, msg.sender, msg.value, o.budget);
        if (o.funded) _ensureSweep(orderId, o, _markets[o.marketId], c, rate);
    }

    /// @notice Check one order now and fill or expire it if due. The caller pays gas; the budget is untouched.
    /// @param orderId An open order.
    /// @return settled True if the order expired (and was refunded) or filled; false if its trigger is not met, the
    ///         guard is not open, the oracle price is unusable, its strategy failed or the swap failed.
    /// @dev A failed swap does not revert: it emits `FillFailed` and returns false.
    /// @dev Reverts `OrderNotOpen` if the order is not open.
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
    /// @param token The token to claim; address(0) for HBAR.
    /// @dev Reverts `NothingToClaim` if the caller has no credit in `token`.
    /// @dev Reverts `TransferFailed` if the payout fails again.
    /// @custom:access Anyone, for their own credits.
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
    ///      paid by the caller, debit nothing and ignore `epoch`. A manual call schedules the next sweep only when
    ///      the chain is dead (see `restartSweep`).
    /// @param marketId A listed market.
    /// @param epoch The epoch a scheduled call was created under; manual calls may pass any value.
    /// @dev Reverts `UnknownMarket` if the market is not listed.
    /// @custom:access Anyone. The Hedera Schedule Service calls it as the vault itself (a scheduled sweep).
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
        pass.c = costs;
        pass.rate = _rate();
        uint256[] memory batch = _nextBatch(marketId, m.sweep.maxOrders);
        // Decided before the loop: orders that settle during it shrink the list, but the ones left out of this
        // batch still need the next sweep soon.
        bool rotating = _openOrders[marketId].length > batch.length;
        if (scheduled) (pass.share, pass.parkFee) = _batchCharges(batch, pass.c, pass.rate);
        pass.reserveGas = SweepMath.finishGas(pass.c);
        pass.next = m.sweep.maxInterval;

        for (uint256 i; i < batch.length; ++i) {
            if (gasleft() < pass.reserveGas + pass.c.checkGas + pass.c.settleGas) {
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

        if (s.fundedOrders > 0 && (scheduled || _sweepIsDead(s))) _scheduleSweep(marketId, s, pass.c, next);
    }

    /// @notice Restart a market's sweep chain if it stopped, e.g. because the vault could not pay a schedule.
    ///         Anyone may call it; the caller pays for scheduling the next sweep.
    /// @dev The chain is dead when no schedule is pending, or the pending one is more than 120 seconds overdue
    ///      (`SweepMath.SWEEP_GRACE`). The new sweep is scheduled `minInterval` seconds out.
    /// @param marketId A listed market with funded orders.
    /// @dev Reverts `UnknownMarket` if the market is not listed.
    /// @dev Reverts `NoFundedOrders` if no funded order is waiting.
    /// @dev Reverts `SweepAlive` if a sweep is still pending.
    function restartSweep(uint256 marketId) external nonReentrant {
        Market storage m = _market(marketId);
        SweepState storage s = sweeps[marketId];
        if (s.fundedOrders == 0) revert NoFundedOrders(marketId);
        if (!_sweepIsDead(s)) revert SweepAlive(marketId, s.nextSweepAt);
        _scheduleSweep(marketId, s, costs, m.sweep.minInterval);
    }

    /// @dev One order in a sweep: expire it, charge it (scheduled sweeps only), then fill it if its trigger is met
    ///      and the guard is open. Updates the pass's next wait: sooner for nearer triggers, back-off for holds.
    ///      Batches come from the open list, and only the current order settles in an iteration.
    function _visit(uint256 orderId, Market storage m, Pass memory pass) internal {
        Order storage o = _orders[orderId];
        if (block.timestamp >= o.expiry) {
            if (pass.scheduled) _debit(o, SweepMath.gasToTinybar(pass.c, pass.c.settleGas, pass.rate));
            _expire(orderId, o);
            return;
        }
        if (!o.funded) return;
        if (pass.scheduled && !_charge(orderId, o, pass)) return;
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
        (address tokenIn,) = _route(m, o.side);
        uint256 fillGas = SweepMath.fillGas(pass.c, tokenIn == HBAR);
        if (pass.filled >= m.sweep.maxFills || gasleft() < pass.reserveGas + fillGas) {
            pass.next = m.sweep.minInterval;
            return;
        }
        if (pass.scheduled) _debit(o, SweepMath.gasToTinybar(pass.c, fillGas, pass.rate));
        if (_tryFill(orderId, g, gasleft() - pass.reserveGas)) pass.filled++;
        else pass.held = true;
    }

    /// @notice Settle a fill. Only callable by the vault itself, so a failed swap can be caught.
    /// @dev The swap's floor is the Chainlink value of `amountIn` less the order's slippage, or the order type's
    ///      `minOut` when that is higher.
    /// @param orderId The order to fill.
    /// @param oraclePrice Chainlink cross price the floor is computed from (quote per 1 base, 8 decimals).
    /// @param poolPrice Pool TWAP price, reported in `OrderFilled`.
    /// @return amountOut Output paid to the holder (or credited for `claim`), in the output token's raw units.
    /// @dev Reverts `OnlySelf` for any other caller. A swap below the floor reverts in the router.
    /// @custom:access The vault itself only.
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

    /// @notice A listed market's configuration.
    /// @param marketId A listed market (1 to `marketCount`).
    /// @return The market.
    /// @dev Reverts `UnknownMarket` if the market is not listed.
    function getMarket(uint256 marketId) external view returns (Market memory) {
        return _market(marketId);
    }

    /// @notice An order as stored. Settled orders keep their record; an unknown id returns all zeros (`Status.None`).
    /// @param orderId The order id (its NFT serial number).
    /// @return The order.
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Ids of a market's open orders, in the list order sweeps rotate through from `sweeps(marketId).cursor`.
    /// @param marketId The market; an unlisted one returns an empty list.
    /// @return The open order ids.
    function openOrders(uint256 marketId) external view returns (uint256[] memory) {
        return _openOrders[marketId];
    }

    /// @notice Current holder of an order's NFT: the account that can cancel it and receives its proceeds.
    /// @param orderId The order id.
    /// @return The holder, from the collection's ERC-721 `ownerOf`.
    function holderOf(uint256 orderId) public view returns (address) {
        return IERC721(collection).ownerOf(orderId);
    }

    /// @notice Chainlink price, pool TWAP price and the guard verdict for a market.
    /// @param marketId A listed market.
    /// @return The reading; see `GuardReading`.
    /// @dev Reverts `UnknownMarket` if the market is not listed.
    function guardReading(uint256 marketId) public view returns (GuardReading memory) {
        return MarketGuard.read(_market(marketId));
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
            if (s.fundedOrders == 1 && !_sweepIsDead(s)) {
                Costs memory c = costs;
                _debit(o, SweepMath.gasToTinybar(c, c.idleSweepGas, _rate()));
            }
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
    function _charge(uint256 orderId, Order storage o, Pass memory pass) internal returns (bool) {
        uint256 share = pass.share;
        if (o.budget < _reserve(o, pass.c, pass.rate) + share) {
            _debit(o, pass.parkFee);
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
    function _reserve(Order storage o, Costs memory c, uint256 rate) internal view returns (uint256) {
        (address tokenIn,) = _route(_markets[o.marketId], o.side);
        return SweepMath.reserve(c, tokenIn == HBAR, rate);
    }

    /// @dev Ask an order's strategy for its distance-to-trigger and next state. View-only (staticcall, since
    ///      `evaluate` is pure), gas-capped and failure-tolerant: a strategy that reverts or burns its stipend
    ///      returns `ok == false`, so the sweep skips the order instead of bricking for everyone.
    function _evaluate(Order storage o, uint256 oraclePrice)
        internal
        view
        returns (uint256 distance, bytes32 newState, bool ok)
    {
        bytes32 state = o.typeState;
        try IOrderType(orderTypes[o.orderType]).evaluate{ gas: EVAL_GAS }(
            o.side, o.typeParam, state, oraclePrice
        ) returns (
            uint256 d, bytes32 ns
        ) {
            return (d, ns, true);
        } catch {
            return (0, state, false);
        }
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
    function _scheduleSweep(uint256 marketId, SweepState storage s, Costs memory c, uint256 delay) internal {
        uint256 gasLimit = _sweepGasLimit(marketId, c);
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
    function _ensureSweep(uint256 orderId, Order storage o, Market storage m, Costs memory c, uint256 rate) internal {
        SweepState storage s = sweeps[o.marketId];
        GuardReading memory g = guardReading(o.marketId);
        uint256 delay = g.oraclePrice == 0 ? m.sweep.minInterval : _delayFor(m, _distanceOf(o, g.oraclePrice), o.expiry);
        bool dead = _sweepIsDead(s);
        if (!dead) {
            if (block.timestamp + delay + m.sweep.minInterval >= s.nextSweepAt) return;
            uint256 fee = SweepMath.gasToTinybar(c, c.idleSweepGas, rate);
            _debit(o, fee);
            emit SweepBroughtForward(orderId, fee, o.budget);
        }
        _scheduleSweep(o.marketId, s, c, delay);
    }

    /// @dev Wait until the price could plausibly have covered `distanceBps`, within the market's bounds and
    ///      never past the order's expiry (so expired orders are refunded promptly).
    function _delayFor(Market storage m, uint256 distanceBps, uint256 expiry) internal view returns (uint256) {
        return SweepMath.delayFor(m.sweep, distanceBps, expiry, block.timestamp);
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
    ///      Returns an expiry with capacity for `gasLimit`, or `target` if none is found. Inline rather than in a
    ///      library: every rescheduling sweep runs it, and a library call would add a cold delegatecall each time.
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
        return SweepMath.isDead(s.pendingSchedule, s.nextSweepAt, block.timestamp);
    }

    /// @dev Charges for this scheduled sweep (see `SweepMath.batchCharges`), from the batch's live orders.
    function _batchCharges(uint256[] memory batch, Costs memory c, uint256 rate)
        internal
        view
        returns (uint256 share, uint256 parkFee)
    {
        SweepMath.ChargeInput[] memory orders = new SweepMath.ChargeInput[](batch.length);
        for (uint256 i; i < batch.length; ++i) {
            Order storage o = _orders[batch[i]];
            if (_live(o)) orders[i] = SweepMath.ChargeInput(true, o.budget, _reserve(o, c, rate));
        }
        return SweepMath.batchCharges(c, rate, orders);
    }

    function _live(Order storage o) internal view returns (bool) {
        return o.status == Status.Open && o.funded && block.timestamp < o.expiry;
    }

    /// @dev Gas limit given to a market's next scheduled sweep: enough for the orders it will check today.
    ///      Hedera bills gas used, but the payer must hold gasLimit x price up front, so keep it tight.
    function _sweepGasLimit(uint256 marketId, Costs memory c) internal view returns (uint256) {
        return SweepMath.sweepGasLimit(c, _markets[marketId].sweep, _openOrders[marketId].length);
    }

    /// @dev HBAR the vault keeps liquid to pay one scheduled sweep at execution, so a surplus withdrawal can
    ///      never leave a funded market unable to pay its own keeper. Sized to the costliest funded market's
    ///      sweep at the configured price. A residual stall (a gas-price spike past this reserve, or HSS
    ///      capacity saturation) is still possible and is what `restartSweep` recovers.
    function _payerFloat() internal view returns (uint256 float) {
        Costs memory c = costs;
        uint256 rate = _rate();
        uint256 n = marketCount;
        for (uint256 id = 1; id <= n; ++id) {
            if (sweeps[id].fundedOrders == 0) continue;
            uint256 need = SweepMath.gasToTinybar(c, _sweepGasLimit(id, c), rate);
            if (need > float) float = need;
        }
    }

    /// @dev HBAR the vault holds beyond what it owes: escrow, budgets, credits and the payer float.
    function _surplus() internal view returns (uint256) {
        uint256 owed = escrowed[HBAR] + totalBudgets + totalCredits[HBAR] + _payerFloat();
        return address(this).balance > owed ? address(this).balance - owed : 0;
    }

    /// @dev Tinybar per RATE_UNIT tinycents from the 0x168 exchange-rate system contract. Read once per call.
    function _rate() internal view returns (uint256) {
        (bool ok, bytes memory ret) =
            EXCHANGE_RATE.staticcall(abi.encodeCall(IExchangeRate.tinycentsToTinybars, (SweepMath.RATE_UNIT)));
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

    /// @notice Receives HBAR the router unwraps when an order buys HBAR.
    /// @dev Reverts `NotRouter` for any other sender; endow the vault through `fund`.
    /// @custom:access The SaucerSwap router only.
    receive() external payable {
        if (msg.sender != address(ROUTER)) revert NotRouter(msg.sender);
    }
}
