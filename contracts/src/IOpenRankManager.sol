// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IOpenRankManager {
    error ComputeRequestNotFound();
    error ComputeResultAlreadySubmitted();
    error ComputeResultNotFound();
    error ChallengeNotFound();
    error ChallengePeriodExpired();
    error CallerNotWhitelisted();
    error InvalidReservationForImageId();

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
        uint32 subJobId;
        bytes certificate;
        uint256 timestamp;
        uint256 requestIndex;
    }

    event MetaComputeRequestEvent(uint256 indexed computeId, bytes32 jobDescriptionId);
    event MetaComputeResultEvent(uint256 indexed computeId, bytes32 commitment, bytes32 resultsId);
    event MetaChallengeEvent(
        uint256 indexed computeId,
        uint32 subJobId,
        bytes certificate
    );

    function setImageId(
        uint32 _imageId
    ) external;
    function submitMetaComputeRequest(
        bytes32 jobDescriptionId
    ) external returns (uint256 computeId);
    function submitMetaComputeResult(
        uint256 computeId,
        bytes32 metaCommitment,
        bytes32 resultsId
    ) external returns (bool);
    function submitMetaChallenge(
        uint256 computeId,
        uint32 subJobId,
        bytes memory certificate
    ) external returns (bool);
    function isAllowlistedComputer(
        address computer
    ) external returns (bool);
    function updateChallengeWindow(
        uint64 challengeWindow
    ) external;
}
