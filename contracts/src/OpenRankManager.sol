// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { IAllocationManager } from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import { IPermissionController } from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {
    IAVSDirectory,
    IRewardsCoordinator,
    IServiceManager,
    ServiceManagerBase
} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import { ISlashingRegistryCoordinator } from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import { IStakeRegistry } from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

contract OpenRankManager is ServiceManagerBase {
    error ComputeRequestNotFound();
    error ComputeResultAlreadySubmitted();
    error ComputeResultNotFound();
    error ChallengeNotFound();
    error ChallengePeriodExpired();
    error JobAlreadyFinalized();
    error CannotFinalizeJob();
    error CallerNotWhitelisted();

    struct ComputeRequest {
        address user;
        uint256 id;
        bytes32 trustId;
        bytes32 seedId;
        uint256 timestamp;
    }

    struct ComputeResult {
        address computer;
        uint256 computeId;
        bytes32 commitment;
        bytes32 scoresId;
        uint256 timestamp;
    }

    struct Challenge {
        address challenger;
        uint256 timestamp;
    }

    struct MetaComputeRequest {
        address user;
        uint256 id;
        bytes32 jobDescriptionId;
        uint256 timestamp;
    }

    struct MetaComputeResult {
        address computer;
        uint256 computeId;
        bytes32 metaCommitment;
        bytes32 resultsId;
        uint256 timestamp;
    }

    struct MetaChallenge {
        address challenger;
        uint256 computeId;
        uint256 subJobId;
        uint256 timestamp;
    }

    uint64 public CHALLENGE_WINDOW = 60 * 60; // 60 minutes
    uint64 public RXP_WINDOW = 60;

    uint256 public idCounter;

    mapping(address => bool) allowlistedComputers;
    mapping(address => bool) allowlistedChallengers;
    mapping(address => bool) allowlistedUsers;

    mapping(uint256 => ComputeRequest) computeRequests;
    mapping(uint256 => ComputeResult) computeResults;
    mapping(uint256 => Challenge) challenges;
    mapping(uint256 => bool) jobsFinalized;

    mapping(uint256 => MetaComputeRequest) metaComputeRequests;
    mapping(uint256 => MetaComputeResult) metaComputeResults;
    mapping(uint256 => MetaChallenge) metaChallenges;
    mapping(uint256 => bool) metaJobsFinalized;

    event ComputeRequestEvent(uint256 indexed computeId, bytes32 trust_id, bytes32 seed_id);
    event ComputeResultEvent(uint256 indexed computeId, bytes32 commitment, bytes32 scores_id);
    event ChallengeEvent(uint256 indexed computeId);
    event JobFinalized(uint256 indexed computeId);
    event MetaComputeRequestEvent(uint256 indexed computeId, bytes32 jobDescriptionId);
    event MetaComputeResultEvent(uint256 indexed computeId, bytes32 commitment, bytes32 resultsId);
    event MetaChallengeEvent(uint256 indexed computeId, uint256 subJobId);
    event MetaJobFinalized(uint256 indexed computeId);

    constructor(
        IAVSDirectory __avsDirectory,
        IRewardsCoordinator __rewardsCoordinator,
        ISlashingRegistryCoordinator __slashingRegistryCoordinator,
        IStakeRegistry __stakeRegistry,
        IPermissionController __permissionController,
        IAllocationManager __allocationManager
    )
        ServiceManagerBase(
            __avsDirectory,
            __rewardsCoordinator,
            __slashingRegistryCoordinator,
            __stakeRegistry,
            __permissionController,
            __allocationManager
        )
    {}

    function initialize(address initialOwner, address _rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, _rewardsInitiator);

        idCounter = 1;

        allowlistedComputers[initialOwner] = true;
        allowlistedChallengers[initialOwner] = true;
        allowlistedUsers[initialOwner] = true;
    }

    // ---------------------------------------------------------------
    // Singular Jobs
    // ---------------------------------------------------------------

    function submitComputeRequest(
        bytes32 trustId,
        bytes32 seedId
    ) external returns (uint256 computeId) {
        if (!allowlistedUsers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        ComputeRequest memory computeRequest = ComputeRequest({
            user: msg.sender,
            id: idCounter,
            trustId: trustId,
            seedId: seedId,
            timestamp: block.timestamp
        });
        computeRequests[idCounter] = computeRequest;

        emit ComputeRequestEvent(idCounter, trustId, seedId);

        computeId = idCounter;
        idCounter += 1;
    }

    function submitComputeResult(
        uint256 computeId,
        bytes32 commitment,
        bytes32 scoresId
    ) external returns (bool) {
        if (!allowlistedComputers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (computeRequests[computeId].id == 0) {
            revert ComputeRequestNotFound();
        }
        if (computeResults[computeId].computeId != 0) {
            revert ComputeResultAlreadySubmitted();
        }

        ComputeResult memory computeResult = ComputeResult({
            computer: msg.sender,
            computeId: computeId,
            commitment: commitment,
            scoresId: scoresId,
            timestamp: block.timestamp
        });
        computeResults[computeId] = computeResult;

        emit ComputeResultEvent(computeId, commitment, scoresId);

        return true;
    }

    function submitChallenge(
        uint256 computeId
    ) external returns (bool) {
        if (!allowlistedChallengers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (computeRequests[computeId].id == 0) {
            revert ComputeRequestNotFound();
        }
        if (computeResults[computeId].computeId == 0) {
            revert ComputeResultNotFound();
        }

        uint256 computeDiff = block.timestamp - computeResults[computeId].timestamp;
        if (computeDiff > CHALLENGE_WINDOW) {
            revert ChallengePeriodExpired();
        } else {
            Challenge memory challenge =
                Challenge({challenger: msg.sender, timestamp: block.timestamp});
            challenges[computeId] = challenge;
            jobsFinalized[computeId] = true;

            emit ChallengeEvent(computeId);
            emit JobFinalized(computeId);
            return true;
        }
    }

    function finalizeJob(
        uint256 computeId
    ) external returns (bool) {
        if (jobsFinalized[computeId]) {
            revert JobAlreadyFinalized();
        }
        if (computeResults[computeId].computeId == 0) {
            revert ComputeResultNotFound();
        }

        uint256 computeDiff = block.timestamp - computeResults[computeId].timestamp;
        if (computeDiff > CHALLENGE_WINDOW && challenges[computeId].challenger == address(0x0)) {
            jobsFinalized[computeId] = true;

            emit JobFinalized(computeId);

            return true;
        } else {
            revert CannotFinalizeJob();
        }
    }

    // ---------------------------------------------------------------
    // Metaed Jobs
    // ---------------------------------------------------------------

    function submitMetaComputeRequest(
        bytes32 jobDescriptionId
    ) external returns (uint256 computeId) {
        if (!allowlistedUsers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        MetaComputeRequest memory computeRequest = MetaComputeRequest({
            user: msg.sender,
            id: idCounter,
            jobDescriptionId: jobDescriptionId,
            timestamp: block.timestamp
        });
        metaComputeRequests[idCounter] = computeRequest;

        emit MetaComputeRequestEvent(idCounter, jobDescriptionId);

        computeId = idCounter;
        idCounter += 1;
    }

    function submitMetaComputeResult(
        uint256 computeId,
        bytes32 metaCommitment,
        bytes32 resultsId
    ) external returns (bool) {
        if (!allowlistedComputers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (metaComputeRequests[computeId].id == 0) {
            revert ComputeRequestNotFound();
        }
        if (metaComputeResults[computeId].computeId != 0) {
            revert ComputeResultAlreadySubmitted();
        }

        MetaComputeResult memory computeResult = MetaComputeResult({
            computer: msg.sender,
            computeId: computeId,
            metaCommitment: metaCommitment,
            resultsId: resultsId,
            timestamp: block.timestamp
        });
        metaComputeResults[computeId] = computeResult;

        emit MetaComputeResultEvent(computeId, metaCommitment, resultsId);

        return true;
    }

    function submitMetaChallenge(uint256 computeId, uint256 subJobId) external returns (bool) {
        if (!allowlistedChallengers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (metaComputeRequests[computeId].id == 0) {
            revert ComputeRequestNotFound();
        }
        if (metaComputeResults[computeId].computeId == 0) {
            revert ComputeResultNotFound();
        }

        uint256 computeDiff = block.timestamp - metaComputeResults[computeId].timestamp;
        if (computeDiff > CHALLENGE_WINDOW) {
            revert ChallengePeriodExpired();
        } else {
            MetaChallenge memory challenge = MetaChallenge({
                challenger: msg.sender,
                computeId: computeId,
                subJobId: subJobId,
                timestamp: block.timestamp
            });
            metaChallenges[computeId] = challenge;
            metaJobsFinalized[computeId] = true;

            emit MetaChallengeEvent(computeId, subJobId);
            emit MetaJobFinalized(computeId);
            return true;
        }
    }

    function finalizeMetaJob(
        uint256 computeId
    ) external returns (bool) {
        if (metaJobsFinalized[computeId]) {
            revert JobAlreadyFinalized();
        }
        if (metaComputeResults[computeId].computeId == 0) {
            revert ComputeResultNotFound();
        }

        uint256 computeDiff = block.timestamp - metaComputeResults[computeId].timestamp;
        if (computeDiff > CHALLENGE_WINDOW && metaChallenges[computeId].challenger == address(0x0))
        {
            metaJobsFinalized[computeId] = true;

            emit MetaJobFinalized(computeId);

            return true;
        } else {
            revert CannotFinalizeJob();
        }
    }

    // ---------------------------------------------------------------
    // Getters
    // ---------------------------------------------------------------

    function isAllowlistedComputer(
        address computer
    ) public view returns (bool) {
        return allowlistedComputers[computer];
    }

    // ---------------------------------------------------------------
    // Setters
    // ---------------------------------------------------------------

    function updateChallengeWindow(
        uint64 challengeWindow
    ) public onlyOwner {
        CHALLENGE_WINDOW = challengeWindow;
    }

    function updateRxPWindow(
        uint64 rxpWindow
    ) public onlyOwner {
        RXP_WINDOW = rxpWindow;
    }
}
