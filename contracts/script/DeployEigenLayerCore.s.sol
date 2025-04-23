// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

import "eigenlayer-contracts/src/contracts/interfaces/IETHPOSDeposit.sol";

import "eigenlayer-contracts/src/contracts/core/AVSDirectory.sol";

import "eigenlayer-contracts/src/contracts/core/AllocationManager.sol";
import "eigenlayer-contracts/src/contracts/core/DelegationManager.sol";
import "eigenlayer-contracts/src/contracts/core/RewardsCoordinator.sol";
import "eigenlayer-contracts/src/contracts/core/StrategyManager.sol";

import "eigenlayer-contracts/src/contracts/permissions/PermissionController.sol";
import "eigenlayer-contracts/src/contracts/strategies/StrategyFactory.sol";

import "eigenlayer-contracts/src/contracts/strategies/StrategyBaseTVLLimits.sol";

import "eigenlayer-contracts/src/contracts/pods/EigenPod.sol";
import "eigenlayer-contracts/src/contracts/pods/EigenPodManager.sol";

import "eigenlayer-contracts/src/contracts/permissions/PauserRegistry.sol";

import "./common/DeployTestUtils.sol";
import "eigenlayer-contracts/src/test/mocks/ETHDepositMock.sol";
import "eigenlayer-contracts/src/test/mocks/EmptyContract.sol";

// # To load the variables in the .env file
// source .env

// # To deploy and verify our contract
contract DeployEigenLayerCore is DeployTestUtils {
    Vm cheats = Vm(VM_ADDRESS);

    // struct used to encode token info in config file
    struct StrategyConfig {
        uint256 maxDeposits;
        uint256 maxPerDeposit;
        address tokenAddress;
        string tokenSymbol;
    }

    string public deployConfigPath;
    // tokens to deploy strategies for
    StrategyConfig[] strategyConfigs;
    string config_data;

    // EigenLayer Contracts
    ProxyAdmin public eigenLayerProxyAdmin;
    PauserRegistry public eigenLayerPauserReg;
    DelegationManager public delegation;
    DelegationManager public delegationImplementation;
    StrategyManager public strategyManager;
    StrategyManager public strategyManagerImplementation;
    RewardsCoordinator public rewardsCoordinator;
    RewardsCoordinator public rewardsCoordinatorImplementation;
    AVSDirectory public avsDirectory;
    AVSDirectory public avsDirectoryImplementation;
    EigenPodManager public eigenPodManager;
    EigenPodManager public eigenPodManagerImplementation;
    UpgradeableBeacon public eigenPodBeacon;
    EigenPod public eigenPodImplementation;
    StrategyFactory public strategyFactory;
    StrategyFactory public strategyFactoryImplementation;
    UpgradeableBeacon public strategyBeacon;
    StrategyBase public baseStrategyImplementation;
    AllocationManager public allocationManagerImplementation;
    AllocationManager public allocationManager;
    PermissionController public permissionControllerImplementation;
    PermissionController public permissionController;

    EmptyContract public emptyContract;

    address executorMultisig;
    address operationsMultisig;
    address pauserMultisig;

    // the ETH2 deposit contract -- if not on mainnet, we deploy a mock as stand-in
    IETHPOSDeposit public ethPOSDeposit;

    // IMMUTABLES TO SET
    uint64 GOERLI_GENESIS_TIME = 1616508000;

    // OTHER DEPLOYMENT PARAMETERS
    uint256 STRATEGY_MANAGER_INIT_PAUSED_STATUS;
    uint256 STRATEGY_FACTORY_INIT_PAUSED_STATUS;
    uint256 DELEGATION_INIT_PAUSED_STATUS;
    uint256 EIGENPOD_MANAGER_INIT_PAUSED_STATUS;
    uint256 REWARDS_COORDINATOR_INIT_PAUSED_STATUS;

    // DelegationManager
    uint32 MIN_WITHDRAWAL_DELAY;

    // AllocationManager
    uint32 DEALLOCATION_DELAY;
    uint32 ALLOCATION_CONFIGURATION_DELAY;

    // RewardsCoordinator
    uint32 REWARDS_COORDINATOR_MAX_REWARDS_DURATION;
    uint32 REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH;
    uint32 REWARDS_COORDINATOR_MAX_FUTURE_LENGTH;
    uint32 REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP;
    address REWARDS_COORDINATOR_UPDATER;
    uint32 REWARDS_COORDINATOR_ACTIVATION_DELAY;
    uint32 REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS;
    uint32 REWARDS_COORDINATOR_GLOBAL_OPERATOR_COMMISSION_BIPS;
    uint32 REWARDS_COORDINATOR_OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP;
    uint32 REWARDS_COORDINATOR_OPERATOR_SET_MAX_RETROACTIVE_LENGTH;

    // AllocationManager
    uint256 ALLOCATION_MANAGER_INIT_PAUSED_STATUS;

    // one week in blocks -- 50400
    uint32 STRATEGY_MANAGER_INIT_WITHDRAWAL_DELAY_BLOCKS;
    uint256 DELEGATION_WITHDRAWAL_DELAY_BLOCKS;

    function run() public virtual {
        bool broadcast = false;

        _parseConfig("deploy_eigenlayer_core.config.json");

        // DEPLOY EIGENLAYER CONTRACTS FROM SCRATCH
        broadcastOrPrank({
            broadcast: broadcast,
            prankAddress: msg.sender,
            deployFunction: _deployEigenLayerContracts,
            writeOutputFunction: _writeOutputJSON
        });

        verifyDeployments("deploy_eigenlayer_core.config.json");
    }

    function _deployEigenLayerContracts() internal {
        // read and log the chainID
        uint256 chainId = block.chainid;
        // deploy proxy admin for ability to upgrade proxy contracts
        eigenLayerProxyAdmin = new ProxyAdmin();

        //deploy pauser registry
        {
            address[] memory pausers = new address[](3);
            pausers[0] = executorMultisig;
            pausers[1] = operationsMultisig;
            pausers[2] = pauserMultisig;
            eigenLayerPauserReg = new PauserRegistry(pausers, executorMultisig);
        }

        /**
         * First, deploy upgradeable proxy contracts that **will point** to the implementations. Since the implementation contracts are
         * not yet deployed, we give these proxies an empty contract as the initial implementation, to act as if they have no code.
         */
        emptyContract = new EmptyContract();
        delegation = DelegationManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        strategyManager = StrategyManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        strategyFactory = StrategyFactory(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        avsDirectory = AVSDirectory(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        eigenPodManager = EigenPodManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        rewardsCoordinator = RewardsCoordinator(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        allocationManager = AllocationManager(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        permissionController = PermissionController(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(eigenLayerProxyAdmin),
                    ""
                )
            )
        );
        // if on mainnet, use the ETH2 deposit contract address
        if (chainId == 1) {
            ethPOSDeposit = IETHPOSDeposit(
                0x00000000219ab540356cBB839Cbe05303d7705Fa
            );
            // if not on mainnet, deploy a mock
        } else {
            ethPOSDeposit = IETHPOSDeposit(
                stdJson.readAddress(config_data, ".ethPOSDepositAddress")
            );
        }
        eigenPodImplementation = new EigenPod(
            ethPOSDeposit,
            eigenPodManager,
            GOERLI_GENESIS_TIME,
            "1.0.0"
        );
        eigenPodBeacon = new UpgradeableBeacon(address(emptyContract));
        strategyBeacon = new UpgradeableBeacon(address(emptyContract));
        // Second, deploy the *implementation* contracts, using the *proxy contracts* as inputs
        delegationImplementation = new DelegationManager(
            strategyManager,
            eigenPodManager,
            allocationManager,
            eigenLayerPauserReg,
            permissionController,
            MIN_WITHDRAWAL_DELAY,
            "1.0.0"
        );
        strategyManagerImplementation = new StrategyManager(
            delegation,
            eigenLayerPauserReg,
            "1.0.0"
        );
        strategyFactoryImplementation = new StrategyFactory(
            strategyManager,
            eigenLayerPauserReg,
            "1.0.0"
        );
        baseStrategyImplementation = new StrategyBase(
            strategyManager,
            eigenLayerPauserReg,
            "v1.0.0"
        );
        avsDirectoryImplementation = new AVSDirectory(
            delegation,
            eigenLayerPauserReg,
            "1.0.0"
        );
        eigenPodManagerImplementation = new EigenPodManager(
            ethPOSDeposit,
            eigenPodBeacon,
            delegation,
            eigenLayerPauserReg,
            "1.0.0"
        );
        IRewardsCoordinatorTypes.RewardsCoordinatorConstructorParams
            memory rewardsCoordinatorConstructorParams = IRewardsCoordinatorTypes
                .RewardsCoordinatorConstructorParams({
                    delegationManager: delegation,
                    strategyManager: strategyManager,
                    allocationManager: allocationManager,
                    pauserRegistry: eigenLayerPauserReg,
                    permissionController: permissionController,
                    CALCULATION_INTERVAL_SECONDS: REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS,
                    MAX_REWARDS_DURATION: REWARDS_COORDINATOR_MAX_REWARDS_DURATION,
                    MAX_RETROACTIVE_LENGTH: REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH,
                    MAX_FUTURE_LENGTH: REWARDS_COORDINATOR_MAX_FUTURE_LENGTH,
                    GENESIS_REWARDS_TIMESTAMP: REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP,
                    version: "1.0.0"
                });
        rewardsCoordinatorImplementation = new RewardsCoordinator(
            rewardsCoordinatorConstructorParams
        );
        allocationManagerImplementation = new AllocationManager(
            delegation,
            eigenLayerPauserReg,
            permissionController,
            DEALLOCATION_DELAY,
            ALLOCATION_CONFIGURATION_DELAY,
            "1.0.0"
        );
        permissionControllerImplementation = new PermissionController("1.0.0");

        // Third, upgrade the proxy contracts to use the correct implementation contracts and initialize them.
        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(delegation))),
            address(delegationImplementation),
            abi.encodeWithSelector(
                DelegationManager.initialize.selector,
                executorMultisig,
                DELEGATION_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(strategyManager))),
            address(strategyManagerImplementation),
            abi.encodeWithSelector(
                StrategyManager.initialize.selector,
                executorMultisig,
                strategyFactory, //whitelister
                STRATEGY_MANAGER_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(avsDirectory))),
            address(avsDirectoryImplementation),
            abi.encodeWithSelector(
                AVSDirectory.initialize.selector,
                executorMultisig,
                0
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(eigenPodManager))),
            address(eigenPodManagerImplementation),
            abi.encodeWithSelector(
                EigenPodManager.initialize.selector,
                executorMultisig,
                EIGENPOD_MANAGER_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(rewardsCoordinator))),
            address(rewardsCoordinatorImplementation),
            abi.encodeWithSelector(
                RewardsCoordinator.initialize.selector,
                executorMultisig,
                REWARDS_COORDINATOR_INIT_PAUSED_STATUS,
                REWARDS_COORDINATOR_UPDATER,
                REWARDS_COORDINATOR_ACTIVATION_DELAY,
                REWARDS_COORDINATOR_GLOBAL_OPERATOR_COMMISSION_BIPS
            )
        );
        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(allocationManager))),
            address(allocationManagerImplementation),
            abi.encodeWithSelector(
                AllocationManager.initialize.selector,
                executorMultisig,
                ALLOCATION_MANAGER_INIT_PAUSED_STATUS
            )
        );
        eigenLayerProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(
                payable(address(permissionController))
            ),
            address(permissionControllerImplementation)
        );

        eigenLayerProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(strategyFactory))),
            address(strategyFactoryImplementation),
            abi.encodeWithSelector(
                StrategyFactory.initialize.selector,
                executorMultisig,
                STRATEGY_FACTORY_INIT_PAUSED_STATUS,
                strategyBeacon
            )
        );

        // Upgrade beacon implementations
        eigenPodBeacon.upgradeTo(address(eigenPodImplementation));
        strategyBeacon.upgradeTo(address(baseStrategyImplementation));
    }

    function verifyDeployments(string memory configFileName) public {
        _parseConfig(configFileName);
        _parseDeployedOutput();
        // CHECK CORRECTNESS OF DEPLOYMENT
        _verifyContractsPointAtOneAnother(
            delegationImplementation,
            strategyManagerImplementation,
            eigenPodManagerImplementation,
            rewardsCoordinatorImplementation
        );
        _verifyContractsPointAtOneAnother(
            delegation,
            strategyManager,
            eigenPodManager,
            rewardsCoordinator
        );
        _verifyImplementationsSetCorrectly();
        _verifyInitialOwners();
        _checkPauserInitializations();
        _verifyInitializationParams();
    }

    function _verifyContractsPointAtOneAnother(
        DelegationManager delegationContract,
        StrategyManager strategyManagerContract,
        EigenPodManager eigenPodManagerContract,
        RewardsCoordinator rewardsCoordinatorContract
    ) internal view {
        require(
            delegationContract.strategyManager() == strategyManager,
            "delegation: strategyManager address not set correctly"
        );
        require(
            strategyManagerContract.delegation() == delegation,
            "strategyManager: delegation address not set correctly"
        );
        require(
            eigenPodManagerContract.ethPOS() == ethPOSDeposit,
            " eigenPodManager: ethPOSDeposit contract address not set correctly"
        );
        require(
            eigenPodManagerContract.eigenPodBeacon() == eigenPodBeacon,
            "eigenPodManager: eigenPodBeacon contract address not set correctly"
        );

        require(
            rewardsCoordinatorContract.delegationManager() == delegation,
            "rewardsCoordinator: delegation address not set correctly"
        );

        require(
            rewardsCoordinatorContract.strategyManager() == strategyManager,
            "rewardsCoordinator: strategyManager address not set correctly"
        );
    }

    function _verifyImplementationsSetCorrectly() internal view {
        require(
            eigenLayerProxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(payable(address(delegation)))
            ) == address(delegationImplementation),
            "delegation: implementation set incorrectly"
        );
        require(
            eigenLayerProxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(payable(address(strategyManager)))
            ) == address(strategyManagerImplementation),
            "strategyManager: implementation set incorrectly"
        );
        require(
            eigenLayerProxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(payable(address(eigenPodManager)))
            ) == address(eigenPodManagerImplementation),
            "eigenPodManager: implementation set incorrectly"
        );
        require(
            eigenLayerProxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(
                    payable(address(rewardsCoordinator))
                )
            ) == address(rewardsCoordinatorImplementation),
            "rewardsCoordinator: implementation set incorrectly"
        );

        require(
            eigenLayerProxyAdmin.getProxyImplementation(
                ITransparentUpgradeableProxy(
                    payable(address(allocationManager))
                )
            ) == address(allocationManagerImplementation),
            "allocationManager: implementation set incorrectly"
        );

        require(
            eigenPodBeacon.implementation() == address(eigenPodImplementation),
            "eigenPodBeacon: implementation set incorrectly"
        );
    }

    function _verifyInitialOwners() internal view {
        require(
            strategyManager.owner() == executorMultisig,
            "strategyManager: owner not set correctly"
        );
        require(
            delegation.owner() == executorMultisig,
            "delegation: owner not set correctly"
        );
        require(
            eigenPodManager.owner() == executorMultisig,
            "eigenPodManager: owner not set correctly"
        );

        require(
            eigenLayerProxyAdmin.owner() == executorMultisig,
            "eigenLayerProxyAdmin: owner not set correctly"
        );
        require(
            eigenPodBeacon.owner() == executorMultisig,
            "eigenPodBeacon: owner not set correctly"
        );
    }

    function _checkPauserInitializations() internal view {
        require(
            delegation.pauserRegistry() == eigenLayerPauserReg,
            "delegation: pauser registry not set correctly"
        );
        require(
            strategyManager.pauserRegistry() == eigenLayerPauserReg,
            "strategyManager: pauser registry not set correctly"
        );
        require(
            eigenPodManager.pauserRegistry() == eigenLayerPauserReg,
            "eigenPodManager: pauser registry not set correctly"
        );
        require(
            rewardsCoordinator.pauserRegistry() == eigenLayerPauserReg,
            "rewardsCoordinator: pauser registry not set correctly"
        );

        require(
            eigenLayerPauserReg.isPauser(operationsMultisig),
            "pauserRegistry: operationsMultisig is not pauser"
        );
        require(
            eigenLayerPauserReg.isPauser(executorMultisig),
            "pauserRegistry: executorMultisig is not pauser"
        );
        require(
            eigenLayerPauserReg.isPauser(pauserMultisig),
            "pauserRegistry: pauserMultisig is not pauser"
        );
        require(
            eigenLayerPauserReg.unpauser() == executorMultisig,
            "pauserRegistry: unpauser not set correctly"
        );
    }

    function _verifyInitializationParams() internal {
        require(
            baseStrategyImplementation.strategyManager() == strategyManager,
            "baseStrategyImplementation: strategyManager set incorrectly"
        );

        require(
            eigenPodImplementation.ethPOS() == ethPOSDeposit,
            "eigenPodImplementation: ethPOSDeposit contract address not set correctly"
        );
        require(
            eigenPodImplementation.eigenPodManager() == eigenPodManager,
            " eigenPodImplementation: eigenPodManager contract address not set correctly"
        );
    }

    function _parseConfig(string memory configFileName) internal {
        // READ JSON CONFIG DATA
        deployConfigPath = string(
            bytes(string.concat("contracts/script/config/", configFileName))
        );
        config_data = vm.readFile(deployConfigPath);
        // bytes memory parsedData = vm.parseJson(config_data);

        MIN_WITHDRAWAL_DELAY = uint32(
            stdJson.readUint(config_data, ".delegation.withdrawal_delay_blocks")
        );
        STRATEGY_MANAGER_INIT_PAUSED_STATUS = stdJson.readUint(
            config_data,
            ".strategyManager.init_paused_status"
        );
        STRATEGY_FACTORY_INIT_PAUSED_STATUS = stdJson.readUint(
            config_data,
            ".strategyFactory.init_paused_status"
        );
        DELEGATION_INIT_PAUSED_STATUS = stdJson.readUint(
            config_data,
            ".delegation.init_paused_status"
        );
        DELEGATION_WITHDRAWAL_DELAY_BLOCKS = stdJson.readUint(
            config_data,
            ".delegation.init_withdrawal_delay_blocks"
        );
        EIGENPOD_MANAGER_INIT_PAUSED_STATUS = stdJson.readUint(
            config_data,
            ".eigenPodManager.init_paused_status"
        );
        REWARDS_COORDINATOR_INIT_PAUSED_STATUS = stdJson.readUint(
            config_data,
            ".rewardsCoordinator.init_paused_status"
        );
        REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.CALCULATION_INTERVAL_SECONDS"
            )
        );
        REWARDS_COORDINATOR_MAX_REWARDS_DURATION = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.MAX_REWARDS_DURATION"
            )
        );
        REWARDS_COORDINATOR_MAX_RETROACTIVE_LENGTH = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.MAX_RETROACTIVE_LENGTH"
            )
        );
        REWARDS_COORDINATOR_MAX_FUTURE_LENGTH = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.MAX_FUTURE_LENGTH"
            )
        );
        REWARDS_COORDINATOR_GENESIS_REWARDS_TIMESTAMP = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.GENESIS_REWARDS_TIMESTAMP"
            )
        );
        REWARDS_COORDINATOR_UPDATER = stdJson.readAddress(
            config_data,
            ".rewardsCoordinator.rewards_updater_address"
        );
        REWARDS_COORDINATOR_ACTIVATION_DELAY = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.activation_delay"
            )
        );
        REWARDS_COORDINATOR_CALCULATION_INTERVAL_SECONDS = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.calculation_interval_seconds"
            )
        );
        REWARDS_COORDINATOR_GLOBAL_OPERATOR_COMMISSION_BIPS = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.global_operator_commission_bips"
            )
        );
        REWARDS_COORDINATOR_OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.OPERATOR_SET_GENESIS_REWARDS_TIMESTAMP"
            )
        );
        REWARDS_COORDINATOR_OPERATOR_SET_MAX_RETROACTIVE_LENGTH = uint32(
            stdJson.readUint(
                config_data,
                ".rewardsCoordinator.OPERATOR_SET_MAX_RETROACTIVE_LENGTH"
            )
        );

        STRATEGY_MANAGER_INIT_WITHDRAWAL_DELAY_BLOCKS = uint32(
            stdJson.readUint(
                config_data,
                ".strategyManager.init_withdrawal_delay_blocks"
            )
        );

        ALLOCATION_MANAGER_INIT_PAUSED_STATUS = uint32(
            stdJson.readUint(
                config_data,
                ".allocationManager.init_paused_status"
            )
        );
        DEALLOCATION_DELAY = uint32(
            stdJson.readUint(
                config_data,
                ".allocationManager.DEALLOCATION_DELAY"
            )
        );
        ALLOCATION_CONFIGURATION_DELAY = uint32(
            stdJson.readUint(
                config_data,
                ".allocationManager.ALLOCATION_CONFIGURATION_DELAY"
            )
        );

        // read and log the chainID
        uint256 chainId = block.chainid;
        // if on mainnet, use the ETH2 deposit contract address
        if (chainId == 1) {
            ethPOSDeposit = IETHPOSDeposit(
                0x00000000219ab540356cBB839Cbe05303d7705Fa
            );
            // if not on mainnet, deploy a mock
        } else {
            ethPOSDeposit = IETHPOSDeposit(
                stdJson.readAddress(config_data, ".ethPOSDepositAddress")
            );
        }

        executorMultisig = stdJson.readAddress(
            config_data,
            ".multisig_addresses.executorMultisig"
        );
        operationsMultisig = stdJson.readAddress(
            config_data,
            ".multisig_addresses.operationsMultisig"
        );
        pauserMultisig = stdJson.readAddress(
            config_data,
            ".multisig_addresses.pauserMultisig"
        );
        // load token list
        bytes memory strategyConfigsRaw = stdJson.parseRaw(
            config_data,
            ".strategies"
        );
        StrategyConfig[] memory stratConfigs = abi.decode(
            strategyConfigsRaw,
            (StrategyConfig[])
        );
        for (uint256 i = 0; i < stratConfigs.length; i++) {
            strategyConfigs.push(stratConfigs[i]);
        }

        require(
            executorMultisig != address(0),
            "executorMultisig address not configured correctly!"
        );
        require(
            operationsMultisig != address(0),
            "operationsMultisig address not configured correctly!"
        );
    }

    function _parseDeployedOutput() internal {
        string
            memory outputPath = "contracts/script/output/deploy_eigenlayer_core_output.json";
        string memory json = vm.readFile(outputPath);

        // Read addresses
        eigenLayerProxyAdmin = ProxyAdmin(
            stdJson.readAddress(json, ".addresses.eigenLayerProxyAdmin")
        );
        eigenLayerPauserReg = PauserRegistry(
            stdJson.readAddress(json, ".addresses.eigenLayerPauserReg")
        );
        delegation = DelegationManager(
            stdJson.readAddress(json, ".addresses.delegationManager")
        );
        delegationImplementation = DelegationManager(
            stdJson.readAddress(
                json,
                ".addresses.delegationManagerImplementation"
            )
        );
        strategyManager = StrategyManager(
            stdJson.readAddress(json, ".addresses.strategyManager")
        );
        strategyManagerImplementation = StrategyManager(
            stdJson.readAddress(
                json,
                ".addresses.strategyManagerImplementation"
            )
        );
        eigenPodManager = EigenPodManager(
            stdJson.readAddress(json, ".addresses.eigenPodManager")
        );
        eigenPodManagerImplementation = EigenPodManager(
            stdJson.readAddress(
                json,
                ".addresses.eigenPodManagerImplementation"
            )
        );
        rewardsCoordinator = RewardsCoordinator(
            stdJson.readAddress(json, ".addresses.rewardsCoordinator")
        );
        rewardsCoordinatorImplementation = RewardsCoordinator(
            stdJson.readAddress(
                json,
                ".addresses.rewardsCoordinatorImplementation"
            )
        );
        avsDirectory = AVSDirectory(
            stdJson.readAddress(json, ".addresses.avsDirectory")
        );
        avsDirectoryImplementation = AVSDirectory(
            stdJson.readAddress(json, ".addresses.avsDirectoryImplementation")
        );
        allocationManager = AllocationManager(
            stdJson.readAddress(json, ".addresses.allocationManager")
        );
        allocationManagerImplementation = AllocationManager(
            stdJson.readAddress(
                json,
                ".addresses.allocationManagerImplementation"
            )
        );
        permissionController = PermissionController(
            stdJson.readAddress(json, ".addresses.permissionController")
        );
        permissionControllerImplementation = PermissionController(
            stdJson.readAddress(
                json,
                ".addresses.permissionControllerImplementation"
            )
        );
        eigenPodBeacon = UpgradeableBeacon(
            stdJson.readAddress(json, ".addresses.eigenPodBeacon")
        );
        eigenPodImplementation = EigenPod(
            payable(
                stdJson.readAddress(json, ".addresses.eigenPodImplementation")
            )
        );
        baseStrategyImplementation = StrategyBase(
            payable(
                stdJson.readAddress(
                    json,
                    ".addresses.baseStrategyImplementation"
                )
            )
        );
        emptyContract = EmptyContract(
            payable(stdJson.readAddress(json, ".addresses.emptyContract"))
        );

        // Read parameters
        executorMultisig = stdJson.readAddress(
            json,
            ".parameters.executorMultisig"
        );
        operationsMultisig = stdJson.readAddress(
            json,
            ".parameters.operationsMultisig"
        );
        pauserMultisig = stdJson.readAddress(
            json,
            ".parameters.pauserMultisig"
        );
    }

    function _writeOutputJSON() internal {
        uint256 chainId = block.chainid;
        // WRITE JSON DATA
        string memory parent_object = "parent object";

        string memory deployed_addresses = "addresses";
        vm.serializeUint(deployed_addresses, "numStrategiesDeployed", 0); // for compatibility with other scripts
        vm.serializeAddress(
            deployed_addresses,
            "eigenLayerProxyAdmin",
            address(eigenLayerProxyAdmin)
        );
        vm.serializeAddress(
            deployed_addresses,
            "eigenLayerPauserReg",
            address(eigenLayerPauserReg)
        );
        vm.serializeAddress(
            deployed_addresses,
            "delegationManager",
            address(delegation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "delegationManagerImplementation",
            address(delegationImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "avsDirectory",
            address(avsDirectory)
        );
        vm.serializeAddress(
            deployed_addresses,
            "avsDirectoryImplementation",
            address(avsDirectoryImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "allocationManager",
            address(allocationManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "allocationManagerImplementation",
            address(allocationManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "permissionController",
            address(permissionController)
        );
        vm.serializeAddress(
            deployed_addresses,
            "permissionControllerImplementation",
            address(permissionControllerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "strategyManager",
            address(strategyManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "strategyManagerImplementation",
            address(strategyManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "strategyFactory",
            address(strategyFactory)
        );
        vm.serializeAddress(
            deployed_addresses,
            "strategyFactoryImplementation",
            address(strategyFactoryImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "strategyBeacon",
            address(strategyBeacon)
        );
        vm.serializeAddress(
            deployed_addresses,
            "strategyBeaconImplementation",
            address(baseStrategyImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "eigenPodManager",
            address(eigenPodManager)
        );
        vm.serializeAddress(
            deployed_addresses,
            "eigenPodManagerImplementation",
            address(eigenPodManagerImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "rewardsCoordinator",
            address(rewardsCoordinator)
        );
        vm.serializeAddress(
            deployed_addresses,
            "rewardsCoordinatorImplementation",
            address(rewardsCoordinatorImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "eigenPodBeacon",
            address(eigenPodBeacon)
        );
        vm.serializeAddress(
            deployed_addresses,
            "eigenPodImplementation",
            address(eigenPodImplementation)
        );
        vm.serializeAddress(
            deployed_addresses,
            "baseStrategyImplementation",
            address(baseStrategyImplementation)
        );
        string memory addresses_output = vm.serializeAddress(
            deployed_addresses,
            "emptyContract",
            address(emptyContract)
        );

        string memory parameters = "parameters";
        vm.serializeAddress(parameters, "executorMultisig", executorMultisig);
        vm.serializeAddress(
            parameters,
            "communityMultisig",
            operationsMultisig
        );
        vm.serializeAddress(parameters, "pauserMultisig", pauserMultisig);
        vm.serializeAddress(parameters, "timelock", address(0));
        string memory parameters_output = vm.serializeAddress(
            parameters,
            "operationsMultisig",
            operationsMultisig
        );

        string memory chain_info = "chainInfo";
        vm.serializeUint(chain_info, "deploymentBlock", block.number);
        string memory chain_info_output = vm.serializeUint(
            chain_info,
            "chainId",
            chainId
        );

        // serialize all the data
        vm.serializeString(parent_object, "addresses", addresses_output);
        vm.serializeString(parent_object, "parameters", parameters_output);
        string memory finalJson = vm.serializeString(
            parent_object,
            "chainInfo",
            chain_info_output
        );

        vm.writeJson(
            finalJson,
            "contracts/script/output/deploy_eigenlayer_core_output.json"
        );
    }
}
