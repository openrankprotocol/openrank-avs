// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Initializable} from "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {
    IAllocationManager,
    IAllocationManagerTypes
} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {ICertificateVerifier} from "./interfaces/ICertificateVerifier.sol";
import {IReexecutionSlasher} from "./interfaces/IReexecutionSlasher.sol";
import {IERC20, IReexecutionEndpoint} from "./interfaces/IReexecutionEndpoint.sol";
import {IReservationRegistry} from "./interfaces/IReservationRegistry.sol";
import {
    IIndexRegistry,
    ISlashingRegistryCoordinator,
    IStakeRegistry
} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {SlasherBase} from "eigenlayer-middleware/src/slashers/base/SlasherBase.sol";

/**
 * @title ReexecutionSlasher
 * @notice slashes operators of an invalid certificate based on majority response of Reexecution challenge
 */
contract ReexecutionSlasher is SlasherBase, Initializable, IReexecutionSlasher {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    IStakeRegistry public immutable stakeRegistry;
    IIndexRegistry public immutable indexRegistry;

    IReexecutionEndpoint public immutable reexecutionEndpoint;
    IReservationRegistry public immutable reservationRegistry;
    ICertificateVerifier public immutable certificateVerifier;

    uint32 public reexecutionOperatorSetId;
    mapping(uint256 requestIndex => bytes32) public requestIndexToTaskHash;
    mapping(uint256 requestIndex => bool) public isRequestProcessed;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[47] private __gap;

    constructor(
        IAllocationManager _allocationManager,
        ISlashingRegistryCoordinator _registryCoordinator,
        IReservationRegistry _reservationRegistry,
        IReexecutionEndpoint _reexecutionEndpoint,
        ICertificateVerifier _certificateVerifier
    ) SlasherBase(_allocationManager, _registryCoordinator, address(0)) {
        stakeRegistry = _registryCoordinator.stakeRegistry();
        indexRegistry = _registryCoordinator.indexRegistry();
        certificateVerifier = _certificateVerifier;
        reexecutionEndpoint = _reexecutionEndpoint;
        reservationRegistry = _reservationRegistry;
    }

    function initialize(
        uint32 _reexecutionOperatorSetId
    ) external initializer {
        reexecutionOperatorSetId = _reexecutionOperatorSetId;
    }

    /// @inheritdoc IReexecutionSlasher
    function requestReexecution(
        ICertificateVerifier.TaskResponse calldata taskResponse
    ) external returns (uint256) {
        // lookup VerifcationRecord from taskHash
        bytes32 taskHash = keccak256(abi.encode(taskResponse));
        ICertificateVerifier.VerificationRecord memory verificationRecord =
            certificateVerifier.verificationRecords(taskHash);
        require(verificationRecord.signatoryRecordHash != bytes32(0), CertificateNotFound());

        // transfer payment token to RxSlasher contract which then gets forwarded to ReexecutionEndpoint
        IERC20 paymentToken = reexecutionEndpoint.paymentToken();
        (uint256 paymentAmount,) =
            reexecutionEndpoint.getRequestFee(uint32(reservationRegistry.currentEpochStartBlock()));
        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        paymentToken.safeIncreaseAllowance(address(reexecutionEndpoint), paymentAmount);

        uint256 requestIndex =
            reexecutionEndpoint.requestReexecution(taskResponse.imageID, taskResponse.inputData);
        requestIndexToTaskHash[requestIndex] = taskHash;
        return requestIndex;
    }

    /// @inheritdoc IReexecutionSlasher
    function processFinalizedReexecutionRequest(
        uint256 requestIndex,
        ICertificateVerifier.TaskResponse calldata taskResponse,
        bytes32[] memory signerOperatorIds,
        uint256[] memory signerOperatorIndices,
        bytes32[] memory nonSignerOperatorIds
    ) external {
        // require requestId is finalized
        (IReexecutionEndpoint.RequestStatus status, bytes32 finalizedResponse) =
            reexecutionEndpoint.getFinalizedResponse(requestIndex);
        require(status == IReexecutionEndpoint.RequestStatus.FINALIZED, RequestNotFinalized());
        require(!isRequestProcessed[requestIndex], RequestAlreadyProcessed());
        require(signerOperatorIds.length == signerOperatorIndices.length, ArrayLengthMismatch());

        isRequestProcessed[requestIndex] = true;
        bytes32 taskHash = requestIndexToTaskHash[requestIndex];

        // ensure the taskResponse is the same as the one that was requested for reexecution
        require(taskHash == keccak256(abi.encode(taskResponse)), InvalidTaskResponse());

        // check if the response from the certificate is the same as the finalized response
        // note that the expected RXP response is the hash of the taskResponse.response
        require(keccak256(taskResponse.response) != finalizedResponse, ResponseIsCorrect());

        // finalized response from Reexecution is different from the certificate indicating that signers
        // of original certificate must be slashed

        // read verificationRecord from msgHash
        ICertificateVerifier.VerificationRecord memory verificationRecord =
            certificateVerifier.verificationRecords(taskHash);

        {
            // verify that all operators in calldata are included at the referenceBlockNumber as signers need to be all slashed
            uint256 operatorCount = indexRegistry.totalOperatorsForQuorumAtBlockNumber({
                quorumNumber: uint8(reexecutionOperatorSetId),
                blockNumber: verificationRecord.referenceBlockNumber
            });
            require(
                operatorCount == signerOperatorIds.length + nonSignerOperatorIds.length,
                InvalidOperatorInputParams()
            );

            // verify that the nonsigners in calldata match the nonsigners in the certificate
            bytes32 signatoryRecordHash = keccak256(
                abi.encodePacked(verificationRecord.referenceBlockNumber, nonSignerOperatorIds)
            );
            require(
                signatoryRecordHash == verificationRecord.signatoryRecordHash,
                InvalidNonsignerOperatorIds()
            );
        }

        // generate slashing params
        (IStrategy[] memory strategies, uint256 numStrats) =
            _getOperatorSetStrategies({operatorSetId: reexecutionOperatorSetId});
        uint256[] memory wadsToSlash = new uint256[](numStrats);
        for (uint256 i = 0; i < numStrats; i++) {
            wadsToSlash[i] = 1e17; // placeholder amount to slash
        }
        IAllocationManagerTypes.SlashingParams memory slashingParams = IAllocationManagerTypes
            .SlashingParams({
            operator: address(0),
            operatorSetId: reexecutionOperatorSetId,
            strategies: strategies,
            wadsToSlash: wadsToSlash,
            description: "Reexecution slashing"
        });

        for (uint256 i = 0; i < signerOperatorIds.length; i++) {
            // for each signer in calldata, verify they are included in the certificate
            _verifySignerInclusion(
                verificationRecord.referenceBlockNumber,
                signerOperatorIds[i],
                signerOperatorIndices[i],
                nonSignerOperatorIds
            );

            // slash the operator
            _executeSlashing(requestIndex, signerOperatorIds[i], slashingParams);
        }
    }

    /// @notice slash operators in EigenLayer
    function _executeSlashing(
        uint256 requestId,
        bytes32 operatorId,
        IAllocationManagerTypes.SlashingParams memory params
    ) internal {
        params.operator = slashingRegistryCoordinator.getOperatorFromId(operatorId);
        _fulfillSlashingRequest(requestId, params);
    }

    /// @dev Read operatorSet strategies from stakeRegistry
    function _getOperatorSetStrategies(
        uint32 operatorSetId
    ) internal view returns (IStrategy[] memory strategies, uint256 numStrats) {
        // slash operators on AllocationManager
        // get length of strategies in quorum 0
        numStrats = stakeRegistry.strategyParamsLength(uint8(operatorSetId));
        strategies = new IStrategy[](numStrats);
        for (uint256 i = 0; i < numStrats; i++) {
            strategies[i] = stakeRegistry.strategyParamsByIndex(uint8(operatorSetId), i).strategy;
        }
    }

    /**
     * @notice verify signer inclusion in the certificate by checking the following:
     * - signer is not included in the list of nonsigner ids
     * - signer was registered for the AVS at the referenceBlockNumber
     */
    function _verifySignerInclusion(
        uint32 referenceBlockNumber,
        bytes32 signer,
        uint256 signerOperatorIndex,
        bytes32[] memory nonSignerOperatorIds
    ) internal view {
        // check that signer was registered for the AVS at the referenceBlockNumber
        uint192 signerBitmap = slashingRegistryCoordinator.getQuorumBitmapAtBlockNumberByIndex(
            signer, referenceBlockNumber, signerOperatorIndex
        );
        require((signerBitmap >> reexecutionOperatorSetId) & 1 == 1, InvalidSigner());

        // linear search to ensure signer does not exist in nonSignerOperatorIds which has already been
        // verified to be the list of nonsigners in the certificate
        for (uint256 i = 0; i < nonSignerOperatorIds.length; ++i) {
            require(nonSignerOperatorIds[i] != signer, InvalidSigner());
        }
    }

    function _checkSlasher(
        address account
    ) internal view override {
        // permissionless slasher
    }
}
