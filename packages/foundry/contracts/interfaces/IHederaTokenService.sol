// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title The subset of the Hedera Token Service system contract (0x167) used by OrderVault.
/// @notice Every call returns a HAPI response code; 22 is SUCCESS.
interface IHederaTokenService {
    struct KeyValue {
        bool inheritAccountKey;
        address contractId;
        bytes ed25519;
        bytes ECDSA_secp256k1;
        address delegatableContractId;
    }

    /// @dev `keyType` is a bit mask: 1 admin, 2 kyc, 4 freeze, 8 wipe, 16 supply, 32 fee, 64 pause.
    struct TokenKey {
        uint256 keyType;
        KeyValue key;
    }

    struct Expiry {
        int64 second;
        address autoRenewAccount;
        int64 autoRenewPeriod;
    }

    struct HederaToken {
        string name;
        string symbol;
        address treasury;
        string memo;
        bool tokenSupplyType;
        int64 maxSupply;
        bool freezeDefault;
        TokenKey[] tokenKeys;
        Expiry expiry;
    }

    function createNonFungibleToken(HederaToken memory token)
        external
        payable
        returns (int64 responseCode, address tokenAddress);

    function mintToken(address token, int64 amount, bytes[] memory metadata)
        external
        returns (int64 responseCode, int64 newTotalSupply, int64[] memory serialNumbers);

    function transferNFT(address token, address sender, address recipient, int64 serialNumber)
        external
        returns (int64 responseCode);

    function burnToken(address token, int64 amount, int64[] memory serialNumbers)
        external
        returns (int64 responseCode, int64 newTotalSupply);

    function wipeTokenAccountNFT(address token, address account, int64[] memory serialNumbers)
        external
        returns (int64 responseCode);

    function associateToken(address account, address token) external returns (int64 responseCode);
}
