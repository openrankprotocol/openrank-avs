// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DeployTestUtils} from "rxp/script/common/DeployTestUtils.sol";
import {DeployEigenLayerCore} from "rxp/script/local/deploy/deploy_eigenlayer_core.s.sol";
import {DeployRxp_Local} from "rxp/script/local/deploy/deploy_rxp_contracts.s.sol";
import { IStrategy } from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {DeployAVSBase} from "./DeployAVSBase.sol";

contract DeployOpenRank is DeployAVSBase {
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

        super.run(false);
    }

    function _deployCore() internal {
        string memory configFile = "deploy_eigenlayer_core.config.json";
        deployCore.run(configFile, false);
    }

    function _deployRxp() internal {
        rxpDeployer.run(false);
    }

    function chooseStrategiesForAVS() public view override returns (IStrategy[] memory) {
        // Create and return an array containing only the RxpStrategy
        IStrategy[] memory selectedStrategies = new IStrategy[](1);
        selectedStrategies[0] = IStrategy(rxpStrategy);
        return selectedStrategies;
    }
}
