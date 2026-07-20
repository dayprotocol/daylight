// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @notice Typed boundary between a DAY executor and a cross-chain owner-command transport.
interface IDayWithdrawalVerifier {
    struct WithdrawalContext {
        bytes32 requestId;
        bytes32 dayTxId;
        address controller;
        uint32 sourceChainId;
        bytes32 sourceExecutor;
        bytes32 sourceRouteHash;
        bytes32 originOwner;
        bytes32 originToken;
        bytes32 originBridgeToken;
        uint32 destinationChainId;
        bytes32 destinationExecutor;
        bytes32 destinationRouteHash;
        bytes32 opportunityId;
        bytes32 adapterId;
        uint256 positionAmount;
        uint256 minBridgeReturnAmount;
        uint256 minReturnAmount;
        uint64 deadline;
        uint64 redeemFee;
        bytes32 adapterDataHash;
        bool fullRefund;
    }

    function verifyAndConsumeMessage(WithdrawalContext calldata context, bytes calldata transportProof)
        external
        returns (bytes32 messageId);

    function encodeMessage(WithdrawalContext calldata context) external pure returns (bytes memory);
    function quoteMessage(WithdrawalContext calldata context) external view returns (uint256 nativeFee);
    function sendMessage(WithdrawalContext calldata context) external payable returns (bytes32 messageId);
    function transportEndpoint() external view returns (address);
    function peerExecutors(uint32 dayChainId) external view returns (bytes32);
    function localDayChainId() external view returns (uint32);
}
