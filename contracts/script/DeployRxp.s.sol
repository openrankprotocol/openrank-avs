// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "eigenlayer-contracts/src/test/mocks/EmptyContract.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PauserRegistry} from "eigenlayer-contracts/src/contracts/permissions/PauserRegistry.sol";

import {ReexecutionEndpoint} from "../src/ReexecutionEndpoint.sol";
import {ReservationRegistry} from "../src/ReservationRegistry.sol";
import {IReservationRegistry} from "../src/interfaces/IReservationRegistry.sol";
import {IReexecutionEndpoint} from "../src/interfaces/IReexecutionEndpoint.sol";
import {IEigenDACertVerifier} from "eigenda/contracts/src/interfaces/IEigenDACertVerifier.sol";

import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/core/AVSDirectory.sol";
import {AllocationManager, IAVSRegistrar, IAllocationManager, IAllocationManagerTypes, OperatorSet} from "eigenlayer-contracts/src/contracts/core/AllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/core/DelegationManager.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/core/RewardsCoordinator.sol";
import {IStrategyManager} from "eigenlayer-contracts/src/contracts/core/StrategyManager.sol";

import {IPermissionController} from "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import {IStrategyFactory, StrategyFactory} from "eigenlayer-contracts/src/contracts/strategies/StrategyFactory.sol";
import {IBLSApkRegistry, IIndexRegistry, ISlashingRegistryCoordinator, ISocketRegistry, IStakeRegistry, IStakeRegistryTypes, SlashingRegistryCoordinator} from "eigenlayer-middleware/src/SlashingRegistryCoordinator.sol";

import {ISlashingRegistryCoordinatorTypes} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";

import {BLSApkRegistry} from "eigenlayer-middleware/src/BLSApkRegistry.sol";

import {IndexRegistry} from "eigenlayer-middleware/src/IndexRegistry.sol";
import {IBLSApkRegistryTypes} from "eigenlayer-middleware/src/interfaces/IBLSApkRegistry.sol";
import {BN254} from "eigenlayer-middleware/src/libraries/BN254.sol";

import {IServiceManager, ServiceManagerBase} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import {SocketRegistry} from "eigenlayer-middleware/src/SocketRegistry.sol";
import {StakeRegistry} from "eigenlayer-middleware/src/StakeRegistry.sol";

import {BLSWallet, Operator, OperatorWalletLib, SigningKeyOperationsLib, Wallet} from "eigenlayer-middleware/test/utils/OperatorWalletLib.sol";

import "./common/DeployTestUtils.sol";
import {IStrategy} from "eigenlayer-middleware/src/StakeRegistry.sol";
import {OpenRankManager} from "../src/OpenRankManager.sol";

contract DeployRxp is DeployTestUtils {
    using BN254 for *;
    using Strings for uint256;

    string public deployConfigPath;

    // EigenLayer Contracts
    IPermissionController permissionController;
    IDelegationManager delegationManager;
    IAVSDirectory avsDirectory;
    IAllocationManager allocationManager;
    IRewardsCoordinator rewardsCoordinator;
    IStrategyManager strategyManager;
    IStrategyFactory strategyFactory;
    PauserRegistry eigenlayerPauserReg;
    ProxyAdmin eigenlayerProxyAdmin;
    // Deployed contracts
    ProxyAdmin public proxyAdmin;
    EmptyContract emptyContract;

    IReservationRegistry public reservationRegistry;
    IReservationRegistry public reservationRegistryImplementation;
    IReexecutionEndpoint public reexecutionEndpoint;
    IReexecutionEndpoint public reexecutionEndpointImplementation;
    address initialOwner;

    // ReexecutionEndpoint
    // initialize
    uint256 responseFeePerOperator;
    uint256 reexecutionFeePerOperator;
    uint256 responseWindowBlocks;
    uint256 maximumRequestsPerReservationPerResponseWindow;

    // ReservationRegistry
    // constructor
    address operatorFeeDistributor;
    IERC20 paymentToken;
    uint256 epochLengthBlocks;
    uint256 epochGenesisBlock;
    uint256 reservationBondAmount;
    // initialize
    uint256 prepaidBilledEpochs;
    uint256 resourceCostPerOperatorPerEpoch;
    uint256 maxImagesPerReservation;
    uint256 maxReservations;

    // AVS Middleware contracts
    IIndexRegistry public indexRegistry;
    IIndexRegistry public indexRegistryImplementation;
    IStakeRegistry public stakeRegistry;
    IStakeRegistry public stakeRegistryImplementation;
    IBLSApkRegistry public apkRegistry;
    IBLSApkRegistry public apkRegistryImplementation;
    ISocketRegistry public socketRegistry;
    ISocketRegistry public socketRegistryImplementation;
    IServiceManager public serviceManager;
    IServiceManager public serviceManagerImplementation;
    ISlashingRegistryCoordinator public slashingRegistryCoordinator;
    ISlashingRegistryCoordinator
        public slashingRegistryCoordinatorImplementation;
    PauserRegistry public avsPauserReg;

    // AVS opSet Strategy
    // rxpStrategy with `paymentToken`
    IStrategy public rxpStrategy;

    // Add this as a state variable at the top with other state variables
    IStrategy[] public strategies;

    // Operator for test along with BLS keys
    Operator public operatorWallet;

    function run() public {
        string
            memory rxpConfigPath = "contracts/script/config/deploy_rxp_contracts.config.json";
        string
            memory eigenlayerContractsPath = "contracts/script/output/deploy_eigenlayer_core_output.json";
        string
            memory outputPath = "contracts/script/output/deploy_rxp_contracts_output.json";

        _parseEigenLayerContracts(eigenlayerContractsPath);
        _parseRxpConfig(rxpConfigPath);
        // DEPLOY RXP CONTRACTS FROM SCRATCH
        broadcastOrPrank({
            broadcast: false,
            prankAddress: msg.sender,
            deployFunction: _deployContracts,
            writeOutputFunction: _writeOutputJSON,
            outputPath: outputPath
        });
    }

    function _deployContracts() internal {
        // deploy proxyAdmin if not deployed
        if (address(proxyAdmin) == address(0)) {
            proxyAdmin = new ProxyAdmin();
        }
        // deploy emptyContract if not deployed
        if (address(emptyContract) == address(0)) {
            emptyContract = new EmptyContract();
        }

        // deploy pauser registry
        {
            address[] memory pausers = new address[](1);
            pausers[0] = msg.sender;
            avsPauserReg = new PauserRegistry(pausers, msg.sender);
        }

        // deploy EigenDACertVerifier
        // TODO: deploy actual EigenDACertVerifier as well as all required dependencies
        IEigenDACertVerifier certificateVerifier = IEigenDACertVerifier(
            address(0)
        );

        // deploy proxies
        reexecutionEndpoint = ReexecutionEndpoint(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );
        reservationRegistry = ReservationRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        serviceManager = ServiceManagerBase(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        slashingRegistryCoordinator = SlashingRegistryCoordinator(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        indexRegistry = IIndexRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        stakeRegistry = IStakeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        apkRegistry = BLSApkRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        socketRegistry = ISocketRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(proxyAdmin),
                    ""
                )
            )
        );

        // deploy a payment token and a strategy for Rxp contracts OperatorSet
        // both as the deposited strategy for Rxp operators but also the Rxp Payment Token
        paymentToken = new ERC20PresetFixedSupply(
            "RXP MOCK",
            "RXP MOCK",
            1000000000 ether,
            initialOwner
        );
        paymentToken.approve(address(reservationRegistry), type(uint256).max);
        paymentToken.approve(address(reexecutionEndpoint), type(uint256).max);
        rxpStrategy = strategyFactory.deployNewStrategy(paymentToken);

        // set strategies array
        strategies = new IStrategy[](1);
        strategies[0] = rxpStrategy;

        // deploy implementations
        reservationRegistryImplementation = new ReservationRegistry(
            IReservationRegistry.ReservationRegistryConstructorParams({
                permissionController: permissionController,
                reexecutionEndpoint: reexecutionEndpoint,
                certificateVerifier: certificateVerifier,
                indexRegistry: indexRegistry,
                operatorFeeDistributor: operatorFeeDistributor,
                paymentToken: paymentToken,
                epochLengthBlocks: epochLengthBlocks,
                epochGenesisBlock: block.number,
                reservationBondAmount: reservationBondAmount
            })
        );

        reexecutionEndpointImplementation = new ReexecutionEndpoint(
            permissionController,
            reservationRegistry,
            slashingRegistryCoordinator,
            indexRegistry,
            stakeRegistry,
            paymentToken
        );

        indexRegistryImplementation = new IndexRegistry(
            slashingRegistryCoordinator
        );

        stakeRegistryImplementation = new StakeRegistry(
            slashingRegistryCoordinator,
            IDelegationManager(delegationManager),
            IAVSDirectory(avsDirectory),
            IAllocationManager(allocationManager)
        );

        apkRegistryImplementation = new BLSApkRegistry(
            slashingRegistryCoordinator
        );

        socketRegistryImplementation = new SocketRegistry(
            slashingRegistryCoordinator
        );

        serviceManagerImplementation = new OpenRankManager(
            IAVSDirectory(avsDirectory),
            IRewardsCoordinator(rewardsCoordinator),
            slashingRegistryCoordinator,
            stakeRegistry,
            IPermissionController(address(permissionController)),
            IAllocationManager(allocationManager)
        );

        slashingRegistryCoordinatorImplementation = new SlashingRegistryCoordinator(
            stakeRegistry,
            apkRegistry,
            indexRegistry,
            socketRegistry,
            IAllocationManager(allocationManager),
            avsPauserReg,
            "1.0.0"
        );

        // upgrade and initilize
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(reexecutionEndpoint))),
            address(reexecutionEndpointImplementation),
            abi.encodeWithSelector(
                ReexecutionEndpoint.initialize.selector,
                initialOwner,
                responseFeePerOperator,
                reexecutionFeePerOperator,
                responseWindowBlocks,
                maximumRequestsPerReservationPerResponseWindow
            )
        );
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(reservationRegistry))),
            address(reservationRegistryImplementation),
            abi.encodeWithSelector(
                ReservationRegistry.initialize.selector,
                initialOwner,
                prepaidBilledEpochs,
                resourceCostPerOperatorPerEpoch,
                maxImagesPerReservation,
                maxReservations
            )
        );

        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(indexRegistry))),
            address(indexRegistryImplementation)
        );

        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(stakeRegistry))),
            address(stakeRegistryImplementation)
        );

        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(apkRegistry))),
            address(apkRegistryImplementation)
        );

        proxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(socketRegistry))),
            address(socketRegistryImplementation)
        );

        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(serviceManager))),
            address(serviceManagerImplementation),
            abi.encodeWithSelector(
                OpenRankManager.initialize.selector,
                initialOwner,
                initialOwner
            )
        );

        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(
                payable(address(slashingRegistryCoordinator))
            ),
            address(slashingRegistryCoordinatorImplementation),
            abi.encodeWithSelector(
                SlashingRegistryCoordinator.initialize.selector,
                initialOwner, // initial owner
                initialOwner, // churn approver
                initialOwner, // ejector
                0, // initial paused status
                address(serviceManager) // accountIdentifier
            )
        );

        // create slashable stake quorum/operatorSet
        // with single strategy
        serviceManager.setAppointee({
            appointee: address(initialOwner),
            target: address(allocationManager),
            selector: IAllocationManager.updateAVSMetadataURI.selector
        });
        allocationManager.updateAVSMetadataURI(
            address(serviceManager),
            "reexecution test"
        );

        serviceManager.setAppointee({
            appointee: address(slashingRegistryCoordinator),
            target: address(allocationManager),
            selector: IAllocationManager.createOperatorSets.selector
        });

        OperatorSet memory operatorSet = OperatorSet({
            avs: address(serviceManager),
            id: 0
        });
        ISlashingRegistryCoordinatorTypes.OperatorSetParam
            memory operatorSetParams = ISlashingRegistryCoordinatorTypes
                .OperatorSetParam({
                    maxOperatorCount: uint32(200),
                    kickBIPsOfOperatorStake: 11000,
                    kickBIPsOfTotalStake: 1001
                });
        IStakeRegistryTypes.StrategyParams[]
            memory strategyParams = new IStakeRegistryTypes.StrategyParams[](1);
        strategyParams[0] = IStakeRegistryTypes.StrategyParams({
            strategy: rxpStrategy,
            multiplier: 1e18
        });

        slashingRegistryCoordinator.createTotalDelegatedStakeQuorum(
            operatorSetParams,
            1e18,
            /* minimumStake */ strategyParams
        );

        // set AVS registrar
        serviceManager.setAppointee({
            appointee: address(initialOwner),
            target: address(allocationManager),
            selector: IAllocationManager.setAVSRegistrar.selector
        });
        allocationManager.setAVSRegistrar(
            address(serviceManager),
            IAVSRegistrar(address(slashingRegistryCoordinator))
        );
    }

    function _parseRxpConfig(string memory configFileName) internal {
        // READ JSON CONFIG DATA
        string memory config_data = vm.readFile(configFileName);

        //proxyAdmin
        proxyAdmin = ProxyAdmin(
            stdJson.readAddress(config_data, ".proxyAdmin")
        );
        emptyContract = EmptyContract(
            stdJson.readAddress(config_data, ".emptyContract")
        );
        initialOwner = stdJson.readAddress(config_data, ".initialOwner");
        // ReexecutionEndpoint
        responseFeePerOperator = stdJson.readUint(
            config_data,
            ".ReexecutionEndpoint.responseFeePerOperator"
        );
        reexecutionFeePerOperator = stdJson.readUint(
            config_data,
            ".ReexecutionEndpoint.reexecutionFeePerOperator"
        );
        responseWindowBlocks = stdJson.readUint(
            config_data,
            ".ReexecutionEndpoint.responseWindowBlocks"
        );
        maximumRequestsPerReservationPerResponseWindow = stdJson.readUint(
            config_data,
            ".ReexecutionEndpoint.maximumRequestsPerReservationPerResponseWindow"
        );

        // ReservationRegistry
        operatorFeeDistributor = stdJson.readAddress(
            config_data,
            ".ReservationRegistry.operatorFeeDistributor"
        );
        epochLengthBlocks = stdJson.readUint(
            config_data,
            ".ReservationRegistry.epochLengthBlocks"
        );
        epochGenesisBlock = stdJson.readUint(
            config_data,
            ".ReservationRegistry.epochGenesisBlock"
        );
        prepaidBilledEpochs = stdJson.readUint(
            config_data,
            ".ReservationRegistry.prepaidBilledEpochs"
        );
        resourceCostPerOperatorPerEpoch = stdJson.readUint(
            config_data,
            ".ReservationRegistry.resourceCostPerOperatorPerEpoch"
        );
        maxImagesPerReservation = stdJson.readUint(
            config_data,
            ".ReservationRegistry.maxImagesPerReservation"
        );
        maxReservations = stdJson.readUint(
            config_data,
            ".ReservationRegistry.maxReservations"
        );
        reservationBondAmount = stdJson.readUint(
            config_data,
            ".ReservationRegistry.reservationBondAmount"
        );
    }

    function _parseEigenLayerContracts(
        string memory eigenlayerContractsPath
    ) internal {
        // READ JSON CONFIG DATA FOR EIGENLAYER CONTRACTS
        string memory eigenlayer_config_data = vm.readFile(
            eigenlayerContractsPath
        );

        // PermissionController - read just the address, not the implementation
        permissionController = IPermissionController(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.permissionController"
            )
        );
        delegationManager = IDelegationManager(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.delegationManager"
            )
        );
        avsDirectory = IAVSDirectory(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.avsDirectory"
            )
        );
        allocationManager = IAllocationManager(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.allocationManager"
            )
        );
        rewardsCoordinator = IRewardsCoordinator(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.rewardsCoordinator"
            )
        );
        strategyManager = IStrategyManager(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.strategyManager"
            )
        );
        strategyFactory = IStrategyFactory(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.strategyFactory"
            )
        );
        eigenlayerProxyAdmin = ProxyAdmin(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.eigenLayerProxyAdmin"
            )
        );
        eigenlayerPauserReg = PauserRegistry(
            stdJson.readAddress(
                eigenlayer_config_data,
                ".addresses.eigenLayerPauserReg"
            )
        );
    }

    function _writeOutputJSON(string memory outputPath) internal {
        // Write deployment info to JSON file
        string memory parent_object = "parent object";
        string memory finalJson;

        {
            // Create addresses object
            string memory addresses = "addresses";

            // Core addresses
            vm.serializeAddress(addresses, "proxyAdmin", address(proxyAdmin));
            vm.serializeAddress(
                addresses,
                "emptyContract",
                address(emptyContract)
            );
            vm.serializeAddress(
                addresses,
                "permissionController",
                address(permissionController)
            );

            // AVS Middleware addresses
            vm.serializeAddress(
                addresses,
                "indexRegistry",
                address(indexRegistry)
            );
            vm.serializeAddress(
                addresses,
                "stakeRegistry",
                address(stakeRegistry)
            );
            vm.serializeAddress(addresses, "apkRegistry", address(apkRegistry));
            vm.serializeAddress(
                addresses,
                "socketRegistry",
                address(socketRegistry)
            );
            vm.serializeAddress(
                addresses,
                "serviceManager",
                address(serviceManager)
            );
            vm.serializeAddress(
                addresses,
                "slashingRegistryCoordinator",
                address(slashingRegistryCoordinator)
            );
            vm.serializeAddress(
                addresses,
                "avsPauserReg",
                address(avsPauserReg)
            );

            // Create operatorSet object
            string memory operator_set = "operatorSet";
            vm.serializeAddress(
                operator_set,
                "rxpStrategy",
                address(rxpStrategy)
            );
            string memory operator_set_output = vm.serializeAddress(
                operator_set,
                "underlyingToken",
                address(paymentToken)
            );

            // Add the operatorSet to the addresses
            vm.serializeString(addresses, "operatorSet", operator_set_output);

            // ReexecutionEndpoint addresses
            string memory reexecution_endpoint = "reexecution_endpoint";
            vm.serializeAddress(
                reexecution_endpoint,
                "proxy",
                address(reexecutionEndpoint)
            );
            string memory reexecution_output = vm.serializeAddress(
                reexecution_endpoint,
                "implementation",
                address(reexecutionEndpointImplementation)
            );

            // ReservationRegistry addresses
            string memory reservation_registry = "reservation_registry";
            vm.serializeAddress(
                reservation_registry,
                "proxy",
                address(reservationRegistry)
            );
            vm.serializeAddress(
                reservation_registry,
                "implementation",
                address(reservationRegistryImplementation)
            );
            vm.serializeAddress(
                reservation_registry,
                "paymentToken",
                address(paymentToken)
            );
            vm.serializeAddress(
                reservation_registry,
                "rxpStrategy",
                address(rxpStrategy)
            );
            string memory reservation_output = vm.serializeAddress(
                reservation_registry,
                "operatorFeeDistributor",
                operatorFeeDistributor
            );

            // Add nested objects to addresses
            vm.serializeString(
                addresses,
                "reexecutionEndpoint",
                reexecution_output
            );
            string memory addresses_output = vm.serializeString(
                addresses,
                "reservationRegistry",
                reservation_output
            );

            // Write parameters
            string memory parameters = "parameters";
            vm.serializeAddress(parameters, "initialOwner", initialOwner);
            vm.serializeUint(
                parameters,
                "responseFeePerOperator",
                responseFeePerOperator
            );
            vm.serializeUint(
                parameters,
                "reexecutionFeePerOperator",
                reexecutionFeePerOperator
            );
            vm.serializeUint(
                parameters,
                "responseWindowBlocks",
                responseWindowBlocks
            );
            vm.serializeUint(
                parameters,
                "maximumRequestsPerReservationPerResponseWindow",
                maximumRequestsPerReservationPerResponseWindow
            );
            vm.serializeUint(
                parameters,
                "prepaidBilledEpochs",
                prepaidBilledEpochs
            );
            vm.serializeUint(
                parameters,
                "resourceCostPerOperatorPerEpoch",
                resourceCostPerOperatorPerEpoch
            );
            vm.serializeUint(
                parameters,
                "maxImagesPerReservation",
                maxImagesPerReservation
            );
            vm.serializeUint(
                parameters,
                "epochLengthBlocks",
                epochLengthBlocks
            );
            vm.serializeUint(
                parameters,
                "epochGenesisBlock",
                epochGenesisBlock
            );
            vm.serializeUint(
                parameters,
                "reservationBondAmount",
                reservationBondAmount
            );
            string memory parameters_output = vm.serializeUint(
                parameters,
                "maxReservations",
                maxReservations
            );

            // Write chain info
            string memory chain_info = "chainInfo";
            vm.serializeUint(chain_info, "deploymentBlock", block.number);
            string memory chain_info_output = vm.serializeUint(
                chain_info,
                "chainId",
                block.chainid
            );

            // Serialize all data
            vm.serializeString(parent_object, "addresses", addresses_output);
            vm.serializeString(parent_object, "parameters", parameters_output);
            finalJson = vm.serializeString(
                parent_object,
                "chainInfo",
                chain_info_output
            );
        }

        // Write to file
        vm.writeJson(finalJson, outputPath);
    }
}
