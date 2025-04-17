// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {OpenRankServiceManager} from "../src/OpenRankServiceManager.sol";
import {IOpenRankServiceManager} from "../src/IOpenRankServiceManager.sol";
import {MockAVSDeployer} from "@eigenlayer-middleware/test/utils/MockAVSDeployer.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/Test.sol";
import {OpenRankDeploymentLib} from "../script/utils/OpenRankDeploymentLib.sol";
import {CoreDeployLib, CoreDeploymentParsingLib} from "../script/utils/CoreDeploymentLib.sol";
import {UpgradeableProxyLib} from "../script/utils/UpgradeableProxyLib.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {IERC20, StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";

import {IECDSAStakeRegistryTypes, IStrategy} from "@eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
import {IStrategyManager} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {IDelegationManager, IDelegationManagerTypes} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {DelegationManager} from "@eigenlayer/contracts/core/DelegationManager.sol";
import {StrategyManager} from "@eigenlayer/contracts/core/StrategyManager.sol";
import {ISignatureUtilsMixin, ISignatureUtilsMixinTypes} from "@eigenlayer/contracts/interfaces/ISignatureUtilsMixin.sol";
import {AVSDirectory} from "@eigenlayer/contracts/core/AVSDirectory.sol";
import {IAVSDirectory, IAVSDirectoryTypes} from "@eigenlayer/contracts/interfaces/IAVSDirectory.sol";
import {Test, console2 as console} from "forge-std/Test.sol";
import {ECDSAUpgradeable} from "@openzeppelin-upgrades/contracts/utils/cryptography/ECDSAUpgradeable.sol";

contract OpenRankTaskManagerSetup is Test {
    // used for `toEthSignedMessageHash`
    using ECDSAUpgradeable for bytes32;

    IECDSAStakeRegistryTypes.Quorum internal quorum;

    struct Operator {
        Vm.Wallet key;
        Vm.Wallet signingKey;
    }

    struct TrafficGenerator {
        Vm.Wallet key;
    }

    struct AVSOwner {
        Vm.Wallet key;
    }

    Operator[] internal operators;
    TrafficGenerator internal generator;
    AVSOwner internal owner;

    OpenRankDeploymentLib.DeploymentData internal openRankDeployment;
    CoreDeployLib.DeploymentData internal coreDeployment;
    CoreDeployLib.DeploymentConfigData coreConfigData;

    address proxyAdmin;

    ERC20Mock public mockToken;

    mapping(address => IStrategy) public tokenToStrategy;

    function setUp() public virtual {
        generator = TrafficGenerator({
            key: vm.createWallet("generator_wallet")
        });
        owner = AVSOwner({key: vm.createWallet("owner_wallet")});

        proxyAdmin = UpgradeableProxyLib.deployProxyAdmin();

        coreConfigData = CoreDeploymentParsingLib.readDeploymentConfigValues(
            "test/mockData/config/core/",
            1337
        );
        coreDeployment = CoreDeployLib.deployContracts(
            proxyAdmin,
            coreConfigData
        );

        vm.prank(coreConfigData.strategyManager.initialOwner);
        StrategyManager(coreDeployment.strategyManager).setStrategyWhitelister(
            coreDeployment.strategyFactory
        );

        mockToken = new ERC20Mock();

        IStrategy strategy = addStrategy(address(mockToken));
        quorum.strategies.push(
            IECDSAStakeRegistryTypes.StrategyParams({
                strategy: strategy,
                multiplier: 10_000
            })
        );

        openRankDeployment = OpenRankDeploymentLib.deployContracts(
            proxyAdmin,
            coreDeployment,
            quorum,
            owner.key.addr,
            owner.key.addr
        );
        openRankDeployment.strategy = address(strategy);
        openRankDeployment.token = address(mockToken);
        labelContracts(coreDeployment, openRankDeployment);
    }

    function addStrategy(address token) public returns (IStrategy) {
        if (tokenToStrategy[token] != IStrategy(address(0))) {
            return tokenToStrategy[token];
        }

        StrategyFactory strategyFactory = StrategyFactory(
            coreDeployment.strategyFactory
        );
        IStrategy newStrategy = strategyFactory.deployNewStrategy(
            IERC20(token)
        );
        tokenToStrategy[token] = newStrategy;
        return newStrategy;
    }

    function labelContracts(
        CoreDeployLib.DeploymentData memory coreDeployment,
        OpenRankDeploymentLib.DeploymentData memory openRankDeployment
    ) internal {
        vm.label(coreDeployment.delegationManager, "DelegationManager");
        vm.label(coreDeployment.avsDirectory, "AVSDirectory");
        vm.label(coreDeployment.strategyManager, "StrategyManager");
        vm.label(coreDeployment.eigenPodManager, "EigenPodManager");
        vm.label(coreDeployment.rewardsCoordinator, "RewardsCoordinator");
        vm.label(coreDeployment.eigenPodBeacon, "EigenPodBeacon");
        vm.label(coreDeployment.pauserRegistry, "PauserRegistry");
        vm.label(coreDeployment.strategyFactory, "StrategyFactory");
        vm.label(coreDeployment.strategyBeacon, "StrategyBeacon");
        vm.label(
            openRankDeployment.openRankServiceManager,
            "OpenRankServiceManager"
        );
        vm.label(openRankDeployment.stakeRegistry, "StakeRegistry");
    }

    function signWithOperatorKey(
        Operator memory operator,
        bytes32 digest
    ) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            operator.key.privateKey,
            digest
        );
        return abi.encodePacked(r, s, v);
    }

    function signWithSigningKey(
        Operator memory operator,
        bytes32 digest
    ) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            operator.signingKey.privateKey,
            digest
        );
        return abi.encodePacked(r, s, v);
    }

    function mintMockTokens(Operator memory operator, uint256 amount) internal {
        mockToken.mint(operator.key.addr, amount);
    }

    function depositTokenIntoStrategy(
        Operator memory operator,
        address token,
        uint256 amount
    ) internal returns (uint256) {
        IStrategy strategy = IStrategy(tokenToStrategy[token]);
        require(address(strategy) != address(0), "Strategy was not found");
        IStrategyManager strategyManager = IStrategyManager(
            coreDeployment.strategyManager
        );

        vm.startPrank(operator.key.addr);
        mockToken.approve(address(strategyManager), amount);
        uint256 shares = strategyManager.depositIntoStrategy(
            strategy,
            IERC20(token),
            amount
        );
        vm.stopPrank();

        return shares;
    }

    function registerAsOperator(Operator memory operator) internal {
        IDelegationManager delegationManager = IDelegationManager(
            coreDeployment.delegationManager
        );

        vm.prank(operator.key.addr);
        delegationManager.registerAsOperator(address(0), 0, "");
    }

    function registerOperatorToAVS(Operator memory operator) internal {
        ECDSAStakeRegistry stakeRegistry = ECDSAStakeRegistry(
            openRankDeployment.stakeRegistry
        );
        AVSDirectory avsDirectory = AVSDirectory(coreDeployment.avsDirectory);

        bytes32 salt = keccak256(
            abi.encodePacked(block.timestamp, operator.key.addr)
        );
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 operatorRegistrationDigestHash = avsDirectory
            .calculateOperatorAVSRegistrationDigestHash(
                operator.key.addr,
                address(openRankDeployment.openRankServiceManager),
                salt,
                expiry
            );

        bytes memory signature = signWithOperatorKey(
            operator,
            operatorRegistrationDigestHash
        );

        ISignatureUtilsMixinTypes.SignatureWithSaltAndExpiry
            memory operatorSignature = ISignatureUtilsMixinTypes
                .SignatureWithSaltAndExpiry({
                    signature: signature,
                    salt: salt,
                    expiry: expiry
                });

        vm.prank(address(operator.key.addr));
        stakeRegistry.registerOperatorWithSignature(
            operatorSignature,
            operator.signingKey.addr
        );
    }

    function deregisterOperatorFromAVS(Operator memory operator) internal {
        ECDSAStakeRegistry stakeRegistry = ECDSAStakeRegistry(
            openRankDeployment.stakeRegistry
        );

        vm.prank(operator.key.addr);
        stakeRegistry.deregisterOperator();
    }

    function createAndAddOperator() internal returns (Operator memory) {
        Vm.Wallet memory operatorKey = vm.createWallet(
            string.concat("operator", vm.toString(operators.length))
        );
        Vm.Wallet memory signingKey = vm.createWallet(
            string.concat("signing", vm.toString(operators.length))
        );

        Operator memory newOperator = Operator({
            key: operatorKey,
            signingKey: signingKey
        });

        operators.push(newOperator);
        return newOperator;
    }

    function updateOperatorWeights(Operator[] memory _operators) internal {
        ECDSAStakeRegistry stakeRegistry = ECDSAStakeRegistry(
            openRankDeployment.stakeRegistry
        );

        address[] memory operatorAddresses = new address[](_operators.length);
        for (uint256 i = 0; i < _operators.length; i++) {
            operatorAddresses[i] = _operators[i].key.addr;
        }

        stakeRegistry.updateOperators(operatorAddresses);
    }

    function getOperators(
        uint256 numOperators
    ) internal returns (Operator[] memory) {
        require(numOperators <= operators.length, "Not enough operators");

        Operator[] memory operatorsMem = new Operator[](numOperators);
        for (uint256 i = 0; i < numOperators; i++) {
            operatorsMem[i] = operators[i];
        }
        // Sort the operators by address
        for (uint256 i = 0; i < numOperators - 1; i++) {
            uint256 minIndex = i;
            // Find the minimum operator by address
            for (uint256 j = i + 1; j < numOperators; j++) {
                if (
                    operatorsMem[minIndex].key.addr > operatorsMem[j].key.addr
                ) {
                    minIndex = j;
                }
            }
            // Swap the minimum operator with the ith operator
            Operator memory temp = operatorsMem[i];
            operatorsMem[i] = operatorsMem[minIndex];
            operatorsMem[minIndex] = temp;
        }
        return operatorsMem;
    }

    function createTask() internal returns (uint256 computeId) {
        IOpenRankServiceManager openRankServiceManager = IOpenRankServiceManager(
                openRankDeployment.openRankServiceManager
            );

        vm.prank(generator.key.addr);
        computeId = openRankServiceManager.submitComputeRequest(
            bytes32(0),
            bytes32(0)
        );
    }

    function respondToTask(
        Operator memory operator,
        uint256 computeId
    ) internal {
        Operator[] memory operatorsMem = new Operator[](1);
        operatorsMem[0] = operator;

        IOpenRankServiceManager(openRankDeployment.openRankServiceManager)
            .submitComputeResult(computeId, bytes32(0), bytes32(0));
    }

    function makeTaskResponse(
        Operator[] memory operatorsMem
    ) internal returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked("Hello, ", "World"));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();

        address[] memory operatorAddrs = new address[](operatorsMem.length);
        for (uint256 i = 0; i < operatorsMem.length; i++) {
            operatorAddrs[i] = operatorsMem[i].key.addr;
        }
        bytes[] memory signatures = new bytes[](operatorsMem.length);
        for (uint256 i = 0; i < operatorsMem.length; i++) {
            signatures[i] = signWithSigningKey(
                operatorsMem[i],
                ethSignedMessageHash
            );
        }

        bytes memory signedTask = abi.encode(operatorAddrs, signatures);

        return signedTask;
    }
}

contract OpenRankServiceManagerInitialization is OpenRankTaskManagerSetup {
    function testInitialization() public view {
        ECDSAStakeRegistry stakeRegistry = ECDSAStakeRegistry(
            openRankDeployment.stakeRegistry
        );

        IECDSAStakeRegistryTypes.Quorum memory quorum = stakeRegistry.quorum();

        assertGt(quorum.strategies.length, 0, "No strategies in quorum");
        assertEq(
            address(quorum.strategies[0].strategy),
            address(tokenToStrategy[address(mockToken)]),
            "First strategy doesn't match mock token strategy"
        );

        assertTrue(
            openRankDeployment.stakeRegistry != address(0),
            "StakeRegistry not deployed"
        );
        assertTrue(
            openRankDeployment.openRankServiceManager != address(0),
            "OpenRankServiceManager not deployed"
        );
        assertTrue(
            coreDeployment.delegationManager != address(0),
            "DelegationManager not deployed"
        );
        assertTrue(
            coreDeployment.avsDirectory != address(0),
            "AVSDirectory not deployed"
        );
        assertTrue(
            coreDeployment.strategyManager != address(0),
            "StrategyManager not deployed"
        );
        assertTrue(
            coreDeployment.eigenPodManager != address(0),
            "EigenPodManager not deployed"
        );
        assertTrue(
            coreDeployment.strategyFactory != address(0),
            "StrategyFactory not deployed"
        );
        assertTrue(
            coreDeployment.strategyBeacon != address(0),
            "StrategyBeacon not deployed"
        );
    }
}
