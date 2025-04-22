// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import { ICertificateVerifier } from "../../src/interfaces/avs/ICertificateVerifier.sol";
import { IReservationRegistry } from "../../src/interfaces/core/IReservationRegistry.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "eigenlayer-middleware/src/BLSSignatureChecker.sol";

import { IBLSSignatureCheckerTypes } from "eigenlayer-middleware/src/interfaces/IBLSSignatureChecker.sol";

import "../RxpTestHelpers.t.sol";
import "../mocks/CertificateVerifierHarness.sol";
import "forge-std/Test.sol";

import "../RxpTestHelpers.t.sol";

contract UserFlows is RxpTestHelpers {
    // Rxp variables
    address avs;
    IERC20 public paymentToken;
    uint256 public reservationID;
    bytes[] imageDACerts;
    bytes quorumNumbers;
    address challenger = address(0x999);

    // Rxp Operators: anvil addresses 0, 1 respectively
    address rxpOp1 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 rxpOp1PrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    Operator public rxpOp1Wallet;
    address rxpOp2 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 rxpOp2PrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    Operator public rxpOp2Wallet;

    // Simple AVS operators

    function setUp() public virtual {
        // IReexecutionEndpoint.getRequestsInCurrentWindow underflows if block.number is not large enough
        vm.roll(block.number + 7200);

        // Set up certificate verifier
        certificateVerifierImplementation =
            new CertificateVerifierHarness(slashingRegistryCoordinator, reservationRegistry);
        // upgrade certificate verifier
        vm.prank(deployer);
        avsProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(address(certificateVerifier)), address(certificateVerifierImplementation)
        );

        avs = address(serviceManager);
        quorumNumbers = new bytes(1);
        quorumNumbers[0] = bytes1(uint8(0));

        imageDACerts = new bytes[](1);
        imageDACerts[0] = new bytes(0);

        paymentToken = IERC20(reservationRegistry.paymentToken());

        // register Operator 1 to Rxp
        depositStrategy(rxpOp1, rxpStrategies[0], 100e18);
        registerOperatorForOperatorSet(
            rxpOp1, rxpOp1PrivateKey, address(rxpServiceManager), rxpSlashingRegistryCoordinator
        );

        // register Operator 2 to Rxp
        depositStrategy(rxpOp2, rxpStrategies[0], 100e18);
        registerOperatorForOperatorSet(
            rxpOp2, rxpOp2PrivateKey, address(rxpServiceManager), rxpSlashingRegistryCoordinator
        );
    }

    function _setDummyCertificate(
        bytes32 responseHash
    ) internal returns (ICertificateVerifier.VerificationRecord memory verificationRecord) {
        verificationRecord = ICertificateVerifier.VerificationRecord({
            referenceBlockNumber: uint32(block.number),
            signatoryRecordHash: bytes32(uint256(1)),
            quorumStakeTotals: IBLSSignatureCheckerTypes.QuorumStakeTotals({
                signedStakeForQuorum: new uint96[](0),
                totalStakeForQuorum: new uint96[](0)
            })
        });
        CertificateVerifierHarness(address(certificateVerifier)).setVerificationRecord(responseHash, verificationRecord);
    }

    function _fundAddress(address to, uint256 amount) internal {
        vm.prank(deployer);
        paymentToken.transfer(to, amount);
    }

    function test_reserve_addImage() public {
        // Add image to reservation
        vm.startPrank(deployer);
        reservationID = reservationRegistry.reserve(avs, 1000);

        uint32 imageID = reservationRegistry.addImage(reservationID, imageDACerts);
        vm.stopPrank();

        assertTrue(reservationRegistry.isImageAdded(imageID));
    }

    function test_reserve_addImage_removeImage() public {
        vm.startPrank(deployer);
        reservationID = reservationRegistry.reserve(avs, 1000);

        uint32 imageID = reservationRegistry.addImage(reservationID, imageDACerts);
        assertTrue(reservationRegistry.isImageAdded(imageID));

        reservationRegistry.removeImage(reservationID, imageID);
        vm.stopPrank();

        assertFalse(reservationRegistry.isImageAdded(imageID));
    }

    /// @dev removing and image reverts if there are active requests in the past response window number
    /// of blocks
    function test_reserve_addImage_request_revert_removeImage() public {
        // 1. reserve and add image
        vm.startPrank(deployer);
        reservationID = reservationRegistry.reserve(avs, 1000);

        uint32 imageID = reservationRegistry.addImage(reservationID, imageDACerts);
        assertTrue(reservationRegistry.isImageAdded(imageID));
        vm.stopPrank();

        // 2. Verify a mock certificate
        bytes memory requestData = new bytes(0);
        ICertificateVerifier.TaskResponse memory taskResponse = ICertificateVerifier.TaskResponse({
            imageID: imageID,
            inputData: new bytes(0),
            response: new bytes(0),
            quorumNumbers: quorumNumbers,
            referenceBlockNumber: uint32(block.number)
        });
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nonSignerParams;
        bytes32 responseHash = keccak256(abi.encode(taskResponse));
        ICertificateVerifier.VerificationRecord memory verificationRecord = _setDummyCertificate(responseHash);

        // 3. Request reexecution
        (uint256 requestFee,) = reexecutionEndpoint.getRequestFee(uint32(block.number));
        _fundAddress(challenger, requestFee);
        vm.startPrank(challenger);
        paymentToken.approve(address(reexecutionSlasher), requestFee);
        reexecutionSlasher.requestReexecution(taskResponse);
        vm.stopPrank();

        // 4. Remove image should revert
        vm.prank(deployer);
        // TODO: UNCOMMENT THIS FOR DEVNET
        // vm.expectRevert(IReservationRegistry.RequestsAreActive.selector);
        reservationRegistry.removeImage(reservationID, imageID);
    }

    /// FINALIZED RX RESPONSE
    function test_reserve_addImage_request_respond_FINALIZED() public {
        // 1. reserve and add image
        vm.startPrank(deployer);
        reservationID = reservationRegistry.reserve(avs, 1000);

        uint32 imageID = reservationRegistry.addImage(reservationID, imageDACerts);
        assertTrue(reservationRegistry.isImageAdded(imageID));
        vm.stopPrank();

        // 2. Verify a mock certificate
        bytes memory requestData = new bytes(0);
        ICertificateVerifier.TaskResponse memory taskResponse = ICertificateVerifier.TaskResponse({
            imageID: imageID,
            inputData: new bytes(0),
            response: new bytes(0),
            quorumNumbers: quorumNumbers,
            referenceBlockNumber: uint32(block.number)
        });
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nonSignerParams;
        bytes32 responseHash = keccak256(abi.encode(taskResponse));
        ICertificateVerifier.VerificationRecord memory verificationRecord = _setDummyCertificate(responseHash);

        // 3. Request reexecution
        (uint256 requestFee,) = reexecutionEndpoint.getRequestFee(uint32(block.number));
        _fundAddress(challenger, requestFee);
        vm.startPrank(challenger);
        paymentToken.approve(address(reexecutionSlasher), requestFee);
        uint256 requestIndex = reexecutionSlasher.requestReexecution(taskResponse);
        vm.stopPrank();

        // 4. Rxp operators respond to request
        vm.prank(rxpOp1);
        reexecutionEndpoint.respond({
            operator: rxpOp1,
            requestIndex: requestIndex,
            responseData: responseHash,
            signature: new bytes(0)
        });
        vm.prank(rxpOp2);
        reexecutionEndpoint.respond({
            operator: rxpOp2,
            requestIndex: requestIndex,
            responseData: responseHash,
            signature: new bytes(0)
        });

        // 5. Get finalized response
        (IReexecutionEndpoint.RequestStatus status, bytes32 finalizedResponse) =
            reexecutionEndpoint.getFinalizedResponse(requestIndex);
        assertEq(uint8(status), uint8(IReexecutionEndpoint.RequestStatus.FINALIZED));
        assertEq(finalizedResponse, responseHash);
    }

    function test_reserve_addImage_request_respond_FINALIZED_getFinalizedResponse() public { }
    /// Successful challenge
    function test_reserve_addImage_request_respond_FINALIZED_slashOperators() public { }
    /// Unsuccessful challenge
    function test_reserve_addImage_request_respond_FINALIZED_revert_slashOperators() public { }

    /// ABSTAIN RX RESPONSE
    function test_reserve_addImage_request_respond_ABSTAIN() public { }
    function test_reserve_addImage_request_respond_ABSTAIN_getFinalizedResponse() public { }
    function test_reserve_addImage_request_respond_ABSTAIN_revert_slashOperators() public { }
}
