// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IAVSDirectory} from "eigenlayer-contracts/src/contracts/interfaces/IAVSDirectory.sol";

import {IAVSRegistrar} from "eigenlayer-contracts/src/contracts/interfaces/IAVSRegistrar.sol";
import {IAllocationManager} from "eigenlayer-contracts/src/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "eigenlayer-contracts/src/contracts/interfaces/IDelegationManager.sol";

import {IPermissionController} from "eigenlayer-contracts/src/contracts/interfaces/IPermissionController.sol";
import {IRewardsCoordinator} from "eigenlayer-contracts/src/contracts/interfaces/IRewardsCoordinator.sol";
import {PauserRegistry} from "eigenlayer-contracts/src/contracts/permissions/PauserRegistry.sol";
import {EmptyContract} from "eigenlayer-contracts/src/test/mocks/EmptyContract.sol";

import {OpenRankManager} from "../../src/avs/OpenRankManager.sol";
import {IPauserRegistry} from "eigenlayer-contracts/src/contracts/interfaces/IPauserRegistry.sol";
import {BLSApkRegistry} from "eigenlayer-middleware/src/BLSApkRegistry.sol";
import {IndexRegistry} from "eigenlayer-middleware/src/IndexRegistry.sol";
import {OperatorStateRetriever} from "eigenlayer-middleware/src/OperatorStateRetriever.sol";

import {ServiceManagerBase} from "eigenlayer-middleware/src/ServiceManagerBase.sol";
import {SlashingRegistryCoordinator} from "eigenlayer-middleware/src/SlashingRegistryCoordinator.sol";
import {ISocketRegistry, SocketRegistry} from "eigenlayer-middleware/src/SocketRegistry.sol";
import {IStrategy, StakeRegistry} from "eigenlayer-middleware/src/StakeRegistry.sol";
import {IBLSApkRegistry} from "eigenlayer-middleware/src/interfaces/IBLSApkRegistry.sol";
import {IIndexRegistry} from "eigenlayer-middleware/src/interfaces/IIndexRegistry.sol";
import {IRegistryCoordinator} from "eigenlayer-middleware/src/interfaces/IRegistryCoordinator.sol";

import {IServiceManager} from "eigenlayer-middleware/src/interfaces/IServiceManager.sol";

import {ISlashingRegistryCoordinator, ISlashingRegistryCoordinatorTypes} from "eigenlayer-middleware/src/interfaces/ISlashingRegistryCoordinator.sol";
import {IStakeRegistry, IStakeRegistryTypes} from "eigenlayer-middleware/src/interfaces/IStakeRegistry.sol";

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/Test.sol";

contract DeployAVS is Script, Test {
    // Core contracts
    ProxyAdmin public avsProxyAdmin;
    PauserRegistry public avsPauserReg;
    EmptyContract public emptyContract;

    // Middleware contracts
    BLSApkRegistry public apkRegistry;
    IServiceManager public serviceManager;
    SlashingRegistryCoordinator public slashingRegistryCoordinator;
    IIndexRegistry public indexRegistry;
    IStakeRegistry public stakeRegistry;
    ISocketRegistry public socketRegistry;
    OperatorStateRetriever public operatorStateRetriever;

    // Implementation contracts
    BLSApkRegistry public apkRegistryImplementation;
    IServiceManager public serviceManagerImplementation;
    ISlashingRegistryCoordinator
        public slashingRegistryCoordinatorImplementation;
    IIndexRegistry public indexRegistryImplementation;
    IStakeRegistry public stakeRegistryImplementation;
    ISocketRegistry public socketRegistryImplementation;

    struct EigenlayerDeployment {
        address allocationManager;
        address delegationManager;
        address permissionController;
        address rewardsCoordinator;
        address avsDirectory;
    }

    function run(
        string memory inputConfigPath,
        uint256 maxOperatorCount,
        IStrategy[] memory strategies
    ) public virtual {
        EigenlayerDeployment memory eigenlayerDeployment = parseConfig(
            inputConfigPath
        );

        // only a lower bound for the deployment block number
        uint256 deploymentBlock = block.number;
        // deploy proxy admin for ability to upgrade proxy contracts
        avsProxyAdmin = new ProxyAdmin();

        // deploy pauser registry
        {
            address[] memory pausers = new address[](1);
            pausers[0] = msg.sender;
            avsPauserReg = new PauserRegistry(pausers, msg.sender);
        }

        emptyContract = new EmptyContract();

        // Deploy upgradeable proxy contracts pointing to empty contract initially
        serviceManager = ServiceManagerBase(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        slashingRegistryCoordinator = SlashingRegistryCoordinator(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        indexRegistry = IIndexRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        stakeRegistry = IStakeRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        apkRegistry = BLSApkRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        socketRegistry = ISocketRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        // Deploy implementations and upgrade proxies

        serviceManagerImplementation = new OpenRankManager(
            IAVSDirectory(eigenlayerDeployment.avsDirectory),
            IRewardsCoordinator(eigenlayerDeployment.rewardsCoordinator),
            ISlashingRegistryCoordinator(address(slashingRegistryCoordinator)),
            IStakeRegistry(address(stakeRegistry)),
            IPermissionController(eigenlayerDeployment.permissionController),
            IAllocationManager(eigenlayerDeployment.allocationManager)
        );

        avsProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(payable(address(serviceManager))),
            address(serviceManagerImplementation),
            abi.encodeWithSelector(
                OpenRankManager.initialize.selector,
                msg.sender,
                msg.sender
            )
        );

        indexRegistryImplementation = new IndexRegistry(
            slashingRegistryCoordinator
        );

        avsProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(indexRegistry))),
            address(indexRegistryImplementation)
        );

        stakeRegistryImplementation = new StakeRegistry(
            slashingRegistryCoordinator,
            IDelegationManager(eigenlayerDeployment.delegationManager),
            IAVSDirectory(eigenlayerDeployment.avsDirectory),
            IAllocationManager(eigenlayerDeployment.allocationManager)
        );

        avsProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(stakeRegistry))),
            address(stakeRegistryImplementation)
        );

        apkRegistryImplementation = new BLSApkRegistry(
            slashingRegistryCoordinator
        );

        avsProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(apkRegistry))),
            address(apkRegistryImplementation)
        );

        socketRegistryImplementation = new SocketRegistry(
            slashingRegistryCoordinator
        );

        avsProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(payable(address(socketRegistry))),
            address(socketRegistryImplementation)
        );

        slashingRegistryCoordinatorImplementation = new SlashingRegistryCoordinator(
            stakeRegistry,
            apkRegistry,
            indexRegistry,
            socketRegistry,
            IAllocationManager(eigenlayerDeployment.allocationManager),
            avsPauserReg,
            "1.0.0"
        );

        {
            ISlashingRegistryCoordinatorTypes.OperatorSetParam[]
                memory operatorSetParams = new ISlashingRegistryCoordinatorTypes.OperatorSetParam[](
                    strategies.length
                );
            for (uint256 i = 0; i < strategies.length; i++) {
                operatorSetParams[i] = ISlashingRegistryCoordinatorTypes
                    .OperatorSetParam({
                        maxOperatorCount: uint32(maxOperatorCount),
                        kickBIPsOfOperatorStake: 11000,
                        kickBIPsOfTotalStake: 1001
                    });
            }

            uint96[] memory minimumStakeForQuourm = new uint96[](
                strategies.length
            );
            for (uint256 i = 0; i < strategies.length; i++) {
                minimumStakeForQuourm[i] = 1;
            }
            IStakeRegistryTypes.StrategyParams[][]
                memory strategyAndWeightingMultipliers = new IStakeRegistryTypes.StrategyParams[][](
                    strategies.length
                );
            for (uint256 i = 0; i < strategies.length; i++) {
                strategyAndWeightingMultipliers[
                    i
                ] = new IStakeRegistryTypes.StrategyParams[](1);
                strategyAndWeightingMultipliers[i][0] = IStakeRegistryTypes
                    .StrategyParams({
                        strategy: strategies[i],
                        multiplier: 1 ether
                    });
            }

            avsProxyAdmin.upgradeAndCall(
                ITransparentUpgradeableProxy(
                    payable(address(slashingRegistryCoordinator))
                ),
                address(slashingRegistryCoordinatorImplementation),
                abi.encodeWithSelector(
                    SlashingRegistryCoordinator.initialize.selector,
                    msg.sender, // initial owner
                    msg.sender, // churn approver
                    msg.sender, // ejector
                    0, // initial paused status
                    address(serviceManager) // accountIdentifier
                )
            );

            // set AVS Registrar on AllocationManager to SlashingRegistryCoordinator
            serviceManager.setAppointee(
                msg.sender,
                eigenlayerDeployment.allocationManager,
                IAllocationManager(eigenlayerDeployment.allocationManager)
                    .setAVSRegistrar
                    .selector
            );

            IAllocationManager(eigenlayerDeployment.allocationManager)
                .setAVSRegistrar(
                    address(serviceManager),
                    IAVSRegistrar(slashingRegistryCoordinator)
                );

            serviceManager.setAppointee(
                msg.sender,
                eigenlayerDeployment.allocationManager,
                IAllocationManager(eigenlayerDeployment.allocationManager)
                    .updateAVSMetadataURI
                    .selector
            );

            IAllocationManager(eigenlayerDeployment.allocationManager)
                .updateAVSMetadataURI(address(serviceManager), "TEST AVS");

            // give slashingregistrycoordindator permission to createTotalDelegatedStakeQuorum
            serviceManager.setAppointee(
                address(slashingRegistryCoordinator),
                eigenlayerDeployment.allocationManager,
                IAllocationManager(eigenlayerDeployment.allocationManager)
                    .createOperatorSets
                    .selector
            );

            for (uint256 i = 0; i < strategies.length; i++) {
                slashingRegistryCoordinator.createSlashableStakeQuorum(
                    operatorSetParams[i],
                    minimumStakeForQuourm[i],
                    strategyAndWeightingMultipliers[i],
                    1
                );
            }
        }

        operatorStateRetriever = new OperatorStateRetriever();
    }

    function parseConfig(
        string memory inputConfigPath
    )
        public
        virtual
        returns (EigenlayerDeployment memory eigenlayerDeployment)
    {
        // read the json file
        string memory inputConfig = vm.readFile(inputConfigPath);
        eigenlayerDeployment = EigenlayerDeployment({
            allocationManager: stdJson.readAddress(
                inputConfig,
                ".allocationManager"
            ),
            delegationManager: stdJson.readAddress(
                inputConfig,
                ".delegationManager"
            ),
            permissionController: stdJson.readAddress(
                inputConfig,
                ".permissionController"
            ),
            rewardsCoordinator: stdJson.readAddress(
                inputConfig,
                ".rewardsCoordinator"
            ),
            avsDirectory: stdJson.readAddress(inputConfig, ".avsDirectory")
        });

        emit log_named_address(
            "allocation manager",
            eigenlayerDeployment.allocationManager
        );
        emit log_named_address(
            "delegation manager",
            eigenlayerDeployment.delegationManager
        );
        emit log_named_address(
            "permission controller",
            eigenlayerDeployment.permissionController
        );
        emit log_named_address(
            "rewards coordinator",
            eigenlayerDeployment.rewardsCoordinator
        );
        emit log_named_address(
            "avs directory",
            eigenlayerDeployment.avsDirectory
        );
    }
}
