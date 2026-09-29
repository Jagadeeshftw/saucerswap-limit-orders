// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Hedera Schedule Service system contract (HIP-755 / HIP-1215), deployed at 0x16b.
/// @notice None of these calls revert; failures come back as a HAPI response code.
interface IHederaScheduleService {
    /// @notice Schedule `to.call{value}(callData)` for the first consensus second at or after `expirySecond`.
    /// @dev The calling contract is the payer. Measured on testnet: ~1.42M gas, independent of `gasLimit`.
    /// @return responseCode 22 (SUCCESS) on success.
    /// @return scheduleAddress The schedule entity, or address(0) on failure.
    function scheduleCall(address to, uint256 expirySecond, uint256 gasLimit, uint64 value, bytes memory callData)
        external
        returns (int64 responseCode, address scheduleAddress);

    /// @notice True if `expirySecond` can still take a call with `gasLimit`; false for invalid or saturated seconds.
    function hasScheduleCapacity(uint256 expirySecond, uint256 gasLimit) external view returns (bool hasCapacity);
}
