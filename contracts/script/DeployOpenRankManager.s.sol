// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {OpenRankDeploymentLib} from "./utils/OpenRankDeploymentLib.sol";
import {CoreDeployLib, CoreDeploymentParsingLib} from "./utils/CoreDeploymentLib.sol";
import {UpgradeableProxyLib} from "./utils/UpgradeableProxyLib.sol";
import {StrategyBase} from "@eigenlayer/contracts/strategies/StrategyBase.sol";
import {ERC20Mock} from "../test/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";
import {StrategyManager} from "@eigenlayer/contracts/core/StrategyManager.sol";
import {IRewardsCoordinator} from "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {IECDSAStakeRegistryTypes, IStrategy} from "@eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
import "forge-std/Test.sol";

contract OpenRankDeployer is Script, Test {
    using CoreDeployLib for *;
    using UpgradeableProxyLib for address;

    address private deployer;
    address proxyAdmin;
    address rewardsOwner;
    address rewardsInitiator;
    IStrategy openRankStrategy;
    CoreDeployLib.DeploymentData coreDeployment;
    OpenRankDeploymentLib.DeploymentData openRankDeployment;
    OpenRankDeploymentLib.DeploymentConfigData openRankConfig;
    IECDSAStakeRegistryTypes.Quorum internal quorum;
    ERC20Mock token;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");

        openRankConfig = OpenRankDeploymentLib.readDeploymentConfigValues(
            "contracts/config/openrank/",
            block.chainid
        );

        coreDeployment = CoreDeploymentParsingLib.readDeploymentJson(
            "contracts/deployments/core/",
            block.chainid
        );
    }

    function run() external {
        vm.startBroadcast(deployer);
        rewardsOwner = openRankConfig.rewardsOwner;
        rewardsInitiator = openRankConfig.rewardsInitiator;

        token = new ERC20Mock();
        // NOTE: if this fails, it's because the initialStrategyWhitelister is not set to be the StrategyFactory
        openRankStrategy = IStrategy(
            StrategyFactory(coreDeployment.strategyFactory).deployNewStrategy(
                token
            )
        );

        quorum.strategies.push(
            IECDSAStakeRegistryTypes.StrategyParams({
                strategy: openRankStrategy,
                multiplier: 10_000
            })
        );

        proxyAdmin = UpgradeableProxyLib.deployProxyAdmin();

        openRankDeployment = OpenRankDeploymentLib.deployContracts(
            proxyAdmin,
            coreDeployment,
            quorum,
            rewardsInitiator,
            rewardsOwner
        );

        openRankDeployment.strategy = address(openRankStrategy);
        openRankDeployment.token = address(token);

        vm.stopBroadcast();
        verifyDeployment();
        OpenRankDeploymentLib.writeDeploymentJson(openRankDeployment);
    }

    function verifyDeployment() internal view {
        require(
            openRankDeployment.stakeRegistry != address(0),
            "StakeRegistry address cannot be zero"
        );
        require(
            openRankDeployment.openRankServiceManager != address(0),
            "OpenRankServiceManager address cannot be zero"
        );
        require(
            openRankDeployment.strategy != address(0),
            "Strategy address cannot be zero"
        );
        require(proxyAdmin != address(0), "ProxyAdmin address cannot be zero");
        require(
            coreDeployment.delegationManager != address(0),
            "DelegationManager address cannot be zero"
        );
        require(
            coreDeployment.avsDirectory != address(0),
            "AVSDirectory address cannot be zero"
        );
    }
}
