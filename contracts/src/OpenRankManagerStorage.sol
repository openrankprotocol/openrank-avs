// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IReservationRegistry} from "rxp/src/interfaces/core/IReservationRegistry.sol";
import {IPermissionController} from
    "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IReexecutionEndpoint} from "rxp/src/interfaces/core/IReexecutionEndpoint.sol";
import {IOpenRankManager} from "./IOpenRankManager.sol";

abstract contract OpenRankManagerStorage is IOpenRankManager {
    uint64 public CHALLENGE_WINDOW = 60 * 60; // 60 minutes

    address owner;
    address permissionController;
    address reservationRegistry;
    address reexecutionEndpoint;
    uint32 imageId;

    uint256 public idCounter;

    mapping(address => bool) allowlistedComputers;
    mapping(address => bool) allowlistedChallengers;
    mapping(address => bool) allowlistedUsers;

    mapping(uint256 => MetaComputeRequest) public metaComputeRequests;
    mapping(uint256 => MetaComputeResult) public metaComputeResults;
    mapping(uint256 => MetaChallenge) public metaChallenges;

    constructor(
        address _permissionController,
        address _reservationRegistry,
        address _reexecutionEndpoint
    ) {
        idCounter = 1;

        allowlistedComputers[msg.sender] = true;
        allowlistedChallengers[msg.sender] = true;
        allowlistedUsers[msg.sender] = true;

        owner = msg.sender;
        permissionController = _permissionController;
        reservationRegistry = _reservationRegistry;
        reexecutionEndpoint = _reexecutionEndpoint;
    }
}
