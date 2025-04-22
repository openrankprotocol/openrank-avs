// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "./IChallengeManager.sol";
import "./ISignatureGuardedForwarder.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/// ERRORS

/// @notice Error thrown when the caller is not the challenge manager
error IStatusBridge_OnlyChallengeManager();
/// @notice Error thrown when the caller is not the signature guarded forwarder
error IStatusBridge_OnlySignatureGuardedForwarder();
/// @notice Error thrown when attempting to pause when already paused
error IStatusBridge_AlreadyPaused();
/// @notice Error thrown when attempting to unpause when not paused
error IStatusBridge_NotPaused();
/// @notice Error thrown when attempting to pause indefinitely when already paused indefinitely
error IStatusBridge_AlreadyPausedIndefinitely();
/// @notice Error thrown when attempting to unpause when paused indefinitely
error IStatusBridge_CannotUnpauseIndefinitely();
/// @notice Error thrown when the caller is not the CETG timelock controller
error IStatusBridge_OnlyCETGTimelockController();

/// EVENTS

/// @notice Emitted when the bridges from the EigenZone to EthZone are paused
event Paused();
/// @notice Emitted when the bridges from the EigenZone to EthZone are paused indefinitely

event PausedIndefinitely();
/// @notice Emitted when the bridges from the EigenZone to EthZone are unpaused

event Unpaused();

/**
 * @title IStatusBridge Interface
 * @notice Interface for the StatusBridge contract which tracks the first challenge block
 * @dev This contract acts as a bridge between the ChallengeManager and other contracts
 * that need to know about the challenge status
 */
interface IStatusBridge {
    /// @notice The challenge manager contract
    function challengeManager() external view returns (IChallengeManager);

    /// @notice The signature guarded forwarder contract
    function signatureGuardedForwarder() external view returns (ISignatureGuardedForwarder);

    /// @notice The CETG Timelock Controller contract
    function cetgTimelockController() external view returns (TimelockController);

    /**
     * @notice Returns whether bridges from the EigenZone are paused
     * @dev Bridges are paused when the first challenge block is set
     * @return Whether bridges are paused
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the block number at which the EigenZone was pausedIndefinitely at
     * @return The block number at which the EigenZone was pausedIndefinitely at
     */
    function pausedIndefinitelyAtBlock() external view returns (uint32);

    /**
     * @notice Pauses the bridges from the EigenZone to EthZone
     * @dev Can only be called by the signature guarded forwarder contract upon a tx being forced through it
     */
    function pause() external;

    /**
     * @notice Unpauses the bridges from the EigenZone to EthZone
     * @dev Can only be called by the CETG Timelock Controller
     */
    function unpause() external;

    /**
     * @notice Pauses the bridges from the EigenZone to EthZone indefinitely
     * @dev Can only be called by the challenge manager contract upon the first challenge
     */
    function pauseIndefinitely() external;
}
