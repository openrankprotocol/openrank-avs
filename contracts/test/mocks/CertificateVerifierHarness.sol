// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../src/avs/CertificateVerifier.sol";
import "../../src/interfaces/avs/ICertificateVerifier.sol";
import "../../src/interfaces/core/IReservationRegistry.sol";
import "eigenlayer-middleware/src/BLSSignatureChecker.sol";
import "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";

/**
 * @title CertificateVerifierHarness
 * @notice A harness contract for testing that allows direct manipulation of storage
 */
contract CertificateVerifierHarness is CertificateVerifier {
    constructor(
        ISlashingRegistryCoordinator __slashingRegistryCoordinator,
        IReservationRegistry __reservationRegistry
    ) CertificateVerifier(__slashingRegistryCoordinator, __reservationRegistry) { }

    /**
     * @notice Directly sets a verification record in storage
     * @param responseHash The hash of the response
     * @param record The verification record to set
     */
    function setVerificationRecord(
        bytes32 responseHash,
        ICertificateVerifier.VerificationRecord memory record
    ) external {
        _verificationRecords[responseHash] = record;
    }
}
