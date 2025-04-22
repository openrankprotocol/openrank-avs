// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../src/interfaces/core/IReexecutionEndpoint.sol";
import "../../src/interfaces/core/IReservationRegistry.sol";
import "../RxpTestHelpers.t.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

contract ReexecutionEndpointUnit is RxpTestHelpers {
    IERC20 public paymentToken;

    function setUp() public virtual {
        paymentToken = IERC20(reexecutionEndpoint.paymentToken());
    }

    function test_setResponseFeePerOperator() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newFee = 1000;
        reexecutionEndpoint.setResponseFeePerOperator(newFee);

        assertEq(reexecutionEndpoint.responseFeePerOperator(), newFee);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reexecutionEndpoint.setResponseFeePerOperator(2000);
        vm.stopPrank();
    }

    function test_setReexecutionFeePerOperator() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newFee = 2000;
        reexecutionEndpoint.setReexecutionFeePerOperator(newFee);

        assertEq(reexecutionEndpoint.reexecutionFeePerOperator(), newFee);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reexecutionEndpoint.setReexecutionFeePerOperator(3000);
        vm.stopPrank();
    }

    function test_setResponseWindowBlocks() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newWindow = 100;
        reexecutionEndpoint.setResponseWindowBlocks(newWindow);

        assertEq(reexecutionEndpoint.responseWindowBlocks(), newWindow);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reexecutionEndpoint.setResponseWindowBlocks(200);
        vm.stopPrank();
    }

    function test_setMaximumRequestsPerReservationPerResponseWindow() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newMax = 50;
        reexecutionEndpoint.setMaximumRequestsPerReservationPerResponseWindow(newMax);

        assertEq(reexecutionEndpoint.maximumRequestsPerReservationPerResponseWindow(), newMax);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reexecutionEndpoint.setMaximumRequestsPerReservationPerResponseWindow(100);
        vm.stopPrank();
    }

    function test_getRequestCount() public {
        // Initially there should be no requests
        assertEq(reexecutionEndpoint.getRequestCount(), 0);
    }

    function test_getResponse() public {
        // Initially there should be no responses, so this should revert
        vm.expectRevert();
        reexecutionEndpoint.getResponse(0, address(0x123));
    }

    function test_getCumulativeReservationRequestCount() public {
        // Initially there should be no requests for any reservation
        assertEq(reexecutionEndpoint.getCumulativeReservationRequestCount(0), 0);
    }

    function test_getCumulativeReservationRequestCountAtBlock() public {
        // Initially there should be no requests for any reservation at any block
        assertEq(reexecutionEndpoint.getCumulativeReservationRequestCountAtBlock(0, uint32(block.number)), 0);
    }

    function test_getRequestsInCurrentWindow() public {
        /// TODO: Fix this underflow error
        // Initially there should be no requests in the current window
        // assertEq(reexecutionEndpoint.getRequestsInCurrentWindow(0), 0);
    }
}
