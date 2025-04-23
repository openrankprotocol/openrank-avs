// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import "forge-std/StdJson.sol";
import "forge-std/Test.sol";

import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";

import {IERC20, IReexecutionEndpoint} from "../../src/interfaces/IReexecutionEndpoint.sol";
import {IReservationRegistry} from "../../src/interfaces/IReservationRegistry.sol";

import {BLSApkRegistry, DeployAVS, EmptyContract, IAVSDirectory, IAVSRegistrar, IAllocationManager, IDelegationManager, IIndexRegistry, IPermissionController, IRewardsCoordinator, ISlashingRegistryCoordinatorTypes, ISocketRegistry, IStakeRegistry, IStakeRegistryTypes, ITransparentUpgradeableProxy, IndexRegistry, OperatorStateRetriever, PauserRegistry, ProxyAdmin, ServiceManagerBase, SlashingRegistryCoordinator, SocketRegistry, StakeRegistry, TransparentUpgradeableProxy} from "./deploy_middleware.sol";

import {CertificateVerifier} from "../../src/CertificateVerifier.sol";
import {ReexecutionSlasher} from "../../src/ReexecutionSlasher.sol";
import {DeployTestUtils} from "./DeployTestUtils.sol";

abstract contract BaseDeploySimpleAVS is DeployAVS, DeployTestUtils {
    IReservationRegistry reservationRegistry;
    IReexecutionEndpoint reexecutionEndpoint;

    ReexecutionSlasher public reexecutionSlasher;
    ReexecutionSlasher public reexecutionSlasherImplementation;
    CertificateVerifier public rxCertificateVerifier;
    CertificateVerifier public rxCertificateVerifierImplementation;

    IStrategy public rxpStrategy;

    // EigenLayer contracts
    IAllocationManager allocationManager;
    IDelegationManager delegationManager;
    IPermissionController permissionController;
    IRewardsCoordinator rewardsCoordinator;
    IAVSDirectory avsDirectory;

    string eigenlayerConfigPath;
    string rxConfigPath;

    // Strategies for AVS
    IStrategy[] avsStrategies;

    function run(bool broadcast) public virtual {
        eigenlayerConfigPath = "contracts/script/output/deploy_eigenlayer_core_output.json";
        rxConfigPath = "contracts/script/output/deploy_rxp_contracts_output.json";

        // parse eigenlayer contracts
        parseConfig(eigenlayerConfigPath);
        // parse RxP contracts config
        parseRxConfig();
        // if broadcasting, write output json. Otherwise prank as msg.sender
        broadcastOrPrank({
            broadcast: broadcast,
            prankAddress: msg.sender,
            deployFunction: _deploySimpleAVS,
            writeOutputFunction: _writeOutputJSON
        });
    }

    function _deploySimpleAVS() internal {
        avsStrategies = chooseStrategiesForAVS();

        uint256 maxOperatorCount = 100;

        super.run(eigenlayerConfigPath, maxOperatorCount, avsStrategies);

        // set the msg.sender i.e address 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 to also be UAM admin
        serviceManager.addPendingAdmin(msg.sender);

        reexecutionSlasher = ReexecutionSlasher(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        rxCertificateVerifier = CertificateVerifier(
            address(
                new TransparentUpgradeableProxy(
                    address(emptyContract),
                    address(avsProxyAdmin),
                    ""
                )
            )
        );

        // Deploy CertificateVerifier
        rxCertificateVerifierImplementation = new CertificateVerifier(
            slashingRegistryCoordinator,
            reservationRegistry
        );

        // Deploy ReexecutionSlasher
        reexecutionSlasherImplementation = new ReexecutionSlasher(
            allocationManager,
            slashingRegistryCoordinator,
            reservationRegistry,
            reexecutionEndpoint,
            rxCertificateVerifier
        );

        avsProxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(reexecutionSlasher)),
            address(reexecutionSlasherImplementation),
            abi.encodeWithSelector(
                ReexecutionSlasher.initialize.selector,
                0 /* operatorSetId */
            )
        );

        avsProxyAdmin.upgrade(
            ITransparentUpgradeableProxy(address(rxCertificateVerifier)),
            address(rxCertificateVerifierImplementation)
        );

        // Set allowance for RxSlasher by admin address for payment token
        IERC20 paymentToken = reexecutionEndpoint.paymentToken();
        paymentToken.approve(address(reexecutionSlasher), type(uint256).max);
        paymentToken.approve(address(reexecutionEndpoint), type(uint256).max);
        paymentToken.approve(address(reservationRegistry), type(uint256).max);

        // Set UAM appointees
        // 1. set Rx Slasher as appointee for calling RxP's ReexecutionEndpoint.requestReexecution
        serviceManager.setAppointee(
            address(reexecutionSlasher),
            address(reexecutionEndpoint),
            reexecutionEndpoint.requestReexecution.selector
        );

        // 2. set Rx Slasher as appointee for calling AllocationManager.slashOperator
        serviceManager.setAppointee(
            address(reexecutionSlasher),
            address(allocationManager),
            allocationManager.slashOperator.selector
        );

        // 3. set owner as appointee for calling RxP's ReservationRegistry interfaces
        serviceManager.setAppointee(
            msg.sender,
            address(reservationRegistry),
            reservationRegistry.reserve.selector
        );

        // 4. set owner as appointee for calling RxP's ReservationRegistry.addImage
        serviceManager.setAppointee(
            msg.sender,
            address(reservationRegistry),
            reservationRegistry.addImage.selector
        );

        // 5. set owner as appointee for calling RxP's ReservationRegistry.removeImage
        serviceManager.setAppointee(
            msg.sender,
            address(reservationRegistry),
            reservationRegistry.removeImage.selector
        );

        // 6. set owner as appointee for calling RxP's ReservationRegistry.addFunds
        serviceManager.setAppointee(
            msg.sender,
            address(reservationRegistry),
            reservationRegistry.addFunds.selector
        );

        // 7. set owner as appointee for calling RxP's ReservationRegistry.deductFees
        serviceManager.setAppointee(
            msg.sender,
            address(reservationRegistry),
            reservationRegistry.deductFees.selector
        );
    }

    function parseConfig(
        string memory eigenlayerConfigPath
    )
        public
        virtual
        override
        returns (EigenlayerDeployment memory eigenlayerDeployment)
    {
        // read the json file
        string memory inputConfig = vm.readFile(eigenlayerConfigPath);

        eigenlayerDeployment = EigenlayerDeployment({
            allocationManager: stdJson.readAddress(
                inputConfig,
                ".addresses.allocationManager"
            ),
            delegationManager: stdJson.readAddress(
                inputConfig,
                ".addresses.delegationManager"
            ),
            permissionController: stdJson.readAddress(
                inputConfig,
                ".addresses.permissionController"
            ),
            rewardsCoordinator: stdJson.readAddress(
                inputConfig,
                ".addresses.rewardsCoordinator"
            ),
            avsDirectory: stdJson.readAddress(
                inputConfig,
                ".addresses.avsDirectory"
            )
        });

        allocationManager = IAllocationManager(
            eigenlayerDeployment.allocationManager
        );
        delegationManager = IDelegationManager(
            eigenlayerDeployment.delegationManager
        );
        permissionController = IPermissionController(
            eigenlayerDeployment.permissionController
        );
        rewardsCoordinator = IRewardsCoordinator(
            eigenlayerDeployment.rewardsCoordinator
        );
        avsDirectory = IAVSDirectory(eigenlayerDeployment.avsDirectory);
    }

    function parseRxConfig() public virtual {
        string
            memory inputConfigPath = "contracts/script/output/deploy_rxp_contracts_output.json";
        string memory inputConfig = vm.readFile(inputConfigPath);

        reservationRegistry = IReservationRegistry(
            stdJson.readAddress(
                inputConfig,
                ".addresses.reservationRegistry.proxy"
            )
        );
        reexecutionEndpoint = IReexecutionEndpoint(
            stdJson.readAddress(
                inputConfig,
                ".addresses.reexecutionEndpoint.proxy"
            )
        );
        rxpStrategy = IStrategy(
            stdJson.readAddress(
                inputConfig,
                ".addresses.reservationRegistry.rxpStrategy"
            )
        );
    }

    /**
     * @notice Selects the strategies to be used for the AVS.
     * @return The strategies to be used for the AVS.
     * @dev This function can be overridden by child contracts to implement custom strategy selection logic.
     */
    function chooseStrategiesForAVS()
        public
        view
        virtual
        returns (IStrategy[] memory);

    function _writeOutputJSON() internal virtual {
        uint256 deploymentBlock = block.number;
        string memory output = "deployment";
        vm.serializeAddress(output, "serviceManager", address(serviceManager));
        vm.serializeAddress(
            output,
            "certificateVerifier",
            address(rxCertificateVerifier)
        );
        vm.serializeAddress(
            output,
            "slashingRegistryCoordinator",
            address(slashingRegistryCoordinator)
        );
        vm.serializeAddress(output, "indexRegistry", address(indexRegistry));
        vm.serializeAddress(output, "stakeRegistry", address(stakeRegistry));
        vm.serializeAddress(output, "apkRegistry", address(apkRegistry));
        vm.serializeAddress(output, "socketRegistry", address(socketRegistry));
        vm.serializeAddress(
            output,
            "operatorStateRetriever",
            address(operatorStateRetriever)
        );
        vm.serializeAddress(output, "avsProxyAdmin", address(avsProxyAdmin));
        vm.serializeAddress(output, "avsPauserReg", address(avsPauserReg));
        address[] memory strategyAddresses = new address[](
            avsStrategies.length
        );
        for (uint256 i = 0; i < avsStrategies.length; i++) {
            strategyAddresses[i] = address(avsStrategies[i]);
        }
        vm.serializeAddress(output, "strategies", strategyAddresses);
        vm.serializeUint(output, "deploymentBlock", deploymentBlock);
        vm.serializeAddress(
            output,
            "reexecutionSlasher",
            address(reexecutionSlasher)
        );
        vm.serializeAddress(
            output,
            "certificateVerifier",
            address(rxCertificateVerifier)
        );
        string memory finalJson = vm.serializeString(output, "object", output);

        string memory outputDir = "contracts/script/output";
        string memory outputPath = string.concat(
            outputDir,
            "/deploy_simple_avs_output.json"
        );
        vm.createDir(outputDir, true);
        vm.writeJson(finalJson, outputPath);
    }
}
