// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IHederaTokenService } from "../interfaces/IHederaTokenService.sol";

/// @title OrderCollection
/// @notice Creates the HTS NFT collection whose serial numbers are order ids.
/// @dev An external library, linked rather than inlined, so this one-time setup doesn't count against
///      OrderVault's 24 KiB limit. It runs by DELEGATECALL, so the vault is the caller HTS sees.
library OrderCollection {
    IHederaTokenService internal constant HTS = IHederaTokenService(address(0x167));
    int64 internal constant HTS_SUCCESS = 22;
    uint256 internal constant KEYS_SUPPLY_AND_WIPE = 16 | 8;
    int64 internal constant AUTO_RENEW_PERIOD = 7_776_000;

    /// @notice Create the collection with the vault as treasury and holder of the supply and wipe keys.
    /// @param fee HBAR (tinybar) forwarded as the HTS creation fee; any excess stays in the vault.
    /// @return rc The HTS response code.
    /// @return collection The new token's address, or zero on failure.
    function create(string calldata name, string calldata symbol, uint256 fee)
        external
        returns (int64 rc, address collection)
    {
        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = IHederaTokenService.TokenKey({
            keyType: KEYS_SUPPLY_AND_WIPE,
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
                second: 0, autoRenewAccount: address(this), autoRenewPeriod: AUTO_RENEW_PERIOD
            })
        });
        return HTS.createNonFungibleToken{ value: fee }(token);
    }
}
