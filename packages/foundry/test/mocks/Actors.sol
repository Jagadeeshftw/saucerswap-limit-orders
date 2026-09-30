// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVault } from "../../contracts/OrderVault.sol";

/// @notice An order holder that refuses HBAR until told otherwise, so payouts to it are credited.
contract HbarRejecter {
    bool public accepts;

    function setAccepts(bool value) external {
        accepts = value;
    }

    function cancel(OrderVault vault, uint256 orderId) external {
        vault.cancel(orderId);
    }

    function claim(OrderVault vault, address token) external {
        vault.claim(token);
    }

    function associate(address collection) external {
        (bool ok,) = collection.call(abi.encodeWithSignature("associate()"));
        require(ok, "associate");
    }

    receive() external payable {
        require(accepts, "no HBAR");
    }
}
