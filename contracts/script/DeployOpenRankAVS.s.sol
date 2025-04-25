// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";

import {IServiceManager} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/core/AVSDirectory.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/core/RewardsCoordinator.sol";
import {IPermissionController} from "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/core/AllocationManager.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

import {DeployCore} from "./DeployCore.s.sol";
import {DeployRxp} from "./DeployRxp.s.sol";
import {DeployAVSBase} from "./common/DeployAVSBase.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IServiceManager} from "eigenlayer-middleware/src/interfaces/IServiceManager.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

contract DeployOpenRankAVS is DeployAVSBase {
    DeployCore deployCore;
    DeployRxp deployRxp;

    function run() public {
        deployCore = new DeployCore();
        deployRxp = new DeployRxp();

        broadcastOrPrank({
            broadcast: false,
            prankAddress: msg.sender,
            deployFunction: _deployCore
        });

        broadcastOrPrank({
            broadcast: false,
            prankAddress: msg.sender,
            deployFunction: _deployRxp
        });

        super.run(false);
    }

    function _deployCore() internal {
        deployCore.run();
    }

    function _deployRxp() internal {
        deployRxp.run();
    }

    function chooseStrategiesForAVS()
        public
        view
        override
        returns (IStrategy[] memory)
    {
        // Create and return an array containing only the RxpStrategy
        IStrategy[] memory selectedStrategies = new IStrategy[](1);
        selectedStrategies[0] = IStrategy(rxpStrategy);
        return selectedStrategies;
    }
}
