// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.9.0;

import "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";

struct StakeRoot {
    uint8 operatorSetId;
    uint32 referenceBlockNumber;
    bytes32 stakeRoot;
}

struct StakeTable {
    uint32 operatorSetId;
    // the block number against which the stakeTable was generated
    uint32 referenceBlockNumber;
    // the underlying stakeTable
    QuorumTotals quorumTotals;
    OperatorInfo[] operatorInfos;
}

struct Certificate {
    bytes32 msgHash;
    uint8 quorumNumber;
    uint32 referenceBlockNumber;
    bytes quorumTotalProof;
    QuorumTotals quorumTotal;
    uint256[] operatorIndices;
    bytes[] operatorProofs;
    OperatorInfo[] operatorInfos;
    // the apkG2 and signatureG1 for bls
    // the list of all signatures for ECDSA
    bytes signatureData;
}

struct QuorumTotals {
    bytes aggregatedKey;
    uint96[] totalStakes;
}

struct OperatorInfo {
    bytes key;
    uint96[] stakes;
}

interface ICertificateRegistry {
    /// @notice the avs that the certificate registry is for
    function avs() external view returns (address);

    /// @notice the address of the entity allowed to set and update stakes
    function transporter() external view returns (address);

    /**
     * @notice intializes the stakeRoot of operatorSets
     * @param stakeRoots a StakeRoot object for each operatorSet being
     * initialized
     * @dev only callable by stakeTableTransporter
     * @dev callable only once for each operatorSet, but can be called seperately
     * for new operatorSets over time
     */
    function initializeStakeRoots(
        StakeRoot[] calldata stakeRoots
    ) external;

    /**
     * @notice intializes the stakes of operatorSets
     * @param stakeTables a StakeTable object for each operatorSet
     * being initialized
     * @dev only callable by stakeTableTransporter
     * @dev callable only once for each operatorSet, but can be called seperately
     * for new operatorSets over time
     */
    function initializeStakeTables(
        StakeTable[] calldata stakeTables
    ) external;

    /**
     * @notice updates the stake root of operatorSets
     * @param stakeRoots the StakeRoot object for each operatorSet being updated
     * @dev only callable by stakeTableTransporter
     * @dev all operatorSets must be initialized before
     */
    function updateStakeRoots(
        StakeRoot[] calldata stakeRoots
    ) external;

    /**
     * @notice updates the stakes of operatorSets
     * @param stakeTables the StakeTable object for each operatorSet being
     * updated
     * @dev only callable by stakeTableTransporter
     * @dev all operatorSets must be initialized before
     */
    function updateStakeTables(
        StakeTable[] calldata stakeTables
    ) external;

    /**
     * @notice verifies a set of certificates
     * @param certs an array of certificates to verify
     * @dev caches the verification result in case called with the same cert
     *  twice
     */
    function verifyCertificates(
        Certificate[] calldata certs
    ) external;
}
