// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

contract OpenRankManagerTest is Test {
    error ChallengePeriodExpired();
    error JobAlreadyFinalized();

    uint256 constant CHALLENGE_WINDOW = 60;
    uint256 constant FEE = 100;
    uint256 constant STAKE = 100;

    OpenRankManager public opManager;

    address[] computers;
    address[] challengers;
    address[] users;

    function setUp() public {
        computers = new address[](1);
        computers[0] = vm.addr(0x01);

        challengers = new address[](1);
        challengers[0] = vm.addr(0x02);

        users = new address[](1);
        users[0] = vm.addr(0x03);

        vm.deal(computers[0], 1 ether);
        vm.deal(challengers[0], 1 ether);
        vm.deal(users[0], 1 ether);

        opManager = new OpenRankManager(computers, challengers, users);
    }

    function testCorrectCompute() public {
        vm.startPrank(users[0]);
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        vm.startPrank(computers[0]);
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeJob(jobId);

        vm.stopPrank();
    }

    function testChallenge() public {
        vm.startPrank(users[0]);
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        vm.startPrank(computers[0]);
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        uint256 balanceBefore = challengers[0].balance;

        vm.startPrank(challengers[0]);
        opManager.submitChallenge(jobId);
        vm.stopPrank();

        uint256 balanceAfter = challengers[0].balance;
        assert(balanceBefore + STAKE + FEE == balanceAfter);
    }

    function testChallengeAfterFinalizedJob() public {
        vm.startPrank(users[0]);
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        vm.startPrank(computers[0]);
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeJob(jobId);

        vm.stopPrank();

        // Attempt to raise a challenge after challenge window has expired
        vm.expectRevert(ChallengePeriodExpired.selector);
        vm.startPrank(challengers[0]);
        opManager.submitChallenge(jobId);
        vm.stopPrank();
    }

    function testFinalizeJobAfterChallenge() public {
        vm.startPrank(users[0]);
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        vm.startPrank(computers[0]);
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );
        vm.stopPrank();

        uint256 balanceBefore = challengers[0].balance;

        vm.startPrank(challengers[0]);
        opManager.submitChallenge(jobId);
        vm.stopPrank();

        uint256 balanceAfter = challengers[0].balance;
        assert(balanceBefore + STAKE + FEE == balanceAfter);

        // Attempt to finalize job
        vm.expectRevert(JobAlreadyFinalized.selector);
        vm.startPrank(computers[0]);
        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeJob(jobId);
        vm.stopPrank();
    }
}
