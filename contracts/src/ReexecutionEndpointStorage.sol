// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./interfaces/IReexecutionEndpoint.sol";
import "./interfaces/IReservationRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "eigenlayer-contracts/src/contracts/libraries/Snapshots.sol";

abstract contract ReexecutionEndpointStorage is IReexecutionEndpoint {
    /// Immutable variables
    /// @inheritdoc IReexecutionEndpoint
    IReservationRegistry public immutable reservationRegistry;
    /// @inheritdoc IReexecutionEndpoint
    IERC20 public immutable paymentToken;
    /// @inheritdoc IReexecutionEndpoint
    ISlashingRegistryCoordinator public immutable slashingRegistryCoordinator;
    /// @inheritdoc IReexecutionEndpoint
    IStakeRegistry public immutable stakeRegistry;
    /// @inheritdoc IReexecutionEndpoint
    IIndexRegistry public immutable indexRegistry;

    /// Storage variables
    /// @inheritdoc IReexecutionEndpoint
    uint256 public responseFeePerOperator;
    /// @inheritdoc IReexecutionEndpoint
    uint256 public reexecutionFeePerOperator;
    /// @inheritdoc IReexecutionEndpoint
    uint256 public responseWindowBlocks;
    /// @inheritdoc IReexecutionEndpoint
    uint256 public maximumRequestsPerReservationPerResponseWindow;

    // Requests
    ReexecutionRequest[] internal _requests;
    // Mapping from requestIndex => operator address (as bytes32) => response data
    mapping(uint256 requestIndex => EnumerableMap.Bytes32ToBytes32Map) internal _operatorResponses;

    // requestIndex => bytes32 response => stake weight
    mapping(uint256 requestIndex => mapping(bytes32 response => uint256 stakeWeight)) internal
        _responseStakeWeights;

    // Mapping from reservationID => request history using DefaultZeroHistory
    mapping(uint256 reservationID => Snapshots.DefaultZeroHistory) internal
        _cumulativeReservationRequests;

    constructor(
        IReservationRegistry _reservationRegistry,
        ISlashingRegistryCoordinator _slashingRegistryCoordinator,
        IIndexRegistry _indexRegistry,
        IStakeRegistry _stakeRegistry,
        IERC20 _paymentToken
    ) {
        reservationRegistry = _reservationRegistry;
        slashingRegistryCoordinator = _slashingRegistryCoordinator;
        stakeRegistry = _stakeRegistry;
        indexRegistry = _indexRegistry;
        paymentToken = _paymentToken;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[42] private __gap;
}
