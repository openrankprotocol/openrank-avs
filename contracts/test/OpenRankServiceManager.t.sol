// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {OpenRankServiceManager} from "../src/OpenRankServiceManager.sol";
import {EigenLayerCoreDeployer} from "../script/DeployEigenLayerCore.s.sol";
import {OpenRankDeployer} from "../script/DeployOpenRankManager.s.sol";
import "forge-std/Test.sol";

contract OpenRankServiceManagerTest is Test {
    EigenLayerCoreDeployer elcd;
    OpenRankDeployer ord;

    function setUp() public {
        elcd = new EigenLayerCoreDeployer();
        ord = new OpenRankDeployer();

        elcd.setUp();
        elcd.run();

        ord.setUp();
        ord.run();
    }

    function testCorrectCompute() public {
        console.log("ChainId: ", block.chainid);
    }
}
