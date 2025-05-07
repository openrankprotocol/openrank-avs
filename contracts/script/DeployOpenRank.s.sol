// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {DeployEigenLayerCore} from "rxp/script/local/deploy/deploy_eigenlayer_core.s.sol";
import {DeployRxp_Local} from "rxp/script/local/deploy/deploy_rxp_contracts.s.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

import {IPermissionController} from "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IReservationRegistry} from "rxp/src/interfaces/core/IReservationRegistry.sol";
import {IReexecutionEndpoint} from "rxp/src/interfaces/core/IReexecutionEndpoint.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployOpenRank is Script {
    DeployEigenLayerCore public coreDeployer;
    DeployRxp_Local public rxpDeployer;
    OpenRankManager public orManager;

    address initialOwner;

    function run() public {
        coreDeployer = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxp_Local();
        initialOwner = msg.sender;

        vm.startPrank(initialOwner);
        _deployCore();
        vm.stopPrank();

        vm.startPrank(initialOwner);
        _deployRxp();
        vm.stopPrank();

        vm.startPrank(initialOwner);
        _deployOrManager();
        vm.stopPrank();
    }

    function _deployCore() internal {
        string memory configFile = "deploy_eigenlayer_core.config.json";
        coreDeployer.run(configFile, false);
    }

    function _deployRxp() internal {
        rxpDeployer.run(false);
    }

    function _deployOrManager() internal {
        IPermissionController permissionController = coreDeployer.permissionController();
        IReservationRegistry reservationRegistry = rxpDeployer.reservationRegistry();
        IReexecutionEndpoint reexecutionEndpoint = rxpDeployer.reexecutionEndpoint();

        orManager = new OpenRankManager(address(permissionController), address(reservationRegistry), address(reexecutionEndpoint));
        orManager.setAppointee({
            appointee: initialOwner,
            target: address(reservationRegistry),
            selector: IReservationRegistry.reserve.selector
        });
        orManager.setAppointee({
            appointee: initialOwner,
            target: address(reservationRegistry),
            selector: IReservationRegistry.addImage.selector
        });

        uint256 fee = reservationRegistry.getReservationTransferAmount();
        IERC20 paymentToken = reservationRegistry.paymentToken();
        paymentToken.approve(address(reservationRegistry), fee);
        uint256 reservationId = reservationRegistry.reserve(address(orManager), fee);
        bytes[] memory imageBytes = new bytes[](0);
        reservationRegistry.addImage(reservationId, imageBytes);
    }
}
