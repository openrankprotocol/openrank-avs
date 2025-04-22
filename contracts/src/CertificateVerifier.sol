// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ICertificateVerifier, IReservationRegistry} from "./interfaces/ICertificateVerifier.sol";
import {BLSSignatureChecker} from "eigenlayer-middleware/src/BLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";

/**
 * @title CertificateVerifier
 * @notice Verifies certificates for the AVS
 */
contract CertificateVerifier is ICertificateVerifier, BLSSignatureChecker {
    // IMMUTABLES
    /// @inheritdoc ICertificateVerifier
    IReservationRegistry public immutable reservationRegistry;

    // CONSTANTS
    uint256 public constant DENOMINATOR = 1e18;
    uint256 public constant THRESHOLD = DENOMINATOR / 2;

    mapping(bytes32 taskHash => VerificationRecord)
        internal _verificationRecords;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;

    constructor(
        ISlashingRegistryCoordinator __slashingRegistryCoordinator,
        IReservationRegistry __reservationRegistry
    ) BLSSignatureChecker(__slashingRegistryCoordinator) {
        reservationRegistry = __reservationRegistry;
    }

    function verifyCertificate(
        TaskResponse calldata taskResponse,
        NonSignerStakesAndSignature calldata nonSignerParams
    ) external {
        IReservationRegistry.Image memory image = reservationRegistry.getImage(
            taskResponse.imageID
        );
        require(image.imageDACerts.length > 0, ImageNotFound());

        bytes32 taskHash = keccak256(abi.encode(taskResponse));
        require(
            _verificationRecords[taskHash].signatoryRecordHash == bytes32(0),
            CertificateAlreadyVerified()
        );

        (
            QuorumStakeTotals memory quorumStakeTotals,
            bytes32 signatoryRecordHash
        ) = checkSignatures(
                taskHash,
                taskResponse.quorumNumbers, // use list of uint8s instead of uint256 bitmap to not iterate 256 times
                taskResponse.referenceBlockNumber,
                nonSignerParams
            );

        for (
            uint256 i = 0;
            i < quorumStakeTotals.signedStakeForQuorum.length;
            i++
        ) {
            require(
                quorumStakeTotals.signedStakeForQuorum[i] * DENOMINATOR >
                    quorumStakeTotals.totalStakeForQuorum[i] * THRESHOLD,
                ThresholdNotMet()
            );
        }

        VerificationRecord memory verificationRecord = VerificationRecord({
            referenceBlockNumber: taskResponse.referenceBlockNumber,
            signatoryRecordHash: signatoryRecordHash,
            quorumStakeTotals: quorumStakeTotals
        });
        _verificationRecords[taskHash] = verificationRecord;

        emit CertificateVerified(taskResponse, verificationRecord);
    }

    function verificationRecords(
        bytes32 taskHash
    ) external view returns (VerificationRecord memory) {
        return _verificationRecords[taskHash];
    }
}
