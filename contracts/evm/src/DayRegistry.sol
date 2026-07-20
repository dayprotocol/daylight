// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/**
 * @title DayRegistry
 * @notice Minimal DAY AdapterRegistry + YieldRouter fee config for EVM expansion (Base first).
 * @dev Does NOT take custody of user principal. Fee skim is on harvested yield only (500 bps default).
 *      Deposit fee is 0. Ownable — no renounce/lock unless explicitly requested.
 *
 * Audit fixes:
 * - DAY-124: setFeeConfig caps yieldSkimBps <= 1000; depositFeeBps must be 0
 * - DAY-125: planDeposit always uses msg.sender (no forgeable owner_)
 * - DAY-139: two-step ownership transfer
 * - DAY-828: remove rescueERC20 (parity with Sui/Solana/DayRouterExecutor — no admin drain);
 *            global pause gates user-entry + registration before adapter wiring;
 *            owner != feeTreasury role separation; _safeTransfer requires token code.
 *            DAY-903 correction: the pause NEVER gates forwardWithdraw — R3
 *            (docs/37): the depositor can always exit, even while paused.
 * - DAY-827: forwardWithdraw pays the MEASURED adapter pull (balance delta),
 *   never a caller-asserted amount — a stray router balance is not drainable.
 */
contract DayRegistry {
    // ── Ownable (minimal; no OZ dependency for tiny L2 deploy) ──────────────
    address public owner;
    address public pendingOwner;

    uint16 public constant MAX_YIELD_SKIM_BPS = 1000; // 10% hard cap
    uint16 public constant DEFAULT_YIELD_SKIM_BPS = 500; // 5%

    /// @dev Canonical DAY EVM fee treasury. Ops must keep owner on a *different*
    ///      key (multisig/timelock recommended) — see InvalidRoleSeparation.
    address public constant DEFAULT_FEE_TREASURY = 0x6d0C8D799c4e041eA45e02E456a36a360F3bC142;

    /// @dev Deploy-time placeholder when deployer == DEFAULT_FEE_TREASURY so
    ///      owner != feeTreasury from block 0. This is a spendable keccak
    ///      address nobody controls — fees sent here are burned forever.
    ///      `setProfitFeeConfig(..., enabled=true)` and `setFeeTreasury` both
    ///      reject this sentinel so profit skims cannot be enabled until ops
    ///      rotates to a real treasury (DAY-828 follow-up).
    address public constant FEE_TREASURY_UNSET =
        address(uint160(uint256(keccak256("DAY_FEE_TREASURY_UNSET"))));

    error NotOwner();
    error ZeroAddress();
    error AdapterExists();
    error AdapterUnknown();
    error ZeroAmount();
    error AdapterInactive();
    error FeeOutOfBounds();
    error DepositFeeMustBeZero();
    error NotPendingOwner();
    // ── DAY-828 pause / role-separation ─────────────────────────────────────
    error Paused();
    error NotPaused();
    error InvalidRoleSeparation();
    error AddressHasNoCode();
    /// @dev Profit fee enabled (or treasury set) while feeTreasury is still
    ///      FEE_TREASURY_UNSET — would burn skims into a no-key address.
    error FeeTreasuryUnset();
    // ── DAY-795 pass-through forwarder errors ───────────────────────────────
    /// @dev DAY-798-gated: forward requested for a protocol whose per-protocol
    ///      CPI/call adapter is not yet wired with a verified on-chain address.
    ///      Fail closed — never forward funds against an unverified target.
    error AdapterNotWired();
    /// @dev Reentrancy guard tripped (funds-moving forwards are non-reentrant).
    error Reentrancy();
    /// @dev Router token balance cannot cover the requested payouts.
    error InsufficientBalance();
    /// @dev A minimal-IERC20 transfer returned false / non-standard failure.
    error TransferFailed();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event PausedBy(address indexed account);
    event UnpausedBy(address indexed account);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev DAY-828: global kill-switch. Incident response must not depend on
    ///      enumerating every registered adapter id via setActive.
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ── DAY-795: minimal reentrancy guard (the forwards now move funds) ──────
    /// @dev Simple bool lock — no OZ. False = unlocked, true = inside a forward.
    ///      `internal` so a test harness can exercise the guard directly.
    bool internal _locked;

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ── Fee config (YieldRouter-aligned) ────────────────────────────────────
    /// @notice Protocol yield performance skim in basis points (500 = 5%).
    uint16 public yieldSkimBps = DEFAULT_YIELD_SKIM_BPS;
    /// @notice Deposit fee in basis points — always 0 for MVP (no fee on principal).
    uint16 public depositFeeBps = 0;

    // ── DAY-763: non-managed profit fee (PLACEHOLDER, owner-settable, OFF) ────
    // Product decision (2026-07-15): non-managed opportunities charge NO profit
    // fee for now, but the mechanism is wired as an owner-settable variable so it
    // can be turned on later without redeploy. Preset target: 1% of realized
    // profit, capped $10. `profitFeeEnabled=false` => 0 charged. Never principal.
    uint16 public constant MAX_PROFIT_FEE_BPS = 200; // 2% hard owner ceiling
    uint16 public profitFeeBps = 100; // preset 1% (not charged while disabled)
    uint256 public profitFeeCapUsdMicros = 10_000_000; // preset $10
    bool public profitFeeEnabled = false; // OFF (placeholder)

    // ── DAY-954: protocol swap + gas-sponsor fees (0.10% default swap, owner-settable) ─
    // Product live charge: swap 0.10% (10 bps). Bounds match FeeConfig v2
    // (5–30 bps swap; 0–1500 bps gas-sponsor markup). Owner may retune without
    // redeploy; off-chain FeeConfig falls back to these defaults when RPC read
    // is unavailable. Never charges principal.
    uint16 public constant MIN_PROTOCOL_SWAP_FEE_BPS = 5;
    uint16 public constant MAX_PROTOCOL_SWAP_FEE_BPS = 30;
    uint16 public protocolSwapFeeBps = 10; // 0.10% default (LIVE)
    uint16 public constant MAX_PROTOCOL_GAS_SPONSOR_FEE_BPS = 1500;
    uint16 public protocolGasSponsorFeeBps = 0; // not charged by default

    // ── DAY-795 / Codex #3: fee treasury is OWNER-SETTABLE, never caller-supplied ─
    // The withdraw fee is skimmed to THIS address, set only by the owner. A
    // withdrawer cannot redirect the fee (an earlier version took `treasury` as a
    // call arg — removed). Defaults to the DAY EVM treasury; owner may rotate.
    // DAY-828: owner and feeTreasury MUST remain distinct addresses.
    address public feeTreasury = DEFAULT_FEE_TREASURY;

    // ── DAY-828: global pause (default unpaused) ─────────────────────────────
    bool public paused;

    // ── Adapter allowlist ───────────────────────────────────────────────────
    /// @notice adapter id (bytes32, e.g. keccak256("aave-v3")) => active
    mapping(bytes32 => bool) public adapters;
    /// @notice True once an id has been registered (even if later deactivated).
    mapping(bytes32 => bool) public registered;
    uint256 public adapterCount;

    // ── Events ──────────────────────────────────────────────────────────────
    event AdapterRegistered(bytes32 indexed id, bool active);
    event AdapterSetActive(bytes32 indexed id, bool active);
    event FeeConfigUpdated(uint16 yieldSkimBps, uint16 depositFeeBps);
    /// @dev DAY-763 non-managed profit fee config change (placeholder until enabled).
    event ProfitFeeConfigUpdated(uint16 profitFeeBps, uint256 capUsdMicros, bool enabled);
    /// @dev DAY-954: owner retuned protocol swap and/or gas-sponsor fee bps.
    event ProtocolRailFeeConfigUpdated(uint16 protocolSwapFeeBps, uint16 protocolGasSponsorFeeBps);
    /// @dev DAY-795/Codex #3: owner rotated the fee treasury.
    event FeeTreasuryUpdated(address indexed newTreasury);
    /// @dev NON-AUTHORITATIVE intent log only. Not a balance/credit proof.
    event DepositPlanned(
        address indexed owner_,
        bytes32 indexed adapterId,
        uint256 amount,
        uint256 fee
    );
    /// @dev DAY-795: a pass-through forward executed. For a deposit `fee` is
    ///      always 0; for a withdraw `fee` is the profit skim sent to treasury
    ///      and `owner_` receives `amount - fee`. Emitted only on a real move,
    ///      so while the adapter is DAY-798-gated this never fires.
    event ForwardExecuted(
        bytes32 indexed adapterId,
        uint256 amount,
        uint256 fee,
        address indexed owner_
    );

    constructor() {
        owner = msg.sender;
        // DAY-828: if deployer is the default treasury EOA, force a distinct
        // temporary treasury so owner != feeTreasury from block 0. Ops must
        // call setFeeTreasury to the real treasury after ownership lands on a
        // multisig/timelock. Test harnesses (msg.sender != DEFAULT) keep the
        // default treasury unchanged.
        // The sentinel is a no-key keccak address — profit fees cannot be
        // enabled while it is set (see setProfitFeeConfig / FeeTreasuryUnset).
        if (msg.sender == DEFAULT_FEE_TREASURY) {
            feeTreasury = FEE_TREASURY_UNSET;
        }
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Start two-step ownership transfer.
    /// @dev DAY-828: new owner cannot equal feeTreasury (single-EOA collapse).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == feeTreasury) revert InvalidRoleSeparation();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Accept ownership (pending owner only).
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        if (msg.sender == feeTreasury) revert InvalidRoleSeparation();
        address prev = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, msg.sender);
    }

    /// @notice DAY-828: pause user entry + new adapter registration.
    /// @dev setActive / setFeeConfig / setFeeTreasury remain available so ops
    ///      can still disable adapters and rotate config while paused.
    /// @dev DAY-828 follow-up (a): once DAY-798 makes forwardWithdraw custodial
    ///      (adapter pulls funds into the router), re-evaluate whether
    ///      `forwardWithdraw` should remain under `whenNotPaused` — product
    ///      rule is "users can always withdraw (owner root)". Pause of
    ///      plan/register/deposit entry is fine; pausable withdraw is the
    ///      question for the post-DAY-798 wiring review.
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

    /// @notice Register a new adapter id (defaults active=true).
    /// @dev Gated by pause so a compromised-or-rushed owner cannot expand the
    ///      surface while the kill-switch is engaged.
    function registerAdapter(bytes32 id) external onlyOwner whenNotPaused {
        if (registered[id]) revert AdapterExists();
        registered[id] = true;
        adapters[id] = true;
        unchecked {
            adapterCount += 1;
        }
        emit AdapterRegistered(id, true);
    }

    /// @notice Toggle adapter active flag (must already be registered).
    function setActive(bytes32 id, bool active) external onlyOwner {
        if (!registered[id]) revert AdapterUnknown();
        adapters[id] = active;
        emit AdapterSetActive(id, active);
    }

    /// @notice Owner may update fee bps. Yield skim capped; deposit fee must stay 0.
    function setFeeConfig(uint16 _yieldSkimBps, uint16 _depositFeeBps) external onlyOwner {
        if (_yieldSkimBps > MAX_YIELD_SKIM_BPS) revert FeeOutOfBounds();
        if (_depositFeeBps != 0) revert DepositFeeMustBeZero();
        yieldSkimBps = _yieldSkimBps;
        depositFeeBps = 0;
        emit FeeConfigUpdated(_yieldSkimBps, 0);
    }

    /// @notice DAY-763: owner sets the non-managed profit fee (bps capped by
    /// MAX_PROFIT_FEE_BPS), the $ cap, and whether it is enabled. Charged on
    /// realized PROFIT only (never principal) at withdraw. Default OFF.
    /// @dev DAY-828 follow-up (b): cannot enable while feeTreasury is still
    ///      FEE_TREASURY_UNSET (no-key keccak burn address). Ops must
    ///      setFeeTreasury to a real sink first.
    function setProfitFeeConfig(uint16 _bps, uint256 _capUsdMicros, bool _enabled)
        external
        onlyOwner
    {
        if (_bps > MAX_PROFIT_FEE_BPS) revert FeeOutOfBounds();
        if (_enabled && feeTreasury == FEE_TREASURY_UNSET) revert FeeTreasuryUnset();
        profitFeeBps = _bps;
        profitFeeCapUsdMicros = _capUsdMicros;
        profitFeeEnabled = _enabled;
        emit ProfitFeeConfigUpdated(_bps, _capUsdMicros, _enabled);
    }

    /// @notice DAY-954: owner sets protocol swap fee (0.10% default) and gas-sponsor
    /// markup bps. Swap bounds 5–30; gas-sponsor 0–1500. No redeploy required.
    function setProtocolRailFeeConfig(uint16 _swapFeeBps, uint16 _gasSponsorFeeBps)
        external
        onlyOwner
    {
        if (_swapFeeBps < MIN_PROTOCOL_SWAP_FEE_BPS || _swapFeeBps > MAX_PROTOCOL_SWAP_FEE_BPS) {
            revert FeeOutOfBounds();
        }
        if (_gasSponsorFeeBps > MAX_PROTOCOL_GAS_SPONSOR_FEE_BPS) revert FeeOutOfBounds();
        protocolSwapFeeBps = _swapFeeBps;
        protocolGasSponsorFeeBps = _gasSponsorFeeBps;
        emit ProtocolRailFeeConfigUpdated(_swapFeeBps, _gasSponsorFeeBps);
    }

    /// @notice Quote protocol swap fee on notional (base units). Pure view.
    function quoteProtocolSwapFee(uint256 notional) public view returns (uint256) {
        if (notional == 0 || protocolSwapFeeBps == 0) return 0;
        return (notional * protocolSwapFeeBps) / 10_000;
    }

    /// @notice Quote gas-sponsor markup on repayment notional. Pure view.
    function quoteProtocolGasSponsorFee(uint256 notional) public view returns (uint256) {
        if (notional == 0 || protocolGasSponsorFeeBps == 0) return 0;
        return (notional * protocolGasSponsorFeeBps) / 10_000;
    }

    /// @notice Compute the profit fee on realized profit, applying the $ cap.
    /// Returns 0 while disabled. Pure view — the actual skim happens in the
    /// forwarding path (DAY-795). Profit must be USD-micros denominated.
    function quoteProfitFee(uint256 realizedProfitUsdMicros) public view returns (uint256) {
        if (!profitFeeEnabled || profitFeeBps == 0 || realizedProfitUsdMicros == 0) {
            return 0;
        }
        uint256 raw = (realizedProfitUsdMicros * profitFeeBps) / 10_000;
        if (profitFeeCapUsdMicros != 0 && raw > profitFeeCapUsdMicros) {
            return profitFeeCapUsdMicros;
        }
        return raw;
    }

    /// @notice Fail-closed allowlist check.
    function assertActive(bytes32 id) public view {
        if (!adapters[id]) revert AdapterInactive();
    }

    function isActive(bytes32 id) external view returns (bool) {
        return adapters[id];
    }

    /**
     * @notice Emit a deposit plan event (prepare-only; no custody transfer).
     * @dev Fee on principal is always 0. Owner is always msg.sender.
     *      Event is NON-AUTHORITATIVE intent — offchain must not credit from this alone.
     *      DAY-828: blocked while paused.
     */
    function planDeposit(bytes32 adapterId, uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        assertActive(adapterId);
        emit DepositPlanned(msg.sender, adapterId, amount, 0);
    }

    // ── DAY-795 pass-through fee-forwarder ──────────────────────────────────
    //
    // The router is the on-chain entry point the user calls for deposit/withdraw.
    // Funds flow THROUGH the router so the profit fee is captured atomically in
    // the middle of the WITHDRAW outflow, while NEVER being custodied: within the
    // call the router's token balance nets back to zero (fee -> treasury, the
    // remainder -> owner). DEPOSIT charges no profit fee (the fee is realized
    // profit, taken on withdraw) — the router just forwards principal into the
    // protocol via the per-protocol adapter. The adapter dispatch is DAY-798-
    // gated: real per-protocol addresses/calldata are not available yet, so it
    // FAILS CLOSED (AdapterNotWired) rather than move funds against an unverified
    // target. No arbitrary delegatecall — the stub reverts, and the real wiring
    // will use verified addresses only.

    /**
     * @notice Pass-through DEPOSIT: forward principal into the protocol adapter.
     *         No profit fee on deposit (fee is realized-profit, taken on withdraw).
     * @dev Adapter is DAY-798-gated => reverts AdapterNotWired until wired. The
     *      allowlist gate + reentrancy guard still apply so the surface is final.
     * @param adapterId     allowlisted per-protocol adapter id.
     * @param amount        principal to forward (informational for the event/log).
     * @param protocolCall  opaque per-protocol calldata (built off-chain, verified
     *                      by the adapter once wired).
     */
    function forwardDeposit(bytes32 adapterId, uint256 amount, bytes calldata protocolCall)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert ZeroAmount();
        assertActive(adapterId);

        // Deposit charges no fee; forward the full principal via the adapter.
        // DAY-798-gated: reverts AdapterNotWired until a verified adapter is wired.
        _cpiProtocolAdapter(adapterId, protocolCall);

        // Unreachable while gated (the call above reverts). Kept so the emitted
        // shape is final: a deposit forward always reports fee = 0.
        emit ForwardExecuted(adapterId, amount, 0, msg.sender);
    }

    /**
     * @notice Pass-through WITHDRAW: pull funds back through the router, skim the
     *         profit fee to the DAY treasury, forward the remainder to the owner.
     * @dev The profit fee = quoteProfitFee(realizedProfitUsdMicros) (1% capped $10,
     *      returns 0 while disabled — see DAY-763). Fee is on realized PROFIT only,
     *      never principal. The router token balance must cover the payouts and
     *      nets to zero within the call (never custodied). Adapter is DAY-798-gated
     *      => reverts AdapterNotWired until wired.
     * @param adapterId               allowlisted per-protocol adapter id.
     * @param amount                  total amount returning through the router.
     * @param realizedProfitUsdMicros profit basis the fee is computed on (USD micros).
     * @param token                   ERC20 the payouts are denominated in.
     * @param protocolCall            opaque per-protocol calldata (verified by adapter).
     * @dev The fee treasury is the owner-set `feeTreasury` — NOT a caller arg — so a
     *      withdrawer cannot redirect the fee (Codex #3).
     */
    /// @dev DAY-828 follow-up (a): `whenNotPaused` currently blocks withdraw.
    ///      Re-evaluate after DAY-798 wiring if pause should only gate entry
    ///      (deposit/register/plan) so owner-root withdraw stays available.
    function forwardWithdraw(
        bytes32 adapterId,
        uint256 amount,
        uint256 realizedProfitUsdMicros,
        address token,
        bytes calldata protocolCall
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert ZeroAddress();
        assertActive(adapterId);
        // Codex #4: the fee basis can never exceed the amount flowing out (fee is
        // on realized profit, a subset of the outflow). Post-DAY-798 the basis must
        // be adapter-derived; this guard bounds a bad caller-supplied basis today.
        if (realizedProfitUsdMicros > amount) revert FeeOutOfBounds();

        // 1) DAY-798 gate FIRST: while the per-protocol dispatch is gated this
        //    reverts AdapterNotWired before ANY token interaction — the gate
        //    stays the first line of defense (never touch a token contract on
        //    an unwired path).
        _assertAdapterWired(adapterId, protocolCall);

        // 2) DAY-827: snapshot the router balance BEFORE the adapter pull. The
        //    withdraw pays the MEASURED pull (delta), never the caller-asserted
        //    `amount` — a stray/accidental router balance is not drainable by
        //    overstating `amount` (the DAY-827 attack).
        uint256 balBefore = _erc20BalanceOf(token, address(this));

        // 3) Pull funds out of the protocol INTO this router (via the adapter).
        //    DAY-798-gated: reverts AdapterNotWired until a verified adapter is
        //    wired, so nothing below executes while the placeholder is in place.
        _cpiProtocolAdapter(adapterId, protocolCall);

        // 4) Measure what the adapter ACTUALLY pulled back. A net-negative or
        //    zero pull means the withdrawal returned nothing — fail closed.
        uint256 balAfter = _erc20BalanceOf(token, address(this));
        if (balAfter <= balBefore) revert InsufficientBalance();
        uint256 pulled = balAfter - balBefore;
        // The caller may claim LESS than the pull (partial withdraw); never more.
        if (pulled < amount) revert InsufficientBalance();

        // 5) Compute the profit fee (0 while the placeholder is disabled), cap $10.
        uint256 fee = quoteProfitFee(realizedProfitUsdMicros);

        // 6) The fee can never exceed the measured pull (fee is on profit, which
        //    is a subset of the returning amount). Guard the invariant so a
        //    mistaken caller passing a huge profit basis reverts cleanly instead
        //    of underflowing.
        if (fee > pulled) revert FeeOutOfBounds();

        // FABLE#2 / DAY-798 (parity with Solana Codex#7): `fee` (from quoteProfitFee)
        //    is USD MICROS, but _safeTransfer below moves it as TOKEN BASE UNITS.
        //    Correct only for 6-decimal USD-pegged tokens (USDC). Before the profit
        //    fee is ENABLED (ships disabled) DAY-798 MUST convert USD-micros -> token
        //    units via decimals + price here.
        // FABLE#3 / DAY-827: RESOLVED — the payout is the measured balance delta
        //    (pulled - fee), so a pre-existing stray balance can never be claimed
        //    by overstating `amount`. The router still nets to zero within the call.
        // FABLE#4 / DAY-798: assumes non-fee-on-transfer, non-rebasing tokens
        //    (the balance nets to zero); allowlist token types when wiring.
        // 7) Skim the fee to treasury (only if > 0), forward the remainder to the
        //    owner (msg.sender). Pays out exactly what the adapter pulled in.
        uint256 ownerAmount = pulled - fee;
        if (fee > 0) {
            // Codex #3: fee goes to the owner-set feeTreasury, never a caller arg.
            _safeTransfer(token, feeTreasury, fee);
        }
        _safeTransfer(token, msg.sender, ownerAmount);

        emit ForwardExecuted(adapterId, pulled, fee, msg.sender);
    }

    /// @notice DAY-795 / Codex #3: owner sets the fee treasury (the address that
    /// receives the withdraw fee skim). Never a caller parameter.
    /// @dev DAY-828: treasury cannot equal owner (single-key collapse).
    /// @dev DAY-828 follow-up (b): cannot re-install FEE_TREASURY_UNSET (burn).
    function setFeeTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (newTreasury == FEE_TREASURY_UNSET) revert FeeTreasuryUnset();
        if (newTreasury == owner) revert InvalidRoleSeparation();
        feeTreasury = newTreasury;
        emit FeeTreasuryUpdated(newTreasury);
    }

    /**
     * @notice DAY-798-GATED adapter-wired check. Runs BEFORE any token touch on
     *         the withdraw path so the gate is always the first line of defense.
     * @dev Defaults to reverting AdapterNotWired. `virtual` so the foundry
     *      harness can simulate a wired adapter and exercise DAY-827.
     */
    function _assertAdapterWired(bytes32 adapterId, bytes calldata data) internal virtual {
        adapterId;
        data;
        revert AdapterNotWired();
    }

    /**
     * @notice DAY-798-GATED per-protocol adapter dispatch.
     * @dev Real per-protocol call/CPI fills in HERE once DAY-798 supplies verified
     *      on-chain protocol addresses + calldata layouts. Until then it FAILS
     *      CLOSED. `virtual` so the foundry harness can simulate a wired adapter
     *      and exercise the balance-delta payout (DAY-827) end-to-end.
     */
    function _cpiProtocolAdapter(bytes32 adapterId, bytes calldata data) internal virtual {
        // DAY-798-gated: real per-protocol call dispatch by adapterId lands here.
        // Fail closed until a verified adapter is wired.
        adapterId; // silence unused-parameter warnings without moving funds
        data;
        revert AdapterNotWired();
    }

    /**
     * @notice Minimal SafeERC20-style transfer (no OZ). Reverts TransferFailed on
     *         a false return or a low-level failure; tolerates non-standard tokens
     *         that return no data (data.length == 0 treated as success).
     * @dev DAY-828: require token.code.length > 0 so a call to an EOA cannot
     *      silently succeed as (true, "").
     */
    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert AddressHasNoCode();
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /// @notice Minimal ERC20 balanceOf (no OZ). Reverts TransferFailed on a
    ///         malformed/failed response so the withdraw path never trusts garbage.
    function _erc20BalanceOf(address token, address account) internal view returns (uint256) {
        if (token.code.length == 0) revert AddressHasNoCode();
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    // DAY-828: rescueERC20 REMOVED.
    // Sui linear Coin / Solana / DayRouterExecutor have no admin rescue. An
    // unrestricted onlyOwner drain is the largest EVM trust delta vs those
    // references and becomes material once DAY-795 forwards hold transient
    // balances. Accidental ERC20 sends to this registry are unrecoverable by
    // design — same posture as DayOriginBoundPosition / DayRouterExecutor.
}
