// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Chain-generic swap boundary used by the public DAY router core.
/// @dev Production venue implementations remain private DAY infrastructure.
interface IDaySwapAdapter {
    function executor() external view returns (address);
    function bridgeToken() external view returns (address);
    function wrappedNative() external view returns (address);
    function supportsToken(address token) external view returns (bool);

    function swapToBridge(
        bytes32 dayTxId,
        address tokenIn,
        uint256 maxAmountIn,
        uint256 exactBridgeAmountOut,
        uint64 deadline
    ) external returns (uint256 amountIn);

    function swapFromBridge(
        bytes32 dayTxId,
        address tokenOut,
        uint256 bridgeAmountIn,
        uint256 minAmountOut,
        uint64 deadline
    ) external returns (uint256 amountOut);
}
