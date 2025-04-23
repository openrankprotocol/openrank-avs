// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IReexecutionEndpoint.sol";
import "./interfaces/IReservationRegistry.sol";
import "./libraries/RxpConstants.sol";
import "./ReexecutionEndpointStorage.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "eigenlayer-contracts/src/contracts/libraries/Snapshots.sol";
import "eigenlayer-contracts/src/contracts/mixins/PermissionControllerMixin.sol";

/**
 * @title ReexecutionEndpoint
 * @notice Implementation of the ReexecutionEndpoint contract
 * @dev This contract manages re-execution requests and responses
 */
contract ReexecutionEndpoint is
    PermissionControllerMixin,
    OwnableUpgradeable,
    ReexecutionEndpointStorage
{
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.Bytes32ToBytes32Map;
    using Snapshots for Snapshots.DefaultZeroHistory;

    /**
     * @notice Constructor
     * @param _reservationRegistry The reservation registry address
     * @param _paymentToken The ERC20 token used for payments
     */
    constructor(
        IPermissionController _permissionController,
        IReservationRegistry _reservationRegistry,
        ISlashingRegistryCoordinator _slashingRegistryCoordinator,
        IIndexRegistry _indexRegistry,
        IStakeRegistry _stakeRegistry,
        IERC20 _paymentToken
    )
        PermissionControllerMixin(_permissionController)
        ReexecutionEndpointStorage(
            _reservationRegistry,
            _slashingRegistryCoordinator,
            _indexRegistry,
            _stakeRegistry,
            _paymentToken
        )
    {
        _disableInitializers();
    }

    /// @inheritdoc IReexecutionEndpoint
    function initialize(
        address initialOwner,
        uint256 _responseFeePerOperator,
        uint256 _reexecutionFeePerOperator,
        uint256 _responseWindowBlocks,
        uint256 _maximumRequestsPerReservationPerResponseWindow
    ) external initializer {
        __Ownable_init();

        responseFeePerOperator = _responseFeePerOperator;
        reexecutionFeePerOperator = _reexecutionFeePerOperator;
        responseWindowBlocks = _responseWindowBlocks;
        maximumRequestsPerReservationPerResponseWindow = _maximumRequestsPerReservationPerResponseWindow;

        _transferOwnership(initialOwner);
    }

    /// PERMISSIONED FUNCTIONS

    /// @inheritdoc IReexecutionEndpoint
    function setResponseFeePerOperator(
        uint256 _responseFeePerOperator
    ) external onlyOwner {
        responseFeePerOperator = _responseFeePerOperator;
    }

    /// @inheritdoc IReexecutionEndpoint
    function setReexecutionFeePerOperator(
        uint256 _reexecutionFeePerOperator
    ) external onlyOwner {
        reexecutionFeePerOperator = _reexecutionFeePerOperator;
    }

    /// @inheritdoc IReexecutionEndpoint
    function setResponseWindowBlocks(
        uint256 _responseWindowBlocks
    ) external onlyOwner {
        responseWindowBlocks = _responseWindowBlocks;
    }

    /// @inheritdoc IReexecutionEndpoint
    function setMaximumRequestsPerReservationPerResponseWindow(
        uint256 _maximumRequestsPerReservationPerResponseWindow
    ) external onlyOwner {
        maximumRequestsPerReservationPerResponseWindow = _maximumRequestsPerReservationPerResponseWindow;
    }

    /// CORE LOGIC

    /// @inheritdoc IReexecutionEndpoint
    function requestReexecution(
        uint32 imageID,
        bytes calldata requestData
    ) external returns (uint256 requestIndex) {
        uint256 reservationID = reservationRegistry.getReservationIDForImageID(
            imageID
        );
        IReservationRegistry.Reservation
            memory reservation = reservationRegistry.getReservation(
                reservationID
            );
        require(_checkCanCall(reservation.avs), InvalidPermissions());
        // Check if the image is reserved and has not exceeded its usage limit
        require(reservationRegistry.isImageAdded(imageID), InvalidRequest());

        // Check if the reservation has not exceeded the maximum requests per response window
        uint256 currentRequests = _cumulativeReservationRequests[reservationID]
            .latest();
        {
            uint32 windowStartBlock = uint32(block.number) -
                uint32(responseWindowBlocks);
            // Get the number of requests at the start of the window
            uint256 requestsAtWindowStart = _cumulativeReservationRequests[
                reservationID
            ].upperLookup(windowStartBlock);
            // Calculate the number of requests in the current window
            uint256 requestsInCurrentWindow = currentRequests -
                requestsAtWindowStart;
            // Check if adding one more request would exceed the maximum
            require(
                requestsInCurrentWindow <=
                    maximumRequestsPerReservationPerResponseWindow,
                MaxRequestsPerReservationExceeded()
            );
        }

        // Create the request
        requestIndex = _requests.length;

        uint32 epochStartBlocknumber = uint32(
            reservationRegistry.currentEpochStartBlock()
        );
        uint96 totalStakeWeight = _getTotalStakeWeight(epochStartBlocknumber);

        // Calculate required fee
        (uint256 requiredFee, uint256 feePerOperator) = getRequestFee(
            epochStartBlocknumber
        );

        _requests.push(
            ReexecutionRequest({
                avs: reservation.avs,
                imageID: imageID,
                requestDataHash: keccak256(abi.encodePacked(requestData)),
                requestBlock: uint32(block.number),
                epochStartBlockNumber: epochStartBlocknumber,
                totalStakeWeight: totalStakeWeight,
                feePerOperator: feePerOperator,
                finalResponse: bytes32(0), // Default to zero
                status: RequestStatus.PENDING
            })
        );
        // Update the request history for this reservation
        // Increment the cumulative request count and store it with the current block number
        _cumulativeReservationRequests[reservationID].push(
            uint32(block.number),
            currentRequests + 1
        );
        emit ReexecutionRequestCreated(
            requestIndex,
            reservation.avs,
            reservationID,
            imageID,
            requestData,
            uint32(block.number)
        );

        // Transfer tokens from user to this contract
        paymentToken.safeTransferFrom(msg.sender, address(this), requiredFee);
    }

    /// @inheritdoc IReexecutionEndpoint
    function respond(
        address operator,
        uint256 requestIndex,
        bytes32 responseData,
        bytes calldata /* signature */
    ) external checkCanCall(operator) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        ReexecutionRequest storage request = _requests[requestIndex];

        require(request.status == RequestStatus.PENDING, RequestNotPending());
        require(
            block.number <= request.requestBlock + responseWindowBlocks,
            ResponseDeadlinePassed()
        );
        _verifyOperatorRegisteredDuringRequest(request.requestBlock, operator);

        bytes32 operatorAddressAsBytes32 = bytes32(uint256(uint160(operator)));
        require(
            !_operatorResponses[requestIndex].contains(
                operatorAddressAsBytes32
            ),
            OperatorAlreadyResponded()
        );

        uint256 operatorStakeWeight = uint256(
            _getOperatorWeight(request.epochStartBlockNumber, operator)
        );

        // Store the response data
        _operatorResponses[requestIndex].set(
            operatorAddressAsBytes32,
            responseData
        );
        _responseStakeWeights[requestIndex][
            responseData
        ] += operatorStakeWeight;

        // compare stake weight to current largest stake weighted response
        // update current largest stake weighted response if the updated stake weight is greater
        uint256 currLargestStakeWeight = _responseStakeWeights[requestIndex][
            request.finalResponse
        ];
        if (
            _responseStakeWeights[requestIndex][responseData] >
            currLargestStakeWeight
        ) {
            request.finalResponse = responseData;
        }
        // check if finalized based on updated stake weight
        (RequestStatus status, ) = _getFinalizedResponse(request, requestIndex);
        if (status == RequestStatus.FINALIZED) {
            request.status = RequestStatus.FINALIZED;
        }

        // Send fees to operator
        paymentToken.safeTransfer(operator, request.feePerOperator);

        // Emit event
        emit OperatorResponse(
            requestIndex,
            operator,
            responseData,
            operatorStakeWeight
        );
    }

    /// @inheritdoc IReexecutionEndpoint
    function getFinalizedResponse(
        uint256 requestIndex
    ) external returns (RequestStatus status, bytes32 finalizedResponse) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        ReexecutionRequest storage request = _requests[requestIndex];
        (status, finalizedResponse) = _getFinalizedResponse(
            request,
            requestIndex
        );
        request.status = status;
        request.finalResponse = finalizedResponse;
    }

    /// INTERNAL FUNCTIONS

    /// @dev Verifies that the operator was registered at the time of the request
    function _verifyOperatorRegisteredDuringRequest(
        uint32 requestBlock,
        address operator
    ) internal view {
        bytes32[] memory operatorIds = new bytes32[](1);
        operatorIds[0] = slashingRegistryCoordinator.getOperatorId(operator);

        uint32[] memory quorumBitmapIndices = slashingRegistryCoordinator
            .getQuorumBitmapIndicesAtBlockNumber({
                blockNumber: requestBlock,
                operatorIds: operatorIds
            });

        // read operators quorum bitmap at
        uint192 quorumBitmap = slashingRegistryCoordinator
            .getQuorumBitmapAtBlockNumberByIndex(
                operatorIds[0],
                requestBlock,
                quorumBitmapIndices[0]
            );

        // bitwise AND with 1 to check if operator is registered for quorum 0
        require(quorumBitmap & 1 == 1, OperatorNotRegistered());
    }

    function _getFinalizedResponse(
        ReexecutionRequest memory request,
        uint256 requestIndex
    ) internal view returns (RequestStatus, bytes32) {
        require(request.status != RequestStatus.NONEXISTANT, InvalidRequest());

        // If request is already finalized or abstained, return the status and response
        if (
            request.status == RequestStatus.FINALIZED ||
            request.status == RequestStatus.ABSTAIN
        ) {
            return (request.status, request.finalResponse);
        }

        // Check if pending request can be finalized
        // TODO: round up on totalStakeWeight / 2?
        uint256 majorityStakeWeight = _responseStakeWeights[requestIndex][
            request.finalResponse
        ];
        if (majorityStakeWeight > (request.totalStakeWeight / 2)) {
            return (RequestStatus.FINALIZED, request.finalResponse);
        }

        // If pending request has passed response window, return ABSTAIN
        if (block.number > request.requestBlock + responseWindowBlocks) {
            return (RequestStatus.ABSTAIN, bytes32(0));
        }

        // Otherwise, request is still pending, return current majority response
        return (request.status, request.finalResponse);
    }

    /// @dev Get the total stake weight of the operator set at a given block number
    function _getTotalStakeWeight(
        uint32 blocknumber
    ) internal view returns (uint96 totalStake) {
        bytes memory quorumNumbers = new bytes(1);
        quorumNumbers[0] = bytes1(RxpConstants.OPERATOR_SET_ID_UINT8);
        uint32[] memory indices = stakeRegistry
            .getTotalStakeIndicesAtBlockNumber({
                blockNumber: blocknumber,
                quorumNumbers: quorumNumbers
            });
        totalStake = stakeRegistry.getTotalStakeAtBlockNumberFromIndex({
            quorumNumber: RxpConstants.OPERATOR_SET_ID_UINT8,
            blockNumber: blocknumber,
            index: indices[0]
        });
    }

    /// @dev Get the stake weight of an operator at a given block number
    function _getOperatorWeight(
        uint32 blocknumber,
        address operator
    ) internal view returns (uint96 operatorStakeWeight) {
        bytes32 operatorId = slashingRegistryCoordinator.getOperatorId(
            operator
        );
        operatorStakeWeight = stakeRegistry.getStakeAtBlockNumber(
            operatorId,
            RxpConstants.OPERATOR_SET_ID_UINT8,
            blocknumber
        );
    }

    /// VIEW FUNCTIONS

    /// @inheritdoc IReexecutionEndpoint
    function getRequestStatus(
        uint256 requestIndex
    ) external view returns (RequestStatus status) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        status = _requests[requestIndex].status;
    }

    /// @inheritdoc IReexecutionEndpoint
    function getRequest(
        uint256 requestIndex
    ) external view returns (ReexecutionRequest memory request) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        return _requests[requestIndex];
    }

    /// @inheritdoc IReexecutionEndpoint
    function getRequestFee(
        uint32 blockNumber
    ) public view returns (uint256 requiredFee, uint256 feePerOperator) {
        // TODO: use binary search lookup?
        uint256 numOperators = indexRegistry
            .totalOperatorsForQuorumAtBlockNumber({
                quorumNumber: RxpConstants.OPERATOR_SET_ID_UINT8,
                blockNumber: blockNumber
            });
        feePerOperator = responseFeePerOperator + reexecutionFeePerOperator;
        // scale the fee based on the number of requests in the current window
        requiredFee = feePerOperator * numOperators;
    }

    /// @inheritdoc IReexecutionEndpoint
    function getRequestCount() external view returns (uint256 count) {
        return _requests.length;
    }

    /// @inheritdoc IReexecutionEndpoint
    function hasOperatorResponded(
        uint256 requestIndex,
        address operator
    ) public view returns (bool) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        bytes32 operatorAddressAsBytes32 = bytes32(uint256(uint160(operator)));
        return
            _operatorResponses[requestIndex].contains(operatorAddressAsBytes32);
    }

    /// @inheritdoc IReexecutionEndpoint
    function getResponse(
        uint256 requestIndex,
        address operator
    ) external view returns (bytes32 response) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        bytes32 operatorAddressAsBytes32 = bytes32(uint256(uint160(operator)));
        require(
            _operatorResponses[requestIndex].contains(operatorAddressAsBytes32),
            OperatorHasNotResponded()
        );
        return _operatorResponses[requestIndex].get(operatorAddressAsBytes32);
    }

    /// @inheritdoc IReexecutionEndpoint
    function getFinalizedResponseView(
        uint256 requestIndex
    ) external view returns (RequestStatus status, bytes32 finalizedResponse) {
        require(requestIndex < _requests.length, InvalidRequestIndex());
        ReexecutionRequest memory request = _requests[requestIndex];
        (status, finalizedResponse) = _getFinalizedResponse(
            request,
            requestIndex
        );
    }

    /// @inheritdoc IReexecutionEndpoint
    function getCumulativeReservationRequestCount(
        uint256 reservationID
    ) external view returns (uint256 count) {
        return _cumulativeReservationRequests[reservationID].latest();
    }

    /// @inheritdoc IReexecutionEndpoint
    function getCumulativeReservationRequestCountAtBlock(
        uint256 reservationID,
        uint32 blockNumber
    ) external view returns (uint256 count) {
        return
            _cumulativeReservationRequests[reservationID].upperLookup(
                blockNumber
            );
    }

    /// @inheritdoc IReexecutionEndpoint
    function getRequestsInCurrentWindow(
        uint256 reservationID
    ) public view returns (uint256 count) {
        uint32 currentBlock = uint32(block.number);
        uint32 windowStartBlock = currentBlock - uint32(responseWindowBlocks);

        uint256 requestsAtWindowStart = _cumulativeReservationRequests[
            reservationID
        ].upperLookup(windowStartBlock);
        uint256 currentRequests = _cumulativeReservationRequests[reservationID]
            .latest();

        return currentRequests - requestsAtWindowStart;
    }
}
