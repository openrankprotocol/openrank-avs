// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IOpenRankManager} from "../src/IOpenRankManager.sol";

contract AddImageId is Script {
    function run() public {
        address initialOwner = vm.envAddress("ADDRESS");
        address orAddress = vm.envAddress("OPENRANK_MANAGER_ADDRESS");
        uint256 imageId = vm.envUint("IMAGE_ID");

        IOpenRankManager orManager = IOpenRankManager(orAddress);

        vm.startBroadcast(initialOwner);
        orManager.setImageId(uint32(imageId));
        vm.stopBroadcast();
    }
}
