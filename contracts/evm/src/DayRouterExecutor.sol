// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {IDayWithdrawalVerifier} from "./IDayWithdrawalTransport.sol";
import {IDaySwapAdapter} from "./DayUniswapV3SwapAdapter.sol";
import {DayOriginBoundPosition, DayOriginBoundPositionFactory} from "./DayOriginBoundPosition.sol";

interface IERC20DayExecutor {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWrappedNativeDayExecutor {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IMayanForwarderDayExecutor {
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function forwardERC20(
        address tokenIn,
        uint256 amountIn,
        PermitParams calldata permit,
        address protocol,
        bytes calldata protocolData
    ) external payable;
}

interface IMayanMctpDayExecutor {
    struct BridgeWithFeeParams {
        uint8 payloadType;
        bytes32 destAddr;
        uint64 gasDrop;
        uint64 redeemFee;
        uint64 burnAmount;
        bytes32 burnToken;
        bytes32 customPayload;
    }

    function bridgeWithFee(
        address tokenIn,
        uint256 amountIn,
        uint64 redeemFee,
        uint64 gasDrop,
        bytes32 destAddr,
        uint32 destDomain,
        uint8 payloadType,
        bytes calldata customPayload
    ) external payable;

    function redeemWithFee(
        bytes calldata cctpMessage,
        bytes calldata cctpAttestation,
        bytes calldata wormholeSignedVaa,
        BridgeWithFeeParams calldata bridgeParams
    ) external payable;
}

/// @notice Constructor-pinned protocol adapter used by DayRouterExecutor.
/// @dev The adapter, not this generic executor, owns protocol-specific calldata validation.
///      A binding is immutable after deployment: adding or changing an adapter requires a new
///      executor deployment and audit.
interface IDayRouterAdapter {
    function deposit(
        bytes32 dayTxId,
        address controller,
        bytes32 opportunityId,
        bytes32 destinationToken,
        address inputToken,
        uint256 inputAmount,
        address receiptOwner,
        bytes calldata
    ) external returns (uint256 positionAmount);

    function positionReceiptToken() external view returns (address);
    function positionVenue() external view returns (address);
    function positionKind() external view returns (uint8);
}

/**
 * @title DayRouterExecutor
 * @notice Immutable execution boundary for DAY EVM cross-chain deposits and reverse withdrawals.
 * @dev This contract is an architecture surface, not a live adapter claim. A production deployment
 *      is executable only for adapter addresses whose implementation and protocol integration have
 *      separately been audited and verified on the destination chain.
 *
 * Mayan MCTP custom action compatibility:
 * - the source sends `abi.encode(DepositIntent)` as Mayan's custom payload;
 * - Mayan commits `keccak256(customPayload)` in BridgeWithFeeParams;
 * - this executor calls redeemWithFee itself, validates that commitment, measures the minted token
 *   balance delta, and deposits through a constructor-pinned adapter in the same transaction.
 *
 * Security properties:
 * - dayTxId and withdrawal replay protection;
 * - controller, source/destination route, tokens, opportunity, adapter, minimums, deadline and return
 *   route are all payload-bound;
 * - no arbitrary target calls, delegatecall, adapter setters, peer setters or admin-selected rescue;
 * - all transfers use balance deltas, so pre-existing stray balances cannot satisfy a route or payout;
 * - a guardian can pause new deposits; source-wallet exits/refunds and reverse returns stay available;
 * - there is no rescue function: neither owner, guardian nor treasury can extract stray balances.
 *
 * Deployment assumptions:
 * - `mayanMctp` is the audited official MCTP deployment whose `redeemWithFee` verifies that the
 *   supplied bridge parameters, including the custom-payload hash, match the attested VAA;
 * - `withdrawalVerifier` is a real audited transport verifier. A mock or permissive verifier makes
 *   cross-chain withdrawals unsafe and MUST NOT be treated as a live configuration.
 */
contract DayRouterExecutor {
    uint8 public constant MAYAN_CUSTOM_PAYLOAD = 2;
    uint64 public constant POST_BRIDGE_SWAP_WINDOW = 30 minutes;
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct Route {
        uint32 chainId;
        uint32 mctpDomain;
        bytes32 owner;
        bytes32 token;
        bytes32 bridgeToken;
        bytes32 executor;
    }

    struct DepositIntent {
        bytes32 dayTxId;
        address controller;
        Route source;
        Route destination;
        bytes32 opportunityId;
        bytes32 adapterId;
        uint256 sourceAmount;
        uint256 sourceBridgeAmount;
        uint256 minDestinationAmount;
        uint256 minBridgeReturnAmount;
        uint256 minReturnAmount;
        uint64 deadline;
        bytes32 adapterDataHash;
    }

    struct ReturnIntent {
        bytes32 dayTxId;
        bytes32 requestId;
        bytes32 withdrawalId;
        address controller;
        Route source;
        Route destination;
        bytes32 opportunityId;
        bytes32 adapterId;
        uint256 amount;
        uint256 minBridgeReturnAmount;
        uint256 minAmount;
        uint64 deadline;
    }

    struct RedeemProof {
        bytes cctpMessage;
        bytes cctpAttestation;
        bytes wormholeSignedVaa;
        IMayanMctpDayExecutor.BridgeWithFeeParams bridgeParams;
    }

    struct WithdrawalRequest {
        bytes32 dayTxId;
        address controller;
        Route source;
        Route destination;
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

    struct Position {
        address controller;
        bytes32 intentHash;
        Route source;
        Route destination;
        bytes32 opportunityId;
        bytes32 adapterId;
        address adapter;
        address positionAccount;
        address asset;
        uint256 principalAmount;
        uint256 initialPosition;
        uint256 remainingPosition;
        uint256 minBridgeReturnAmount;
        uint256 minReturnAmount;
        uint64 depositDeadline;
    }

    struct ExitParams {
        uint256 positionAmount;
        uint256 minBridgeReturnAmount;
        uint256 minReturnAmount;
        uint64 returnDeadline;
        uint64 redeemFee;
        bytes32 sourceRequestId;
    }

    address public owner;
    address public pendingOwner;
    address public immutable guardian;
    address public immutable treasury;
    address public immutable mayanForwarder;
    address public immutable mayanMctp;
    address public immutable withdrawalVerifier;
    address public immutable positionFactory;
    address public immutable withdrawalTransportEndpoint;
    address public immutable sourceSwapAdapter;
    address public immutable swapBridgeToken;
    address public immutable wrappedNative;
    uint32 public immutable localChainId;
    bool public paused;

    mapping(bytes32 => address) public adapters;
    mapping(uint32 => bytes32) public peerExecutors;
    mapping(bytes32 => bool) public sourceStarted;
    mapping(bytes32 => bool) public destinationExecuted;
    mapping(bytes32 => bool) public returnExecuted;
    mapping(bytes32 => uint256) public withdrawalNonces;
    mapping(bytes32 => uint256) public sourceWithdrawalNonces;
    mapping(bytes32 => bool) public sourceWithdrawalRequested;
    mapping(bytes32 => bytes32) public sourceWithdrawalCommitments;
    mapping(bytes32 => bool) public verifiedWithdrawalExecuted;
    mapping(bytes32 => Position) private _positions;

    bool private _locked;

    error NotOwner();
    error NotPendingOwner();
    error NotGuardian();
    error NotController();
    error Paused();
    error NotPaused();
    error Reentrancy();
    error ZeroAddress();
    error InvalidRoleSeparation();
    error InvalidArrayLengths();
    error DuplicateBinding();
    error AddressHasNoCode();
    error InvalidDayTxId();
    error InvalidRoute();
    error InvalidToken();
    error InvalidAmount();
    error DeadlineExpired();
    error IntentAlreadyStarted();
    error IntentAlreadyExecuted();
    error ReturnAlreadyExecuted();
    error AdapterNotPinned();
    error PeerNotPinned();
    error PayloadMismatch();
    error UnsupportedRoute();
    error BalanceDeltaMismatch();
    error MinimumNotMet();
    error PositionNotFound();
    error PositionAmountExceeded();
    error TransferFailed();
    error RefundNotAvailable();
    error VerifiedWithdrawalRequired();
    error WithdrawalProofInvalid();
    error WithdrawalRequestMismatch();
    error WithdrawalTransportFeeMismatch();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedBy(address indexed guardian);
    event UnpausedBy(address indexed owner);
    event SourceDepositStarted(
        bytes32 indexed dayTxId,
        address indexed controller,
        bytes32 indexed intentHash,
        uint32 destinationChainId,
        uint256 amount
    );
    event DestinationDepositExecuted(
        bytes32 indexed dayTxId,
        address indexed controller,
        bytes32 indexed adapterId,
        uint256 receivedAmount,
        uint256 positionAmount
    );
    event SameChainDepositExecuted(
        bytes32 indexed dayTxId,
        address indexed controller,
        bytes32 indexed adapterId,
        address receiptOwner,
        uint256 inputAmount,
        uint256 positionAmount
    );
    event OriginBoundPositionCreated(
        bytes32 indexed dayTxId,
        address indexed positionAccount,
        bytes32 indexed originOwner,
        bytes32 bindingHash
    );
    event WithdrawalReturned(
        bytes32 indexed dayTxId,
        bytes32 indexed withdrawalId,
        address indexed controller,
        uint32 sourceChainId,
        uint256 outputAmount,
        bytes32 returnPayloadHash
    );
    event ReturnRedeemed(
        bytes32 indexed dayTxId, bytes32 indexed withdrawalId, address indexed controller, uint256 receivedAmount
    );
    event SourceWithdrawalRequested(
        bytes32 indexed dayTxId,
        bytes32 indexed requestId,
        address indexed controller,
        uint32 destinationChainId,
        bytes32 payloadHash
    );
    event VerifiedWithdrawalConsumed(bytes32 indexed dayTxId, bytes32 indexed requestId, bytes32 indexed withdrawalId);
    event WithdrawalTransportPublished(
        bytes32 indexed dayTxId,
        bytes32 indexed requestId,
        bytes32 indexed messageId,
        bytes32 requestHash,
        bytes32 payloadHash
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(
        address owner_,
        address guardian_,
        address treasury_,
        address mayanForwarder_,
        address mayanMctp_,
        address withdrawalVerifier_,
        address positionFactory_,
        address sourceSwapAdapter_,
        bytes32[] memory adapterIds,
        address[] memory adapterAddresses,
        uint32[] memory peerChainIds,
        bytes32[] memory peerAddresses
    ) {
        if (
            owner_ == address(0) || guardian_ == address(0) || treasury_ == address(0) || mayanForwarder_ == address(0)
                || mayanMctp_ == address(0) || withdrawalVerifier_ == address(0) || positionFactory_ == address(0)
        ) revert ZeroAddress();
        if (owner_ == guardian_ || owner_ == treasury_ || guardian_ == treasury_) {
            revert InvalidRoleSeparation();
        }
        if (adapterIds.length != adapterAddresses.length || peerChainIds.length != peerAddresses.length) {
            revert InvalidArrayLengths();
        }
        _requireCode(mayanForwarder_);
        _requireCode(mayanMctp_);
        _requireCode(withdrawalVerifier_);
        _requireCode(positionFactory_);

        owner = owner_;
        guardian = guardian_;
        treasury = treasury_;
        mayanForwarder = mayanForwarder_;
        mayanMctp = mayanMctp_;
        withdrawalVerifier = withdrawalVerifier_;
        positionFactory = positionFactory_;
        if (block.chainid > type(uint32).max) revert InvalidRoute();
        localChainId = uint32(block.chainid);
        if (IDayWithdrawalVerifier(withdrawalVerifier_).localDayChainId() != localChainId) revert InvalidRoute();
        address withdrawalTransportEndpoint_ = IDayWithdrawalVerifier(withdrawalVerifier_).transportEndpoint();
        _requireCode(withdrawalTransportEndpoint_);
        withdrawalTransportEndpoint = withdrawalTransportEndpoint_;

        if (sourceSwapAdapter_ != address(0)) {
            _requireCode(sourceSwapAdapter_);
            if (IDaySwapAdapter(sourceSwapAdapter_).executor() != address(this)) revert InvalidRoute();
            address swapBridgeToken_ = IDaySwapAdapter(sourceSwapAdapter_).bridgeToken();
            address wrappedNative_ = IDaySwapAdapter(sourceSwapAdapter_).wrappedNative();
            _requireCode(swapBridgeToken_);
            _requireCode(wrappedNative_);
            sourceSwapAdapter = sourceSwapAdapter_;
            swapBridgeToken = swapBridgeToken_;
            wrappedNative = wrappedNative_;
        }

        for (uint256 i; i < adapterIds.length; ++i) {
            if (adapterIds[i] == bytes32(0) || adapterAddresses[i] == address(0)) {
                revert InvalidRoute();
            }
            if (adapters[adapterIds[i]] != address(0)) revert DuplicateBinding();
            _requireCode(adapterAddresses[i]);
            adapters[adapterIds[i]] = adapterAddresses[i];
        }
        for (uint256 i; i < peerChainIds.length; ++i) {
            if (peerChainIds[i] == 0 || peerAddresses[i] == bytes32(0)) revert InvalidRoute();
            if (peerExecutors[peerChainIds[i]] != bytes32(0)) revert DuplicateBinding();
            if (IDayWithdrawalVerifier(withdrawalVerifier_).peerExecutors(peerChainIds[i]) != peerAddresses[i]) {
                revert InvalidRoute();
            }
            peerExecutors[peerChainIds[i]] = peerAddresses[i];
        }

        emit OwnershipTransferred(address(0), owner_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == guardian || newOwner == treasury) revert InvalidRoleSeparation();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        paused = true;
        emit PausedBy(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit UnpausedBy(msg.sender);
    }

    function hashDepositIntent(DepositIntent calldata intent) external pure returns (bytes32) {
        return keccak256(abi.encode(intent));
    }

    function hashReturnIntent(ReturnIntent calldata intent) external pure returns (bytes32) {
        return keccak256(abi.encode(intent));
    }

    function getPosition(bytes32 dayTxId) external view returns (Position memory) {
        return _positions[dayTxId];
    }

    /// @notice Original-source wallet creates the exact withdrawal command that a pinned transport
    ///         must attest to the destination executor. Emission is not transport completion.
    function requestWithdrawal(WithdrawalRequest calldata request)
        external
        payable
        nonReentrant
        returns (bytes32 requestId)
    {
        if (request.dayTxId == bytes32(0) || request.controller != msg.sender) {
            revert NotController();
        }
        if (
            request.source.chainId != localChainId || request.source.executor != _evmBytes32(address(this))
                || request.source.owner != _evmBytes32(msg.sender) || request.destination.chainId == localChainId
        ) revert InvalidRoute();
        if (peerExecutors[request.destination.chainId] != request.destination.executor) {
            revert PeerNotPinned();
        }
        if (
            request.opportunityId == bytes32(0) || request.adapterId == bytes32(0)
                || request.deadline <= block.timestamp || request.adapterDataHash == bytes32(0)
                || request.minBridgeReturnAmount == 0 || request.minReturnAmount == 0
                || (request.fullRefund ? request.positionAmount != 0 : request.positionAmount == 0)
        ) revert InvalidAmount();

        uint256 nonce = ++sourceWithdrawalNonces[request.dayTxId];
        requestId = keccak256(abi.encode(request, nonce));
        sourceWithdrawalRequested[requestId] = true;
        sourceWithdrawalCommitments[requestId] = _withdrawalReturnCommitment(request);
        bytes32 requestHash = keccak256(abi.encode(requestId, request));
        IDayWithdrawalVerifier.WithdrawalContext memory context = _withdrawalContext(requestId, request);
        bytes memory payload = IDayWithdrawalVerifier(withdrawalVerifier).encodeMessage(context);
        uint256 messageFee = IDayWithdrawalVerifier(withdrawalVerifier).quoteMessage(context);
        if (msg.value != messageFee) revert WithdrawalTransportFeeMismatch();
        bytes32 messageId = IDayWithdrawalVerifier(withdrawalVerifier).sendMessage{value: messageFee}(context);
        if (messageId == bytes32(0)) revert WithdrawalProofInvalid();
        emit SourceWithdrawalRequested(
            request.dayTxId, requestId, request.controller, request.destination.chainId, requestHash
        );
        emit WithdrawalTransportPublished(request.dayTxId, requestId, messageId, requestHash, keccak256(payload));
    }

    /// @notice Fund the source route, optionally exact-output swap through the immutable adapter,
    ///         and bridge the exact payload-bound bridge amount through Mayan MCTP.
    function initiateDeposit(DepositIntent calldata intent, uint64 redeemFee)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        _validateSourceIntent(intent);
        if (sourceStarted[intent.dayTxId]) revert IntentAlreadyStarted();
        sourceStarted[intent.dayTxId] = true;

        bool nativeSource = _isNative(intent.source.token);
        address sourceToken = nativeSource ? wrappedNative : _evmAddress(intent.source.token);
        address bridgeToken = _evmAddress(intent.source.bridgeToken);
        uint256 beforeSource = _balanceOf(sourceToken, address(this));
        uint256 beforeBridge = sourceToken == bridgeToken ? beforeSource : _balanceOf(bridgeToken, address(this));
        uint256 transportValue = _fundSource(sourceToken, nativeSource, intent.sourceAmount);
        uint256 bridgeAmount = _prepareBridgeAsset(intent, sourceToken, bridgeToken, beforeSource, beforeBridge);
        bytes memory customPayload = abi.encode(intent);
        bytes memory protocolData = abi.encodeCall(
            IMayanMctpDayExecutor.bridgeWithFee,
            (
                bridgeToken,
                bridgeAmount,
                redeemFee,
                uint64(0),
                intent.destination.executor,
                intent.destination.mctpDomain,
                MAYAN_CUSTOM_PAYLOAD,
                customPayload
            )
        );
        _approveExact(bridgeToken, mayanForwarder, bridgeAmount);
        IMayanForwarderDayExecutor(mayanForwarder).forwardERC20{value: transportValue}(
            bridgeToken,
            bridgeAmount,
            IMayanForwarderDayExecutor.PermitParams(0, 0, 0, bytes32(0), bytes32(0)),
            mayanMctp,
            protocolData
        );
        _approveExact(bridgeToken, mayanForwarder, 0);

        if (_balanceOf(sourceToken, address(this)) != beforeSource) revert BalanceDeltaMismatch();
        if (sourceToken != bridgeToken && _balanceOf(bridgeToken, address(this)) != beforeBridge) {
            revert BalanceDeltaMismatch();
        }
        emit SourceDepositStarted(
            intent.dayTxId, intent.controller, keccak256(customPayload), intent.destination.chainId, intent.sourceAmount
        );
    }

    /// @notice Same-chain deposits mint venue receipts directly to the depositor. DAY records no
    ///         position and has no withdrawal authority; the user exits the venue directly.
    function depositSameChain(DepositIntent calldata intent, bytes calldata adapterData)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 positionAmount)
    {
        address adapter = _validateSameChainIntent(intent, adapterData);
        if (sourceStarted[intent.dayTxId] || destinationExecuted[intent.dayTxId]) revert IntentAlreadyExecuted();
        sourceStarted[intent.dayTxId] = true;
        destinationExecuted[intent.dayTxId] = true;

        address token = _evmAddress(intent.source.token);
        uint256 beforeBalance = _balanceOf(token, address(this));
        _safeTransferFrom(token, msg.sender, address(this), intent.sourceAmount);
        if (_balanceOf(token, address(this)) - beforeBalance != intent.sourceAmount) revert BalanceDeltaMismatch();
        _approveExact(token, adapter, intent.sourceAmount);
        positionAmount = _depositThroughAdapter(
            intent, adapterData, adapter, token, intent.sourceAmount, intent.controller
        );
        _approveExact(token, adapter, 0);
        if (_balanceOf(token, address(this)) != beforeBalance) revert BalanceDeltaMismatch();
        if (positionAmount < intent.minDestinationAmount) revert MinimumNotMet();
        if (positionAmount > type(uint192).max) revert InvalidAmount();

        emit SameChainDepositExecuted(
            intent.dayTxId,
            intent.controller,
            intent.adapterId,
            intent.controller,
            intent.sourceAmount,
            positionAmount
        );
    }

    /// @notice Redeem a Mayan custom action and deposit through the pinned opportunity adapter.
    ///         Any validation, redeem, approval or adapter failure reverts the entire transaction.
    function redeemAndDeposit(DepositIntent calldata intent, bytes calldata adapterData, RedeemProof calldata proof)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        address adapter = _validateDestinationIntent(intent, adapterData, proof.bridgeParams);
        if (destinationExecuted[intent.dayTxId]) revert IntentAlreadyExecuted();
        destinationExecuted[intent.dayTxId] = true;

        address token = _evmAddress(intent.destination.bridgeToken);
        uint256 beforeBalance = _balanceOf(token, address(this));
        IMayanMctpDayExecutor(mayanMctp).redeemWithFee{value: msg.value}(
            proof.cctpMessage, proof.cctpAttestation, proof.wormholeSignedVaa, proof.bridgeParams
        );
        uint256 redeemedBalance = _balanceOf(token, address(this));
        uint256 received = redeemedBalance - beforeBalance;
        if (received == 0) revert InvalidAmount();

        DayOriginBoundPosition positionAccount = _deployOriginBoundPosition(intent, adapter, token);
        _approveExact(token, adapter, received);
        uint256 positionAmount =
            _depositThroughAdapter(intent, adapterData, adapter, token, received, address(positionAccount));
        _approveExact(token, adapter, 0);
        if (_balanceOf(token, address(this)) != beforeBalance) revert BalanceDeltaMismatch();
        if (positionAmount < intent.minDestinationAmount) revert MinimumNotMet();
        if (positionAmount > type(uint192).max) revert InvalidAmount();

        Position storage position = _positions[intent.dayTxId];
        position.controller = intent.controller;
        position.intentHash = keccak256(abi.encode(intent));
        position.source = intent.source;
        position.destination = intent.destination;
        position.opportunityId = intent.opportunityId;
        position.adapterId = intent.adapterId;
        position.adapter = adapter;
        position.positionAccount = address(positionAccount);
        position.asset = token;
        position.principalAmount = received;
        position.initialPosition = positionAmount;
        position.remainingPosition = positionAmount;
        position.minBridgeReturnAmount = intent.minBridgeReturnAmount;
        position.minReturnAmount = intent.minReturnAmount;
        position.depositDeadline = intent.deadline;

        emit DestinationDepositExecuted(intent.dayTxId, intent.controller, intent.adapterId, received, positionAmount);
    }

    function _depositThroughAdapter(
        DepositIntent calldata intent,
        bytes calldata adapterData,
        address adapter,
        address token,
        uint256 received,
        address receiptOwner
    ) internal returns (uint256) {
        return IDayRouterAdapter(adapter)
            .deposit(
                intent.dayTxId,
                intent.controller,
                intent.opportunityId,
                intent.destination.token,
                token,
                received,
                receiptOwner,
                adapterData
            );
    }

    function _deployOriginBoundPosition(DepositIntent calldata intent, address adapter, address token)
        internal
        returns (DayOriginBoundPosition positionAccount)
    {
        DayOriginBoundPosition.Binding memory binding = DayOriginBoundPosition.Binding({
            authenticatedRouter: address(this),
            dayTxId: intent.dayTxId,
            controller: intent.controller,
            originOwner: intent.source.owner,
            sourceRouteHash: keccak256(abi.encode(intent.source)),
            destinationRouteHash: keccak256(abi.encode(intent.destination)),
            opportunityId: intent.opportunityId,
            adapterId: intent.adapterId,
            asset: token,
            receiptToken: IDayRouterAdapter(adapter).positionReceiptToken(),
            venue: IDayRouterAdapter(adapter).positionVenue(),
            positionKind: IDayRouterAdapter(adapter).positionKind()
        });
        bytes32 salt = keccak256(abi.encode(intent.dayTxId, intent.source.owner, intent.opportunityId));
        positionAccount = DayOriginBoundPositionFactory(positionFactory).deploy(salt, binding);
        emit OriginBoundPositionCreated(intent.dayTxId, address(positionAccount), intent.source.owner, positionAccount.bindingHash());
    }

    function _fundSource(address sourceToken, bool nativeSource, uint256 sourceAmount)
        internal
        returns (uint256 transportValue)
    {
        if (nativeSource) {
            if (msg.value < sourceAmount) revert InvalidAmount();
            IWrappedNativeDayExecutor(sourceToken).deposit{value: sourceAmount}();
            return msg.value - sourceAmount;
        }
        _safeTransferFrom(sourceToken, msg.sender, address(this), sourceAmount);
        return msg.value;
    }

    function _prepareBridgeAsset(
        DepositIntent calldata intent,
        address sourceToken,
        address bridgeToken,
        uint256 beforeSource,
        uint256 beforeBridge
    ) internal returns (uint256 bridgeAmount) {
        if (_balanceOf(sourceToken, address(this)) - beforeSource != intent.sourceAmount) {
            revert BalanceDeltaMismatch();
        }
        bridgeAmount = intent.sourceBridgeAmount;
        if (sourceToken == bridgeToken) return bridgeAmount;

        _approveExact(sourceToken, sourceSwapAdapter, intent.sourceAmount);
        uint256 sourceSpent = IDaySwapAdapter(sourceSwapAdapter)
            .swapToBridge(intent.dayTxId, sourceToken, intent.sourceAmount, bridgeAmount, intent.deadline);
        _approveExact(sourceToken, sourceSwapAdapter, 0);
        if (sourceSpent == 0 || sourceSpent > intent.sourceAmount) revert BalanceDeltaMismatch();
        if (_balanceOf(bridgeToken, address(this)) - beforeBridge != bridgeAmount) {
            revert BalanceDeltaMismatch();
        }

        uint256 refund = intent.sourceAmount - sourceSpent;
        if (refund != 0) {
            if (_isNative(intent.source.token)) {
                IWrappedNativeDayExecutor(sourceToken).withdraw(refund);
                _safeNativeTransfer(msg.sender, refund);
            } else {
                _safeTransfer(sourceToken, msg.sender, refund);
            }
        }
        if (_balanceOf(sourceToken, address(this)) != beforeSource) revert BalanceDeltaMismatch();
    }

    /// @notice Source-wallet-controlled partial/full exit. The payout route is the source route committed
    ///         in the original deposit payload; callers cannot substitute a recipient or chain.
    function withdrawAndReturn(
        bytes32 dayTxId,
        uint256 positionAmount,
        uint256 minBridgeReturnAmount,
        uint256 minReturnAmount,
        uint64 returnDeadline,
        uint64 redeemFee,
        bytes calldata adapterData
    ) external payable nonReentrant returns (bytes32 withdrawalId) {
        Position storage position = _positions[dayTxId];
        _requireController(position);
        if (position.source.chainId != localChainId) revert VerifiedWithdrawalRequired();
        if (minReturnAmount < position.minReturnAmount) revert MinimumNotMet();
        withdrawalId = _withdrawAndReturn(
            dayTxId,
            position,
            ExitParams(
                positionAmount,
                minBridgeReturnAmount,
                minReturnAmount,
                returnDeadline,
                redeemFee,
                bytes32(0)
            ),
            adapterData
        );
    }

    /// @notice Source-wallet-only refund path after the original deposit deadline. It exits the
    ///         complete remaining position to the same source route. Pause deliberately leaves this
    ///         user escape hatch open while blocking new principal from entering the system.
    function refundExpiredToSource(bytes32 dayTxId, uint64 returnDeadline, uint64 redeemFee, bytes calldata adapterData)
        external
        payable
        nonReentrant
        returns (bytes32 withdrawalId)
    {
        Position storage position = _positions[dayTxId];
        _requireController(position);
        if (position.source.chainId != localChainId) revert VerifiedWithdrawalRequired();
        if (block.timestamp <= position.depositDeadline) {
            revert RefundNotAvailable();
        }
        withdrawalId = _withdrawAndReturn(
            dayTxId,
            position,
            ExitParams(
                position.remainingPosition,
                _proportionalBridgeFloor(position, position.remainingPosition),
                position.minReturnAmount,
                returnDeadline,
                redeemFee,
                bytes32(0)
            ),
            adapterData
        );
    }

    /// @notice Destination execution of a withdrawal authorized on the original source router.
    /// @dev `transportProof` must be accepted by the immutable verifier. Without a deployed real
    ///      verifier adapter, cross-chain withdrawal remains intentionally unavailable.
    function executeVerifiedWithdrawal(
        bytes32 requestId,
        WithdrawalRequest calldata request,
        bytes calldata transportProof,
        bytes calldata adapterData
    ) external payable nonReentrant returns (bytes32 withdrawalId) {
        Position storage position = _positions[request.dayTxId];
        if (position.controller == address(0)) revert PositionNotFound();
        if (verifiedWithdrawalExecuted[requestId]) revert ReturnAlreadyExecuted();
        _validateWithdrawalRequest(position, request, adapterData);
        IDayWithdrawalVerifier.WithdrawalContext memory context = _withdrawalContext(requestId, request);
        IDayWithdrawalVerifier(withdrawalVerifier).verifyAndConsumeMessage(context, transportProof);
        verifiedWithdrawalExecuted[requestId] = true;

        withdrawalId = _completeVerifiedWithdrawal(position, requestId, request, adapterData);
        emit VerifiedWithdrawalConsumed(request.dayTxId, requestId, withdrawalId);
    }

    function _completeVerifiedWithdrawal(
        Position storage position,
        bytes32 requestId,
        WithdrawalRequest calldata request,
        bytes calldata adapterData
    ) internal returns (bytes32 withdrawalId) {
        uint256 amount = request.positionAmount;
        if (request.fullRefund) {
            if (block.timestamp <= position.depositDeadline) revert RefundNotAvailable();
            amount = position.remainingPosition;
        }
        withdrawalId = _withdrawAndReturn(
            request.dayTxId,
            position,
            ExitParams(
                amount,
                request.minBridgeReturnAmount,
                request.minReturnAmount,
                request.deadline,
                request.redeemFee,
                requestId
            ),
            adapterData
        );
    }

    /// @notice Redeem the reverse custom payload and return the exact original source asset.
    function redeemReturnToOwner(ReturnIntent calldata intent, RedeemProof calldata proof)
        external
        payable
        nonReentrant
    {
        _validateReturnIntent(intent, proof.bridgeParams);
        if (returnExecuted[intent.withdrawalId]) revert ReturnAlreadyExecuted();
        returnExecuted[intent.withdrawalId] = true;

        address token = _evmAddress(intent.source.bridgeToken);
        address recipient = _evmAddress(intent.source.owner);
        uint256 beforeBalance = _balanceOf(token, address(this));
        IMayanMctpDayExecutor(mayanMctp).redeemWithFee{value: msg.value}(
            proof.cctpMessage, proof.cctpAttestation, proof.wormholeSignedVaa, proof.bridgeParams
        );
        uint256 received = _balanceOf(token, address(this)) - beforeBalance;
        if (received == 0) revert InvalidAmount();
        uint256 returnedAmount = _returnSourceAsset(intent, token, recipient, received, beforeBalance);
        if (_balanceOf(token, address(this)) != beforeBalance) revert BalanceDeltaMismatch();

        emit ReturnRedeemed(intent.dayTxId, intent.withdrawalId, intent.controller, returnedAmount);
    }

    function _returnSourceAsset(
        ReturnIntent calldata intent,
        address bridgeToken,
        address recipient,
        uint256 bridgeAmount,
        uint256 beforeBridge
    ) internal returns (uint256 returnedAmount) {
        if (intent.source.token == intent.source.bridgeToken) {
            if (bridgeAmount < intent.minAmount) revert MinimumNotMet();
            _safeTransfer(bridgeToken, recipient, bridgeAmount);
            return bridgeAmount;
        }

        address outputToken = _isNative(intent.source.token) ? wrappedNative : _evmAddress(intent.source.token);
        uint256 beforeOutput = _balanceOf(outputToken, address(this));
        _approveExact(bridgeToken, sourceSwapAdapter, bridgeAmount);
        // The source owner already committed the minimum output. A relay delay after Mayan
        // accepted the return must not permanently expire redemption, so the AMM deadline is
        // derived at execution time while the payload-bound slippage floor remains unchanged.
        uint64 executionDeadline = uint64(block.timestamp) + POST_BRIDGE_SWAP_WINDOW;
        returnedAmount = IDaySwapAdapter(sourceSwapAdapter)
            .swapFromBridge(intent.dayTxId, outputToken, bridgeAmount, intent.minAmount, executionDeadline);
        _approveExact(bridgeToken, sourceSwapAdapter, 0);
        if (
            returnedAmount < intent.minAmount || _balanceOf(outputToken, address(this)) - beforeOutput != returnedAmount
        ) {
            revert BalanceDeltaMismatch();
        }
        if (_isNative(intent.source.token)) {
            IWrappedNativeDayExecutor(outputToken).withdraw(returnedAmount);
            _safeNativeTransfer(recipient, returnedAmount);
        } else {
            _safeTransfer(outputToken, recipient, returnedAmount);
        }
        if (
            _balanceOf(outputToken, address(this)) != beforeOutput
                || _balanceOf(bridgeToken, address(this)) != beforeBridge
        ) revert BalanceDeltaMismatch();
    }

    function _withdrawAndReturn(
        bytes32 dayTxId,
        Position storage position,
        ExitParams memory exit,
        bytes calldata
    ) internal returns (bytes32 withdrawalId) {
        if (exit.positionAmount == 0) {
            revert InvalidAmount();
        }
        if (exit.positionAmount > position.remainingPosition) revert PositionAmountExceeded();
        position.remainingPosition -= exit.positionAmount;

        uint256 beforeBalance = _balanceOf(position.asset, address(this));
        uint256 reportedAmount = DayOriginBoundPosition(position.positionAccount).exit(exit.positionAmount);
        uint256 outputAmount = _balanceOf(position.asset, address(this)) - beforeBalance;
        if (outputAmount == 0 || outputAmount != reportedAmount) revert BalanceDeltaMismatch();
        // The original payload binds separate floors because the destination
        // bridge asset and original source asset can have different units.
        uint256 proportionalFloor = _proportionalBridgeFloor(position, exit.positionAmount);
        if (exit.minBridgeReturnAmount < proportionalFloor || outputAmount < exit.minBridgeReturnAmount) {
            revert MinimumNotMet();
        }
        if (position.source.token == position.source.bridgeToken && outputAmount < exit.minReturnAmount) {
            revert MinimumNotMet();
        }

        uint256 nonce = ++withdrawalNonces[dayTxId];
        withdrawalId = keccak256(abi.encode(dayTxId, nonce));
        bytes32 returnPayloadHash;
        if (position.source.chainId == localChainId) {
            if (
                position.source.token != position.destination.bridgeToken
                    || position.source.bridgeToken != position.source.token
            ) revert UnsupportedRoute();
            _safeTransfer(position.asset, _evmAddress(position.source.owner), outputAmount);
        } else {
            returnPayloadHash = _bridgeReturn(dayTxId, withdrawalId, position, outputAmount, exit);
        }
        if (_balanceOf(position.asset, address(this)) != beforeBalance) {
            revert BalanceDeltaMismatch();
        }

        _emitWithdrawal(position, dayTxId, withdrawalId, outputAmount, returnPayloadHash);
    }

    /// @dev The deposit-time bridge floor describes the complete initial position. Each partial
    ///      exit carries its own floor, but it may never weaken the original protection pro rata.
    ///      Ceiling division prevents repeated small exits from rounding the committed floor down.
    function _proportionalBridgeFloor(Position storage position, uint256 positionAmount)
        internal
        view
        returns (uint256)
    {
        if (position.initialPosition == 0 || positionAmount == 0) revert InvalidAmount();
        uint256 floor = position.minBridgeReturnAmount;
        if (floor > type(uint256).max / positionAmount) revert InvalidAmount();
        uint256 numerator = floor * positionAmount;
        return numerator / position.initialPosition + (numerator % position.initialPosition == 0 ? 0 : 1);
    }

    function _emitWithdrawal(
        Position storage position,
        bytes32 dayTxId,
        bytes32 withdrawalId,
        uint256 outputAmount,
        bytes32 returnPayloadHash
    ) internal {
        emit WithdrawalReturned(
            dayTxId, withdrawalId, position.controller, position.source.chainId, outputAmount, returnPayloadHash
        );
    }

    function _bridgeReturn(
        bytes32 dayTxId,
        bytes32 withdrawalId,
        Position storage position,
        uint256 outputAmount,
        ExitParams memory exit
    ) internal returns (bytes32 payloadHash) {
        if (exit.sourceRequestId == bytes32(0)) revert WithdrawalRequestMismatch();
        // Mayan's burn amount is uint64. Local owner payouts never traverse Mayan and retain
        // the full ERC-20 uint256 amount domain.
        if (outputAmount > type(uint64).max) revert InvalidAmount();
        ReturnIntent memory returnIntent;
        returnIntent.dayTxId = dayTxId;
        returnIntent.requestId = exit.sourceRequestId;
        returnIntent.withdrawalId = withdrawalId;
        returnIntent.controller = position.controller;
        returnIntent.source = position.source;
        returnIntent.destination = position.destination;
        returnIntent.opportunityId = position.opportunityId;
        returnIntent.adapterId = position.adapterId;
        returnIntent.amount = outputAmount;
        returnIntent.minBridgeReturnAmount = exit.minBridgeReturnAmount;
        returnIntent.minAmount = exit.minReturnAmount;
        returnIntent.deadline = exit.returnDeadline;

        bytes memory customPayload = abi.encode(returnIntent);
        payloadHash = keccak256(customPayload);
        bytes memory protocolData = abi.encodeCall(
            IMayanMctpDayExecutor.bridgeWithFee,
            (
                position.asset,
                outputAmount,
                exit.redeemFee,
                uint64(0),
                position.source.executor,
                position.source.mctpDomain,
                MAYAN_CUSTOM_PAYLOAD,
                customPayload
            )
        );
        _approveExact(position.asset, mayanForwarder, outputAmount);
        IMayanForwarderDayExecutor(mayanForwarder).forwardERC20{value: msg.value}(
            position.asset,
            outputAmount,
            IMayanForwarderDayExecutor.PermitParams(0, 0, 0, bytes32(0), bytes32(0)),
            mayanMctp,
            protocolData
        );
        _approveExact(position.asset, mayanForwarder, 0);
    }

    function _validateSourceIntent(DepositIntent calldata intent) internal view {
        _validateIntentCommon(intent, true);
        if (msg.sender != intent.controller) revert NotController();
        if (intent.source.chainId != localChainId) revert InvalidRoute();
        if (intent.source.owner != _evmBytes32(intent.controller)) revert InvalidRoute();
        if (intent.source.executor != _evmBytes32(address(this))) revert InvalidRoute();
        if (intent.destination.chainId == localChainId) revert InvalidRoute();
        if (peerExecutors[intent.destination.chainId] != intent.destination.executor) {
            revert PeerNotPinned();
        }
        if (intent.sourceBridgeAmount > type(uint64).max) revert InvalidAmount();
        if (intent.source.token == intent.source.bridgeToken) {
            if (intent.sourceAmount != intent.sourceBridgeAmount || _isNative(intent.source.token)) {
                revert UnsupportedRoute();
            }
            _requireToken(intent.source.token);
        } else {
            _validateSwapRoute(intent.source.token, intent.source.bridgeToken);
        }
        _requireToken(intent.source.bridgeToken);
    }

    function _validateDestinationIntent(
        DepositIntent calldata intent,
        bytes calldata adapterData,
        IMayanMctpDayExecutor.BridgeWithFeeParams calldata bridgeParams
    ) internal view returns (address adapter) {
        // Mayan has already accepted and transported principal. Destination execution remains
        // permissionless after the source initiation deadline so relay latency cannot strand it.
        _validateIntentCommon(intent, false);
        if (intent.destination.chainId != localChainId) revert InvalidRoute();
        if (intent.destination.owner != _evmBytes32(intent.controller)) revert InvalidRoute();
        if (intent.destination.executor != _evmBytes32(address(this))) revert InvalidRoute();
        if (peerExecutors[intent.source.chainId] != intent.source.executor) revert PeerNotPinned();
        adapter = adapters[intent.adapterId];
        if (adapter == address(0)) revert AdapterNotPinned();
        if (keccak256(adapterData) != intent.adapterDataHash) revert PayloadMismatch();
        _validateMayanCommitment(
            keccak256(abi.encode(intent)),
            intent.destination.executor,
            intent.source.bridgeToken,
            intent.sourceBridgeAmount,
            bridgeParams
        );
        _requireToken(intent.destination.bridgeToken);
    }

    function _validateSameChainIntent(DepositIntent calldata intent, bytes calldata adapterData)
        internal
        view
        returns (address adapter)
    {
        _validateIntentCommon(intent, true);
        bytes32 self = _evmBytes32(address(this));
        bytes32 routeOwner = _evmBytes32(intent.controller);
        if (
            msg.sender != intent.controller || intent.source.chainId != localChainId
                || intent.destination.chainId != localChainId || intent.source.executor != self
                || intent.destination.executor != self || intent.source.owner != routeOwner
                || intent.destination.owner != routeOwner
        ) revert InvalidRoute();
        if (
            intent.source.token != intent.destination.token || intent.source.token != intent.source.bridgeToken
                || intent.source.token != intent.destination.bridgeToken || intent.sourceAmount != intent.sourceBridgeAmount
        ) revert UnsupportedRoute();
        adapter = adapters[intent.adapterId];
        if (adapter == address(0)) revert AdapterNotPinned();
        if (keccak256(adapterData) != intent.adapterDataHash) revert PayloadMismatch();
        _requireToken(intent.source.token);
    }

    function _validateReturnIntent(
        ReturnIntent calldata intent,
        IMayanMctpDayExecutor.BridgeWithFeeParams calldata bridgeParams
    ) internal view {
        if (
            intent.dayTxId == bytes32(0) || intent.requestId == bytes32(0) || intent.withdrawalId == bytes32(0)
                || intent.controller == address(0) || intent.amount == 0
        ) revert InvalidRoute();
        if (intent.source.chainId != localChainId) revert InvalidRoute();
        if (intent.source.executor != _evmBytes32(address(this))) revert InvalidRoute();
        if (peerExecutors[intent.destination.chainId] != intent.destination.executor) {
            revert PeerNotPinned();
        }
        if (intent.source.token != intent.source.bridgeToken) {
            _validateSwapRoute(intent.source.token, intent.source.bridgeToken);
        }
        bytes32 expectedReturnCommitment = sourceWithdrawalCommitments[intent.requestId];
        if (expectedReturnCommitment == bytes32(0) || expectedReturnCommitment != _returnIntentCommitment(intent)) {
            revert WithdrawalRequestMismatch();
        }
        _validateMayanCommitment(
            keccak256(abi.encode(intent)),
            intent.source.executor,
            intent.destination.bridgeToken,
            intent.amount,
            bridgeParams
        );
        _requireToken(intent.source.bridgeToken);
    }

    function _validateSwapRoute(bytes32 sourceToken, bytes32 bridgeToken) internal view {
        if (sourceSwapAdapter == address(0) || bridgeToken != _evmBytes32(swapBridgeToken)) {
            revert UnsupportedRoute();
        }
        address inputToken = _isNative(sourceToken) ? wrappedNative : _evmAddress(sourceToken);
        _requireCode(inputToken);
        if (!IDaySwapAdapter(sourceSwapAdapter).supportsToken(inputToken)) revert UnsupportedRoute();
    }

    function _withdrawalReturnCommitment(WithdrawalRequest calldata request) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                request.dayTxId,
                request.controller,
                request.source,
                request.destination,
                request.opportunityId,
                request.adapterId,
                request.minBridgeReturnAmount,
                request.minReturnAmount,
                request.deadline
            )
        );
    }

    function _withdrawalContext(bytes32 requestId, WithdrawalRequest calldata request)
        internal
        pure
        returns (IDayWithdrawalVerifier.WithdrawalContext memory context)
    {
        context.requestId = requestId;
        context.dayTxId = request.dayTxId;
        context.controller = request.controller;
        context.sourceChainId = request.source.chainId;
        context.sourceExecutor = request.source.executor;
        context.sourceRouteHash = keccak256(abi.encode(request.source));
        context.originOwner = request.source.owner;
        context.originToken = request.source.token;
        context.originBridgeToken = request.source.bridgeToken;
        context.destinationChainId = request.destination.chainId;
        context.destinationExecutor = request.destination.executor;
        context.destinationRouteHash = keccak256(abi.encode(request.destination));
        context.opportunityId = request.opportunityId;
        context.adapterId = request.adapterId;
        context.positionAmount = request.positionAmount;
        context.minBridgeReturnAmount = request.minBridgeReturnAmount;
        context.minReturnAmount = request.minReturnAmount;
        context.deadline = request.deadline;
        context.redeemFee = request.redeemFee;
        context.adapterDataHash = request.adapterDataHash;
        context.fullRefund = request.fullRefund;
    }

    function _returnIntentCommitment(ReturnIntent calldata intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                intent.dayTxId,
                intent.controller,
                intent.source,
                intent.destination,
                intent.opportunityId,
                intent.adapterId,
                intent.minBridgeReturnAmount,
                intent.minAmount,
                intent.deadline
            )
        );
    }

    function _validateWithdrawalRequest(
        Position storage position,
        WithdrawalRequest calldata request,
        bytes calldata adapterData
    ) internal view {
        if (
            request.dayTxId == bytes32(0) || request.controller != position.controller
                || request.opportunityId != position.opportunityId
                || request.adapterId != position.adapterId || keccak256(adapterData) != request.adapterDataHash
                || request.minReturnAmount < position.minReturnAmount
                || request.minBridgeReturnAmount < _proportionalBridgeFloor(
                    position, request.fullRefund ? position.remainingPosition : request.positionAmount
                )
        ) revert WithdrawalRequestMismatch();
        if (
            keccak256(abi.encode(request.source)) != keccak256(abi.encode(position.source))
                || keccak256(abi.encode(request.destination)) != keccak256(abi.encode(position.destination))
        ) revert WithdrawalRequestMismatch();
        if (
            request.source.chainId == localChainId || request.destination.chainId != localChainId
                || request.destination.executor != _evmBytes32(address(this))
                || peerExecutors[request.source.chainId] != request.source.executor
        ) revert InvalidRoute();
        if (request.fullRefund ? request.positionAmount != 0 : request.positionAmount == 0) revert InvalidAmount();
    }

    function _validateIntentCommon(DepositIntent calldata intent, bool enforceInitiationDeadline) internal view {
        if (intent.dayTxId == bytes32(0)) revert InvalidDayTxId();
        if (intent.controller == address(0) || intent.opportunityId == bytes32(0) || intent.adapterId == bytes32(0)) {
            revert InvalidRoute();
        }
        // mctpDomain is a Circle CCTP domain id (uint32). Domain 0 is ethereum mainnet and is
        // VALID — never treat 0 as "unset". Reject only domains outside the allowlist.
        if (
            intent.source.chainId == 0 || intent.destination.chainId == 0
                || !_isSupportedMctpDomain(intent.source.mctpDomain)
                || !_isSupportedMctpDomain(intent.destination.mctpDomain) || intent.source.owner == bytes32(0)
                || intent.destination.owner == bytes32(0) || intent.source.token == bytes32(0)
                || intent.source.bridgeToken == bytes32(0) || intent.destination.token == bytes32(0)
                || intent.destination.bridgeToken == bytes32(0) || intent.source.executor == bytes32(0)
                || intent.destination.executor == bytes32(0)
        ) revert InvalidRoute();
        if (
            intent.sourceAmount == 0 || intent.sourceBridgeAmount == 0 || intent.minDestinationAmount == 0
                || intent.minBridgeReturnAmount == 0 || intent.minReturnAmount == 0
        ) revert InvalidAmount();
        // Mayan bridge amounts are uint64. Bounding the full-position floor to the same domain,
        // while protocol position units are capped at uint192 on deposit, also makes the
        // proportional-floor multiplication provably overflow-free.
        if (intent.minBridgeReturnAmount > type(uint64).max) revert InvalidAmount();
        if (intent.deadline == 0) revert DeadlineExpired();
        if (enforceInitiationDeadline && intent.deadline <= block.timestamp) revert DeadlineExpired();
    }

    /// @notice Circle CCTP / Mayan classic MCTP domain allowlist.
    /// @dev Domain 0 = ethereum (Circle). Prior bytecode treated 0 as unset and bricked eth routes.
    ///      Product homes: ethereum=0, arbitrum=3, base=6. Extended domains kept for rail parity.
    function _isSupportedMctpDomain(uint32 domain) internal pure returns (bool) {
        // 0 ethereum, 1 avalanche, 2 optimism, 3 arbitrum, 4 noble, 5 solana, 6 base, 7 polygon
        if (domain <= 7) return true;
        // 8 sui, 9 aptos, 10 unichain, 11 lineasepolia-like / newer Circle ids as product expands
        if (domain == 8 || domain == 9 || domain == 10 || domain == 11) return true;
        return false;
    }

    function _validateMayanCommitment(
        bytes32 expectedPayloadHash,
        bytes32 expectedExecutor,
        bytes32 expectedBurnToken,
        uint256 expectedBurnAmount,
        IMayanMctpDayExecutor.BridgeWithFeeParams calldata bridgeParams
    ) internal pure {
        if (
            bridgeParams.payloadType != MAYAN_CUSTOM_PAYLOAD || bridgeParams.destAddr != expectedExecutor
                || bridgeParams.gasDrop != 0 || bridgeParams.burnToken != expectedBurnToken
                || bridgeParams.customPayload != expectedPayloadHash
                || uint256(bridgeParams.burnAmount) != expectedBurnAmount
        ) revert PayloadMismatch();
    }

    function _requireController(Position storage position) internal view {
        if (position.controller == address(0)) revert PositionNotFound();
        if (msg.sender != position.controller) revert NotController();
    }

    function _requireToken(bytes32 token) internal view {
        _requireCode(_evmAddress(token));
    }

    function _isNative(bytes32 token) internal pure returns (bool) {
        return token == _evmBytes32(NATIVE_TOKEN);
    }

    function _requireCode(address target) internal view {
        if (target.code.length == 0) revert AddressHasNoCode();
    }

    function _evmBytes32(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _evmAddress(bytes32 account) internal pure returns (address) {
        if (uint256(account) >> 160 != 0) revert InvalidToken();
        address decoded = address(uint160(uint256(account)));
        if (decoded == address(0)) revert InvalidToken();
        return decoded;
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        _requireCode(token);
        (bool ok, bytes memory result) = token.staticcall(abi.encodeCall(IERC20DayExecutor.balanceOf, (account)));
        if (!ok || result.length < 32) revert TransferFailed();
        return abi.decode(result, (uint256));
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20DayExecutor.transfer, (to, amount)));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20DayExecutor.transferFrom, (from, to, amount)));
    }

    function _safeNativeTransfer(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _approveExact(address token, address spender, uint256 amount) internal {
        _callOptionalReturn(token, abi.encodeCall(IERC20DayExecutor.approve, (spender, 0)));
        if (amount != 0) {
            _callOptionalReturn(token, abi.encodeCall(IERC20DayExecutor.approve, (spender, amount)));
        }
    }

    function _callOptionalReturn(address token, bytes memory data) internal {
        _requireCode(token);
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TransferFailed();
        }
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert TransferFailed();
    }
}
