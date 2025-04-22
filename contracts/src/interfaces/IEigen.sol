// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "./IChallengeManager.sol";

// STRUCTS

struct WrapRequest {
    address requester;
    uint256 amount;
    uint32 completeAfterBlock;
    bool completed;
}

struct Unwrapping {
    address recipient;
    uint256 amount;
    uint32 blockNumber;
}

// EVENTS

/// @notice Emitted when an instant wrapper is added
event InstantWrapperAdded(address indexed wrapper);
/// @notice Emitted when an instant wrapper is removed

event InstantWrapperRemoved(address indexed wrapper);
/// @notice Emitted when a wrap request is created

event WrapRequested(address indexed requester, uint256 amount, uint32 blockNumber);
/// @notice Emitted when a wrap request is refunded

event WrapRefunded(address indexed requester, uint256 amount, uint32 blockNumber);
/// @notice Emitted when a wrap request is completed

event WrapCompleted(address indexed requester, uint256 amount, uint32 blockNumber);
/// @notice Emitted when a token is unwrapped

event Unwrap(
    address indexed unwrapper, address indexed forkRecipient, IERC20 token, uint256 amount, uint32 blockNumber
);
/// @notice Emitted when the first challenge block is set

event FirstChallengeBlockSet(uint32 firstChallengeBlock, uint32 setAtBlock);

/// @notice Emitted when the challenge delay is set
event ChallengeDelaySet(uint32 challengeDelay, uint32 setAtBlock);

// ERRORS

/// @notice Thrown when an instant wrapper already exists
error IEigen_InstantWrapperExists();
/// @notice Thrown when an instant wrapper does not exist
error IEigen_InstantWrapperDoesNotExist();
/// @notice Thrown when a entity that is not an instant wrapper attempts to instant wrap
error IEigen_NotAnInstantWrapper();
/// @notice Thrown when the challenge params have already been set
error IEigen_ChallengeParamsAlreadySet();
/// @notice Thrown when the first challenge block is not set
error IEigen_FirstChallengeBlockNotSet();
/// @notice Thrown when the challenge delay is not set
error IEigen_ChallengeDelayNotSet();
/// @notice Thrown when bridges from the EigenZone to EthZone are paused
error IEigen_WrappingPaused();
/// @notice Thrown when the wrap is not ready to complete
error IEigen_WrapNotReadyToComplete();
/// @notice Thrown when a wrap request has already been completed
error IEigen_WrapAlreadyCompleted();
/// @notice Thrown when a transfer fails
error IEigen_TransferFailed();
/// @notice Thrown when a token is attempted to be unwrapped to Eigen
error IEigen_CannotUnwrapToEigen();

interface IEigen {
    /**
     * @notice An initializer function that sets initial values for the contract's state variables.
     */
    function initialize(
        address initialOwner
    ) external;

    /**
     * @notice Adds an instant wrapper
     * @param wrapper the address to add
     */
    function addInstantWrapper(
        address wrapper
    ) external;

    /**
     * @notice Removes an instant wrapper
     * @param wrapper the address to remove
     */
    function removeInstantWrapper(
        address wrapper
    ) external;

    /**
     * @notice Request to wrap bEIGEN tokens
     * @param amount the amount of bEIGEN tokens to wrap
     * @return the index of the wrap request
     */
    function queueWrap(
        uint256 amount
    ) external returns (uint256);

    /**
     * @notice Completes a pending wrap request
     * @param index the index of the wrap request to complete
     */
    function completeWrap(
        uint256 index
    ) external;

    /**
     * @notice Enables instant wrappers to wrap their bEIGEN tokens into Eigen
     * @param amount the amount of bEIGEN tokens to wrap
     * @dev This function can only be called by instant wrappers
     */
    function wrap(
        uint256 amount
    ) external;

    /**
     * @notice Enables Eigen holders to unwrap their tokens into bEIGEN
     * @param token the backing token to unwrap to. This may be different than the Eigen token due to forks.
     * @param amount the amount of Eigen tokens to unwrap
     * @param forkRecipient the address to allow to redeem alternative bEIGEN if the
     * current bEIGEN token is forked
     */
    function unwrap(IERC20 token, uint256 amount, address forkRecipient) external;

    /**
     * @notice Gets the bEIGEN token
     * @return the bEIGEN token
     */
    function bEIGEN() external view returns (IERC20);

    /**
     * @notice Gets the challenge manager
     * @return the challenge manager
     */
    function challengeManager() external view returns (IChallengeManager);

    /**
     * @notice Checks if an address is an instant wrapper
     * @param wrapper the address to check
     * @return whether the address is an instant wrapper
     */
    function isInstantWrapper(
        address wrapper
    ) external view returns (bool);

    /**
     * @notice Gets an instant wrapper at a given index
     * @param index the index of the instant wrapper to get
     * @return the instant wrapper at the given index
     */
    function instantWrapperAt(
        uint256 index
    ) external view returns (address);

    /**
     * @notice Gets the number of instant wrappers
     * @return the number of instant wrappers
     */
    function instantWrapperCount() external view returns (uint256);

    /**
     * @notice Gets the number of wrap requests
     * @return the number of wrap requests
     */
    function wrapRequestCount() external view returns (uint256);

    /**
     * @notice Gets a wrap request at a given index
     * @param index the index of the wrap request to get
     * @return the wrap request at the given index
     */
    function wrapRequestAt(
        uint256 index
    ) external view returns (WrapRequest memory);

    /**
     * @notice Gets the number of unwrappings
     * @return the number of unwrappings
     */
    function unwrappingCount() external view returns (uint256);

    /**
     * @notice Gets an unwrapping at a given index
     * @param index the index of the unwrapping to get
     * @return the unwrapping at the given index
     */
    function unwrappingAt(
        uint256 index
    ) external view returns (Unwrapping memory);
}
