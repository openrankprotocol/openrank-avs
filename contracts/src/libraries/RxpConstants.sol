// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

/**
 * @title Library of utilities for calculations related to epochs in EigenLayer
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 */
library RxpConstants {
    /// @notice The operator set ID as a uint32 (AllocationManager interfaces)
    uint32 internal constant OPERATOR_SET_ID = 0;

    /// @notice The operator set ID as a uint8 (Middleware interfaces)
    uint8 internal constant OPERATOR_SET_ID_UINT8 = 0;
}
