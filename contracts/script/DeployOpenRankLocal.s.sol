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
import {Vm} from "forge-std/Vm.sol";

contract DeployOpenRank is Script {
    DeployEigenLayerCore public coreDeployer;
    DeployRxp_Local public rxpDeployer;
    OpenRankManager public orManager;
    DeployEigenLayerCore.EigenLayerDeployment coreDeployment;
    DeployEigenLayerCore.EigenLayerConfig coreConfig;
    DeployRxp_Local.RXPDeployment rxpDeployment;
    DeployRxp_Local.RXPConfig rxpConfig;

    address initialOwner;

    function run() public {
        coreDeployer = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxp_Local();
        initialOwner = msg.sender;

        _deployCore(true, initialOwner);
        _deployRxp(true, initialOwner);

        vm.startBroadcast(initialOwner);
        _deployOrManager();
        _writeOrOutputJSON();
        vm.stopBroadcast();
    }

    function testRun(address sender) public {
        coreDeployer = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxp_Local();
        initialOwner = sender;

        _deployCore(false, initialOwner);
        _deployRxp(false, initialOwner);

        vm.startPrank(sender);
        _deployOrManager();
        _writeOrOutputJSON();
        vm.stopPrank();
    }

    function _deployCore(bool broadcast, address prankAddress) internal {
        string memory configFile = "deploy_eigenlayer_core.config.json";
        string memory eigenlayerConfigPath = string.concat("script/local/config/", configFile);
        coreConfig = coreDeployer._readEigenLayerConfigJSON(eigenlayerConfigPath);
        coreDeployment = coreDeployer.run(coreConfig, broadcast, prankAddress);
    }

    function _deployRxp(bool broadcast, address prankAddress) internal {
        string memory rxpConfigPath = string.concat("script/", "local", "/config/deploy_rxp_contracts.config.json");
        string memory eigenlayerContractsPath =
            string.concat("script/", "local", "/output/deploy_eigenlayer_core_output.json");
        string memory outputPath = string.concat("script/", "local", "/output/deploy_rxp_contracts_output.json");

        rxpConfig = rxpDeployer._readRxpConfigJSON(rxpConfigPath);
        rxpDeployment = rxpDeployer.run(rxpConfig, coreDeployment, broadcast, prankAddress);
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

        // uint256 fee = reservationRegistry.getReservationTransferAmount(IReservationRegistry.ResourceConfigType.CPU);
        IERC20 paymentToken = reservationRegistry.paymentToken();
        // paymentToken.approve(address(reservationRegistry), fee);
        // uint256 reservationId = reservationRegistry.reserve(address(orManager), IReservationRegistry.ResourceConfigType.CPU, fee);
        // bytes[] memory imageBytes = new bytes[](0);
        // uint32 imageId = reservationRegistry.addImage(reservationId, imageBytes);
        // orManager.setImageId(imageId);

        paymentToken.transfer(address(orManager), 100000000);

        console.log("address(orManager): ", address(orManager));
        console.log("address(reexecutionEndpoint): ", address(reexecutionEndpoint));
    }

    function _writeOrOutputJSON() internal {
        string memory outputPath = "script/local/output/deploy_or_contracts_output.json";

        string memory json = string.concat(
            '{\n',
            '  "addresses": {\n',
            '    "openRankManager": "',
            vm.toString(address(orManager)),
            '"\n',
            '  }\n',
            '}'
        );

        vm.writeFile(outputPath, json);
        console.log("OpenRank deployment output written to:", outputPath);
    }
}
