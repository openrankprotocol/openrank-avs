// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console, stdJson} from "forge-std/Script.sol";
import {IOpenRankManager} from "../src/IOpenRankManager.sol";

contract AddImageId is Script {
    function run() public {
        string memory outputFile = "deploy_or_contracts_output.json";
        string memory orOutputPath = string.concat("script/local/output/", outputFile);
        string memory outputData = vm.readFile(orOutputPath);

        address orAddress = stdJson.readAddress(outputData, ".addresses.openRankManager");

        address initialOwner = vm.envAddress("ADDRESS");
        uint256 imageId = vm.envUint("IMAGE_ID");

        IOpenRankManager orManager = IOpenRankManager(orAddress);

        vm.startBroadcast(initialOwner);
        orManager.setImageId(uint32(imageId));
        vm.stopBroadcast();
    }
}
