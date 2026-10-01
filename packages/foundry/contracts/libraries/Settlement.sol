// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHederaTokenService } from "../interfaces/IHederaTokenService.sol";
import { IHederaScheduleService } from "../interfaces/IHederaScheduleService.sol";
import { ISaucerSwapV2Router } from "../interfaces/ISaucerSwapV2.sol";
import { HtsError, HtsOperation } from "../types/OrderTypes.sol";

/// @title Settlement — the vault's external-interaction layer.
/// @notice The SaucerSwap swap, the HTS token and order-NFT operations, ERC-20 moves, and the HSS capacity probe.
///         It is an external library (its own deployed code, linked like `MarketGuard`/`OrderCollection`), so this
///         call-encoding-heavy code lives outside `OrderVault` and the vault stays under the 24 KB limit with room
///         to spare. The vault keeps the readable sweep → evaluate → guard → fill flow and calls here only for the
///         external interactions; it still enforces the guard and its own Chainlink slippage floor before any swap.
library Settlement {
    int64 internal constant HTS_SUCCESS = 22;
    int64 internal constant HTS_ALREADY_ASSOCIATED = 194;
    address internal constant HBAR = address(0);
    uint256 internal constant SWAP_DEADLINE = 300;

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut` on SaucerSwap V2, requiring at least `minOut`. For an
    ///         HBAR leg, WHBAR is used and the router wraps/unwraps. The caller has already checked escrow and set
    ///         `minOut` from Chainlink, so the swap's own `amountOutMinimum` is the final price protection.
    function swap(
        ISaucerSwapV2Router router,
        address whbar,
        uint24 poolFee,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) public returns (uint256 amountOut) {
        ISaucerSwapV2Router.ExactInputSingleParams memory params =
            ISaucerSwapV2Router.ExactInputSingleParams({
                tokenIn: tokenIn == HBAR ? whbar : tokenIn,
                tokenOut: tokenOut == HBAR ? whbar : tokenOut,
                fee: poolFee,
                recipient: tokenOut == HBAR ? address(router) : address(this),
                deadline: block.timestamp + SWAP_DEADLINE,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });
        if (tokenIn != HBAR) {
            if (!IERC20(tokenIn).approve(address(router), amountIn)) revert TransferRejected();
        }
        uint256 value = tokenIn == HBAR ? amountIn : 0;
        if (tokenOut == HBAR) {
            bytes[] memory calls = new bytes[](2);
            calls[0] = abi.encodeCall(ISaucerSwapV2Router.exactInputSingle, (params));
            calls[1] = abi.encodeCall(ISaucerSwapV2Router.unwrapWHBAR, (minOut, address(this)));
            bytes[] memory results = router.multicall{ value: value }(calls);
            amountOut = abi.decode(results[0], (uint256));
        } else {
            amountOut = router.exactInputSingle{ value: value }(params);
        }
    }

    error TransferRejected();

    /// @notice Mint one order NFT in `collection` and transfer it to `to`. The serial is the order id.
    function mintNft(IHederaTokenService hts, address collection, address to) public returns (uint256 orderId) {
        bytes[] memory metadata = new bytes[](1);
        metadata[0] = bytes("saucerswap-limit-order");
        (int64 rc,, int64[] memory serials) = hts.mintToken(collection, 0, metadata);
        if (rc != HTS_SUCCESS) revert HtsError(HtsOperation.Mint, rc);
        rc = hts.transferNFT(collection, address(this), to, serials[0]);
        if (rc != HTS_SUCCESS) revert HtsError(HtsOperation.TransferNft, rc);
        orderId = uint256(uint64(serials[0]));
    }

    /// @notice Retire a settled order's NFT (burn if the vault holds it, else wipe from the holder). Never reverts;
    ///         returns the response code so the vault can report a failure through an event without blocking settle.
    function retireNft(IHederaTokenService hts, address collection, uint256 orderId, address holder)
        public
        returns (int64 rc)
    {
        int64[] memory serials = new int64[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        serials[0] = int64(uint64(orderId));
        if (holder == address(this)) {
            (rc,) = hts.burnToken(collection, 0, serials);
        } else {
            rc = hts.wipeTokenAccountNFT(collection, holder, serials);
        }
    }

    /// @notice Associate the vault with an HTS token (idempotent).
    function associate(IHederaTokenService hts, address token) public {
        int64 rc = hts.associateToken(address(this), token);
        if (rc != HTS_SUCCESS && rc != HTS_ALREADY_ASSOCIATED) revert HtsError(HtsOperation.Associate, rc);
    }

    /// @notice Pull `amount` of `token` from `from` to the vault; returns false on a failed or false-returning move.
    function pullToken(address token, address from, address to, uint256 amount) public returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @notice Send `amount` of `token` to `to`; returns false on a failed or false-returning move.
    function transferToken(address token, address to, uint256 amount) public returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @notice HIP-1215's suggested probe: exponential back-off with PRNG jitter so vaults don't stampede one
    ///         second. Returns an expiry with capacity for `gasLimit`, or `target` if none is found in `probes`.
    function findCapacity(IHederaScheduleService hss, uint256 target, uint256 gasLimit, uint256 probes)
        public
        view
        returns (uint256)
    {
        if (hss.hasScheduleCapacity(target, gasLimit)) return target;
        bytes32 seed = bytes32(block.prevrandao);
        for (uint256 i; i < probes; ++i) {
            uint256 backoff = 2 ** i;
            uint256 candidate = target + backoff + (uint256(keccak256(abi.encodePacked(seed, i))) % backoff);
            if (hss.hasScheduleCapacity(candidate, gasLimit)) return candidate;
        }
        return target;
    }
}
