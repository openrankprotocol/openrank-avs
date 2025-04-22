// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../interfaces/IEigen.sol";
import "../interfaces/ISignatureGuardedForwarder.sol";

abstract contract EigenStorage is IEigen, OwnableUpgradeable, ERC20VotesUpgradeable {
    /// CONSTANTS & IMMUTABLES

    /// @notice the address of the backing Eigen token bEIGEN
    IERC20 public immutable bEIGEN;
    /// @notice the status bridge contract
    IStatusBridge public immutable statusBridge;
    /// @notice the challenge manager contract
    IChallengeManager public immutable challengeManager;

    /// DEPRECATED STORAGE
    /// @notice mapping of minter addresses to the timestamp after which they are allowed to mint
    mapping(address => uint256) public __deprecated_mintAllowedAfter;
    /// @notice mapping of minter addresses to the amount of tokens they are allowed to mint
    mapping(address => uint256) public __deprecated_mintingAllowance;

    /// @notice the timestamp after which transfer restrictions are disabled
    uint256 public __deprecated_transferRestrictionsDisabledAfter;
    /// @notice mapping of addresses that are allowed to transfer tokens to any address
    mapping(address => bool) public __deprecated_allowedFrom;
    /// @notice mapping of addresses that are allowed to receive tokens from any address
    mapping(address => bool) public __deprecated_allowedTo;

    /// STORAGE

    /// @notice the block number of the first global EigenZone challenge
    uint32 public firstChallengeBlock;
    /// @notice the challenge period
    uint32 public challengeDelayBlocks;

    /// @notice set of addresses that are instantly allowed to wrap tokens
    EnumerableSet.AddressSet internal _instantWrappers;
    /// @notice mapping of pending wrap requests
    WrapRequest[] public wrapRequests;
    /// @notice mapping of unwrapping the occured, deleted upon claiming after a fork
    Unwrapping[] public unwrappings;

    constructor(IERC20 _bEIGEN, IStatusBridge _statusBridge, IChallengeManager _challengeManager) {
        bEIGEN = _bEIGEN;
        statusBridge = _statusBridge;
        challengeManager = _challengeManager;

        _disableInitializers();
    }
}
