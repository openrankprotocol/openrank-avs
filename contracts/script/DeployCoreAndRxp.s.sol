// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {console} from "forge-std/Script.sol";

import "./common/DeployTestUtils.sol";
import {DeployCore} from "./DeployCore.s.sol";
import {DeployRxp} from "./DeployRxp.s.sol";

contract DeployCoreAndRxp is DeployTestUtils {
    DeployCore deployCore;
    DeployRxp deployRxp;

    function run() public {
        deployCore = new DeployCore();
        deployRxp = new DeployRxp();

        broadcastOrPrank({
            broadcast: false,
            prankAddress: msg.sender,
            deployFunction: _deployCore
        });

        broadcastOrPrank({
            broadcast: false,
            prankAddress: msg.sender,
            deployFunction: _deployRxp
        });
    }

    function _deployCore() internal {
        deployCore.run();
    }

    function _deployRxp() internal {
        deployRxp.run();
    }
}
