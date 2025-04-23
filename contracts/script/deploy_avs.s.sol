// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {BaseDeploySimpleAVS} from "./common/deploy_simple_avs.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

contract DeployOpenRankAVS is BaseDeploySimpleAVS {
    function run() public {
        super.run(false);
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
