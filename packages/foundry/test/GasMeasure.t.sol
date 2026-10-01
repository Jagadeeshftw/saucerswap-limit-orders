// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OrderVaultBase } from "./OrderVaultBase.t.sol";
import { MockHss } from "./mocks/MockHederaSystem.sol";
import { Trigger } from "../contracts/types/OrderTypes.sol";

/// @notice Measures the gas a scheduled sweep uses: one funded order (a solo check), a three-order shared sweep,
///         and a sweep that fills a DAI stop-loss. Run with `--isolate` so each sweep is its own transaction and
///         pays cold-access gas as on Hedera: `forge test --match-contract GasMeasure --isolate -vv`.
contract GasMeasureTest is OrderVaultBase {
    uint128 internal constant FAR = 12_500_000; // ~12% above, so the order is checked and not filled

    function _measureSweep() internal returns (uint256 used) {
        MockHss.Scheduled memory job = hss.last();
        vm.warp(job.expiry);
        vm.prank(address(vault));
        uint256 g0 = gasleft();
        (bool ok,) = address(vault).call{ gas: job.gasLimit }(job.callData);
        used = g0 - gasleft();
        require(ok, "sweep reverted");
    }

    function test_gas_singleOrderCheck() public {
        _sellHbar(alice, FAR, Trigger.AtOrAbove);
        emit log_named_uint("scheduled sweep gas, 1 order", _measureSweep());
    }

    function test_gas_sharedCheck() public {
        _sellHbar(alice, FAR, Trigger.AtOrAbove);
        _sellHbar(bob, FAR, Trigger.AtOrAbove);
        _sellHbar(keeper, FAR, Trigger.AtOrAbove);
        emit log_named_uint("scheduled sweep gas, 3 orders", _measureSweep());
    }

    function test_gas_fill() public {
        _daiStop(alice, 99_990_000); // DAI at 0.9998: at or below the trigger, so the first sweep fills it
        emit log_named_uint("scheduled sweep gas, 1 DAI fill", _measureSweep());
    }
}
