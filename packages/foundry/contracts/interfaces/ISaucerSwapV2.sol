// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title SaucerSwap V2 SwapRouter (a Uniswap v3-periphery fork). Testnet 0.0.1414040, mainnet 0.0.3949434.
interface ISaucerSwapV2Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev For HBAR in, pass WHBAR as `tokenIn` and send the amount as value; the router wraps it.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);

    /// @notice Unwrap the router's WHBAR balance and send HBAR to `recipient`.
    function unwrapWHBAR(uint256 amountMinimum, address recipient) external payable;
}

/// @title SaucerSwap V2 pool (a Uniswap v3-core fork).
interface ISaucerSwapV2Pool {
    function token0() external view returns (address);

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
