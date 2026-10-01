// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import { MarketConfig } from "./MarketConfig.sol";
import { OrderVault } from "../contracts/OrderVault.sol";
import { OrderVaultLens } from "../contracts/OrderVaultLens.sol";
import { LimitOrderType } from "../contracts/ordertypes/LimitOrderType.sol";
import { StopOrderType } from "../contracts/ordertypes/StopOrderType.sol";
import { TrailingStopType } from "../contracts/ordertypes/TrailingStopType.sol";
import { IHederaTokenService } from "../contracts/interfaces/IHederaTokenService.sol";
import { ISaucerSwapV2Router } from "../contracts/interfaces/ISaucerSwapV2.sol";

/// @notice Deploys OrderVault to Hedera testnet, creates its order NFT collection, lists both markets, registers
///         the three order types (limit 0, stop 1, trailing stop 2) and deploys the read-only OrderVaultLens.
/// @dev Run through the root `foundry:deploy` script (Hedera testnet by default). The deployer needs ~25 testnet HBAR.
///
///      Forge runs a script locally before broadcasting it, and a local fork has no HTS system contract.
///      The script therefore mocks HTS for that local pass only. The broadcast transactions carry explicit
///      gas limits (measured on testnet) and execute against the real HTS on-chain.
contract DeployScript is ScaffoldETHDeploy {
    /// @dev Covers the HTS NFT collection fee (~15.3 HBAR on testnet); the excess stays as withdrawable surplus.
    uint256 internal constant COLLECTION_FEE = 20 ether;
    /// @dev Liquid HBAR endowed to back the payer float (~3.2 HBAR per market at current prices), so scheduled
    ///      sweeps can always pay their gas even after the owner withdraws surplus. Comfortably above one float.
    uint256 internal constant FLOAT_ENDOWMENT = 10 ether;
    uint256 internal constant INITIALIZE_GAS = 800_000;
    uint256 internal constant LIST_MARKET_GAS = 3_000_000;
    address internal constant HTS = address(0x167);

    error UnsupportedChain(uint256 chainId);
    error UnexpectedOrderTypeId(uint8 got, uint8 want);

    function run() external ScaffoldEthDeployerRunner {
        if (block.chainid != MarketConfig.HEDERA_TESTNET) revert UnsupportedChain(block.chainid);
        _mockHtsForLocalPass();

        OrderVault vault = new OrderVault(
            deployer, ISaucerSwapV2Router(MarketConfig.SWAP_ROUTER), MarketConfig.WHBAR, MarketConfig.costs()
        );
        vault.initialize{ value: COLLECTION_FEE, gas: INITIALIZE_GAS }("SaucerSwap Limit Order", "SSLO");
        vault.listMarket{ gas: LIST_MARKET_GAS }(MarketConfig.hbarUsdc());
        vault.listMarket{ gas: LIST_MARKET_GAS }(MarketConfig.usdcDai());
        vault.fund{ value: FLOAT_ENDOWMENT }();

        // The frontend and docs refer to the types by these ids, so the registration order is fixed.
        _register(vault, address(new LimitOrderType()), 0);
        _register(vault, address(new StopOrderType()), 1);
        _register(vault, address(new TrailingStopType()), 2);
        OrderVaultLens lens = new OrderVaultLens(vault);

        deployments.push(Deployment({ name: "OrderVault", addr: address(vault) }));
        deployments.push(Deployment({ name: "OrderVaultLens", addr: address(lens) }));
        deployments.push(Deployment({ name: "LimitOrderType", addr: vault.orderTypes(0) }));
        deployments.push(Deployment({ name: "StopOrderType", addr: vault.orderTypes(1) }));
        deployments.push(Deployment({ name: "TrailingStopType", addr: vault.orderTypes(2) }));
    }

    function _register(OrderVault vault, address impl, uint8 want) internal {
        uint8 id = vault.registerOrderType(impl);
        if (id != want) revert UnexpectedOrderTypeId(id, want);
    }

    function _mockHtsForLocalPass() internal {
        vm.mockCall(
            HTS,
            abi.encodeWithSelector(IHederaTokenService.createNonFungibleToken.selector),
            abi.encode(int64(22), address(0x00000000000000000000000000000000000c0ffe))
        );
        vm.mockCall(HTS, abi.encodeWithSelector(IHederaTokenService.associateToken.selector), abi.encode(int64(22)));
    }
}
