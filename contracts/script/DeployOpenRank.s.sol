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
    DeployEigenLayerCore.EigenLayerDeployment coreDeployment;
    DeployRxp_Local.RXPDeployment rxpDeployment;

    address initialOwner;

    function run() public {
        coreDeployer = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxp_Local();
        initialOwner = msg.sender;

        _deployCore();
        _deployRxp();

        vm.startBroadcast(initialOwner);
        _deployOrManager();
        vm.stopPrank();
    }

    function _deployCore() internal {
        string memory configFile = "deploy_eigenlayer_core.config.json";
        coreDeployment = coreDeployer.run(configFile, true);
    }

    function _deployRxp() internal {
        rxpDeployment = rxpDeployer.run(true);
    }

    function _deployOrManager() internal {
        IPermissionController permissionController = coreDeployment.core.permissionController;
        IReservationRegistry reservationRegistry = rxpDeployment.reservationRegistry;
        IReexecutionEndpoint reexecutionEndpoint = rxpDeployment.reexecutionEndpoint;

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

        uint256 fee = reservationRegistry.getReservationTransferAmount(IReservationRegistry.ResourceConfigType.CPU);
        IERC20 paymentToken = reservationRegistry.paymentToken();
        paymentToken.approve(address(reservationRegistry), fee);
        uint256 reservationId = reservationRegistry.reserve(address(orManager), IReservationRegistry.ResourceConfigType.CPU, fee);
        bytes[] memory imageBytes = new bytes[](0);
        reservationRegistry.addImage(reservationId, imageBytes);
    }
}
