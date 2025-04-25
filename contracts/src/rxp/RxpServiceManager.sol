// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IAllocationManager } from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import { IPermissionController } from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {
    IAVSDirectory,
    IRewardsCoordinator,
    IServiceManager,
    ServiceManagerBase
} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import { ISlashingRegistryCoordinator } from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import { IStakeRegistry } from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

contract RxpServiceManager is ServiceManagerBase {
    constructor(
        IAVSDirectory __avsDirectory,
        IRewardsCoordinator __rewardsCoordinator,
        ISlashingRegistryCoordinator __slashingRegistryCoordinator,
        IStakeRegistry __stakeRegistry,
        IPermissionController __permissionController,
        IAllocationManager __allocationManager
    )
        ServiceManagerBase(
            __avsDirectory,
            __rewardsCoordinator,
            __slashingRegistryCoordinator,
            __stakeRegistry,
            __permissionController,
            __allocationManager
        )
    { }

    function initialize(address initialOwner, address _rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, _rewardsInitiator);
    }
}
