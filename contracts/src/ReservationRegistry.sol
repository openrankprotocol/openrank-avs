// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./libraries/RxpConstants.sol";
import "./ReservationRegistryStorage.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "eigenda/contracts/src/interfaces/IEigenDACertVerifier.sol";
import "eigenlayer-contracts/src/contracts/mixins/PermissionControllerMixin.sol";

/**
 * @title ReservationRegistry
 * @notice Implementation of the ReservationRegistry contract
 * @dev This contract manages reservations for re-execution of images by AVSs
 */
contract ReservationRegistry is
    PermissionControllerMixin,
    OwnableUpgradeable,
    ReservationRegistryStorage
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    constructor(
        ReservationRegistryConstructorParams memory params
    )
        PermissionControllerMixin(params.permissionController)
        ReservationRegistryStorage(
            params.reexecutionEndpoint,
            params.certificateVerifier,
            params.indexRegistry,
            params.operatorFeeDistributor,
            params.paymentToken,
            params.epochLengthBlocks,
            params.epochGenesisBlock,
            params.reservationBondAmount
        )
    {
        _disableInitializers();
    }

    /// @inheritdoc IReservationRegistry
    function initialize(
        address initialOwner,
        uint256 _prepaidBilledEpochs,
        uint256 _resourceCostPerOperatorPerEpoch,
        uint256 _maxImagesPerReservation,
        uint256 _maxReservations
    ) external initializer {
        __Ownable_init();

        prepaidBilledEpochs = _prepaidBilledEpochs;
        resourceCostPerOperatorPerEpoch = _resourceCostPerOperatorPerEpoch;
        maxImagesPerReservation = _maxImagesPerReservation;
        maxReservations = _maxReservations;

        _transferOwnership(initialOwner);
    }

    /// PERMISSIONED FUNCTIONS

    /// @inheritdoc IReservationRegistry
    function setMaxImagesPerReservation(
        uint256 _maxImagesPerReservation
    ) external onlyOwner {
        maxImagesPerReservation = _maxImagesPerReservation;
    }

    /// @inheritdoc IReservationRegistry
    function setPrepaidBilledEpochs(
        uint256 _prepaidBilledEpochs
    ) external onlyOwner {
        prepaidBilledEpochs = _prepaidBilledEpochs;
    }

    /// @inheritdoc IReservationRegistry
    function setResourceCostPerOperatorPerEpoch(
        uint256 cost
    ) external onlyOwner {
        resourceCostPerOperatorPerEpoch = cost;
    }

    /// @inheritdoc IReservationRegistry
    function setMaxReservations(
        uint256 _maxReservations
    ) external onlyOwner {
        maxReservations = _maxReservations;
    }

    /// CORE LOGIC

    /// @inheritdoc IReservationRegistry
    function reserve(
        address avs,
        uint256 transferAmount
    ) external checkCanCall(avs) returns (uint256 reservationID) {
        require(activeReservationCount < maxReservations, MaxReservationsReached());
        require(transferAmount >= getReservationTransferAmount(), InsufficientPayment());

        // Create reservation
        reservationID = nextReservationId;
        _reservations[reservationID] = Reservation({
            avs: avs,
            balance: transferAmount,
            lastDeductionEpoch: currentEpoch(),
            active: true
        });
        _activeReservationIds.add(reservationID);
        nextReservationId++;
        activeReservationCount++;
        emit ReservationCreated(avs, reservationID, transferAmount);

        // Transfer tokens from sender to this contract
        paymentToken.safeTransferFrom(msg.sender, address(this), transferAmount);
    }

    /// @inheritdoc IReservationRegistry
    function addImage(
        uint256 reservationID,
        bytes[] calldata imageDACerts
    ) external returns (uint32 imageID) {
        Reservation memory reservation = _reservations[reservationID];
        require(reservation.active, ReservationNotActive());
        require(_checkCanCall(reservation.avs), InvalidPermissions());
        require(
            _reservationImageIDs[reservationID].length() < maxImagesPerReservation,
            MaxImagesPerReservationReached()
        );
        require(imageDACerts.length <= MAX_IMAGE_DA_CERTS, ImageTooLarge());

        // TODO Commented out for now for POC testing purposes
        // _verifyImageCertificates(image);

        // Generate new image ID
        imageID = nextImageId;
        nextImageId++;

        _reservationImageIDs[reservationID].add(imageID);
        _images[imageID] = Image({
            reservationID: reservationID,
            imageDACerts: imageDACerts,
            creationTime: uint32(block.timestamp)
        }); // Updated Image struct
        emit ImageAdded(reservationID, imageID);
    }

    /// @inheritdoc IReservationRegistry
    function removeImage(uint256 reservationID, uint32 imageID) external {
        Reservation memory reservation = _reservations[reservationID];
        require(reservation.active, ReservationNotActive());
        require(_checkCanCall(reservation.avs), InvalidPermissions());
        require(_reservationImageIDs[reservationID].remove(imageID), ImageNotAdded());

        // TODO: COMMENT OUT IMPORTANT CHECK FOR DEVNET
        // require(reexecutionEndpoint.getRequestsInCurrentWindow(reservationID) == 0, RequestsAreActive());

        delete _images[imageID];
        emit ImageRemoved(reservationID, imageID);
    }

    /// @inheritdoc IReservationRegistry
    function addFunds(uint256 reservationID, uint256 paymentAmount) external {
        Reservation storage reservation = _reservations[reservationID];
        require(reservation.active, ReservationNotActive());
        require(_checkCanCall(reservation.avs), InvalidPermissions());
        // Transfer tokens from sender to this contract
        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        reservation.balance += paymentAmount;

        emit ReservationBalanceUpdated(reservationID, reservation.balance);
    }

    /// @inheritdoc IReservationRegistry
    function deductFees(
        uint256[] calldata reservationIDs
    ) external {
        uint256 totalFees = 0;

        for (uint256 i = 0; i < reservationIDs.length; i++) {
            uint256 reservationID = reservationIDs[i];
            Reservation storage reservation = _reservations[reservationID];
            require(_checkCanCall(reservation.avs), InvalidPermissions());

            if (!reservation.active) {
                continue;
            }

            // Check if it's time to deduct fees
            uint32 epoch = currentEpoch();
            uint256 numPassedEpochs = epoch - reservation.lastDeductionEpoch;
            uint32 currentNumOperators = indexRegistry.totalOperatorsForQuorumAtBlockNumber({
                quorumNumber: RxpConstants.OPERATOR_SET_ID_UINT8,
                blockNumber: uint32(currentEpochStartBlock())
            });

            if (numPassedEpochs > 0) {
                uint256 billAmount =
                    resourceCostPerOperatorPerEpoch * currentNumOperators * numPassedEpochs;

                if (billAmount >= reservation.balance) {
                    // Deactivate reservation due to insufficient balance
                    billAmount = reservation.balance;
                    reservation.active = false;
                    activeReservationCount--;
                    // Remove from active reservation IDs set
                    _activeReservationIds.remove(reservationID);

                    emit ReservationDeactivated(reservationID);
                } else {
                    // Deduct fees from reservation
                    reservation.balance -= billAmount;
                    reservation.lastDeductionEpoch = epoch;
                    totalFees += billAmount;

                    emit ReservationFeesDeducted(reservationID, billAmount);
                    emit ReservationBalanceUpdated(reservationID, reservation.balance);
                }
            }
        }

        if (totalFees > 0) {
            // Transfer fees to the operator fee distributor
            paymentToken.safeTransfer(operatorFeeDistributor, totalFees);
        }
    }

    /// INTERNAL FUNCTIONS

    function _verifyImageCertificates(
        Image calldata image
    ) internal view {
        // /// Verify image certificate
        // certificateVerifier.verifyDACertV2({
        //     batchHeader: image.imageDACert.batchHeader,
        //     blobInclusionInfo: image.imageDACert.blobInclusionInfo,
        //     nonSignerStakesAndSignature: image.imageDACert.nonSignerStakesAndSignature,
        //     signedQuorumNumbers: image.imageDACert.signedQuorumNumbers
        // });
    }

    /// VIEW FUNCTIONS

    /// @inheritdoc IReservationRegistry
    function isImageAdded(
        uint32 imageID
    ) external view returns (bool isValid) {
        Image memory image = _images[imageID];
        if (image.creationTime == 0) {
            return false;
        }
        return _reservations[image.reservationID].active;
    }

    /// @inheritdoc IReservationRegistry
    function getReservationTransferAmount() public view returns (uint256) {
        /// TODO: use more efficient interface on IndexRegistry when internal function is public
        uint32 currentNumOperators = indexRegistry.totalOperatorsForQuorumAtBlockNumber({
            quorumNumber: RxpConstants.OPERATOR_SET_ID_UINT8,
            blockNumber: uint32(currentEpochStartBlock())
        });
        return prepaidReservationFee(currentNumOperators) + reservationBondAmount;
    }

    /// @inheritdoc IReservationRegistry
    function getActiveReservationIds() external view returns (uint256[] memory) {
        return _activeReservationIds.values();
    }

    /// @inheritdoc IReservationRegistry
    function getReservation(
        uint256 reservationID
    ) external view returns (Reservation memory reservation) {
        return _reservations[reservationID];
    }

    /// @inheritdoc IReservationRegistry
    function getReservationsForAVS(
        address avs
    ) external view returns (uint256[] memory reservationIDs, Reservation[] memory reservations) {
        uint256[] memory activeReservationIds = _activeReservationIds.values();
        uint256 activeCount = activeReservationIds.length;
        uint256[] memory tempReservationIds = new uint256[](activeCount);
        uint256 count = 0;

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 currentId = activeReservationIds[i];
            if (_reservations[currentId].avs == avs) {
                tempReservationIds[count] = currentId;
                count++;
            }
        }

        reservationIDs = new uint256[](count);
        reservations = new Reservation[](count);
        for (uint256 i = 0; i < count; i++) {
            reservationIDs[i] = tempReservationIds[i];
            reservations[i] = _reservations[tempReservationIds[i]];
        }
    }

    /// @inheritdoc IReservationRegistry
    function getImages(
        uint256 reservationID
    ) external view returns (uint32[] memory imageIDs, Image[] memory images) {
        uint256[] memory uintImageIDs = _reservationImageIDs[reservationID].values();
        imageIDs = new uint32[](uintImageIDs.length);
        for (uint256 i = 0; i < uintImageIDs.length; i++) {
            imageIDs[i] = uint32(uintImageIDs[i]);
        }
        images = new Image[](imageIDs.length);
        for (uint256 i = 0; i < imageIDs.length; i++) {
            images[i] = _images[uint32(imageIDs[i])];
        }
    }

    /// @inheritdoc IReservationRegistry
    function getImage(
        uint32 imageID
    ) external view returns (Image memory image) {
        require(_images[imageID].creationTime != 0, ImageNotFound()); // Check creationTime directly
        return _images[imageID];
    }

    /// @inheritdoc IReservationRegistry
    function getReservationIDForImageID(
        uint32 imageID
    ) external view returns (uint256) {
        return _images[imageID].reservationID;
    }

    /// @inheritdoc IReservationRegistry
    function prepaidReservationFee(
        uint32 numOperators
    ) public view returns (uint256 fee) {
        return resourceCostPerOperatorPerEpoch * numOperators * prepaidBilledEpochs;
    }

    /// @inheritdoc IReservationRegistry
    function getEpochFromBlocknumber(
        uint256 blocknumber
    ) public view returns (uint32) {
        require(blocknumber >= epochGenesisBlock, "Block number before genesis");
        return uint32((blocknumber - epochGenesisBlock) / epochLengthBlocks);
    }

    /// @inheritdoc IReservationRegistry
    function currentEpoch() public view returns (uint32) {
        return getEpochFromBlocknumber(block.number);
    }

    /// @inheritdoc IReservationRegistry
    function currentEpochStartBlock() public view returns (uint256) {
        uint32 epoch = currentEpoch();
        return epochGenesisBlock + (epoch * epochLengthBlocks);
    }
}
