// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

contract OPManagerScript is Script {
    function run() public {
        vm.startBroadcast();

        OpenRankManager opManager = new OpenRankManager();
        console.log("OP Manager address: ", address(opManager));

        vm.stopBroadcast();
    }
}
