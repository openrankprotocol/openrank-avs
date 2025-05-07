// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IReservationRegistry} from "rxp/src/interfaces/core/IReservationRegistry.sol";
import {IPermissionController} from
    "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IReexecutionEndpoint} from "rxp/src/interfaces/core/IReexecutionEndpoint.sol";
import {OpenRankManagerStorage} from "./OpenRankManagerStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OpenRankManager is OpenRankManagerStorage {
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor(
        address _permissionController,
        address _reexecutionEndpoint,
        address _reservationRegistry
    ) OpenRankManagerStorage(_permissionController, _reexecutionEndpoint, _reservationRegistry) {}

    function setAppointee(address appointee, address target, bytes4 selector) public onlyOwner {
        IPermissionController(permissionController).setAppointee({
            account: address(this),
            appointee: appointee,
            target: target,
            selector: selector
        });
    }

    function setImageId(
        uint32 _imageId
    ) public onlyOwner {
        uint256 reservationID =
            IReservationRegistry(reservationRegistry).getReservationIDForImageID(_imageId);
        IReservationRegistry.Reservation memory reservation =
            IReservationRegistry(reservationRegistry).getReservation(reservationID);
        require(reservation.avs == address(this), InvalidReservationForImageId());
        imageId = _imageId;
    }

    // ---------------------------------------------------------------
    // Meta Jobs
    // ---------------------------------------------------------------

    function submitMetaComputeRequest(
        bytes32 jobDescriptionId
    ) external returns (uint256 computeId) {
        require(allowlistedUsers[msg.sender], CallerNotWhitelisted());
        MetaComputeRequest memory computeRequest = MetaComputeRequest({
            user: msg.sender,
            id: idCounter,
            jobDescriptionId: jobDescriptionId,
            timestamp: block.timestamp
        });
        metaComputeRequests[idCounter] = computeRequest;

        emit MetaComputeRequestEvent(idCounter, jobDescriptionId);

        computeId = idCounter;
        idCounter += 1;
    }

    function submitMetaComputeResult(
        uint256 computeId,
        bytes32 metaCommitment,
        bytes32 resultsId
    ) external returns (bool) {
        require(allowlistedComputers[msg.sender], CallerNotWhitelisted());
        require(metaComputeRequests[computeId].id != 0, ComputeRequestNotFound());
        require(metaComputeResults[computeId].computeId == 0, ComputeResultAlreadySubmitted());

        MetaComputeResult memory computeResult = MetaComputeResult({
            computer: msg.sender,
            computeId: computeId,
            metaCommitment: metaCommitment,
            resultsId: resultsId,
            timestamp: block.timestamp
        });
        metaComputeResults[computeId] = computeResult;

        emit MetaComputeResultEvent(computeId, metaCommitment, resultsId);

        return true;
    }

    function submitMetaChallenge(uint256 computeId, uint256 subJobId) external returns (bool) {
        require(allowlistedChallengers[msg.sender], CallerNotWhitelisted());
        require(metaComputeRequests[computeId].id != 0, ComputeRequestNotFound());
        require(metaComputeResults[computeId].computeId != 0, ComputeResultNotFound());

        uint256 computeDiff = block.timestamp - metaComputeResults[computeId].timestamp;
        require(computeDiff <= CHALLENGE_WINDOW, ChallengePeriodExpired());

        IReexecutionEndpoint rxp = IReexecutionEndpoint(reexecutionEndpoint);
        (uint256 requiredFee,) = rxp.getRequestFee(uint32(block.number));
        IERC20 paymentToken = rxp.paymentToken();
        paymentToken.approve(address(rxp), requiredFee);

        bytes memory inputData = abi.encode(computeId, subJobId);
        uint256 requestIndex = rxp.requestReexecution(imageId, inputData);
        MetaChallenge memory challenge = MetaChallenge({
            challenger: msg.sender,
            computeId: computeId,
            subJobId: subJobId,
            timestamp: block.timestamp,
            requestIndex: requestIndex
        });
        metaChallenges[computeId] = challenge;

        emit MetaChallengeEvent(computeId, subJobId);
        return true;
    }

    // ---------------------------------------------------------------
    // Getters
    // ---------------------------------------------------------------

    function isAllowlistedComputer(
        address computer
    ) public view returns (bool) {
        return allowlistedComputers[computer];
    }

    // ---------------------------------------------------------------
    // Setters
    // ---------------------------------------------------------------

    function updateChallengeWindow(
        uint64 challengeWindow
    ) public onlyOwner {
        CHALLENGE_WINDOW = challengeWindow;
    }
}
