// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "../interfaces/ICertificateRegistry.sol";

library Hashing {
    function hash(
        StakeRoot calldata stakeRoot
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("STAKE_ROOT", stakeRoot));
    }

    function hash(
        Certificate calldata cert
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("CERTIFICATE", cert));
    }

    function hash(
        QuorumTotals calldata quorumTotal
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("QUORUM_TOTALS", quorumTotal));
    }

    function hashMem(
        QuorumTotals memory quorumTotal
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("QUORUM_TOTALS", quorumTotal));
    }

    function hash(
        OperatorInfo calldata operatorInfo
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("OPERATOR_INFO", operatorInfo));
    }

    function hashMem(
        OperatorInfo memory operatorInfo
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("OPERATOR_INFO", operatorInfo));
    }

    function encode(
        OperatorInfo memory operatorInfo
    ) internal pure returns (bytes memory) {
        return abi.encode("OPERATOR_INFO", operatorInfo);
    }
}
