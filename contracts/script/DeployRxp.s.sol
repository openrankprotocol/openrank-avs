// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";

import {IServiceManager} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/core/AVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/core/RewardsCoordinator.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/core/AllocationManager.sol";
import {ITransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {DeployRxpBase} from "./common/DeployRxpBase.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";
import {IOpenRankManager} from "../src/interfaces/IOpenRankManager.sol";

contract DeployRxp is DeployRxpBase {
    function run() public {
        broadcastOrPrank({
            broadcast: false,
            prankAddress: msg.sender,
            deployFunction: _runRxp
        });
    }

    function newServiceManagerImplementation() public override returns (IServiceManager) {
        OpenRankManager manager = new OpenRankManager(
            IAVSDirectory(avsDirectory),
            IRewardsCoordinator(rewardsCoordinator),
            slashingRegistryCoordinator,
            stakeRegistry,
            IPermissionController(address(permissionController)),
            IAllocationManager(allocationManager)
        );
        return manager;
    }

    function initializeServiceManager() public override {
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(serviceManager))),
            address(serviceManagerImplementation),
            abi.encodeWithSelector(
                OpenRankManager.initialize.selector,
                initialOwner,
                initialOwner
            )
        );
    }
}
