// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

/**
 * @title DeployTestUtils
 * @notice Utility contract with helper functions for deployment scripts
 * allows us to reuse the same deployment scripts for different environments including testing
 */
contract DeployTestUtils is Script, Test {
    /**
     * @notice Start broadcasting or pranking based on the broadcast parameter
     * @param broadcast If true, start broadcasting; if false, start pranking
     * @param prankAddress The address to prank as (only used if broadcast is false)
     */
    function startOperation(bool broadcast, address prankAddress) internal {
        if (broadcast) {
            vm.startBroadcast();
        } else {
            vm.startPrank(prankAddress);
        }
    }

    /**
     * @notice Stop broadcasting or pranking based on the broadcast parameter
     * @param broadcast If true, stop broadcasting; if false, stop pranking
     */
    function stopOperation(
        bool broadcast
    ) internal {
        if (broadcast) {
            vm.stopBroadcast();
        } else {
            vm.stopPrank();
        }
    }

    /**
     * @notice Execute a function with broadcasting or pranking
     * @param broadcast If true, use broadcasting; if false, use pranking
     * @param prankAddress The address to prank as (only used if broadcast is false)
     * @param deployFunction The function to execute
     * @param writeOutputFunction The function to write output, only run if testing
     */
    function broadcastOrPrank(
        bool broadcast,
        address prankAddress,
        function() internal deployFunction,
        function() internal writeOutputFunction
    ) internal {
        startOperation(broadcast, prankAddress);
        deployFunction();
        stopOperation(broadcast);

        // if (broadcast) {
        writeOutputFunction();
        // }
    }

    /**
     * @notice Execute a function with broadcasting or pranking
     * @param broadcast If true, use broadcasting; if false, use pranking
     * @param prankAddress The address to prank as (only used if broadcast is false)
     * @param deployFunction The function to execute
     * @param writeOutputFunction The function to write output, only run if testing
     * @param outputPath The path to write output to
     */
    function broadcastOrPrank(
        bool broadcast,
        address prankAddress,
        function() internal deployFunction,
        function(string memory) internal writeOutputFunction,
        string memory outputPath
    ) internal {
        startOperation(broadcast, prankAddress);
        deployFunction();
        stopOperation(broadcast);

        // if (broadcast) {
        writeOutputFunction(outputPath);
        // }
    }

    /**
     * @notice Exact same as above without writing output
     * @param broadcast If true, use broadcasting; if false, use pranking
     * @param prankAddress The address to prank as (only used if broadcast is false)
     * @param deployFunction The function to execute
     */
    function broadcastOrPrank(bool broadcast, address prankAddress, function() internal deployFunction) internal {
        startOperation(broadcast, prankAddress);
        deployFunction();
        stopOperation(broadcast);
    }
}
