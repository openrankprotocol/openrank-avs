// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "./IReservationRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    IIndexRegistry,
    ISlashingRegistryCoordinator,
    IStakeRegistry
} from "eigenlayer-middleware/src/SlashingRegistryCoordinator.sol";

/**
 * @title IOREO
 * @notice Interface for the OREO (Offchain Re-Execution Oracle) contract
 * @dev This contract manages re-execution requests and responses
 */
interface IReexecutionEndpoint {
    // Custom errors
    error InvalidRequest();
    error InvalidRequestIndex();
    error RequestNotPending();
    error ResponseDeadlinePassed();
    error ResponseDeadlineNotPassed();
    error OperatorAlreadyResponded();
    error OperatorHasNotResponded();
    error OperatorNotRegistered();
    error MaxRequestsPerReservationExceeded();
    error TimestampBeforeGenesis();

    enum RequestStatus {
        NONEXISTANT,
        PENDING,
        FINALIZED,
        ABSTAIN
    }

    /**
     * @notice Struct representing a re-execution request
     * @param avs The avs address that made the request
     * @param imageID The ID of the image to be re-executed
     * @param requestData The data to be inputted to the image
     * @param requestBlock The block number at which the request was made
     * @param epochStartBlockNumber The block number at which the epoch started
     * @param totalStakeWeight The total stake weight of the operator set at the epoch start block number
     * @param feePerOperator The fee per operator sent upon response
     * @param finalResponse The final response data (32 bytes)
     * @param isFinalized Whether the request has been finalized
     */
    struct ReexecutionRequest {
        address avs;
        uint32 imageID;
        bytes32 requestDataHash;
        uint32 requestBlock;
        uint32 epochStartBlockNumber;
        uint96 totalStakeWeight;
        bytes32 finalResponse;
        uint256 feePerOperator;
        RequestStatus status;
    }

    /**
     * @notice Event emitted when a new re-execution request is created
     * @param requestIndex The index of the request
     * @param avs The address that made the request
     * @param reservationID The ID of the reservation
     * @param imageID The ID of the image to be re-executed
     * @param requestData The data to be inputted to the image
     * @param requestBlock The block number at which the request was made
     */
    event ReexecutionRequestCreated(
        uint256 indexed requestIndex,
        address indexed avs,
        uint256 indexed reservationID,
        uint32 imageID,
        bytes requestData,
        uint32 requestBlock
    );

    /**
     * @notice Event emitted when an operator responds to a re-execution request
     * @param requestIndex The index of the request
     * @param operator The address of the operator
     * @param response The 32-byte response data
     * @param stake The amount of stake backing the response
     */
    event OperatorResponse(
        uint256 indexed requestIndex, address indexed operator, bytes32 indexed response, uint256 stake
    );

    /**
     * @notice Event emitted when a re-execution request is finalized
     * @param requestIndex The index of the request
     * @param finalResponse The final 32-byte response
     */
    event RequestFinalized(uint256 indexed requestIndex, bytes32 indexed finalResponse);

    // STATE VARIABLES AND IMMUTABLES

    /**
     * @notice The reservation registry contract
     * @return The IReservationRegistry contract
     */
    function reservationRegistry() external view returns (IReservationRegistry);

    /**
     * @notice The slashing registry coordinator contract
     * @return The ISlashingRegistryCoordinator contract
     */
    function slashingRegistryCoordinator() external view returns (ISlashingRegistryCoordinator);

    /**
     * @notice The index registry contract
     * @return The IIndexRegistry contract
     */
    function indexRegistry() external view returns (IIndexRegistry);

    /**
     * @notice The stake registry contract
     * @return The IStakeRegistry contract
     */
    function stakeRegistry() external view returns (IStakeRegistry);

    /**
     * @notice The payment token used for requests
     * @return The ERC20 token used for payments
     */
    function paymentToken() external view returns (IERC20);

    /**
     * @notice The fee paid to each operator for responding
     * @return The response fee per operator
     */
    function responseFeePerOperator() external view returns (uint256);

    /**
     * @notice The fee paid to each operator for re-execution
     * @return The re-execution fee per operator
     */
    function reexecutionFeePerOperator() external view returns (uint256);

    /**
     * @notice The window in blocks during which operators can respond
     * @return The response window in blocks
     */
    function responseWindowBlocks() external view returns (uint256);

    /**
     * @notice The maximum number of requests allowed per reservation per response window
     * @return The maximum number of requests
     */
    function maximumRequestsPerReservationPerResponseWindow() external view returns (uint256);

    /**
     * @notice Initializes the contract with the required parameters
     * @param initialOwner The initial owner of the contract
     * @param _responseFeePerOperator The fee paid to each operator for responding
     * @param _reexecutionFeePerOperator The fee paid to each operator for re-execution
     * @param _responseWindowBlocks The window in blocks during which operators can respond
     * @param _maximumRequestsPerReservationPerResponseWindow The maximum number of requests allowed per reservation per response window
     */
    function initialize(
        address initialOwner,
        uint256 _responseFeePerOperator,
        uint256 _reexecutionFeePerOperator,
        uint256 _responseWindowBlocks,
        uint256 _maximumRequestsPerReservationPerResponseWindow
    ) external;

    // PERMISSIONED FUNCTIONS

    /**
     * @notice Sets the response fee per operator
     * @param _responseFeePerOperator The new response fee per operator
     */
    function setResponseFeePerOperator(
        uint256 _responseFeePerOperator
    ) external;

    /**
     * @notice Sets the re-execution fee per operator
     * @param _reexecutionFeePerOperator The new re-execution fee per operator
     */
    function setReexecutionFeePerOperator(
        uint256 _reexecutionFeePerOperator
    ) external;

    /**
     * @notice Sets the response window in blocks
     * @param _responseWindowBlocks The new response window in blocks
     */
    function setResponseWindowBlocks(
        uint256 _responseWindowBlocks
    ) external;

    /**
     * @notice Sets the maximum number of requests allowed per reservation per response window
     * @param _maximumRequestsPerReservationPerResponseWindow The new maximum number of requests
     */
    function setMaximumRequestsPerReservationPerResponseWindow(
        uint256 _maximumRequestsPerReservationPerResponseWindow
    ) external;

    // CORE LOGIC

    /**
     * @notice Creates a new re-execution request
     * @param imageID The ID of the image to be re-executed
     * @param requestData The data to be inputted to the image
     * @return requestIndex The index of the created request
     * @dev Only callable by the AVS who made the original reservation
     */
    function requestReexecution(uint32 imageID, bytes calldata requestData) external returns (uint256 requestIndex);

    /**
     * @notice Responds to a re-execution request
     * @param operator The address of the operator
     * @param requestIndex The index of the request
     * @param responseData The 32-byte data returned by the re-execution
     * @param signature The BLS signature on the response
     */
    function respond(address operator, uint256 requestIndex, bytes32 responseData, bytes calldata signature) external;

    /**
     * @notice Finalizes a re-execution request
     * @param requestIndex The index of the request
     * @return status The status of the request
     */
    function getFinalizedResponse(
        uint256 requestIndex
    ) external returns (RequestStatus status, bytes32 finalizedResponse);

    // VIEW FUNCTIONS

    /**
     * @notice Checks if a re-execution request has been finalized
     * @param requestIndex The index of the request
     * @return status The status of the request
     * @dev reverts if requestIndex is out of bounds
     */
    function getRequestStatus(
        uint256 requestIndex
    ) external view returns (RequestStatus status);

    /**
     * @notice Gets a re-execution request by index
     * @param requestIndex The index of the request
     * @return request The request
     */
    function getRequest(
        uint256 requestIndex
    ) external view returns (ReexecutionRequest memory request);

    /**
     * @notice Gets the fee for a re-execution request
     * @param blockNumber The block number to check at
     * @return requiredFee The total required fee
     * @return feePerOperator The fee per operator
     */
    function getRequestFee(
        uint32 blockNumber
    ) external view returns (uint256 requiredFee, uint256 feePerOperator);

    /**
     * @notice Gets the total number of requests
     * @return count The number of requests
     */
    function getRequestCount() external view returns (uint256 count);

    /**
     * @notice Checks if an operator has responded to a request
     * @param requestIndex The index of the request
     * @param operator The address of the operator
     * @return hasResponded Whether the operator has responded
     */
    function hasOperatorResponded(uint256 requestIndex, address operator) external view returns (bool hasResponded);

    /**
     * @notice Gets the response data from an operator for a request
     * @param requestIndex The index of the request
     * @param operator The address of the operator
     * @return response The 32-byte response data
     */
    function getResponse(uint256 requestIndex, address operator) external view returns (bytes32 response);

    /**
     * @notice View implementation of getFinalizedResponse without modifying state
     * Gets the finalized response for a request
     * @param requestIndex The index of the request
     * @return status The status of the request
     * @return finalizedResponse The finalized response
     */
    function getFinalizedResponseView(
        uint256 requestIndex
    ) external view returns (RequestStatus status, bytes32 finalizedResponse);

    /**
     * @notice Gets the total number of requests made for a reservation
     * @param reservationID The ID of the reservation
     * @return count The total number of requests
     */
    function getCumulativeReservationRequestCount(
        uint256 reservationID
    ) external view returns (uint256 count);

    /**
     * @notice Gets the number of requests made for a reservation until and includings a specific block
     * @param reservationID The ID of the reservation
     * @param blockNumber The block number to check
     * @return count The number of requests at the specified block
     */
    function getCumulativeReservationRequestCountAtBlock(
        uint256 reservationID,
        uint32 blockNumber
    ) external view returns (uint256 count);

    /**
     * @notice Gets the number of requests made for a reservation in the current response window
     * @param reservationID The ID of the reservation
     * @return count The number of requests in the current window
     */
    function getRequestsInCurrentWindow(
        uint256 reservationID
    ) external view returns (uint256 count);
}
