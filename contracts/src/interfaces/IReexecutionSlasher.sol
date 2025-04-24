// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ICertificateVerifier} from "./ICertificateVerifier.sol";
import {
    BLSSignatureChecker,
    IBLSSignatureChecker
} from "eigenlayer-middleware/src/BLSSignatureChecker.sol";

interface IReexecutionSlasher {
    error InvalidSigner();
    error CertificateNotFound();
    error RequestNotFinalized();
    error RequestAlreadyProcessed();
    error ResponseIsCorrect();
    error ArrayLengthMismatch();
    error InvalidOperatorInputParams();
    error InvalidNonsignerOperatorIds();
    error InvalidTaskResponse();

    /**
     * @notice Request reexecution of a certificate. Forwards payment token from msg.sender to ReexecutionEndpoint.
     * Keeps track of requestIndex to msgHash mapping.
     * @param taskResponse the task response that was signed
     */
    function requestReexecution(
        ICertificateVerifier.TaskResponse calldata taskResponse
    ) external returns (uint256);

    /**
     * @notice Process a finalized reexecution request. If the finalized response of reexecution does not match
     * the original certificate, then the original signers are slashed. The signers/nonsigners in the calldata
     * are verified against the signatoryRecordHash in the certificate.
     * TODO: Gas costs of this calls and slashing of all signer operators.
     * Slashing may need to be done in multi tx manner.
     */
    function processFinalizedReexecutionRequest(
        uint256 requestIndex,
        ICertificateVerifier.TaskResponse calldata taskResponse,
        bytes32[] memory signerOperatorIds,
        uint256[] memory signerOperatorIndices,
        bytes32[] memory nonSignerOperatorIds
    ) external;
}
