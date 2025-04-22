// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { BaseDeploySimpleAVS } from "../../common/deploy_simple_avs.sol";
import { IStrategy } from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

/**
 * @title DeploySimpleAVS_Local
 * @notice Script to deploy the Simple AVS for a local environment.
 */
contract DeploySimpleAVS_Local is BaseDeploySimpleAVS {
    /**
     * @notice Main entry point for the script.
     * @param broadcast Whether to broadcast the transactions.
     */
    function run(
        bool broadcast
    ) public {
        // Call the base run function with the 'local' environment
        super.run(broadcast, "local");
    }

    /**
     * @notice Selects the strategies to be used for the AVS in the local environment.
     * @return The strategies to be used for the AVS.
     * @dev Uses the same strategy for the AVS as the RxpStrategy.
     */
    function chooseStrategiesForAVS() public view override returns (IStrategy[] memory) {
        // Create and return an array containing only the RxpStrategy
        IStrategy[] memory selectedStrategies = new IStrategy[](1);
        selectedStrategies[0] = IStrategy(rxpStrategy);
        return selectedStrategies;
    }
}
