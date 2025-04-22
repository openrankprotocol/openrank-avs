// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.9.0;

import "./IStatusBridge.sol";
import "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";

// EVENTS

/// @notice Emitted when a call is forwarded after successful signature verification
event CallForwarded(address target, bytes data, bytes32 msgHash, bytes32 signatoryRecordHash);

// ERRORS

/// @notice Thrown when the signed stake is insufficient
error ISignatureGuardedForwarder_InsufficientSignedStake();
/// @notice Thrown when the reference block number is too old
error ISignatureGuardedForwarder_ReferenceBlockNumberStale();

/**
 * @title ISignatureGuardedForwarder
 * @notice A contract that forwards arbitrary calls after verifying BLS signatures from authorized operators
 */
interface ISignatureGuardedForwarder {
    /// @notice The BLSSignatureChecker contract used for signature verification
    function signatureChecker() external view returns (IBLSSignatureChecker);

    /// @notice The status bridge contract
    function statusBridge() external view returns (IStatusBridge);

    /**
     * @notice Forward a call after verifying BLS signatures
     * @param target The address to forward the call to
     * @param data The calldata to forward
     * @param referenceBlockNumber The block number to use for stake calculations
     * @param params The signature verification parameters
     * @dev sets the latestForwardBlockNumber in the status bridge
     */
    function forward(
        address target,
        bytes calldata data,
        uint32 referenceBlockNumber,
        IBLSSignatureChecker.NonSignerStakesAndSignature calldata params
    ) external;
}
