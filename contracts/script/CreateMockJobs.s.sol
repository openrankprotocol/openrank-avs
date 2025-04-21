// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {OpenRankDeploymentLib} from "./utils/OpenRankDeploymentLib.sol";
import {IOpenRankServiceManager} from "../src/IOpenRankServiceManager.sol";

contract CreateMockJobs is Script {
    uint256 constant CHALLENGE_WINDOW = 60 * 60;

    OpenRankDeploymentLib.DeploymentData openRankDeployment;
    IOpenRankServiceManager openRankServiceManager;

    address private deployer;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");

        openRankDeployment = OpenRankDeploymentLib.readDeploymentJson(
            "contracts/deployments/openrank/",
            block.chainId
        );

        openRankServiceManager = IOpenRankServiceManager(
            openRankDeployment.openRankServiceManager
        );
    }

    function run() external {
        address owner = openRankServiceManager.owner();
        vm.startBroadcast(owner);

        uint256 jobId = openRankServiceManager.submitComputeRequest(
            bytes32(0),
            bytes32(0)
        );
        openRankServiceManager.submitComputeResult(
            jobId,
            bytes32(0),
            bytes32(0)
        );
        openRankServiceManager.submitChallenge(jobId);

        vm.stopBroadcast();
    }
}
