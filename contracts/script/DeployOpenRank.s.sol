// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {DeployEigenLayerCore} from "rxp/script/local/deploy/deploy_eigenlayer_core.s.sol";
import {DeployRxp_Local} from "rxp/script/local/deploy/deploy_rxp_contracts.s.sol";

contract DeployOpenRank is Script {
    DeployEigenLayerCore deployCore;
    DeployRxp_Local rxpDeployer;

    function run() public {
        deployCore = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxp_Local();

        vm.startPrank(msg.sender);
        _deployCore();
        vm.stopPrank();

        vm.startPrank(msg.sender);
        _deployRxp();
        vm.stopPrank();
    }

    function _deployCore() internal {
        string memory configFile = "deploy_eigenlayer_core.config.json";
        deployCore.run(configFile, false);
    }

    function _deployRxp() internal {
        rxpDeployer.run(false);
    }
}
