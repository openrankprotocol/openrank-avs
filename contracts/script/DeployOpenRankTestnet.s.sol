// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {DeployEigenLayerCore} from "rxp/script/holesky/deploy/deploy_eigenlayer_core.s.sol";
import {DeployRxp_Holesky} from "rxp/script/holesky/deploy/deploy_rxp_contracts.s.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

import {IPermissionController} from "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IReservationRegistry} from "rxp/src/interfaces/core/IReservationRegistry.sol";
import {IReexecutionEndpoint} from "rxp/src/interfaces/core/IReexecutionEndpoint.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract DeployOpenRank is Script {
    DeployEigenLayerCore public coreDeployer;
    DeployRxp_Holesky public rxpDeployer;
    OpenRankManager public orManager;
    DeployEigenLayerCore.EigenLayerDeployment coreDeployment;
    DeployEigenLayerCore.EigenLayerConfig coreConfig;
    DeployRxp_Holesky.RXPDeployment rxpDeployment;
    DeployRxp_Holesky.RXPConfig rxpConfig;

    address initialOwner;

    function run() public {
        coreDeployer = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxp_Holesky();
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
        rxpDeployer = new DeployRxp_Holesky();
        initialOwner = sender;

        _deployCore(false, initialOwner);
        _deployRxp(false, initialOwner);

        vm.startPrank(sender);
        _deployOrManager();
        _writeOrOutputJSON();
        vm.stopPrank();
    }

    function _deployCore(bool broadcast, address prankAddress) internal {
        string memory eigenlayerConfigPath = "script/holesky/config/deploy_eigenlayer_core.config.json";
        coreConfig = coreDeployer._readEigenLayerConfigJSON(eigenlayerConfigPath);
        coreDeployment = coreDeployer.run(coreConfig, broadcast, prankAddress);
    }

    function _deployRxp(bool broadcast, address prankAddress) internal {
        string memory rxpConfigPath = "script/holesky/config/deploy_rxp_contracts.config.json";
        rxpConfig = rxpDeployer._readRxpConfigJSON(rxpConfigPath);
        rxpDeployment = rxpDeployer.run(rxpConfig, coreDeployment, broadcast, prankAddress, "holesky");
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

        IERC20 paymentToken = reservationRegistry.paymentToken();
        paymentToken.transfer(address(orManager), 100000000);

        console.log("address(orManager): ", address(orManager));
        console.log("address(reexecutionEndpoint): ", address(reexecutionEndpoint));
    }

    function _writeOrOutputJSON() internal {
        string memory outputPath = "script/holesky/output/deploy_or_contracts_output.json";

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
