// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

contract OpenRankManager {
    error ComputeRequestNotFound();
    error ComputeResultAlreadySubmitted();
    error ComputeResultNotFound();
    error ChallengeNotFound();
    error ChallengePeriodExpired();
    error JobAlreadyFinalized();
    error CannotFinalizeJob();
    error InvalidFee();
    error InvalidStake();
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

    uint64 public constant CHALLENGE_WINDOW = 60;
    uint64 public constant RXP_WINDOW = 60;
    uint256 public constant FEE = 100;
    uint256 public constant STAKE = 100;

    uint256 public idCounter;
    mapping(address => bool) whitelistedComputers;
    mapping(address => bool) whitelistedChallengers;
    mapping(address => bool) whitelistedUsers;
    mapping(uint256 => ComputeRequest) computeRequests;
    mapping(uint256 => ComputeResult) computeResults;
    mapping(uint256 => Challenge) challenges;
    mapping(uint256 => bool) finalizedJobs;

    event ComputeRequestEvent(
        uint256 indexed computeId,
        bytes32 trust_id,
        bytes32 seed_id
    );
    event ComputeResultEvent(
        uint256 indexed computeId,
        bytes32 commitment,
        bytes32 scores_id
    );
    event ChallengeEvent(uint256 indexed computeId);
    event JobFinalized(uint256 indexed computeId);

    constructor(
        address[] memory computers,
        address[] memory challengers,
        address[] memory users
    ) {
        idCounter = 1;

        for (uint256 i = 0; i < computers.length; i++) {
            whitelistedComputers[computers[i]] = true;
        }

        for (uint256 i = 0; i < challengers.length; i++) {
            whitelistedChallengers[challengers[i]] = true;
        }

        for (uint256 i = 0; i < users.length; i++) {
            whitelistedUsers[users[i]] = true;
        }
    }

    function submitComputeRequest(
        bytes32 trustId,
        bytes32 seedId
    ) external payable returns (uint256 computeId) {
        if (!whitelistedUsers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (msg.value != FEE) {
            revert InvalidFee();
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
    ) external payable returns (bool) {
        if (!whitelistedComputers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (computeRequests[computeId].id == 0) {
            revert ComputeRequestNotFound();
        }
        if (computeResults[computeId].computeId != 0) {
            revert ComputeResultAlreadySubmitted();
        }
        if (msg.value != STAKE) {
            revert InvalidStake();
        }

        ComputeResult memory computeResult = ComputeResult({
            computer: payable(msg.sender),
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
    ) external payable returns (bool) {
        if (!whitelistedChallengers[msg.sender]) {
            revert CallerNotWhitelisted();
        }
        if (computeRequests[computeId].id == 0) {
            revert ComputeRequestNotFound();
        }
        if (computeResults[computeId].computeId == 0) {
            revert ComputeResultNotFound();
        }

        uint256 computeDiff = block.timestamp -
            computeResults[computeId].timestamp;
        if (computeDiff > CHALLENGE_WINDOW) {
            revert ChallengePeriodExpired();
        } else {
            Challenge memory challenge = Challenge({
                challenger: payable(msg.sender),
                timestamp: block.timestamp
            });
            challenges[computeId] = challenge;

            payable(challenge.challenger).transfer(FEE + STAKE);
            finalizedJobs[computeId] = true;

            emit ChallengeEvent(computeId);
            emit JobFinalized(computeId);
            return true;
        }
    }

    function finalizeJob(uint256 computeId) external returns (bool) {
        if (finalizedJobs[computeId]) {
            revert JobAlreadyFinalized();
        }
        if (computeResults[computeId].computeId == 0) {
            revert ComputeResultNotFound();
        }

        uint256 computeDiff = block.timestamp -
            computeResults[computeId].timestamp;
        if (
            computeDiff > CHALLENGE_WINDOW &&
            challenges[computeId].challenger == address(0x0)
        ) {
            payable(computeResults[computeId].computer).transfer(FEE + STAKE);
            finalizedJobs[computeId] = true;

            emit JobFinalized(computeId);

            return true;
        } else {
            revert CannotFinalizeJob();
        }
    }
}
