// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../common/deploy_rxp.sol";

/**
 * @title DeployRxp_Local
 * @notice Script to deploy the Rxp contracts for a local environment.
 */
contract DeployRxp_Local is BaseDeployRxp {
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
}
