// // SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.9.0;

import "./IStatusBridge.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// STRUCTS

struct ChallengeConfig {
    uint32 challengeDelayBlocks;
    uint256 cpf;
}

struct Challenge {
    address challenger;
    address beneficiary;
    uint256 amountBurned;
    bytes32 fraudProofHash;
    uint32 blockNumber;
}

// EVENTS

/// @notice emitted when the challenge config is set
event ChallengeConfigSet(ChallengeConfig config);

/// @notice emitted when a challenge is created
event ChallengeCreated(Challenge challenge, bytes fraudProof);

/**
 * @title IChallengeManager
 * @notice Interface for the ChallengeManager contract, which handles challenges to the EigenZone.
 * Challenges can be created by any user who is willing to burn a proportion of the total bEIGEN supply.
 * If a challenge is successful, the beneficiary receives all forked tokens in the new EigenZone.
 *
 * Social consensus listens to challenges in order initiate forking the EigenZone.
 */
interface IChallengeManager {
    /// @notice the address of the bEIGEN token
    function bEIGEN() external view returns (IERC20);

    /// @notice the address of the status bridge
    function statusBridge() external view returns (IStatusBridge);

    /// @notice the challenge config
    function challengeConfig() external view returns (ChallengeConfig memory);

    /// @notice the number of challenges
    function challengeCount() external view returns (uint256);

    /// @notice the challenge at the given index
    function challengeAt(
        uint256 index
    ) external view returns (Challenge memory);

    /**
     * @notice sets the challenge config
     * @param config the challenge config
     * @dev only the owner can call this functions
     */
    function setChallengeConfig(
        ChallengeConfig memory config
    ) external;

    /**
     * @notice called by a user to challenge the EigenZone
     * @param beneficiary the address of the beneficiary of the forked tokens if the challenge is successful
     * @param fraudProof the proof of fraud that justifies this challenge
     * @dev msg.sender must have approved the bEIGEN token to this contract for globalConfig().challengeConfig().cpf proportion of the total supply of bEIGEN
     * @dev the fraud proof is hashed and stored in the challenge struct for later verification
     */
    function createChallenge(address beneficiary, bytes calldata fraudProof) external;
}
