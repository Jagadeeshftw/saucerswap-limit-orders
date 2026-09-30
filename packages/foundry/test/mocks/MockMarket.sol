// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ISaucerSwapV2Router } from "../../contracts/interfaces/ISaucerSwapV2.sol";

/// @notice ERC-20 with configurable decimals. Transfers to a blocked account return false, which is
///         how an HTS token behaves when the receiver is not associated.
contract MockToken is ERC20 {
    uint8 internal immutable _decimals;
    mapping(address account => bool) public blocked;
    /// @notice When set, transferFrom and approve return false instead of reverting.
    bool public refuses;

    constructor(string memory symbol, uint8 decimals_) ERC20(symbol, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function setRefuses(bool value) external {
        refuses = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (refuses) return false;
        return super.transferFrom(from, to, amount);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (refuses) return false;
        return super.approve(spender, amount);
    }
}

/// @notice Chainlink-style feed with settable answer and timestamp.
contract MockAggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public broken;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        set(answer_, block.timestamp);
    }

    function set(int256 answer_, uint256 updatedAt_) public {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Pool whose TWAP is a constant tick, or unavailable.
contract MockPool {
    address public token0;
    int24 public tick;
    bool public unavailable;

    constructor(address token0_, int24 tick_) {
        token0 = token0_;
        tick = tick_;
    }

    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function observe(uint32[] calldata secondsAgo) external view returns (int56[] memory c, uint160[] memory l) {
        require(!unavailable, "OLD");
        c = new int56[](secondsAgo.length);
        l = new uint160[](secondsAgo.length);
        for (uint256 i; i < secondsAgo.length; ++i) {
            c[i] = int56(tick) * int56(uint56(block.timestamp - secondsAgo[i]));
        }
    }
}

/// @notice SwapRouter stand-in: swaps at a set output-per-input rate (RAY) and honours amountOutMinimum.
/// @dev `whbar` stands for HBAR: value in wraps it, and `unwrapWHBAR` pays out HBAR the router holds.
contract MockRouter {
    uint256 internal constant RAY = 1e27;

    address public immutable whbar;
    mapping(address tokenIn => mapping(address tokenOut => uint256)) public rateRay;
    uint256 public wrappedBalance;
    bool public broken;

    constructor(address whbar_) {
        whbar = whbar_;
    }

    function setRate(address tokenIn, address tokenOut, uint256 outPerInRay) external {
        rateRay[tokenIn][tokenOut] = outPerInRay;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    function exactInputSingle(ISaucerSwapV2Router.ExactInputSingleParams calldata p)
        public
        payable
        returns (uint256 amountOut)
    {
        require(!broken, "router down");
        if (p.tokenIn == whbar) {
            require(msg.value == p.amountIn, "value");
        } else {
            require(ERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn), "pull");
        }
        amountOut = Math.mulDiv(p.amountIn, rateRay[p.tokenIn][p.tokenOut], RAY);
        require(amountOut >= p.amountOutMinimum, "Too little received");
        if (p.tokenOut == whbar) {
            require(p.recipient == address(this), "unwrap via router");
            wrappedBalance += amountOut;
        } else {
            MockToken(p.tokenOut).mint(p.recipient, amountOut);
        }
    }

    function unwrapWHBAR(uint256 amountMinimum, address recipient) public payable {
        uint256 amount = wrappedBalance;
        require(amount >= amountMinimum, "Insufficient WHBAR");
        wrappedBalance = 0;
        (bool ok,) = recipient.call{ value: amount }("");
        require(ok, "send");
    }

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    receive() external payable { }
}
