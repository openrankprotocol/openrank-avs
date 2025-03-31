// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

contract OPManagerScript is Script {
    function run() public {
        vm.startBroadcast();

        address whitelisted_address = vm.envAddress("ADDRESS");

        address[] memory computers = new address[](1);
        computers[0] = whitelisted_address;

        address[] memory challengers = new address[](1);
        challengers[0] = whitelisted_address;

        address[] memory users = new address[](1);
        users[0] = whitelisted_address;

        OpenRankManager opManager = new OpenRankManager(
            computers,
            challengers,
            users
        );

        console.log("OP Manager address: ", address(opManager));

        vm.stopBroadcast();
    }
}
