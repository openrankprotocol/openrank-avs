// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./IChallengeManager.sol";
// EVENTS

/// @notice emitted when a forkable token account is added to the EigenZone
event ForkableTokenAccountAdded(address forkableTokenAccount);

/// @notice emitted when a forkable token account is removed from the EigenZone
event ForkableTokenAccountRemoved(address forkableTokenAccount);

/// @notice emitted when an AVS is added to the EigenZone
event AVSAdded(address avs);

/// @notice emitted when an AVS is removed from the EigenZone
event AVSRemoved(address avs);

// ERRORS

/// @notice error emitted when a forkable token account is already added to the EigenZone
error IGlobalConfig_ForkableTokenAccountAlreadyExists();
/// @notice error emitted when a forkable token account is not in the EigenZone
error IGlobalConfig_ForkableTokenAccountDoesNotExist();
/// @notice error emitted when an AVS is already added to the EigenZone
error IGlobalConfig_AVSAlreadyExists();
/// @notice error emitted when an AVS is not in the EigenZone
error IGlobalConfig_AVSDoesNotExist();

/**
 * @title IGlobalConfig
 * @notice Interface for the GlobalConfig contract, which maintains the important
 * configuration values for the EigenZone. It is entirely owned and upgradable by
 * the Protocol Council Cryptoeconomic Tiered Governer.
 *
 * This contract is forked upon upgrades and acts as the central configuration value
 * around which social consensus coalesces.
 */
interface IGlobalConfig {
    /// @notice the address of the bEIGEN token
    function bEIGEN() external view returns (IERC20);

    /// @notice the address of the EIGEN token
    function EIGEN() external view returns (IERC20);

    /// @notice the address of the ChallengeManager
    function challengeManager() external view returns (IChallengeManager);

    /// @notice the address of the merkle distributor in case this is not the first deployment
    function merkleDistributor() external view returns (address);

    /// @notice the number of forkable token accounts
    /// @dev this is the number of forkable token accounts that have their bEIGEN token balance forked to a different contract upon an EigenZone fork
    function forkableTokenAccountCount() external view returns (uint256);

    /// @notice the system address at the given index
    function forkableTokenAccountAt(
        uint256 index
    ) external view returns (address);

    /// @notice the number of AVSs
    /// @dev this is the number of AVS that must be forked upon an EigenZone fork
    function avsCount() external view returns (uint256);

    /// @notice the AVS at the given index
    function avsAt(
        uint256 index
    ) external view returns (address);

    /**
     * @notice initialize the global config
     * @param initialOwner the address to initialize as the owner
     */
    function initialize(
        address initialOwner
    ) external;

    /**
     * @notice add a forkable token account to the set of forkable token accounts
     * @param forkableTokenAccount the address to add the set of forkable token accounts
     * @dev only the owner can call this function
     * @dev reverts if the forkable token account is already in the set
     */
    function addForkableTokenAccount(
        address forkableTokenAccount
    ) external;

    /**
     * @notice remove a forkable token account from the set of forkable token accounts
     * @param forkableTokenAccount the address to remove
     * @dev only the owner can call this function
     * @dev reverts if the forkable token account is not in the set
     */
    function removeForkableTokenAccount(
        address forkableTokenAccount
    ) external;

    /**
     * @notice add an AVS to the set of AVSs
     * @param avs the address to add
     * @dev only the owner can call this function
     * @dev reverts if the AVS is already in the set
     */
    function addAVS(
        address avs
    ) external;

    /**
     * @notice remove an AVS from the set of AVSs
     * @param avs the address to remove
     * @dev only the owner can call this function
     * @dev reverts if the AVS is not in the set
     */
    function removeAVS(
        address avs
    ) external;
}
