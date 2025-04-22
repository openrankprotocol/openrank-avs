// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IReexecutionEndpoint.sol";
import "eigenda/contracts/src/interfaces/IEigenDACertVerifier.sol";
import "eigenda/contracts/src/interfaces/IEigenDAStructs.sol";
import "eigenlayer-contracts/src/contracts/mixins/PermissionControllerMixin.sol";
import "eigenlayer-middleware/src/interfaces/IIndexRegistry.sol";
/**
 * @title IReservationRegistry
 * @notice Interface for the ReservationRegistry contract
 * @dev This contract manages reservations for re-execution of images by AVSs
 */

interface IReservationRegistry {
    error MaxReservationsReached();
    error InsufficientPayment();
    error ReservationNotActive();
    error MaxImagesPerReservationReached();
    error ImageNotAdded();
    error RequestsAreActive();
    error ImageTooLarge();
    error ImageNotFound();

    struct ReservationRegistryConstructorParams {
        IPermissionController permissionController;
        IReexecutionEndpoint reexecutionEndpoint;
        IEigenDACertVerifier certificateVerifier;
        IIndexRegistry indexRegistry;
        address operatorFeeDistributor;
        IERC20 paymentToken;
        uint256 epochLengthBlocks;
        uint256 epochGenesisBlock;
        uint256 reservationBondAmount;
    }

    /**
     * @notice Struct representing a reservation for re-execution
     * @param avs The address of the AVS the reservation belongs to
     * @param balance The current balance of the reservation
     * @param lastDeductionEpoch The epoch number of the last fee deduction
     * @param active Whether the reservation is active
     */
    struct Reservation {
        address avs;
        uint256 balance;
        uint32 lastDeductionEpoch;
        bool active;
    }

    struct EigenDACertificateData {
        BatchHeaderV2 batchHeader;
        BlobInclusionInfo blobInclusionInfo;
        NonSignerStakesAndSignature nonSignerStakesAndSignature;
        bytes signedQuorumNumbers;
    }

    /**
     * @notice Struct representing a reserved image
     * @param reservationID The ID of the reservation the image belongs to
     * @param imageDACerts The EigenDA certificates that compose the image
     * @param creationTime The creation time of the image
     */
    struct Image {
        uint256 reservationID;
        bytes[] imageDACerts;
        uint32 creationTime;
    }

    /**
     * @notice Event emitted when a new reservation is created
     * @param reserver The address that made the reservation
     * @param reservationID The ID of the reservation
     * @param initialBalance The initial balance of the reservation
     */
    event ReservationCreated(address indexed reserver, uint256 indexed reservationID, uint256 initialBalance);

    /**
     * @notice Event emitted when an image is added to a reservation
     * @param reservationID The ID of the reservation
     * @param imageID The ID of the image
     */
    event ImageAdded(uint256 indexed reservationID, uint32 indexed imageID);

    /**
     * @notice Event emitted when an image is removed from a reservation
     * @param reservationID The ID of the reservation
     * @param imageID The ID of the image
     */
    event ImageRemoved(uint256 indexed reservationID, uint32 indexed imageID);

    /**
     * @notice Event emitted when a reservation's balance is updated
     * @param reservationID The ID of the reservation
     * @param newBalance The new balance of the reservation
     */
    event ReservationBalanceUpdated(uint256 indexed reservationID, uint256 newBalance);

    /**
     * @notice Event emitted when a reservation is deactivated
     * @param reservationID The ID of the reservation
     */
    event ReservationDeactivated(uint256 indexed reservationID);

    /**
     * @notice Event emitted when fees are deducted from a reservation
     * @param reservationID The ID of the reservation
     * @param amount The amount deducted
     */
    event ReservationFeesDeducted(uint256 indexed reservationID, uint256 amount);

    // STATE VARIABLES AND IMMUTABLES AND CONSTANTS

    /**
     * @notice Returns the maximum number of DA certificates allowed per image
     * @return The maximum number of DA certificates
     */
    function MAX_IMAGE_DA_CERTS() external pure returns (uint256);

    /**
     * @notice The reexecution endpoint
     * @return The address of the reexecution endpoint
     */
    function reexecutionEndpoint() external view returns (IReexecutionEndpoint);

    /**
     * @notice The EigenDA certificate verifier
     * @return The address of the EigenDA certificate verifier
     */
    function certificateVerifier() external view returns (IEigenDACertVerifier);

    /**
     * @notice The index registry
     * @return The address of the index registry
     */
    function indexRegistry() external view returns (IIndexRegistry);

    /**
     * @notice The operator fee distributor address
     * @return The address of the operator fee distributor
     */
    function operatorFeeDistributor() external view returns (address);

    /**
     * @notice The payment token used for reservations
     * @return The ERC20 token used for payments
     */
    function paymentToken() external view returns (IERC20);

    /**
     * @notice The length of an epoch in blocks
     * @return The number of blocks in an epoch
     */
    function epochLengthBlocks() external view returns (uint256);

    /**
     * @notice The genesis block for epoch calculations
     * @return The block number of the genesis block
     */
    function epochGenesisBlock() external view returns (uint256);

    /**
     * @notice The number of billing epochs that must be prepaid
     * @return The number of prepaid epochs
     */
    function prepaidBilledEpochs() external view returns (uint256);

    /**
     * @notice The resource cost per operator per billing epochs
     * @return The cost per operator per epoch
     */
    function resourceCostPerOperatorPerEpoch() external view returns (uint256);

    /**
     * @notice A one-time bond amount paid per reservation by an AVS.
     * This bond can be confiscated and the reservation can be removed by governance
     * in case the image is proven to be nondeterministic.
     * TODO: determinism challenge flow
     * @return The reservation bond amount
     */
    function reservationBondAmount() external view returns (uint256);

    /**
     * @notice The maximum number of images per reservation
     * @return The maximum number of images
     */
    function maxImagesPerReservation() external view returns (uint256);

    /**
     * @notice The maximum number of reservations allowed
     * @return The maximum number of reservations
     */
    function maxReservations() external view returns (uint256);

    /**
     * @notice The next reservation ID assigned to a new reservation
     * @return The next reservation ID
     */
    function nextReservationId() external view returns (uint256);

    /**
     * @notice The current number of active reservations
     * @return The count of active reservations
     */
    function activeReservationCount() external view returns (uint256);

    /**
     * @notice Initializes the contract with the required parameters
     * @param initialOwner The initial owner of the contract
     * @param _prepaidBilledEpochs The number of epochs that must be prepaid
     * @param _resourceCostPerOperatorPerEpoch The resource cost per operator per epoch
     * @param _maxImagesPerReservation The maximum number of images per reservation
     * @param _maxReservations The maximum number of reservations allowed
     */
    function initialize(
        address initialOwner,
        uint256 _prepaidBilledEpochs,
        uint256 _resourceCostPerOperatorPerEpoch,
        uint256 _maxImagesPerReservation,
        uint256 _maxReservations
    ) external;

    // PERMISSIONED FUNCTIONS

    /**
     * @notice Sets the maximum number of images per reservation
     * @param _maxImagesPerReservation The new maximum number of images per reservation
     */
    function setMaxImagesPerReservation(
        uint256 _maxImagesPerReservation
    ) external;

    /**
     * @notice Sets the prepaid billing epochs
     * @param _prepaidBilledEpochs The new prepaid billing epochs
     */
    function setPrepaidBilledEpochs(
        uint256 _prepaidBilledEpochs
    ) external;

    /**
     * @notice Sets the resource cost per operator per epoch
     * @param cost The new cost
     */
    function setResourceCostPerOperatorPerEpoch(
        uint256 cost
    ) external;

    /**
     * @notice Sets the maximum number of reservations allowed
     * @param _maxReservations The new maximum number of reservations
     */
    function setMaxReservations(
        uint256 _maxReservations
    ) external;

    // CORE LOGIC

    /**
     * @notice Creates a new reservation for re-execution
     * @param avs The address of the AVS the reservation belongs to
     * @param paymentAmount The amount of tokens to pay for the reservation
     * @return reservationID The ID of the reservation
     */
    function reserve(address avs, uint256 paymentAmount) external returns (uint256 reservationID);

    /**
     * @notice Gets the number of tokens required to reserve a reservation
     * @return transferAmount The number of tokens required to reserve a reservation
     */
    function getReservationTransferAmount() external view returns (uint256);

    /**
     * @notice Adds an image to a reservation
     * @param reservationID The ID of the reservation
     * @param imageDACerts The EigenDA certificates that compose the image
     * @return imageID The ID of the image
     */
    function addImage(uint256 reservationID, bytes[] calldata imageDACerts) external returns (uint32 imageID);

    /**
     * @notice Removes an image from a reservation
     * @param reservationID The ID of the reservation
     * @param imageID The ID of the image
     */
    function removeImage(uint256 reservationID, uint32 imageID) external;

    /**
     * @notice Adds funds to an existing reservation
     * @param reservationID The ID of the reservation
     * @param paymentAmount The amount of tokens to add
     */
    function addFunds(uint256 reservationID, uint256 paymentAmount) external;

    /**
     * @notice Deducts fees from reservations and sends them to operators
     * @param reservationIDs The IDs of the reservations to deduct fees from
     */
    function deductFees(
        uint256[] calldata reservationIDs
    ) external;

    // VIEW FUNCTIONS

    /**
     * @notice Checks if an image is attached to an active reservation
     * @param imageID The ID of the image
     * @return isValid Whether the reservation is valid for a request
     */
    function isImageAdded(
        uint32 imageID
    ) external view returns (bool isValid);

    /**
     * @notice Gets all active reservation IDs
     * @return Array of active reservation IDs
     */
    function getActiveReservationIds() external view returns (uint256[] memory);

    /**
     * @notice Gets a reservation by ID
     * @param reservationID The ID of the reservation
     * @return reservation The reservation
     */
    function getReservation(
        uint256 reservationID
    ) external view returns (Reservation memory reservation);

    /**
     * @notice Gets all reservations for an AVS and their IDs
     * @param avs The address of the AVS
     * @return reservationIDs The reservation IDs
     * @return reservations The reservations
     */
    function getReservationsForAVS(
        address avs
    ) external view returns (uint256[] memory reservationIDs, Reservation[] memory reservations);

    /**
     * @notice Gets all images for a reservation
     * @param reservationID The ID of the reservation
     * @return imageIDs The image IDs
     * @return images The images
     */
    function getImages(
        uint256 reservationID
    ) external view returns (uint32[] memory imageIDs, Image[] memory images);

    /**
     * @notice Gets an image by ID
     * @param imageID The ID of the image
     * @return image The image
     */
    function getImage(
        uint32 imageID
    ) external view returns (Image memory image);

    /**
     * @notice Gets the reservationID for an imageID
     * @param imageID The ID of the image
     * @return reservationID The ID of the reservation
     */
    function getReservationIDForImageID(
        uint32 imageID
    ) external view returns (uint256 reservationID);

    /**
     * @notice Gets the next image ID to be assigned
     * @return The next image ID
     */
    function nextImageId() external view returns (uint32);

    /**
     * @notice Gets the prepaid reservation fee required to create a reservation
     * Includes the calculated fees for operator compute resources over prepaidBilledEpochs
     * @param numOperators The number of operators in the epoch
     * @return fee The required fee
     */
    function prepaidReservationFee(
        uint32 numOperators
    ) external view returns (uint256 fee);

    /**
     * @notice Returns the epoch number for a given block number
     * @param blocknumber The block number to get the epoch for
     * @return The epoch number
     */
    function getEpochFromBlocknumber(
        uint256 blocknumber
    ) external view returns (uint32);

    /**
     * @notice Returns the current epoch number
     * @return The current epoch number
     */
    function currentEpoch() external view returns (uint32);

    /**
     * @notice Returns the start block from the current epoch
     * @return The start block number
     */
    function currentEpochStartBlock() external view returns (uint256);
}
