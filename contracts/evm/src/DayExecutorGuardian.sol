// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Thin pause relay so DayRouterExecutor guardian role is distinct from owner and treasury.
/// @dev Executor.pause() requires msg.sender == guardian. Admin (owner EOA) calls this contract,
///      which then invokes pause on the executor. No unpause path — only owner on the executor
///      can unpause. No rescue, upgrade, or token surface.
interface IDayPausableExecutor {
    function pause() external;
}

contract DayExecutorGuardian {
    address public immutable admin;

    error NotAdmin();
    error ZeroAddress();

    event PauseRelayed(address indexed executor, address indexed admin);

    constructor(address admin_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
    }

    /// @notice Relay pause to a DayRouterExecutor that pins this contract as guardian.
    function pause(address executor) external {
        if (msg.sender != admin) revert NotAdmin();
        if (executor == address(0)) revert ZeroAddress();
        IDayPausableExecutor(executor).pause();
        emit PauseRelayed(executor, msg.sender);
    }
}
