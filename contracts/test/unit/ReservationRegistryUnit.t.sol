// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "../../src/core/ReservationRegistry.sol";
import "../../src/interfaces/core/IReexecutionEndpoint.sol";
import "../../src/interfaces/core/IReservationRegistry.sol";
import "../RxpTestHelpers.t.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/Test.sol";

contract ReservationRegistryUnit is RxpTestHelpers {
    IERC20 public paymentToken;

    function setUp() public virtual {
        paymentToken = IERC20(reservationRegistry.paymentToken());
    }

    function test_setMaxImagesPerReservation() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newMaxImages = 10;
        reservationRegistry.setMaxImagesPerReservation(newMaxImages);

        assertEq(reservationRegistry.maxImagesPerReservation(), newMaxImages);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reservationRegistry.setMaxImagesPerReservation(20);
        vm.stopPrank();
    }

    function test_setPrepaidBilledEpochs() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newPrepaidEpochs = 5;
        reservationRegistry.setPrepaidBilledEpochs(newPrepaidEpochs);

        assertEq(reservationRegistry.prepaidBilledEpochs(), newPrepaidEpochs);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reservationRegistry.setPrepaidBilledEpochs(10);
        vm.stopPrank();
    }

    function test_setResourceCostPerOperatorPerEpoch() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newCost = 1000;
        reservationRegistry.setResourceCostPerOperatorPerEpoch(newCost);

        assertEq(reservationRegistry.resourceCostPerOperatorPerEpoch(), newCost);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reservationRegistry.setResourceCostPerOperatorPerEpoch(2000);
        vm.stopPrank();
    }

    function test_setMaxReservations() public {
        // Only owner can call this function
        vm.startPrank(deployer);

        uint256 newMaxReservations = 50;
        reservationRegistry.setMaxReservations(newMaxReservations);

        assertEq(reservationRegistry.maxReservations(), newMaxReservations);

        vm.stopPrank();

        // Non-owner cannot call this function
        vm.startPrank(address(0x123));
        vm.expectRevert("Ownable: caller is not the owner");
        reservationRegistry.setMaxReservations(100);
        vm.stopPrank();
    }

    function test_getEpochFromBlocknumber() public {
        uint256 genesisBlock = reservationRegistry.epochGenesisBlock();
        uint256 epochLength = reservationRegistry.epochLengthBlocks();

        // Test epoch calculation for different block numbers
        assertEq(reservationRegistry.getEpochFromBlocknumber(genesisBlock), 0);
        assertEq(reservationRegistry.getEpochFromBlocknumber(genesisBlock + 1), 0);
        assertEq(reservationRegistry.getEpochFromBlocknumber(genesisBlock + epochLength - 1), 0);
        assertEq(reservationRegistry.getEpochFromBlocknumber(genesisBlock + epochLength), 1);
        assertEq(reservationRegistry.getEpochFromBlocknumber(genesisBlock + epochLength * 2), 2);
    }

    function test_currentEpoch() public {
        uint256 genesisBlock = reservationRegistry.epochGenesisBlock();
        uint256 epochLength = reservationRegistry.epochLengthBlocks();

        // Set block number to different epochs
        vm.roll(genesisBlock);
        assertEq(reservationRegistry.currentEpoch(), 0);

        vm.roll(genesisBlock + epochLength - 1);
        assertEq(reservationRegistry.currentEpoch(), 0);

        vm.roll(genesisBlock + epochLength);
        assertEq(reservationRegistry.currentEpoch(), 1);

        vm.roll(genesisBlock + epochLength * 2);
        assertEq(reservationRegistry.currentEpoch(), 2);
    }

    function test_currentEpochStartBlock() public {
        uint256 genesisBlock = reservationRegistry.epochGenesisBlock();
        uint256 epochLength = reservationRegistry.epochLengthBlocks();

        // Set block number to different epochs
        vm.roll(genesisBlock);
        assertEq(reservationRegistry.currentEpochStartBlock(), genesisBlock);

        vm.roll(genesisBlock + epochLength - 1);
        assertEq(reservationRegistry.currentEpochStartBlock(), genesisBlock);

        vm.roll(genesisBlock + epochLength);
        assertEq(reservationRegistry.currentEpochStartBlock(), genesisBlock + epochLength);

        vm.roll(genesisBlock + epochLength * 2);
        assertEq(reservationRegistry.currentEpochStartBlock(), genesisBlock + epochLength * 2);
    }

    function test_prepaidReservationFee() public {
        // Test fee calculation for different numbers of operators
        uint256 costPerOperator = reservationRegistry.resourceCostPerOperatorPerEpoch();
        uint256 prepaidEpochs = reservationRegistry.prepaidBilledEpochs();

        // For 1 operator
        assertEq(reservationRegistry.prepaidReservationFee(1), costPerOperator * prepaidEpochs);

        // For 5 operators
        assertEq(reservationRegistry.prepaidReservationFee(5), costPerOperator * 5 * prepaidEpochs);

        // For 10 operators
        assertEq(reservationRegistry.prepaidReservationFee(10), costPerOperator * 10 * prepaidEpochs);
    }
}
