// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";
import {DeployOpenRank} from "../script/DeployOpenRank.s.sol";

import {DeployRxp_Local} from "rxp/script/local/deploy/deploy_rxp_contracts.s.sol";
import {IReexecutionEndpoint} from "rxp/src/interfaces/core/IReexecutionEndpoint.sol";

contract OpenRankManagerTest is Test {
    uint256 constant CHALLENGE_WINDOW = 60;

    DeployOpenRank openRankDeployer;
    address initialOwner;

    function setUp() public {
        openRankDeployer = new DeployOpenRank();

        initialOwner = vm.envAddress("ADDRESS");
        console.log("initialOwner: ", initialOwner);
        openRankDeployer.run();
    }

    function testMetaChallenge() public {
        vm.startPrank(initialOwner);

        OpenRankManager orManager = openRankDeployer.orManager();
        uint256 jobId = orManager.submitMetaComputeRequest(
            bytes32(0)
        );
        orManager.submitMetaComputeResult(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.expectEmit();
        bytes memory inputData = abi.encode(jobId, 0);
        emit IReexecutionEndpoint.ReexecutionRequestCreated(0, address(orManager), 0, 0, hex"", bytes32(0), inputData, hex"", 1);

        orManager.submitMetaChallenge(jobId, 0, hex"");

        vm.stopPrank();
    }
}
