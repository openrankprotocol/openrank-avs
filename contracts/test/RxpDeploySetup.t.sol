// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {DeployEigenLayerCore, StrategyBase} from "../script/deploy/deploy_eigenlayer_core.s.sol";
import {BLSApkRegistry, DeployRxp_Local as DeployRxpContracts, IAVSDirectory, IAllocationManager, IAllocationManagerTypes, IBLSApkRegistry, IBLSApkRegistryTypes, IDelegationManager, IERC20, IIndexRegistry, IPermissionController, IReexecutionEndpoint, IReservationRegistry, IRewardsCoordinator, IServiceManager, ISlashingRegistryCoordinator, ISlashingRegistryCoordinatorTypes, ISocketRegistry, IStakeRegistry, IStrategy, IStrategyManager, Operator, PauserRegistry, ProxyAdmin, SlashingRegistryCoordinator} from "../script/deploy/deploy_rxp_contracts.s.sol";

import {CertificateVerifier, ReexecutionSlasher} from "../script/common/deploy_simple_avs.sol";

import {DeploySimpleAVS_Local as DeploySimpleAVS} from "../script/deploy/deploy_simple_avs.s.sol";

import "forge-std/Test.sol";
import {MinimalCertificateVerifier} from "teal-contracts/src/MinimalCertificateVerifier.sol";

import {BLSWallet, BN254, Operator, OperatorWalletLib, SigningKeyOperationsLib, Strings, Wallet} from "eigenlayer-middleware/test/utils/OperatorWalletLib.sol";

/**
 * @title RxpDeploySetup
 * @notice Test harness for deploying all RxP contracts in a test environment
 * @dev This contract sets up a complete RxP deployment by running all three deployment scripts in sequence
 */

contract RxpDeploySetup is Test {
    // Deployment scripts
    DeployEigenLayerCore public eigenLayerDeployer;
    DeployRxpContracts public rxpDeployer;
    DeploySimpleAVS public avsDeployer;

    // Deployment output paths
    string public constant EIGENLAYER_CONFIG_PATH =
        "deploy_eigenlayer_core.config.json";
    string public constant RXP_CONFIG_PATH = "deploy_rxp_contracts.config.json";

    // Deployer private key
    uint256 public deployerPrivateKey;
    address public deployer;

    /// CONTRACT ADDRESSES
    // EigenLayer Contracts
    IPermissionController permissionController;
    IDelegationManager delegationManager;
    IAVSDirectory avsDirectory;
    IAllocationManager allocationManager;
    IRewardsCoordinator rewardsCoordinator;
    IStrategyManager strategyManager;
    PauserRegistry eigenlayerPauserReg;
    ProxyAdmin eigenlayerProxyAdmin;
    // RXP Contracts
    ProxyAdmin rxpProxyAdmin;
    IReservationRegistry reservationRegistry;
    IReservationRegistry reservationRegistryImplementation;
    IReexecutionEndpoint reexecutionEndpoint;
    IReexecutionEndpoint reexecutionEndpointImplementation;
    address initialOwner;
    IIndexRegistry rxpIndexRegistry;
    IIndexRegistry rxpIndexRegistryImplementation;
    IStakeRegistry rxpStakeRegistry;
    IStakeRegistry rxpStakeRegistryImplementation;
    IBLSApkRegistry rxpApkRegistry;
    IBLSApkRegistry rxpApkRegistryImplementation;
    ISocketRegistry rxpSocketRegistry;
    ISocketRegistry rxpSocketRegistryImplementation;
    IServiceManager rxpServiceManager;
    IServiceManager rxpServiceManagerImplementation;
    ISlashingRegistryCoordinator rxpSlashingRegistryCoordinator;
    ISlashingRegistryCoordinator rxpSlashingRegistryCoordinatorImplementation;
    PauserRegistry rxpPauserReg;
    IStrategy[] public rxpStrategies;

    // Simple AVS
    ReexecutionSlasher reexecutionSlasher;
    ReexecutionSlasher reexecutionSlasherImplementation;
    CertificateVerifier certificateVerifier;
    CertificateVerifier certificateVerifierImplementation;
    BLSApkRegistry apkRegistry;
    BLSApkRegistry apkRegistryImplementation;
    IServiceManager serviceManager;
    IServiceManager serviceManagerImplementation;
    ISlashingRegistryCoordinator slashingRegistryCoordinator;
    ISlashingRegistryCoordinator slashingRegistryCoordinatorImplementation;
    IIndexRegistry indexRegistry;
    IIndexRegistry indexRegistryImplementation;
    IStakeRegistry stakeRegistry;
    IStakeRegistry stakeRegistryImplementation;
    ISocketRegistry socketRegistry;
    ISocketRegistry socketRegistryImplementation;
    ProxyAdmin avsProxyAdmin;
    IStrategy[] public avsStrategies;

    // AVS opSet Strategy
    StrategyBase public mockStrategy;
    IERC20 public mockToken;

    // Operator for test along with BLS keys
    Operator public operatorWallet;

    // Constructor sets up the deployment scripts
    constructor() {
        // Use anvil default private key for testing
        deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        deployer = vm.addr(deployerPrivateKey);

        // Initialize deployment scripts
        eigenLayerDeployer = new DeployEigenLayerCore();
        rxpDeployer = new DeployRxpContracts();
        avsDeployer = new DeploySimpleAVS();

        deployAll();
    }

    function deployAll() public {
        // Start from the deployer address

        // Step 1: Deploy EigenLayer core contracts
        console.log("Step 1: Deploying EigenLayer core contracts...");
        vm.startPrank(deployer);
        eigenLayerDeployer.run(EIGENLAYER_CONFIG_PATH, false);
        vm.stopPrank();
        _getDeployedEigenlayerAddresses();

        // Step 2: Deploy RxP core contracts
        console.log("Step 2: Deploying RxP core contracts...");
        vm.startPrank(deployer);
        rxpDeployer.run(false);
        vm.stopPrank();
        _getDeployedRxPAddresses();

        // Step 3: Deploy example AVS contracts
        console.log("Step 3: Deploying example AVS contracts...");
        vm.startPrank(deployer);
        avsDeployer.run(false);
        vm.stopPrank();
        _getDeployedSimpleAVSAddresses();
    }

    function _getDeployedEigenlayerAddresses() internal {
        // Eigenlayer contracts
        permissionController = eigenLayerDeployer.permissionController();
        delegationManager = eigenLayerDeployer.delegation();
        avsDirectory = eigenLayerDeployer.avsDirectory();
        allocationManager = eigenLayerDeployer.allocationManager();
        rewardsCoordinator = eigenLayerDeployer.rewardsCoordinator();
        strategyManager = eigenLayerDeployer.strategyManager();
        eigenlayerPauserReg = eigenLayerDeployer.eigenLayerPauserReg();
        eigenlayerProxyAdmin = eigenLayerDeployer.eigenLayerProxyAdmin();
    }

    function _getDeployedRxPAddresses() internal {
        // RXP contracts
        rxpProxyAdmin = rxpDeployer.proxyAdmin();
        reservationRegistry = rxpDeployer.reservationRegistry();
        reservationRegistryImplementation = rxpDeployer
            .reservationRegistryImplementation();
        reexecutionEndpoint = rxpDeployer.reexecutionEndpoint();
        reexecutionEndpointImplementation = rxpDeployer
            .reexecutionEndpointImplementation();
        rxpIndexRegistry = rxpDeployer.indexRegistry();
        rxpIndexRegistryImplementation = rxpDeployer
            .indexRegistryImplementation();
        rxpStakeRegistry = rxpDeployer.stakeRegistry();
        rxpStakeRegistryImplementation = rxpDeployer
            .stakeRegistryImplementation();
        rxpApkRegistry = rxpDeployer.apkRegistry();
        rxpApkRegistryImplementation = rxpDeployer.apkRegistryImplementation();
        rxpSocketRegistry = rxpDeployer.socketRegistry();
        rxpSocketRegistryImplementation = rxpDeployer
            .socketRegistryImplementation();
        rxpServiceManager = rxpDeployer.serviceManager();
        rxpServiceManagerImplementation = rxpDeployer
            .serviceManagerImplementation();
        rxpSlashingRegistryCoordinator = rxpDeployer
            .slashingRegistryCoordinator();
        rxpSlashingRegistryCoordinatorImplementation = rxpDeployer
            .slashingRegistryCoordinatorImplementation();
        rxpPauserReg = rxpDeployer.avsPauserReg();
        rxpStrategies.push(rxpDeployer.rxpStrategy());
    }

    function _getDeployedSimpleAVSAddresses() internal {
        // Simple AVS contracts
        reexecutionSlasher = avsDeployer.reexecutionSlasher();
        reexecutionSlasherImplementation = avsDeployer
            .reexecutionSlasherImplementation();
        certificateVerifier = avsDeployer.rxCertificateVerifier();
        certificateVerifierImplementation = avsDeployer
            .rxCertificateVerifierImplementation();
        apkRegistry = avsDeployer.apkRegistry();
        apkRegistryImplementation = avsDeployer.apkRegistryImplementation();
        serviceManager = avsDeployer.serviceManager();
        serviceManagerImplementation = avsDeployer
            .serviceManagerImplementation();
        slashingRegistryCoordinator = avsDeployer.slashingRegistryCoordinator();
        slashingRegistryCoordinatorImplementation = avsDeployer
            .slashingRegistryCoordinatorImplementation();
        indexRegistry = avsDeployer.indexRegistry();
        indexRegistryImplementation = avsDeployer.indexRegistryImplementation();
        stakeRegistry = avsDeployer.stakeRegistry();
        stakeRegistryImplementation = avsDeployer.stakeRegistryImplementation();
        socketRegistry = avsDeployer.socketRegistry();
        socketRegistryImplementation = avsDeployer
            .socketRegistryImplementation();
        avsProxyAdmin = avsDeployer.avsProxyAdmin();
        avsStrategies.push(avsDeployer.rxpStrategy());
    }
}
