// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.12;

import "./EigenStorage.sol";

contract Eigen is EigenStorage {
    using EnumerableSet for EnumerableSet.AddressSet;

    modifier onlyWhenWrappingNotPaused() {
        require(!statusBridge.paused(), IEigen_WrappingPaused());
        _;
    }

    constructor(
        IERC20 _bEIGEN,
        IStatusBridge _statusBridge,
        IChallengeManager _challengeManager
    ) EigenStorage(_bEIGEN, _statusBridge, _challengeManager) { }

    /// @inheritdoc IEigen
    function initialize(
        address initialOwner
    ) public initializer {
        __Ownable_init();
        __ERC20_init("Eigen", "EIGEN");
        _transferOwnership(initialOwner);
        __ERC20Permit_init("EIGEN");
    }

    /// @inheritdoc IEigen
    function addInstantWrapper(
        address wrapper
    ) external onlyOwner {
        require(_instantWrappers.add(wrapper), IEigen_InstantWrapperExists());
        emit InstantWrapperAdded(wrapper);
    }

    /// @inheritdoc IEigen
    function removeInstantWrapper(
        address wrapper
    ) external onlyOwner {
        require(_instantWrappers.remove(wrapper), IEigen_InstantWrapperDoesNotExist());
        emit InstantWrapperRemoved(wrapper);
    }

    /// @inheritdoc IEigen
    function queueWrap(
        uint256 amount
    ) external onlyWhenWrappingNotPaused returns (uint256) {
        bEIGEN.transferFrom(msg.sender, address(this), amount);

        WrapRequest memory request = WrapRequest({
            requester: msg.sender,
            amount: amount,
            completeAfterBlock: uint32(block.number) + challengeManager.challengeConfig().challengeDelayBlocks,
            completed: false
        });
        wrapRequests.push(request);

        emit WrapRequested(msg.sender, amount, uint32(block.number));

        return wrapRequests.length - 1;
    }

    /// @inheritdoc IEigen
    function completeWrap(
        uint256 index
    ) external {
        WrapRequest memory request = wrapRequests[index];
        require(!request.completed, IEigen_WrapAlreadyCompleted());
        require(request.completeAfterBlock < block.number, IEigen_WrapNotReadyToComplete());
        wrapRequests[index].completed = true;

        // check if bridges from the EigenZone to the EthZone are paused indefinitely
        uint32 pausedIndefinitelyAtBlock = statusBridge.pausedIndefinitelyAtBlock();
        if (pausedIndefinitelyAtBlock != 0 && pausedIndefinitelyAtBlock <= request.completeAfterBlock) {
            // if so, refund the requester
            bEIGEN.transfer(request.requester, request.amount);
            emit WrapRefunded(request.requester, request.amount, uint32(block.number));
        } else {
            // otherwise, complete the wrap
            _mint(request.requester, request.amount);
            emit WrapCompleted(request.requester, request.amount, uint32(block.number));
        }
    }

    /// @inheritdoc IEigen
    function wrap(
        uint256 amount
    ) external onlyWhenWrappingNotPaused {
        require(_instantWrappers.contains(msg.sender), IEigen_NotAnInstantWrapper());

        bEIGEN.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    /// @inheritdoc IEigen
    function unwrap(IERC20 token, uint256 amount, address forkRecipient) external {
        // TODO: do we need this check?
        require(token != IERC20(address(this)), IEigen_CannotUnwrapToEigen());

        _burn(msg.sender, amount);
        token.transfer(msg.sender, amount);

        // store the unwrapping for possible later claim due to forking within unwrapping
        unwrappings.push(Unwrapping({ recipient: forkRecipient, amount: amount, blockNumber: uint32(block.number) }));

        emit Unwrap(msg.sender, forkRecipient, token, amount, uint32(block.number));
    }

    /// @inheritdoc IEigen
    function isInstantWrapper(
        address wrapper
    ) external view returns (bool) {
        return _instantWrappers.contains(wrapper);
    }

    /// @inheritdoc IEigen
    function instantWrapperAt(
        uint256 index
    ) external view returns (address) {
        return _instantWrappers.at(index);
    }

    /// @inheritdoc IEigen
    function instantWrapperCount() external view returns (uint256) {
        return _instantWrappers.length();
    }

    /// @inheritdoc IEigen
    function wrapRequestCount() external view returns (uint256) {
        return wrapRequests.length;
    }

    /// @inheritdoc IEigen
    function wrapRequestAt(
        uint256 index
    ) external view returns (WrapRequest memory) {
        return wrapRequests[index];
    }

    /// @inheritdoc IEigen
    function unwrappingCount() external view returns (uint256) {
        return unwrappings.length;
    }

    /// @inheritdoc IEigen
    function unwrappingAt(
        uint256 index
    ) external view returns (Unwrapping memory) {
        return unwrappings[index];
    }

    /**
     * @notice Overridden to return the total bEIGEN supply instead.
     * @dev The issued supply of EIGEN should match the bEIGEN balance of this contract,
     * less any bEIGEN tokens that were sent directly to the contract (rather than being wrapped)
     */
    function totalSupply() public view override returns (uint256) {
        return bEIGEN.totalSupply();
    }

    /**
     * @dev Clock used for flagging checkpoints. Has been overridden to implement timestamp based
     * checkpoints (and voting).
     */
    function clock() public view override returns (uint48) {
        return SafeCastUpgradeable.toUint48(block.timestamp); // TODO: do we need to switch the clock to block based?
    }

    /**
     * @dev Machine-readable description of the clock as specified in EIP-6372.
     * Has been overridden to inform callers that this contract uses timestamps instead of block numbers, to match `clock()`
     */
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }
}
