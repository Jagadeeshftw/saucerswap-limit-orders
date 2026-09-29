// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Status } from "../contracts/types/OrderTypes.sol";
import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { VaultHandler } from "./OrderVault.invariant.t.sol";

/// @notice Fixed handler sequences proving the invariant campaign can reach fills and expiries.
contract OrderVaultHandlerTest is OrderVaultBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = keeper;
        handler = new VaultHandler(vault, router, [whbar, usdc, dai], hbarFeed, daiFeed, hbarPool, daiPool, actors);
    }

    function test_handler_canFill() public {
        handler.place(0, false, false, true, 100e8, 0, 0); // sell HBAR at or above 97% of spot
        handler.scheduledSweep(false);
        assertEq(uint8(vault.getOrder(handler.orderIds(0)).status), uint8(Status.Filled));
    }

    function test_handler_canExpire() public {
        handler.place(0, false, true, false, 0, 0, 0); // buy HBAR at or below 97% of spot, 1 hour expiry
        handler.warp(2 hours);
        handler.manualExecute(0, 1);
        assertEq(uint8(vault.getOrder(handler.orderIds(0)).status), uint8(Status.Expired));
    }
}
