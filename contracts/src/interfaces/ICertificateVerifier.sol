// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {BLSSignatureChecker, IBLSSignatureChecker} from "eigenlayer-middleware/src/BLSSignatureChecker.sol";

import "./IReservationRegistry.sol";

interface ICertificateVerifier {
    struct TaskResponse {
        uint32 imageID;
        bytes quorumNumbers;
        uint32 referenceBlockNumber;
        bytes inputData;
        bytes response;
    }

    struct VerificationRecord {
        uint32 referenceBlockNumber;
        bytes32 signatoryRecordHash;
        IBLSSignatureChecker.QuorumStakeTotals quorumStakeTotals;
    }

    error ImageNotFound();
    error CertificateAlreadyVerified();
    error ThresholdNotMet();

    event CertificateVerified(
        TaskResponse taskResponse,
        VerificationRecord verificationRecord
    );

    /// @notice Returns the reservation registry
    /// @return reservationRegistry The reservation registry
    function reservationRegistry() external view returns (IReservationRegistry);

    function verifyCertificate(
        TaskResponse calldata taskResponse,
        IBLSSignatureChecker.NonSignerStakesAndSignature
            calldata nonSignerParams
    ) external;

    function verificationRecords(
        bytes32 taskHash
    ) external view returns (VerificationRecord memory);
}
