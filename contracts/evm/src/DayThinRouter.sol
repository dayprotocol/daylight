// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/**
 * @title DayThinRouter
 * @notice DAY-346 thin helper router (Base/Arb expansion) — non-custodial.
 * @dev Does NOT take custody of user principal. Only:
 *      - allowlist strategy adapter ids
 *      - yield skim config (default 500 bps, cap 1000)
 *      - planDeposit / planHarvestSkim event accounting
 *
 * Owner signs real strategy txs separately. This contract never holds funds.
 *
 * Invariants:
 * - depositFeeBps always 0
 * - yield skim only on harvested yield
 * - planDeposit always uses msg.sender (no forgeable owner)
 *
 * DAY-828:
 * - no receive() / no rescueEth — pure event emitter must not accept or hold ETH
 * - global pause gates plan* entry points (parity with DayRegistry / Sui router)
 */
contract DayThinRouter {
    address public owner;
    address public pendingOwner;

    uint16 public constant MAX_YIELD_SKIM_BPS = 1000;
    uint16 public constant DEFAULT_YIELD_SKIM_BPS = 500;
    uint16 public constant DEPOSIT_FEE_BPS = 0;
    uint16 public constant WITHDRAW_FEE_BPS = 0;

    error NotOwner();
    error ZeroAddress();
    error NotPendingOwner();
    error StrategyExists();
    error StrategyUnknown();
    error ZeroAmount();
    error StrategyInactive();
    error FeeOutOfBounds();
    error DepositFeeMustBeZero();
    error Paused();
    error NotPaused();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event StrategyRegistered(bytes32 indexed id, bool active);
    event StrategySetActive(bytes32 indexed id, bool active);
    event FeeConfigUpdated(uint16 yieldSkimBps);
    /// @dev NON-AUTHORITATIVE intent log — not a balance/credit proof.
    event DepositPlanned(address indexed owner_, bytes32 indexed strategyId, uint256 amountMicros);
    event HarvestSkimPlanned(
        address indexed owner_,
        bytes32 indexed strategyId,
        uint256 grossYieldMicros,
        uint256 protocolSkimMicros,
        uint256 netYieldMicros,
        uint16 feeBps
    );
    event PausedBy(address indexed account);
    event UnpausedBy(address indexed account);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    uint16 public yieldSkimBps = DEFAULT_YIELD_SKIM_BPS;
    bool public paused;
    mapping(bytes32 => bool) public strategies;
    mapping(bytes32 => bool) public registered;
    uint256 public strategyCount;

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, msg.sender);
    }

    /// @notice DAY-828: pause plan* entry and new strategy registration.
    function pause() external onlyOwner {
        if (paused) revert Paused();
        paused = true;
        emit PausedBy(msg.sender);
    }

    /// @notice DAY-828: clear the global pause.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit UnpausedBy(msg.sender);
    }

    function registerStrategy(bytes32 id) external onlyOwner whenNotPaused {
        if (registered[id]) revert StrategyExists();
        registered[id] = true;
        strategies[id] = true;
        unchecked {
            strategyCount += 1;
        }
        emit StrategyRegistered(id, true);
    }

    function setActive(bytes32 id, bool active) external onlyOwner {
        if (!registered[id]) revert StrategyUnknown();
        strategies[id] = active;
        emit StrategySetActive(id, active);
    }

    /// @notice Set yield skim bps (1..1000). Deposit fee is immutable 0.
    function setYieldSkimBps(uint16 newSkimBps) external onlyOwner {
        if (newSkimBps == 0 || newSkimBps > MAX_YIELD_SKIM_BPS) revert FeeOutOfBounds();
        yieldSkimBps = newSkimBps;
        emit FeeConfigUpdated(newSkimBps);
    }

    /// @notice Prepare deposit plan — does not move tokens. Owner = msg.sender.
    function planDeposit(bytes32 strategyId, uint256 amountMicros) external whenNotPaused {
        if (amountMicros == 0) revert ZeroAmount();
        if (!registered[strategyId] || !strategies[strategyId]) revert StrategyInactive();
        // deposit fee is always 0 — never charge principal
        if (DEPOSIT_FEE_BPS != 0) revert DepositFeeMustBeZero();
        emit DepositPlanned(msg.sender, strategyId, amountMicros);
    }

    /// @notice Harvest skim accounting only (yield path). Pure math event.
    /// @dev Owner-gated (DAY-629): harvest is an operator/protocol action, so a
    ///      HarvestSkimPlanned event can only be emitted by the router owner —
    ///      matching how registerStrategy/setYieldSkimBps are gated and the
    ///      Solana day_router, which requires the harvest signer. Non-owners can
    ///      no longer emit arbitrary skim intents. Still NON-AUTHORITATIVE.
    function planHarvestSkim(bytes32 strategyId, uint256 grossYieldMicros) external onlyOwner whenNotPaused {
        if (grossYieldMicros == 0) revert ZeroAmount();
        if (!registered[strategyId] || !strategies[strategyId]) revert StrategyInactive();
        uint256 skim = (grossYieldMicros * uint256(yieldSkimBps)) / 10_000;
        uint256 net = grossYieldMicros - skim;
        emit HarvestSkimPlanned(
            msg.sender,
            strategyId,
            grossYieldMicros,
            skim,
            net,
            yieldSkimBps
        );
    }

    function depositFeeBps() external pure returns (uint16) {
        return DEPOSIT_FEE_BPS;
    }

    function withdrawFeeBps() external pure returns (uint16) {
        return WITHDRAW_FEE_BPS;
    }

    // DAY-828: receive() and rescueEth REMOVED.
    // This is a pure event-emitter; it must not accept ETH and has no admin
    // recovery path. Accidental selfdestruct dust is unrecoverable by design
    // (parity with DayRouterExecutor / DayRegistry after rescue removal).
}
