// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IReservationRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "eigenda/contracts/src/interfaces/IEigenDACertVerifier.sol";

abstract contract ReservationRegistryStorage is IReservationRegistry {
    // Constant variables
    /// @inheritdoc IReservationRegistry
    uint256 public constant MAX_IMAGE_DA_CERTS = 64; // each DA blob is max 16 MiB, so 64 DA blobs is max 1 GiB

    // Immutable variables
    /// @inheritdoc IReservationRegistry
    IReexecutionEndpoint public immutable reexecutionEndpoint;
    /// @inheritdoc IReservationRegistry
    IEigenDACertVerifier public immutable certificateVerifier;
    /// @inheritdoc IReservationRegistry
    IIndexRegistry public immutable indexRegistry;
    /// @inheritdoc IReservationRegistry
    address public immutable operatorFeeDistributor;
    /// @inheritdoc IReservationRegistry
    IERC20 public immutable paymentToken;
    /// @inheritdoc IReservationRegistry
    uint256 public immutable epochLengthBlocks;
    /// @inheritdoc IReservationRegistry
    uint256 public immutable epochGenesisBlock;
    /// @inheritdoc IReservationRegistry
    uint256 public immutable reservationBondAmount;

    // Storage variables
    /// @inheritdoc IReservationRegistry
    uint256 public prepaidBilledEpochs;
    /// @inheritdoc IReservationRegistry
    uint256 public resourceCostPerOperatorPerEpoch;

    /// @inheritdoc IReservationRegistry
    uint256 public maxImagesPerReservation;
    /// @inheritdoc IReservationRegistry
    uint256 public maxReservations;
    /// @inheritdoc IReservationRegistry
    uint256 public nextReservationId;
    /// @inheritdoc IReservationRegistry
    uint256 public activeReservationCount;
    /// @inheritdoc IReservationRegistry
    uint32 public nextImageId;

    // Reservations and images
    mapping(uint256 reservationID => Reservation reservation)
        internal _reservations;
    mapping(uint256 reservationID => EnumerableSet.UintSet imageIDs)
        internal _reservationImageIDs;
    mapping(uint32 imageID => Image image) internal _images;

    // Set to track active reservation IDs
    EnumerableSet.UintSet internal _activeReservationIds;

    constructor(
        IReexecutionEndpoint _reexecutionEndpoint,
        IEigenDACertVerifier _certificateVerifier,
        IIndexRegistry _indexRegistry,
        address _operatorFeeDistributor,
        IERC20 _paymentToken,
        uint256 _epochLengthBlocks,
        uint256 _epochGenesisBlock,
        uint256 _reservationBondAmount
    ) {
        reexecutionEndpoint = _reexecutionEndpoint;
        certificateVerifier = _certificateVerifier;
        indexRegistry = _indexRegistry;
        operatorFeeDistributor = _operatorFeeDistributor;
        paymentToken = _paymentToken;
        epochLengthBlocks = _epochLengthBlocks;
        epochGenesisBlock = _epochGenesisBlock;
        reservationBondAmount = _reservationBondAmount;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[41] private __gap;
}
