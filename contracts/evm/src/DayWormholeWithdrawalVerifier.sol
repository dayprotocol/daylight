// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IDayWithdrawalVerifier} from "./IDayWithdrawalTransport.sol";

/// @notice Official Wormhole Core interface subset.
/// @dev Struct layout and parseAndVerifyVM signature are copied from
///      wormhole-foundation/wormhole/ethereum/contracts/interfaces/IWormhole.sol.
interface IWormholeDayVerifier {
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }

    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence);

    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (VM memory vm, bool valid, string memory reason);

    function messageFee() external view returns (uint256);
    function evmChainId() external view returns (uint256);
}

/// @title DayWormholeWithdrawalVerifier
/// @notice Guardian-quorum verification and replay consumption for DAY withdrawal commands.
/// @dev A deployment is production-usable only when `wormholeCore` is the official Core Bridge
///      for the local chain and every peer is the audited DAY router emitter on that chain.
contract DayWormholeWithdrawalVerifier is IDayWithdrawalVerifier {
    bytes32 public constant MESSAGE_DOMAIN = keccak256("DAY_PROTOCOL_WORMHOLE_WITHDRAWAL_V1");
    uint8 public constant MESSAGE_VERSION = 1;
    uint8 public constant WITHDRAWAL_ACTION = 1;
    address public constant ETHEREUM_WORMHOLE_CORE = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
    address public constant BASE_WORMHOLE_CORE = 0xbebdb6C8ddC678FfA9f8748f85C815C556Dd8ac6;
    address public constant ARBITRUM_WORMHOLE_CORE = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;

    address public immutable wormholeCore;
    uint32 public immutable localDayChainId;
    uint8 public immutable consistencyLevel;

    mapping(uint32 => uint16) public wormholeChainIds;
    mapping(uint32 => bytes32) public peerEmitters;
    mapping(uint32 => bytes32) public peerExecutors;
    mapping(bytes32 => bool) public consumedVaas;
    mapping(bytes32 => bool) public consumedRequests;

    error ZeroAddress();
    error AddressHasNoCode();
    error CoreNotOfficial();
    error InvalidLocalChain();
    error InvalidArrayLengths();
    error InvalidPeer();
    error DuplicatePeer();
    error InvalidDestination();
    error InvalidSource();
    error InvalidContext();
    error InvalidVaa(string reason);
    error EmitterNotPinned();
    error PayloadMismatch();
    error VaaAlreadyConsumed();
    error RequestAlreadyConsumed();
    error FeeMismatch();

    event WithdrawalMessageConsumed(
        bytes32 indexed dayTxId,
        bytes32 indexed requestId,
        bytes32 indexed vaaHash,
        uint32 sourceChainId,
        bytes32 sourceEmitter
    );

    constructor(
        address wormholeCore_,
        uint8 consistencyLevel_,
        uint32[] memory dayChainIds,
        uint16[] memory wormholeChainIds_,
        bytes32[] memory peerEmitters_,
        bytes32[] memory peerExecutors_
    ) {
        if (wormholeCore_ == address(0)) revert ZeroAddress();
        if (wormholeCore_ != _officialCoreForChain()) revert CoreNotOfficial();
        if (wormholeCore_.code.length == 0) revert AddressHasNoCode();
        if (block.chainid > type(uint32).max) revert InvalidLocalChain();
        if (IWormholeDayVerifier(wormholeCore_).evmChainId() != block.chainid) revert InvalidLocalChain();
        if (
            dayChainIds.length != wormholeChainIds_.length || dayChainIds.length != peerEmitters_.length
                || dayChainIds.length != peerExecutors_.length
        ) {
            revert InvalidArrayLengths();
        }

        wormholeCore = wormholeCore_;
        localDayChainId = uint32(block.chainid);
        consistencyLevel = consistencyLevel_;

        for (uint256 i; i < dayChainIds.length; ++i) {
            if (
                dayChainIds[i] == 0 || wormholeChainIds_[i] == 0 || peerEmitters_[i] == bytes32(0)
                    || peerExecutors_[i] == bytes32(0)
            ) {
                revert InvalidPeer();
            }
            if (wormholeChainIds[dayChainIds[i]] != 0) revert DuplicatePeer();
            wormholeChainIds[dayChainIds[i]] = wormholeChainIds_[i];
            peerEmitters[dayChainIds[i]] = peerEmitters_[i];
            peerExecutors[dayChainIds[i]] = peerExecutors_[i];
        }
    }

    function verifyAndConsumeMessage(WithdrawalContext calldata context, bytes calldata signedVaa)
        external
        returns (bytes32 vaaHash)
    {
        _validateContext(context);
        (IWormholeDayVerifier.VM memory vm, bool valid, string memory reason) =
            IWormholeDayVerifier(wormholeCore).parseAndVerifyVM(signedVaa);
        if (!valid) revert InvalidVaa(reason);

        uint16 expectedWormholeChain = wormholeChainIds[context.sourceChainId];
        bytes32 expectedEmitter = peerEmitters[context.sourceChainId];
        bytes32 expectedExecutor = peerExecutors[context.sourceChainId];
        if (
            expectedWormholeChain == 0 || expectedEmitter == bytes32(0) || vm.emitterChainId != expectedWormholeChain
                || vm.emitterAddress != expectedEmitter || context.sourceExecutor != expectedExecutor
        ) revert EmitterNotPinned();
        if (keccak256(vm.payload) != keccak256(_encodeMessage(context))) revert PayloadMismatch();

        vaaHash = vm.hash;
        if (vaaHash == bytes32(0)) revert InvalidContext();
        if (consumedVaas[vaaHash]) revert VaaAlreadyConsumed();
        if (consumedRequests[context.requestId]) revert RequestAlreadyConsumed();
        consumedVaas[vaaHash] = true;
        consumedRequests[context.requestId] = true;

        emit WithdrawalMessageConsumed(
            context.dayTxId, context.requestId, vaaHash, context.sourceChainId, expectedEmitter
        );
    }

    function encodeMessage(WithdrawalContext calldata context) external pure returns (bytes memory) {
        return _encodeMessage(context);
    }

    function quoteMessage(WithdrawalContext calldata context) external view returns (uint256 nativeFee) {
        _validateSourceContext(context);
        return IWormholeDayVerifier(wormholeCore).messageFee();
    }

    function sendMessage(WithdrawalContext calldata context) external payable returns (bytes32 messageId) {
        _validateSourceContext(context);
        uint256 fee = IWormholeDayVerifier(wormholeCore).messageFee();
        if (msg.value != fee) revert FeeMismatch();
        uint64 sequence = IWormholeDayVerifier(wormholeCore).publishMessage{value: fee}(
            uint32(uint256(context.requestId)), _encodeMessage(context), consistencyLevel
        );
        messageId = keccak256(abi.encode(MESSAGE_DOMAIN, localDayChainId, sequence, context.requestId));
    }

    function transportEndpoint() external view returns (address) {
        return wormholeCore;
    }

    function _encodeMessage(WithdrawalContext calldata context) internal pure returns (bytes memory) {
        return abi.encode(MESSAGE_DOMAIN, MESSAGE_VERSION, WITHDRAWAL_ACTION, context);
    }

    function _validateContext(WithdrawalContext calldata context) internal view {
        _validateCommonContext(context);
        if (
            context.destinationChainId != localDayChainId
                || context.destinationExecutor != bytes32(uint256(uint160(msg.sender)))
        ) revert InvalidDestination();
    }

    function _validateSourceContext(WithdrawalContext calldata context) internal view {
        _validateCommonContext(context);
        if (
            context.sourceChainId != localDayChainId
                || context.sourceExecutor != bytes32(uint256(uint160(msg.sender)))
                || peerEmitters[context.destinationChainId] == bytes32(0)
                || peerExecutors[context.destinationChainId] != context.destinationExecutor
        ) revert InvalidSource();
    }

    function _validateCommonContext(WithdrawalContext calldata context) internal pure {
        if (
            context.requestId == bytes32(0) || context.dayTxId == bytes32(0) || context.controller == address(0)
                || context.sourceChainId == 0 || context.sourceExecutor == bytes32(0)
                || context.sourceRouteHash == bytes32(0) || context.originOwner == bytes32(0)
                || context.originToken == bytes32(0) || context.originBridgeToken == bytes32(0)
                || context.destinationRouteHash == bytes32(0) || context.opportunityId == bytes32(0)
                || context.adapterId == bytes32(0)
                || (context.fullRefund ? context.positionAmount != 0 : context.positionAmount == 0)
                || context.deadline == 0 || context.adapterDataHash == bytes32(0)
        ) revert InvalidContext();
    }

    function _officialCoreForChain() private view returns (address) {
        if (block.chainid == 1) return ETHEREUM_WORMHOLE_CORE;
        if (block.chainid == 8453) return BASE_WORMHOLE_CORE;
        if (block.chainid == 42161) return ARBITRUM_WORMHOLE_CORE;
        revert InvalidLocalChain();
    }
}
