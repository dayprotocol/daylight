// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {IDayWithdrawalVerifier} from "./IDayWithdrawalTransport.sol";

/// @title DayLayerZeroOwnerCommand
/// @notice Immutable LayerZero v2 transport for DAY owner-bound withdrawal commands.
/// @dev Principal still moves through Mayan. This OApp transports authorization only. It has no
///      owner, delegate, peer setter, arbitrary destination, token approval, or rescue surface.
contract DayLayerZeroOwnerCommand is IDayWithdrawalVerifier, ILayerZeroReceiver {
    bytes32 public constant MESSAGE_DOMAIN = keccak256("DAY_PROTOCOL_LAYERZERO_WITHDRAWAL_V1");
    uint8 public constant MESSAGE_VERSION = 1;
    uint8 public constant WITHDRAWAL_ACTION = 1;
    uint32 public constant BASE_EID = 30_184;
    uint32 public constant ARBITRUM_EID = 30_110;
    uint32 public constant SUI_EID = 30_378;
    // DAY-903 expansion tier — eids verified against live LayerZero metadata
    // (metadata.layerzero-api.com/v1/metadata, 2026-07-17). All chainType=evm,
    // chainStatus=ACTIVE. Robinhood (Arbitrum Orbit L2) is a DISTINCT chain from
    // Arbitrum — its own endpoint/eid, NOT covered by the Arbitrum spoke.
    uint32 public constant ETHEREUM_EID = 30_101;
    uint32 public constant BSC_EID = 30_102;
    uint32 public constant POLYGON_EID = 30_109;
    uint32 public constant MONAD_EID = 30_390;
    uint32 public constant PLASMA_EID = 30_383;
    uint32 public constant ROBINHOOD_EID = 30_416;
    address public constant OFFICIAL_EVM_ENDPOINT_V2 = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @dev DAY-903: Monad, Plasma, and Robinhood mainnets run a DIFFERENT
    ///      official Endpoint V2 deployment than the canonical 0x1a44… address
    ///      (verified in live LZ metadata 2026-07-17). A single-endpoint pin
    ///      would make the transport undeployable on those three chains.
    address public constant OFFICIAL_EVM_ENDPOINT_V2_ALT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;

    address public immutable transportEndpoint;
    address public immutable localExecutor;
    uint32 public immutable localDayChainId;
    uint32 public immutable localEid;

    mapping(uint32 dayChainId => uint32 eid) public layerZeroEids;
    mapping(uint32 eid => uint32 dayChainId) public dayChainsByEid;
    mapping(uint32 dayChainId => bytes32 transport) public peerTransports;
    mapping(uint32 dayChainId => bytes32 executor) public peerExecutors;
    mapping(uint32 dayChainId => bytes options) private _enforcedOptions;
    mapping(bytes32 guid => bytes32 payloadHash) public receivedPayloadHashes;
    mapping(bytes32 requestId => bytes32 guid) public receivedRequestGuids;
    mapping(bytes32 guid => bool consumed) public consumedGuids;
    mapping(bytes32 requestId => bool consumed) public consumedRequests;
    mapping(uint32 sourceEid => mapping(bytes32 sender => uint64 nonce)) public receivedNonces;

    error ZeroAddress();
    error AddressHasNoCode();
    error EndpointNotOfficial();
    error InvalidLocalChain();
    error InvalidArrayLengths();
    error InvalidPeer();
    error DuplicatePeer();
    error InvalidOptions();
    error OnlyLocalExecutor();
    error OnlyEndpoint();
    error InvalidSource();
    error InvalidDestination();
    error InvalidContext();
    error InvalidMessage();
    error FeeMismatch();
    error GuidAlreadyReceived();
    error RequestAlreadyReceived();
    error GuidAlreadyConsumed();
    error RequestAlreadyConsumed();
    error ProofNotReceived();
    error NonceGap();

    event OwnerCommandSent(
        bytes32 indexed dayTxId, bytes32 indexed requestId, bytes32 indexed guid, uint32 destinationEid, uint64 nonce
    );
    event OwnerCommandReceived(
        bytes32 indexed dayTxId, bytes32 indexed requestId, bytes32 indexed guid, uint32 sourceEid, uint64 nonce
    );
    event OwnerCommandConsumed(bytes32 indexed dayTxId, bytes32 indexed requestId, bytes32 indexed guid);

    constructor(
        address endpoint_,
        address localExecutor_,
        uint32[] memory dayChainIds,
        uint32[] memory endpointIds,
        bytes32[] memory peerTransportIds,
        bytes32[] memory peerExecutorIds,
        bytes[] memory enforcedOptions_
    ) {
        if (endpoint_ == address(0) || localExecutor_ == address(0)) revert ZeroAddress();
        if (block.chainid > type(uint32).max) revert InvalidLocalChain();
        // DAY-903: the official endpoint is per-chain (canonical 0x1a44… on
        // Ethereum/BSC/Polygon/Base/Arbitrum; ALT 0x6F47… on Monad/Plasma/
        // Robinhood). Never accept a caller-supplied endpoint blindly.
        if (endpoint_ != _officialEndpointForChain(uint32(block.chainid))) revert EndpointNotOfficial();
        if (endpoint_.code.length == 0) revert AddressHasNoCode();
        uint32 expectedLocalEid = _officialLocalEid();
        if (ILayerZeroEndpointV2(endpoint_).eid() != expectedLocalEid) revert InvalidLocalChain();
        if (
            dayChainIds.length != endpointIds.length || dayChainIds.length != peerTransportIds.length
                || dayChainIds.length != peerExecutorIds.length || dayChainIds.length != enforcedOptions_.length
        ) revert InvalidArrayLengths();

        transportEndpoint = endpoint_;
        localExecutor = localExecutor_;
        localDayChainId = uint32(block.chainid);
        localEid = expectedLocalEid;

        for (uint256 i; i < dayChainIds.length; ++i) {
            uint32 dayChainId = dayChainIds[i];
            uint32 eid = endpointIds[i];
            bytes32 peerTransport = peerTransportIds[i];
            bytes32 peerExecutor = peerExecutorIds[i];
            bytes memory options = enforcedOptions_[i];
            if (
                dayChainId == 0 || dayChainId == localDayChainId || eid == 0 || eid == localEid
                    || peerTransport == bytes32(0) || peerExecutor == bytes32(0)
            ) {
                revert InvalidPeer();
            }
            if (eid != _officialEidForDayChain(dayChainId)) revert InvalidPeer();
            if (!ILayerZeroEndpointV2(endpoint_).isSupportedEid(eid)) revert InvalidPeer();
            if (!_isCanonicalOrderedReceiveOptions(options)) revert InvalidOptions();
            if (layerZeroEids[dayChainId] != 0 || dayChainsByEid[eid] != 0) revert DuplicatePeer();
            layerZeroEids[dayChainId] = eid;
            dayChainsByEid[eid] = dayChainId;
            peerTransports[dayChainId] = peerTransport;
            peerExecutors[dayChainId] = peerExecutor;
            _enforcedOptions[dayChainId] = options;
        }
    }

    function enforcedOptions(uint32 dayChainId) external view returns (bytes memory) {
        return _enforcedOptions[dayChainId];
    }

    function encodeMessage(WithdrawalContext calldata context) external pure returns (bytes memory) {
        return _encodeMessage(context);
    }

    function quoteMessage(WithdrawalContext calldata context) external view returns (uint256 nativeFee) {
        _validateSourceContext(context);
        MessagingFee memory fee = ILayerZeroEndpointV2(transportEndpoint).quote(_params(context), address(this));
        if (fee.lzTokenFee != 0) revert FeeMismatch();
        return fee.nativeFee;
    }

    function sendMessage(WithdrawalContext calldata context) external payable returns (bytes32 messageId) {
        _validateSourceContext(context);
        MessagingParams memory params = _params(context);
        MessagingFee memory fee = ILayerZeroEndpointV2(transportEndpoint).quote(params, address(this));
        if (fee.lzTokenFee != 0 || msg.value != fee.nativeFee) revert FeeMismatch();
        MessagingReceipt memory receipt =
            ILayerZeroEndpointV2(transportEndpoint).send{value: msg.value}(params, localExecutor);
        if (receipt.guid == bytes32(0)) revert InvalidMessage();
        emit OwnerCommandSent(context.dayTxId, context.requestId, receipt.guid, params.dstEid, receipt.nonce);
        return receipt.guid;
    }

    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        uint32 dayChainId = dayChainsByEid[origin.srcEid];
        return dayChainId != 0 && peerTransports[dayChainId] == origin.sender;
    }

    /// @dev Ordered delivery is enforced in addition to independent requestId and GUID replay protection.
    function nextNonce(uint32 sourceEid, bytes32 sender) external view returns (uint64) {
        return receivedNonces[sourceEid][sender] + 1;
    }

    function lzReceive(Origin calldata origin, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
    {
        if (msg.sender != transportEndpoint) revert OnlyEndpoint();
        if (msg.value != 0 || guid == bytes32(0) || origin.nonce == 0) revert InvalidMessage();
        uint32 sourceDayChainId = dayChainsByEid[origin.srcEid];
        if (sourceDayChainId == 0 || peerTransports[sourceDayChainId] != origin.sender) revert InvalidSource();
        if (origin.nonce != receivedNonces[origin.srcEid][origin.sender] + 1) revert NonceGap();
        (bytes32 domain, uint8 version, uint8 action, WithdrawalContext memory context) =
            abi.decode(message, (bytes32, uint8, uint8, WithdrawalContext));
        if (domain != MESSAGE_DOMAIN || version != MESSAGE_VERSION || action != WITHDRAWAL_ACTION) {
            revert InvalidMessage();
        }
        _validateReceivedContext(context, sourceDayChainId, origin.sender);
        if (receivedPayloadHashes[guid] != bytes32(0) || consumedGuids[guid]) revert GuidAlreadyReceived();
        if (receivedRequestGuids[context.requestId] != bytes32(0) || consumedRequests[context.requestId]) {
            revert RequestAlreadyReceived();
        }
        receivedPayloadHashes[guid] = keccak256(message);
        receivedRequestGuids[context.requestId] = guid;
        receivedNonces[origin.srcEid][origin.sender] = origin.nonce;
        emit OwnerCommandReceived(context.dayTxId, context.requestId, guid, origin.srcEid, origin.nonce);
    }

    function verifyAndConsumeMessage(WithdrawalContext calldata context, bytes calldata transportProof)
        external
        returns (bytes32 guid)
    {
        if (msg.sender != localExecutor) revert OnlyLocalExecutor();
        _validateDestinationContext(context);
        if (transportProof.length != 32) revert ProofNotReceived();
        guid = abi.decode(transportProof, (bytes32));
        if (guid == bytes32(0) || receivedRequestGuids[context.requestId] != guid) revert ProofNotReceived();
        if (consumedGuids[guid]) revert GuidAlreadyConsumed();
        if (consumedRequests[context.requestId]) revert RequestAlreadyConsumed();
        if (receivedPayloadHashes[guid] != keccak256(_encodeMessage(context))) revert ProofNotReceived();
        consumedGuids[guid] = true;
        consumedRequests[context.requestId] = true;
        delete receivedPayloadHashes[guid];
        delete receivedRequestGuids[context.requestId];
        emit OwnerCommandConsumed(context.dayTxId, context.requestId, guid);
    }

    function _params(WithdrawalContext calldata context) internal view returns (MessagingParams memory params) {
        uint32 dstEid = layerZeroEids[context.destinationChainId];
        bytes32 receiver = peerTransports[context.destinationChainId];
        if (dstEid == 0 || receiver == bytes32(0)) revert InvalidDestination();
        params = MessagingParams({
            dstEid: dstEid,
            receiver: receiver,
            message: _encodeMessage(context),
            options: _enforcedOptions[context.destinationChainId],
            payInLzToken: false
        });
    }

    function _validateSourceContext(WithdrawalContext calldata context) internal view {
        if (msg.sender != localExecutor) revert OnlyLocalExecutor();
        _validateCommonContext(context);
        if (
            context.sourceChainId != localDayChainId
                || context.sourceExecutor != bytes32(uint256(uint160(localExecutor)))
                || peerExecutors[context.destinationChainId] != context.destinationExecutor
                || layerZeroEids[context.destinationChainId] == 0
        ) revert InvalidSource();
    }

    function _validateDestinationContext(WithdrawalContext calldata context) internal view {
        _validateCommonContext(context);
        if (
            context.destinationChainId != localDayChainId
                || context.destinationExecutor != bytes32(uint256(uint160(localExecutor)))
                || peerExecutors[context.sourceChainId] != context.sourceExecutor
                || layerZeroEids[context.sourceChainId] == 0
        ) revert InvalidDestination();
    }

    function _validateReceivedContext(WithdrawalContext memory context, uint32 sourceDayChainId, bytes32 sourcePeer)
        internal
        view
    {
        _validateCommonContext(context);
        if (
            peerTransports[sourceDayChainId] != sourcePeer || context.sourceChainId != sourceDayChainId
                || context.sourceExecutor != peerExecutors[sourceDayChainId]
                || context.destinationChainId != localDayChainId
                || context.destinationExecutor != bytes32(uint256(uint160(localExecutor)))
        ) revert InvalidDestination();
    }

    function _validateCommonContext(WithdrawalContext memory context) internal pure {
        if (
            context.requestId == bytes32(0) || context.dayTxId == bytes32(0) || context.controller == address(0)
                || context.sourceChainId == 0 || context.sourceExecutor == bytes32(0)
                || context.sourceRouteHash == bytes32(0) || context.originOwner == bytes32(0)
                || context.originToken == bytes32(0) || context.originBridgeToken == bytes32(0)
                || context.destinationChainId == 0 || context.destinationExecutor == bytes32(0)
                || context.destinationRouteHash == bytes32(0) || context.opportunityId == bytes32(0)
                || context.adapterId == bytes32(0)
                || (context.fullRefund ? context.positionAmount != 0 : context.positionAmount == 0)
                || context.minBridgeReturnAmount == 0 || context.minReturnAmount == 0 || context.deadline == 0
                || context.adapterDataHash == bytes32(0)
        ) revert InvalidContext();
    }

    function _encodeMessage(WithdrawalContext memory context) internal pure returns (bytes memory) {
        return abi.encode(MESSAGE_DOMAIN, MESSAGE_VERSION, WITHDRAWAL_ACTION, context);
    }

    /// @dev DAY-903: the official Endpoint V2 address per chain. Ethereum, BSC,
    ///      Polygon, Base, and Arbitrum share the canonical deployment; Monad,
    ///      Plasma, and Robinhood run the ALT deployment (LZ metadata 2026-07-17).
    function _officialEndpointForChain(uint32 chainId) private pure returns (address) {
        if (chainId == 143 || chainId == 9745 || chainId == 4663) {
            return OFFICIAL_EVM_ENDPOINT_V2_ALT;
        }
        return OFFICIAL_EVM_ENDPOINT_V2;
    }

    function _officialLocalEid() private view returns (uint32) {
        if (block.chainid == 8453) return BASE_EID;
        if (block.chainid == 42161) return ARBITRUM_EID;
        // DAY-903 expansion tier
        if (block.chainid == 1) return ETHEREUM_EID;
        if (block.chainid == 56) return BSC_EID;
        if (block.chainid == 137) return POLYGON_EID;
        if (block.chainid == 143) return MONAD_EID;
        if (block.chainid == 9745) return PLASMA_EID;
        if (block.chainid == 4663) return ROBINHOOD_EID;
        revert InvalidLocalChain();
    }

    function _officialEidForDayChain(uint32 dayChainId) private pure returns (uint32) {
        if (dayChainId == 8453) return BASE_EID;
        if (dayChainId == 42161) return ARBITRUM_EID;
        if (dayChainId == 784) return SUI_EID;
        // DAY-903 expansion tier
        if (dayChainId == 1) return ETHEREUM_EID;
        if (dayChainId == 56) return BSC_EID;
        if (dayChainId == 137) return POLYGON_EID;
        if (dayChainId == 143) return MONAD_EID;
        if (dayChainId == 9745) return PLASMA_EID;
        if (dayChainId == 4663) return ROBINHOOD_EID;
        revert InvalidPeer();
    }

    /// @dev Canonical Type-3 options: one non-zero-gas lzReceive option with no value,
    ///      followed by ordered execution. Native drops and arbitrary options are forbidden.
    function _isCanonicalOrderedReceiveOptions(bytes memory options) private pure returns (bool) {
        if (
            options.length != 26 || uint8(options[0]) != 0 || uint8(options[1]) != 3 || uint8(options[2]) != 1
                || uint8(options[3]) != 0 || uint8(options[4]) != 17 || uint8(options[5]) != 1
                || uint8(options[22]) != 1 || uint8(options[23]) != 0 || uint8(options[24]) != 1
                || uint8(options[25]) != 4
        ) return false;
        uint128 receiveGas;
        assembly {
            receiveGas := shr(128, mload(add(add(options, 0x20), 6)))
        }
        return receiveGas != 0;
    }
}
