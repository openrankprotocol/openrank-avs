// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

contract OpenRankManagerTest is Test {
    error ChallengePeriodExpired();
    error JobAlreadyFinalized();

    uint256 constant CHALLENGE_WINDOW = 60 * 60;
    uint256 constant FEE = 100;
    uint256 constant STAKE = 100;

    OpenRankManager public opManager;

    function setUp() public {
        opManager = new OpenRankManager();
    }

    function testCorrectCompute() public {
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeJob(jobId);
    }

    function testChallenge() public {
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        uint256 balanceBefore = address(this).balance;
        opManager.submitChallenge(jobId);
        uint256 balanceAfter = address(this).balance;
        assert(balanceBefore + STAKE + FEE == balanceAfter);
    }

    function testChallengeAfterFinalizedJob() public {
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );

        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeJob(jobId);

        // Attempt to raise a challenge after challenge window has expired
        vm.expectRevert(ChallengePeriodExpired.selector);
        opManager.submitChallenge(jobId);
    }

    function testFinalizeJobAfterChallenge() public {
        uint256 jobId = opManager.submitComputeRequest{value: FEE}(
            bytes32(0),
            bytes32(0)
        );
        opManager.submitComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        uint256 balanceBefore = address(this).balance;
        opManager.submitChallenge(jobId);

        uint256 balanceAfter = address(this).balance;
        assert(balanceBefore + STAKE + FEE == balanceAfter);

        // Attempt to finalize job
        vm.expectRevert(JobAlreadyFinalized.selector);
        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeJob(jobId);
    }

    function testMetaCorrectCompute() public {
        uint256 jobId = opManager.submitMetaComputeRequest{value: FEE}(
            bytes32(0)
        );
        opManager.submitMetaComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeMetaJob(jobId);
    }

    function testMetaChallenge() public {
        uint256 jobId = opManager.submitMetaComputeRequest{value: FEE}(
            bytes32(0)
        );
        opManager.submitMetaComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        uint256 balanceBefore = address(this).balance;
        opManager.submitMetaChallenge(jobId, 0);

        uint256 balanceAfter = address(this).balance;
        assert(balanceBefore + STAKE + FEE == balanceAfter);
    }

    function testMetaChallengeAfterFinalizedJob() public {
        uint256 jobId = opManager.submitMetaComputeRequest{value: FEE}(
            bytes32(0)
        );
        opManager.submitMetaComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeMetaJob(jobId);

        // Attempt to raise a challenge after challenge window has expired
        vm.expectRevert(ChallengePeriodExpired.selector);
        opManager.submitMetaChallenge(jobId, 0);
    }

    function testMetaFinalizeJobAfterChallenge() public {
        uint256 jobId = opManager.submitMetaComputeRequest{value: FEE}(
            bytes32(0)
        );
        opManager.submitMetaComputeResult{value: STAKE}(
            jobId,
            bytes32(0),
            bytes32(0)
        );

        uint256 balanceBefore = address(this).balance;
        opManager.submitMetaChallenge(jobId, 0);

        uint256 balanceAfter = address(this).balance;
        assert(balanceBefore + STAKE + FEE == balanceAfter);

        // Attempt to finalize job
        vm.expectRevert(JobAlreadyFinalized.selector);
        vm.warp(CHALLENGE_WINDOW + 2);
        opManager.finalizeMetaJob(jobId);
    }

    receive() external payable {}
}
