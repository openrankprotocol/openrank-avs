// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IOpenRankServiceManager {
    function submitComputeRequest(
        bytes32 trustId,
        bytes32 seedId
    ) external payable returns (uint256 computeId);

    function submitComputeResult(
        uint256 computeId,
        bytes32 commitment,
        bytes32 scoresId
    ) external payable returns (bool);

    function submitChallenge(uint256 computeId) external payable returns (bool);

    function finalizeJob(uint256 computeId) external returns (bool);
}
