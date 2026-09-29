// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Hedera exchange-rate system contract (HIP-475), deployed at 0x168.
/// @notice Converts USD-denominated amounts using the same rate the network uses to charge fees.
interface IExchangeRate {
    function tinycentsToTinybars(uint256 tinycents) external returns (uint256 tinybars);

    function tinybarsToTinycents(uint256 tinybars) external returns (uint256 tinycents);
}
