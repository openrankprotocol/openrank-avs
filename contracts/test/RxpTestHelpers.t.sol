// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "./RxpDeploySetup.t.sol";

contract RxpTestHelpers is RxpDeploySetup {
    using BN254 for *;
    using Strings for uint256;

    /// @notice deposits an amount of an underlying token into a strategy for an operator
    /// assumes deployer has the underlying token
    function depositStrategy(address operator, IStrategy strategy, uint256 amount) public {
        IERC20 underlyingToken = IERC20(strategy.underlyingToken());

        vm.prank(deployer);
        underlyingToken.transfer(operator, amount);

        vm.startPrank(operator);
        underlyingToken.approve(address(strategyManager), type(uint256).max);
        strategyManager.depositIntoStrategy(strategy, underlyingToken, amount);
        vm.stopPrank();
    }

    /**
     * ================================================
     * Operator Registration with BLS keys
     * ================================================
     */
    function registerOperatorForOperatorSet(
        address operatorAddress,
        uint256 privateKey,
        address avs,
        ISlashingRegistryCoordinator registryCoordinator
    ) public {
        vm.startPrank(operatorAddress);
        // 1. register operator in eigenlayer
        delegationManager.registerAsOperator(operatorAddress, 0, "");

        // 2. register operator in AVS operatorSet
        (, IAllocationManagerTypes.RegisterParams memory registerParams) =
            createOperatorRegistrationParams(operatorAddress, privateKey, avs, registryCoordinator);
        allocationManager.registerForOperatorSets(operatorAddress, registerParams);
        vm.stopPrank();
    }

    /// @notice privateKey needs to be valid private key for the operator address
    function createOperatorRegistrationParams(
        address operatorAddress,
        uint256 privateKey,
        address avs,
        ISlashingRegistryCoordinator registryCoordinator
    ) public returns (Operator memory operator, IAllocationManagerTypes.RegisterParams memory registerParams) {
        {
            Wallet memory vmWallet = Wallet({ addr: operatorAddress, privateKey: privateKey });
            BLSWallet memory blsWallet = createBLSWallet(privateKey);

            operator = Operator({ key: vmWallet, signingKey: blsWallet });
        }

        IBLSApkRegistryTypes.PubkeyRegistrationParams memory pubkeyParams =
            createPubkeyRegistrationParams(operator, registryCoordinator);
        string memory socket = "socket:8545";

        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 0;
        IAllocationManagerTypes.RegisterParams memory registerParams = IAllocationManagerTypes.RegisterParams({
            avs: avs,
            operatorSetIds: operatorSetIds,
            data: abi.encode(ISlashingRegistryCoordinatorTypes.RegistrationType.NORMAL, socket, pubkeyParams)
        });

        return (operator, registerParams);
    }

    function createPubkeyRegistrationParams(
        Operator memory operator,
        ISlashingRegistryCoordinator registryCoordinator
    ) internal view returns (IBLSApkRegistryTypes.PubkeyRegistrationParams memory) {
        address operatorAddress = operator.key.addr;
        bytes32 messageHash = registryCoordinator.calculatePubkeyRegistrationMessageHash(operatorAddress);
        BN254.G1Point memory signature = SigningKeyOperationsLib.sign(operator.signingKey, messageHash);

        return IBLSApkRegistryTypes.PubkeyRegistrationParams(
            signature, operator.signingKey.publicKeyG1, operator.signingKey.publicKeyG2
        );
    }

    function createBLSWallet(
        uint256 privateKey
    ) internal returns (BLSWallet memory) {
        BN254.G1Point memory publicKeyG1 = BN254.generatorG1().scalar_mul(privateKey);
        BN254.G2Point memory publicKeyG2 = mul(privateKey);

        return BLSWallet({ privateKey: privateKey, publicKeyG2: publicKeyG2, publicKeyG1: publicKeyG1 });
    }

    function mul(
        uint256 x
    ) internal returns (BN254.G2Point memory g2Point) {
        string[] memory inputs = new string[](5);
        inputs[0] = "go";
        inputs[1] = "run";
        inputs[2] = "test/ffi/g2mul.go";
        inputs[3] = x.toString();

        inputs[4] = "1";
        bytes memory res = vm.ffi(inputs);
        g2Point.X[1] = abi.decode(res, (uint256));

        inputs[4] = "2";
        res = vm.ffi(inputs);
        g2Point.X[0] = abi.decode(res, (uint256));

        inputs[4] = "3";
        res = vm.ffi(inputs);
        g2Point.Y[1] = abi.decode(res, (uint256));

        inputs[4] = "4";
        res = vm.ffi(inputs);
        g2Point.Y[0] = abi.decode(res, (uint256));
    }
}
