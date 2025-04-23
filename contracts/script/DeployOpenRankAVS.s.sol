// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseDeploySimpleAVS} from "./common/BaseDeployAVS.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {IServiceManager} from "eigenlayer-middleware/src/interfaces/IServiceManager.sol";

contract DeployOpenRankAVS is BaseDeploySimpleAVS {
    function run() public {
        super.run(false);
    }

    function newServiceManager()
        public
        returns (IServiceManager serviceManager)
    {
        serviceManager = new OpenRankManager(
            IAVSDirectory(eigenlayerDeployment.avsDirectory),
            IRewardsCoordinator(eigenlayerDeployment.rewardsCoordinator),
            ISlashingRegistryCoordinator(address(slashingRegistryCoordinator)),
            IStakeRegistry(address(stakeRegistry)),
            IPermissionController(eigenlayerDeployment.permissionController),
            IAllocationManager(eigenlayerDeployment.allocationManager)
        );
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
