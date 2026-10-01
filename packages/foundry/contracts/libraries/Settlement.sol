// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IHederaTokenService } from "../interfaces/IHederaTokenService.sol";
import { ISaucerSwapV2Router } from "../interfaces/ISaucerSwapV2.sol";
import { HtsError, HtsOperation } from "../types/OrderTypes.sol";

/// @title Settlement — the vault's external-interaction layer.
/// @notice The SaucerSwap swap, the HTS token and order-NFT operations, and ERC-20 moves.
///         It is an external library (its own deployed code, linked like `MarketGuard`/`OrderCollection`), so this
///         call-encoding-heavy code lives outside `OrderVault` and the vault stays under the 24 KB limit with room
///         to spare. The vault keeps the readable sweep → evaluate → guard → fill flow and calls here only for the
///         external interactions; it still enforces the guard and its own Chainlink slippage floor before any swap.
library Settlement {
    /// @dev HTS response code for success.
    int64 internal constant HTS_SUCCESS = 22;
    /// @dev HTS response code for a token already associated with the account.
    int64 internal constant HTS_ALREADY_ASSOCIATED = 194;
    /// @dev Stands for HBAR in token arguments.
    address internal constant HBAR = address(0);
    /// @dev Seconds a swap stays valid: its router deadline.
    uint256 internal constant SWAP_DEADLINE = 300;

    /// @notice Swap `amountIn` of `tokenIn` for `tokenOut` on SaucerSwap V2, requiring at least `minOut`. For an
    ///         HBAR leg, WHBAR is used and the router wraps/unwraps. The caller has already checked escrow and set
    ///         `minOut` from Chainlink, so the swap's own `amountOutMinimum` is the final price protection.
    /// @param router The SaucerSwap V2 SwapRouter.
    /// @param whbar The WHBAR token, substituted for an HBAR leg.
    /// @param poolFee The pool's fee, in hundredths of a basis point.
    /// @param tokenIn Input token; address(0) for HBAR.
    /// @param tokenOut Output token; address(0) for HBAR.
    /// @param amountIn Input amount, in raw units.
    /// @param minOut Smallest acceptable output, in raw units.
    /// @return amountOut Output received, in raw units.
    /// @dev Reverts `TransferRejected` if approving the router for a token input returns false. The router
    ///      reverts if the output is below `minOut`.
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

    /// @notice Approving the router for the input token returned false.
    error TransferRejected();

    /// @notice Mint one order NFT in `collection` and transfer it to `to`. The serial is the order id.
    /// @param hts The HTS system contract.
    /// @param collection The order NFT collection.
    /// @param to The maker.
    /// @return orderId The minted serial number.
    /// @dev Reverts `HtsError` (`Mint` or `TransferNft`) if HTS refuses either step.
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
    /// @param hts The HTS system contract.
    /// @param collection The order NFT collection.
    /// @param orderId The order's serial number.
    /// @param holder The NFT's current holder.
    /// @return rc The HTS response code (22 is success).
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
    /// @param hts The HTS system contract.
    /// @param token The token.
    /// @dev Reverts `HtsError` (`Associate`) unless HTS answers success (22) or already associated (194).
    function associate(IHederaTokenService hts, address token) public {
        int64 rc = hts.associateToken(address(this), token);
        if (rc != HTS_SUCCESS && rc != HTS_ALREADY_ASSOCIATED) revert HtsError(HtsOperation.Associate, rc);
    }

    /// @notice Pull `amount` of `token` from `from` to the vault; returns false on a failed or false-returning move.
    /// @param token The token.
    /// @param from The owner, who must have approved the vault.
    /// @param to The recipient (the vault).
    /// @param amount Amount, in raw units.
    /// @return Whether the transfer succeeded.
    function pullToken(address token, address from, address to, uint256 amount) public returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// @notice Send `amount` of `token` to `to`; returns false on a failed or false-returning move.
    /// @param token The token.
    /// @param to The recipient.
    /// @param amount Amount, in raw units.
    /// @return Whether the transfer succeeded.
    function transferToken(address token, address to, uint256 amount) public returns (bool) {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }
}
