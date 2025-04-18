// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {OpenRankDeploymentLib} from "./utils/OpenRankDeploymentLib.sol";
import {IOpenRankServiceManager} from "../src/IOpenRankServiceManager.sol";

contract CreateMockJobs is Script {
    OpenRankDeploymentLib.DeploymentData openRankDeployment;
    IOpenRankServiceManager openRankServiceManager;

    function setUp() public virtual {
        openRankDeployment = OpenRankDeploymentLib.readDeploymentJson(
            "contracts/deployments/openrank/",
            84532
        );

        openRankServiceManager = IOpenRankServiceManager(
            openRankDeployment.openRankServiceManager
        );
    }

    function run() external {}
}
