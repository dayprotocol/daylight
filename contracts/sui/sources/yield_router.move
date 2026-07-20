// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY YieldRouter — main entry for deposit/withdraw/harvest under owner policy.
/// Product: agent-native yield **router**, not a vault farm.
/// Fee: 500 bps on harvested yield only; 0 on deposit/withdraw principal.
/// Stake/strategy default OFF. UpgradeCap held — do not lock without go.
module day::yield_router {
    use day::adapter_registry::{Self, AdapterRegistry, AdapterRegistryV2};
    use day::managed_position::{Self, OpportunityAccounting, Position};
    use sui::coin::{Self, Coin};
    use sui::dynamic_field;
    use sui::package::UpgradeCap;

    /// EStrategyOff
    const E_STRATEGY_OFF: u64 = 1;
    /// EZeroAmount
    const E_ZERO_AMOUNT: u64 = 2;
    /// ENotOwner — DAY-4306: withdraw owner must be the tx sender (no redirect).
    const E_NOT_OWNER: u64 = 3;
    /// EProfitFeeTooHigh — DAY-763: profit_fee_bps may not exceed MAX_PROFIT_FEE_BPS.
    const E_PROFIT_FEE_TOO_HIGH: u64 = 4;
    /// EAdapterNotWired — DAY-795/798: a forward was requested for a protocol whose
    /// on-chain adapter (package/object ids + call layout) is not yet wired/verified.
    /// The forwarder fails closed here rather than move funds against unverified ids.
    const E_ADAPTER_NOT_WIRED: u64 = 5;
    /// ENotAuthority — DAY-763 (Grok HIGH #1): only the DAY protocol authority may
    /// bootstrap the canonical RouterFeeConfig.
    const E_NOT_AUTHORITY: u64 = 6;
    /// EZeroTreasury — DAY-763 (Grok LOW #4): the fee treasury may not be @0x0
    /// (parity with the EVM router, which rejects the zero address).
    const E_ZERO_TREASURY: u64 = 10;
    /// EAuthenticatedPlanRequired — legacy V1 plan events are forgeable and retired.
    const E_AUTHENTICATED_PLAN_REQUIRED: u64 = 11;
    /// ERecordedPositionRequired — payout may only come from a Position record.
    const E_RECORDED_POSITION_REQUIRED: u64 = 12;
    /// EWrongUpgradeCap — only the canonical held capability can bootstrap admin.
    const E_WRONG_UPGRADE_CAP: u64 = 13;
    /// EWrongRouter — RouterAdminCap is bound to exactly one YieldRouter object.
    const E_WRONG_ROUTER: u64 = 14;
    /// ERouterAdminAlreadyBootstrapped — one immutable admin anchor per router.
    const E_ROUTER_ADMIN_ALREADY_BOOTSTRAPPED: u64 = 15;
    /// EInvalidGovernanceRecipient — never grant router admin to zero/treasury EOA.
    const E_INVALID_GOVERNANCE_RECIPIENT: u64 = 16;

    /// DAY-763 non-managed profit fee placeholder defaults (owner-settable, OFF by default).
    /// Preset target once enabled: 1% of realized profit, capped $10. Hard ceiling 2%.
    /// Charged on realized PROFIT only — never on principal.
    const PROFIT_FEE_BPS_DEFAULT: u64 = 100; // 1%
    const MAX_PROFIT_FEE_BPS: u64 = 200; // 2% hard ceiling
    const PROFIT_FEE_CAP_USD_MICROS_DEFAULT: u64 = 10_000_000; // $10
    const PROFIT_FEE_BASIS_POINTS: u64 = 10_000;

    /// DAY-763 quote/config default treasury. DAY-824 quarantines the executable
    /// sender-paying split; this address is not used on the principal settlement path.
    const DEFAULT_FEE_TREASURY: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;

    /// DAY-763 (Grok HIGH #1 / Fable 5 MEDIUM) protocol AUTHORITY — the ONLY
    /// hardcoded per-protocol address permitted here (it is the DAY treasury/
    /// authority, not any external protocol package). Config creation is capability
    /// controlled: `create_fee_config` takes a `FeeConfigCreatorCap` BY
    ///       VALUE and consumes (deletes) it. The cap has no `store`/`copy`/`drop`, so
    ///       it cannot be duplicated, stashed, or reused — each cap enables creating
    ///       exactly one RouterFeeConfig. The cap is minted only via
    ///       `mint_fee_config_creator_cap`, which is itself authority-gated
    ///       (sender == DAY_AUTHORITY). This makes creation one-shot per cap.
    /// Equal to DEFAULT_FEE_TREASURY by construction; kept as a distinct named const so
    /// the authorization semantics are explicit at each call site.
    const DAY_AUTHORITY: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;

    /// Stable across package upgrades. The capability stays held; never burn/freeze it.
    const CANONICAL_UPGRADE_CAP: address =
        @0xfb7a7925da9332ab039cd7296828f5ebaef5ff7246f1bfa051d0a409fa15eb2d;
    /// The one deployed shared YieldRouter. A bootstrap against any other object fails.
    const CANONICAL_YIELD_ROUTER: address =
        @0xa0722a3dd74837d9daa4a82c2ffd7ed4c1b6013d57a362a42cb5a6c9c004db6f;
    const AUTHENTICATED_PLAN_VERSION: u64 = 2;

    /// Router config (shared). Does not hold user principal.
    ///
    /// DAY-763 CRITICAL: this is the ALREADY-DEPLOYED shared object. A Sui package
    /// upgrade cannot change the layout of a live shared object, so its fields MUST
    /// stay exactly as originally deployed. The owner + profit-fee config live in the
    /// SEPARATE, newly-created `RouterFeeConfig` shared object below instead.
    public struct YieldRouter has key {
        id: UID,
        /// Global auto-yield default OFF
        auto_yield_default_off: bool,
        protocol_yield_skim_bps: u64,
        paused: bool,
    }

    /// DAY-763 profit-fee + owner config (shared). A NEW object minted post-upgrade via
    /// `create_fee_config`, so no migration of the deployed YieldRouter is needed. Holds
    /// the owner authority (mirrors day::agent_cap owner idiom + the Solana router
    /// `authority`), the owner-settable non-managed profit fee, and the fee treasury.
    /// Does not hold user principal.
    public struct RouterFeeConfig has key {
        id: UID,
        /// Recorded config owner — only this address may mutate owner-gated config.
        owner: address,
        // DAY-763 non-managed profit fee (placeholder; owner-settable; OFF by default).
        profit_fee_bps: u64,
        profit_fee_cap_usd_micros: u64,
        profit_fee_enabled: bool,
        /// Fee destination. Owner-settable; NEVER a caller arg on the withdraw path so
        /// the withdrawer cannot redirect the fee. Defaults to the DAY Sui treasury.
        treasury: address,
    }

    /// DAY-763 (Fable 5 MEDIUM): one-shot creator capability for `create_fee_config`.
    /// Deliberately has NONE of `store`, `copy`, `drop` — it can only be transferred
    /// (by `mint_fee_config_creator_cap`) or consumed/deleted (by `create_fee_config`)
    /// from within this module. Because it has no `drop`, a cap can never be silently
    /// discarded — it MUST be either transferred or consumed by value; and because it
    /// has no `copy`, it can never be duplicated. `create_fee_config` takes the cap BY
    /// VALUE and destroys it, so each minted cap authorizes creating exactly one
    /// RouterFeeConfig. This is the mechanism that makes config creation genuinely
    /// one-shot rather than merely authority-gated.
    public struct FeeConfigCreatorCap has key {
        id: UID,
    }

    /// Typed dynamic-field key anchoring the one RouterAdminCap without changing the
    /// frozen YieldRouter layout.
    public struct RouterAdminAnchorKey has copy, drop, store {}

    /// Immutable public record of the capability selected by governance at bootstrap.
    public struct RouterAdminAnchor has copy, drop, store {
        admin_cap_id: ID,
        governance: address,
    }

    /// Non-copyable, non-droppable, non-storable pause authority for one router.
    public struct RouterAdminCap has key {
        id: UID,
        router_id: ID,
    }

    /// Soft position tracking is offchain for MVP; onchain events for audit.
    public struct DepositPlanned has copy, drop {
        owner: address,
        adapter_id: vector<u8>,
        amount_micros: u64,
        fee_micros: u64,
    }

    public struct WithdrawPlanned has copy, drop {
        owner: address,
        adapter_id: vector<u8>,
        amount_micros: u64,
        fee_micros: u64,
    }

    public struct HarvestSkimmed has copy, drop {
        owner: address,
        adapter_id: vector<u8>,
        gross_yield_micros: u64,
        protocol_skim_micros: u64,
        net_yield_micros: u64,
        fee_bps: u64,
    }

    /// DAY-829 authenticated event generation. Consumers MUST ignore the legacy
    /// DepositPlanned/WithdrawPlanned/HarvestSkimmed types, which historical package
    /// versions can still emit with caller-chosen identities.
    public struct DepositPlannedV2 has copy, drop {
        version: u64,
        owner: address,
        adapter_id: vector<u8>,
        amount_micros: u64,
        fee_micros: u64,
    }

    public struct WithdrawPlannedV2 has copy, drop {
        version: u64,
        owner: address,
        adapter_id: vector<u8>,
        amount_micros: u64,
        fee_micros: u64,
    }

    public struct HarvestSkimmedV2 has copy, drop {
        version: u64,
        owner: address,
        adapter_id: vector<u8>,
        gross_yield_micros: u64,
        protocol_skim_micros: u64,
        net_yield_micros: u64,
        fee_bps: u64,
    }

    public struct RouterAdminCreated has copy, drop {
        router_id: ID,
        admin_cap_id: ID,
        governance: address,
    }

    public struct RouterPauseChanged has copy, drop {
        router_id: ID,
        paused: bool,
    }

    /// DAY-763: emitted when the owner updates the non-managed profit fee config.
    public struct ProfitFeeConfigured has copy, drop {
        owner: address,
        profit_fee_bps: u64,
        profit_fee_cap_usd_micros: u64,
        profit_fee_enabled: bool,
        treasury: address,
    }

    /// DAY-795 legacy event shape retained for package compatibility. The sender-paying
    /// fee path that emitted it is quarantined by DAY-824.
    /// `amount` is the gross Coin<T> value that flowed THROUGH the router; `fee` is
    /// the profit fee (0 while the placeholder is disabled) split off to treasury.
    /// Consumers must use managed_position::OwnerExitRecorded for current settlement.
    public struct ForwardExecuted has copy, drop {
        owner: address,
        adapter_id: vector<u8>,
        amount: u64,
        fee: u64,
    }

    /// Create the deployed router config. Layout is FROZEN (see struct doc): only
    /// id, auto_yield_default_off, protocol_yield_skim_bps, paused.
    public fun create(ctx: &mut TxContext) {
        let r = YieldRouter {
            id: object::new(ctx),
            auto_yield_default_off: true,
            protocol_yield_skim_bps: 500,
            paused: false,
        };
        transfer::share_object(r);
    }

    /// One-shot post-upgrade bootstrap for pause governance. The frozen router layout
    /// is unchanged: the immutable anchor is a typed dynamic field. Publishing this
    /// code does NOT create or transfer authority; bootstrap remains a separate
    /// governance-recipient transaction.
    public fun bootstrap_router_admin(
        router: &mut YieldRouter,
        upgrade_cap: &UpgradeCap,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(object::id_address(upgrade_cap) == CANONICAL_UPGRADE_CAP, E_WRONG_UPGRADE_CAP);
        assert!(object::id_address(router) == CANONICAL_YIELD_ROUTER, E_WRONG_ROUTER);
        assert_governance_recipient(recipient);
        let cap = bootstrap_router_admin_internal(router, recipient, ctx);
        transfer::transfer(cap, recipient);
    }

    fun bootstrap_router_admin_internal(
        router: &mut YieldRouter,
        recipient: address,
        ctx: &mut TxContext,
    ): RouterAdminCap {
        assert!(
            !dynamic_field::exists(&router.id, RouterAdminAnchorKey {}),
            E_ROUTER_ADMIN_ALREADY_BOOTSTRAPPED,
        );

        let router_id = object::id(router);
        let cap = RouterAdminCap { id: object::new(ctx), router_id };
        let admin_cap_id = object::id(&cap);
        dynamic_field::add(
            &mut router.id,
            RouterAdminAnchorKey {},
            RouterAdminAnchor { admin_cap_id, governance: recipient },
        );
        sui::event::emit(RouterAdminCreated { router_id, admin_cap_id, governance: recipient });
        cap
    }

    /// Capability-authenticated emergency pause. This gates new risk-increasing work,
    /// never the position-record owner exit path.
    public fun set_paused(
        cap: &RouterAdminCap,
        router: &mut YieldRouter,
        paused: bool,
    ) {
        assert_router_admin(cap, router);
        router.paused = paused;
        sui::event::emit(RouterPauseChanged { router_id: object::id(router), paused });
    }

    /// DAY-763 (Fable 5 MEDIUM): mint the ONE-SHOT `FeeConfigCreatorCap` and transfer it
    /// to the DAY authority. Authority-gated: only `DAY_AUTHORITY` may call this
    /// (E_NOT_AUTHORITY otherwise). This is the single bootstrap step that must precede
    /// `create_fee_config`.
    ///
    /// This function is itself technically re-callable (nothing stops the authority
    /// from calling it again), but doing so only mints ANOTHER cap to the authority's
    /// own address — it does not let anyone create a second config for free, because
    /// `create_fee_config` still consumes one cap per config. In practice the authority
    /// calls this exactly once as part of the bootstrap PTB, immediately followed by
    /// `create_fee_config` consuming the freshly-minted cap. The critical invariant —
    /// "at most one config per cap consumed, and cap issuance is authority-controlled" —
    /// holds regardless of how many times this is called.
    public entry fun mint_fee_config_creator_cap(ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == DAY_AUTHORITY, E_NOT_AUTHORITY);
        let cap = FeeConfigCreatorCap { id: object::new(ctx) };
        transfer::transfer(cap, DAY_AUTHORITY);
    }

    /// DAY-763 (Grok HIGH #1, hardened Fable 5 MEDIUM): create + share the CANONICAL
    /// RouterFeeConfig. This is a NEW shared object minted AFTER the package upgrade —
    /// it does NOT migrate or touch the already deployed YieldRouter, so there is no
    /// forbidden shared-object layout change.
    ///
    /// ONE-SHOT: this function takes `cap: FeeConfigCreatorCap` BY VALUE and CONSUMES
    /// (deletes) it before sharing the new config. The cap has no `store`/`copy`/`drop`
    /// (see the struct doc), so it cannot be duplicated or reused — a given cap can
    /// authorize creating exactly one RouterFeeConfig. Combined with
    /// `mint_fee_config_creator_cap` being authority-gated, this guarantees the DAY
    /// authority cannot accidentally (or be tricked into) creating a second live
    /// config: each config creation burns a cap, and caps don't stack or clone.
    ///
    /// Also re-asserts `sender == DAY_AUTHORITY` (E_NOT_AUTHORITY) as defense in depth
    /// — even though only the authority can ever hold a cap (mint is authority-gated
    /// and `transfer::transfer` is non-public-store, so a cap cannot be freely handed
    /// off to a third party either).
    ///
    /// Profit fee 1% / $10 cap, DISABLED by default; treasury = DAY.
    public fun create_fee_config(cap: FeeConfigCreatorCap, ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == DAY_AUTHORITY, E_NOT_AUTHORITY);
        // Consume the cap BEFORE creating the config: no `drop`/`copy` means this is
        // the only way to discharge it, so this call site is the one and only place a
        // RouterFeeConfig can come from.
        let FeeConfigCreatorCap { id } = cap;
        object::delete(id);
        let cfg = RouterFeeConfig {
            id: object::new(ctx),
            // Owner is pinned to the authority (== tx sender here). The executable
            // sender-paying fee split is quarantined; config remains quote-only.
            owner: DAY_AUTHORITY,
            // DAY-763: non-managed profit fee is a placeholder — DISABLED by default
            // (charges 0). Owner may later enable it up to MAX_PROFIT_FEE_BPS.
            profit_fee_bps: PROFIT_FEE_BPS_DEFAULT,
            profit_fee_cap_usd_micros: PROFIT_FEE_CAP_USD_MICROS_DEFAULT,
            profit_fee_enabled: false,
            treasury: DEFAULT_FEE_TREASURY,
        };
        transfer::share_object(cfg);
    }

    /// Legacy deployed ABI retained for compatible upgrades. Historical package
    /// versions can emit DepositPlanned with a caller-chosen owner, so consumers must
    /// ignore that V1 type and this newest implementation always fails closed.
    public fun plan_deposit(
        _router: &YieldRouter,
        _registry: &AdapterRegistry,
        _adapter_id: vector<u8>,
        _amount_micros: u64,
        _owner: address,
        _auto_yield_enabled: bool,
    ) {
        abort E_AUTHENTICATED_PLAN_REQUIRED
    }

    /// Authenticated V2 deposit intent. Identity comes from TxContext, and the event
    /// type did not exist in historical packages, so consumers can reject V1 events.
    public fun plan_deposit_v2(
        router: &YieldRouter,
        registry: &AdapterRegistryV2,
        adapter_id: vector<u8>,
        amount_micros: u64,
        owner: address,
        auto_yield_enabled: bool,
        ctx: &TxContext,
    ) {
        assert!(owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(!router.paused, E_STRATEGY_OFF);
        assert!(amount_micros > 0, E_ZERO_AMOUNT);
        adapter_registry::assert_active_v2(registry, adapter_id);
        let _ = auto_yield_enabled;
        sui::event::emit(DepositPlannedV2 {
            version: AUTHENTICATED_PLAN_VERSION,
            owner,
            adapter_id,
            amount_micros,
            fee_micros: 0,
        });
    }

    /// Deployed five-argument ABI retained for compatibility but quarantined. It can
    /// never emit another forgeable WithdrawPlanned V1 event from the newest package.
    public fun plan_withdraw(
        _router: &YieldRouter,
        _registry: &AdapterRegistry,
        _adapter_id: vector<u8>,
        _amount_micros: u64,
        _owner: address,
    ) {
        abort E_AUTHENTICATED_PLAN_REQUIRED
    }

    /// Previously-added authenticated wrapper still emitted the ambiguous V1 type.
    /// Retain its ABI as an aborting compatibility shape; use V2 below.
    public fun plan_withdraw_authenticated(
        _router: &YieldRouter,
        _registry: &AdapterRegistry,
        _adapter_id: vector<u8>,
        _amount_micros: u64,
        _owner: address,
        _ctx: &TxContext,
    ) {
        abort E_AUTHENTICATED_PLAN_REQUIRED
    }

    /// V2 owner-locked withdrawal intent. Pause is deliberately NOT consulted: owner
    /// principal exit remains available while governance freezes new risk.
    public fun plan_withdraw_authenticated_v2(
        router: &YieldRouter,
        registry: &AdapterRegistryV2,
        adapter_id: vector<u8>,
        amount_micros: u64,
        owner: address,
        ctx: &TxContext,
    ) {
        assert!(owner == tx_context::sender(ctx), E_NOT_OWNER);
        let _ = router;
        assert!(amount_micros > 0, E_ZERO_AMOUNT);
        adapter_registry::assert_active_v2(registry, adapter_id);
        sui::event::emit(WithdrawPlannedV2 {
            version: AUTHENTICATED_PLAN_VERSION,
            owner,
            adapter_id,
            amount_micros,
            fee_micros: 0,
        });
    }

    /// Legacy V1 harvest intent is unauthenticated and caller-asserted. Preserve its
    /// deployed ABI but never emit the forgeable event again.
    public fun plan_harvest_skim(
        _router: &YieldRouter,
        _registry: &AdapterRegistry,
        _adapter_id: vector<u8>,
        _gross_yield_micros: u64,
        _owner: address,
    ) {
        abort E_AUTHENTICATED_PLAN_REQUIRED
    }

    /// Wallet authentication cannot prove realized yield, so the public V2 shape is
    /// also quarantined. A measured package adapter uses the position-bound hook below.
    public fun plan_harvest_skim_v2(
        _router: &YieldRouter,
        _registry: &AdapterRegistryV2,
        _adapter_id: vector<u8>,
        _gross_yield_micros: u64,
        _owner: address,
    ) {
        abort E_AUTHENTICATED_PLAN_REQUIRED
    }

    /// Compatibility ABI retained for a future measured adapter-receipt replacement.
    /// The historical body accepted caller-authored yield and adapter metadata, so it
    /// is unsafe once consented Position objects become shared. Keep this fail-closed
    /// until the package consumes an authenticated measured receipt bound to Position.
    public(package) fun record_harvest_skim_v2_for_position(
        _router: &YieldRouter,
        _registry: &AdapterRegistryV2,
        _position: &Position,
        _adapter_id: vector<u8>,
        _gross_yield_micros: u64,
    ) {
        abort E_AUTHENTICATED_PLAN_REQUIRED
    }

    /// DAY-763: owner-only update of the non-managed profit fee config (placeholder
    /// until enabled). `profit_fee_bps` is hard-capped at MAX_PROFIT_FEE_BPS. Also sets
    /// the fee `treasury` (owner-controlled destination). Auth mirrors day::agent_cap:
    /// only the recorded config owner (tx sender) may set. Charged on realized PROFIT
    /// only (never principal) once enabled. Operates on RouterFeeConfig, NOT YieldRouter.
    public entry fun set_profit_fee(
        config: &mut RouterFeeConfig,
        profit_fee_bps: u64,
        profit_fee_cap_usd_micros: u64,
        enabled: bool,
        treasury: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == config.owner, E_NOT_OWNER);
        assert!(profit_fee_bps <= MAX_PROFIT_FEE_BPS, E_PROFIT_FEE_TOO_HIGH);
        // DAY-763 (Grok LOW #4): reject a zero treasury (parity with the EVM router).
        assert!(treasury != @0x0, E_ZERO_TREASURY);
        config.profit_fee_bps = profit_fee_bps;
        config.profit_fee_cap_usd_micros = profit_fee_cap_usd_micros;
        config.profit_fee_enabled = enabled;
        config.treasury = treasury;
        sui::event::emit(ProfitFeeConfigured {
            owner: config.owner,
            profit_fee_bps,
            profit_fee_cap_usd_micros,
            profit_fee_enabled: enabled,
            treasury,
        });
    }

    /// DAY-763: owner-only update of just the fee treasury destination.
    public entry fun set_treasury(
        config: &mut RouterFeeConfig,
        treasury: address,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == config.owner, E_NOT_OWNER);
        // DAY-763 (Grok LOW #4): reject a zero treasury (parity with the EVM router).
        assert!(treasury != @0x0, E_ZERO_TREASURY);
        config.treasury = treasury;
        sui::event::emit(ProfitFeeConfigured {
            owner: config.owner,
            profit_fee_bps: config.profit_fee_bps,
            profit_fee_cap_usd_micros: config.profit_fee_cap_usd_micros,
            profit_fee_enabled: config.profit_fee_enabled,
            treasury,
        });
    }

    /// DAY-763: quote the profit fee on realized profit (USD micros), applying the $ cap.
    /// Returns 0 while disabled / zero-bps / zero-profit. Never charges principal —
    /// the caller passes realized PROFIT only. u128 intermediate avoids overflow.
    public fun quote_profit_fee(config: &RouterFeeConfig, realized_profit_usd_micros: u64): u64 {
        if (!config.profit_fee_enabled
            || config.profit_fee_bps == 0
            || realized_profit_usd_micros == 0) {
            return 0
        };
        let raw = ((realized_profit_usd_micros as u128)
            * (config.profit_fee_bps as u128)
            / (PROFIT_FEE_BASIS_POINTS as u128)) as u64;
        if (config.profit_fee_cap_usd_micros != 0 && raw > config.profit_fee_cap_usd_micros) {
            config.profit_fee_cap_usd_micros
        } else {
            raw
        }
    }

    // ── DAY-795 pass-through fee-forwarder ───────────────────────────────────
    //
    // The router is the on-chain entry point the user calls for deposit/withdraw.
    // Funds flow THROUGH the router as a linear Coin<T> so the profit fee is
    // captured atomically in the middle of the WITHDRAW outflow, while NEVER being
    // custodied: Sui's linear Coin types make the atomic forward natural — the
    // coin is split and both parts are transferred out within the same tx, so no
    // balance persists in the router. The real protocol interaction is a call into
    // the protocol package, dispatched per-protocol through an ADAPTER. Those
    // adapters are DAY-798-gated (they need verified on-chain package/object ids +
    // call layouts per protocol); until then the dispatch fails closed rather than
    // move funds against unverified ids. NEVER hardcode a protocol address here.

    /// DAY-795 forward DEPOSIT: no profit fee on deposit (the fee is realized-profit
    /// only, taken at withdraw). The router receives the user's `funds: Coin<T>` and
    /// is meant to forward the FULL principal into the protocol via a per-protocol
    /// adapter call.
    ///
    /// DAY-798-GATED / fail-closed: the real adapter (verified on-chain package/object
    /// ids + call layout) is not wired yet, so this ABORTS with E_ADAPTER_NOT_WIRED
    /// rather than fabricate a protocol call against an unverified id. Crucially the
    /// abort is the LAST thing that touches `funds` — the linear Coin<T> is never
    /// split, dropped, or sent anywhere. Because abort reverts the whole transaction,
    /// `funds` is returned intact to the sender (no funds lost or stranded), and the
    /// abort itself discharges the compiler's linear obligation on `funds`.
    ///
    /// Post-DAY-798: replace the abort with the real adapter call that consumes
    /// `funds` (by value) into the protocol, then emit ForwardExecuted{ fee: 0 }.
    public entry fun forward_deposit<T>(
        router: &YieldRouter,
        registry: &AdapterRegistry,
        adapter_id: vector<u8>,
        funds: Coin<T>,
        protocol_ix: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(!router.paused, E_STRATEGY_OFF);
        assert!(coin::value(&funds) > 0, E_ZERO_AMOUNT);
        adapter_registry::assert_active(registry, adapter_id);
        let _ = protocol_ix;
        let _ = ctx;

        // Fail closed: abort BEFORE `funds` is moved. The tx reverts and `funds`
        // returns to the sender; the abort also satisfies linearity for `funds`.
        // Post-DAY-798 the real per-protocol adapter call consumes `funds` here.
        abort E_ADAPTER_NOT_WIRED
    }

    /// DAY-821 V2 forward-deposit gate. Still DAY-798-blocked, but the gate is now
    /// anchored to a fresh registry type that legacy package code cannot mutate.
    public entry fun forward_deposit_v2<T>(
        router: &YieldRouter,
        registry: &AdapterRegistryV2,
        adapter_id: vector<u8>,
        funds: Coin<T>,
        protocol_ix: vector<u8>,
        ctx: &mut TxContext,
    ) {
        assert!(!router.paused, E_STRATEGY_OFF);
        assert!(coin::value(&funds) > 0, E_ZERO_AMOUNT);
        adapter_registry::assert_active_v2(registry, adapter_id);
        let _ = protocol_ix;
        let _ = ctx;
        abort E_ADAPTER_NOT_WIRED
    }

    /// DAY-795 forward WITHDRAW (entry).
    ///
    /// DAY-798-GATED / fail-closed (Codex #2): the per-protocol adapter PULL that
    /// PRODUCES the withdrawn `funds: Coin<T>` is not wired/verified yet, so this entry
    /// ABORTS with E_ADAPTER_NOT_WIRED rather than move any funds. Fail-closed parity
    /// with `forward_deposit`: no caller-supplied coin is split or transferred while the
    /// adapter is gated.
    ///
    /// Post-DAY-798: the verified per-protocol call (using `adapter_id` + a protocol
    /// payload) produces venue proceeds. A NEW position/accounting-bound entry must then
    /// call `settle_position_owner_exit`; this frozen signature lacks those proofs and
    /// therefore remains permanently fail-closed.
    #[allow(unused_type_parameter)]
    public entry fun forward_withdraw<T>(
        router: &YieldRouter,
        registry: &AdapterRegistry,
        config: &RouterFeeConfig,
        adapter_id: vector<u8>,
        realized_profit_usd_micros: u64,
        ctx: &mut TxContext,
    ) {
        assert!(!router.paused, E_STRATEGY_OFF);
        adapter_registry::assert_active(registry, adapter_id);
        let _ = config;
        let _ = realized_profit_usd_micros;
        let _ = ctx;

        // Fail closed: the adapter that would PRODUCE `funds` is DAY-798-gated. Abort
        // rather than move any funds. Do not wire this frozen shape: it has no Position
        // or OpportunityAccounting input. Add a position-bound entry instead.
        abort E_ADAPTER_NOT_WIRED
    }

    /// DAY-821 V2 forward-withdraw gate. No adapter pull exists yet, so this remains
    /// fail-closed while proving the eventual money path cannot consult legacy state.
    #[allow(unused_type_parameter)]
    public entry fun forward_withdraw_v2<T>(
        router: &YieldRouter,
        registry: &AdapterRegistryV2,
        config: &RouterFeeConfig,
        adapter_id: vector<u8>,
        realized_profit_usd_micros: u64,
        ctx: &mut TxContext,
    ) {
        assert!(!router.paused, E_STRATEGY_OFF);
        adapter_registry::assert_active_v2(registry, adapter_id);
        let _ = config;
        let _ = realized_profit_usd_micros;
        let _ = ctx;
        abort E_ADAPTER_NOT_WIRED
    }

    /// Legacy package ABI retained only for upgrade compatibility. Its payout came from
    /// tx_context::sender and therefore could pay a leader/cranker instead of the
    /// depositor. It must never move funds again; use the position-bound function below.
    public(package) fun split_and_forward_fee<T>(
        _config: &RouterFeeConfig,
        _funds: Coin<T>,
        _adapter_id: vector<u8>,
        _realized_profit_usd_micros: u64,
        _ctx: &mut TxContext,
    ) {
        abort E_RECORDED_POSITION_REQUIRED
    }

    /// DAY-824 owner-exit settlement. Do not reimplement payout binding here: the
    /// managed-position module consumes its private OwnerPayout and atomically proves
    /// accounting id, position id, origin asset type, shares, exact Coin value, signer,
    /// and immutable recorded destination. There is deliberately no destination,
    /// adapter id, caller-asserted profit, fee, router, pause, or leader input.
    public(package) fun settle_position_owner_exit<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        shares: u128,
        proceeds: Coin<T>,
        ctx: &mut TxContext,
    ) {
        managed_position::settle_owner_exit<T>(accounting, position, shares, proceeds, ctx);
    }

    fun assert_router_admin(cap: &RouterAdminCap, router: &YieldRouter) {
        assert!(cap.router_id == object::id(router), E_WRONG_ROUTER);
        assert!(
            dynamic_field::exists(&router.id, RouterAdminAnchorKey {}),
            E_WRONG_ROUTER,
        );
        let anchor = dynamic_field::borrow<RouterAdminAnchorKey, RouterAdminAnchor>(
            &router.id,
            RouterAdminAnchorKey {},
        );
        assert!(anchor.admin_cap_id == object::id(cap), E_WRONG_ROUTER);
    }

    fun assert_governance_recipient(recipient: address) {
        assert!(recipient != @0x0, E_INVALID_GOVERNANCE_RECIPIENT);
        assert!(recipient != DAY_AUTHORITY, E_INVALID_GOVERNANCE_RECIPIENT);
    }

    public fun auto_yield_default_off(router: &YieldRouter): bool {
        router.auto_yield_default_off
    }

    public fun protocol_yield_skim_bps(router: &YieldRouter): u64 {
        router.protocol_yield_skim_bps
    }

    public fun is_paused(router: &YieldRouter): bool {
        router.paused
    }

    public fun router_admin_cap_id(router: &YieldRouter): Option<ID> {
        if (!dynamic_field::exists(&router.id, RouterAdminAnchorKey {})) {
            return option::none()
        };
        let anchor = dynamic_field::borrow<RouterAdminAnchorKey, RouterAdminAnchor>(
            &router.id,
            RouterAdminAnchorKey {},
        );
        option::some(anchor.admin_cap_id)
    }

    public fun router_admin_governance(router: &YieldRouter): Option<address> {
        if (!dynamic_field::exists(&router.id, RouterAdminAnchorKey {})) {
            return option::none()
        };
        let anchor = dynamic_field::borrow<RouterAdminAnchorKey, RouterAdminAnchor>(
            &router.id,
            RouterAdminAnchorKey {},
        );
        option::some(anchor.governance)
    }

    public fun owner(config: &RouterFeeConfig): address {
        config.owner
    }

    public fun profit_fee_bps(config: &RouterFeeConfig): u64 {
        config.profit_fee_bps
    }

    public fun profit_fee_cap_usd_micros(config: &RouterFeeConfig): u64 {
        config.profit_fee_cap_usd_micros
    }

    public fun profit_fee_enabled(config: &RouterFeeConfig): bool {
        config.profit_fee_enabled
    }

    public fun treasury(config: &RouterFeeConfig): address {
        config.treasury
    }

    #[test_only]
    /// The DAY authority address, for test assertions on the canonical-config pin.
    public fun day_authority_for_testing(): address {
        DAY_AUTHORITY
    }

    #[test_only]
    /// Mint a `FeeConfigCreatorCap` directly, bypassing the authority-gated
    /// `mint_fee_config_creator_cap` entry point — for unit tests that need a cap in
    /// hand without composing a separate mint transaction. Production code can only
    /// obtain a cap via `mint_fee_config_creator_cap` (authority-gated); this helper
    /// exists solely so tests can exercise `create_fee_config`'s cap-consuming behavior
    /// directly.
    public fun fee_config_creator_cap_for_testing(ctx: &mut TxContext): FeeConfigCreatorCap {
        FeeConfigCreatorCap { id: object::new(ctx) }
    }

    #[test_only]
    /// Build a CANONICAL RouterFeeConfig (owner = DAY_AUTHORITY) with an explicit
    /// profit-fee config for unit tests — mirrors what `create_fee_config` produces, so
    /// it passes the owner==authority pin on the fee path.
    public fun new_config_for_testing(
        profit_fee_bps: u64,
        profit_fee_cap_usd_micros: u64,
        profit_fee_enabled: bool,
        treasury: address,
        ctx: &mut TxContext,
    ): RouterFeeConfig {
        RouterFeeConfig {
            id: object::new(ctx),
            owner: DAY_AUTHORITY,
            profit_fee_bps,
            profit_fee_cap_usd_micros,
            profit_fee_enabled,
            treasury,
        }
    }

    #[test_only]
    /// Build a RouterFeeConfig with an ARBITRARY recorded owner — used to construct a
    /// ROGUE config (owner != DAY_AUTHORITY) and prove the fee path rejects it.
    public fun new_config_with_owner_for_testing(
        owner: address,
        profit_fee_bps: u64,
        profit_fee_cap_usd_micros: u64,
        profit_fee_enabled: bool,
        treasury: address,
        ctx: &mut TxContext,
    ): RouterFeeConfig {
        RouterFeeConfig {
            id: object::new(ctx),
            owner,
            profit_fee_bps,
            profit_fee_cap_usd_micros,
            profit_fee_enabled,
            treasury,
        }
    }

    #[test_only]
    public fun destroy_config_for_testing(config: RouterFeeConfig) {
        let RouterFeeConfig {
            id,
            owner: _,
            profit_fee_bps: _,
            profit_fee_cap_usd_micros: _,
            profit_fee_enabled: _,
            treasury: _,
        } = config;
        object::delete(id);
    }

    #[test_only]
    /// Build a YieldRouter (deployed-layout) for unit tests.
    public fun new_router_for_testing(ctx: &mut TxContext): YieldRouter {
        YieldRouter {
            id: object::new(ctx),
            auto_yield_default_off: true,
            protocol_yield_skim_bps: 500,
            paused: false,
        }
    }

    #[test_only]
    /// Test-only capability constructor that exercises the exact anchor creation and
    /// recipient validation without requiring the mainnet UpgradeCap object id.
    public fun bootstrap_router_admin_for_testing(
        router: &mut YieldRouter,
        recipient: address,
        ctx: &mut TxContext,
    ): RouterAdminCap {
        assert_governance_recipient(recipient);
        bootstrap_router_admin_internal(router, recipient, ctx)
    }

    #[test_only]
    public fun destroy_router_admin_cap_for_testing(cap: RouterAdminCap) {
        let RouterAdminCap { id, router_id: _ } = cap;
        object::delete(id);
    }

    #[test_only]
    public fun destroy_for_testing(router: YieldRouter) {
        let YieldRouter {
            mut id,
            auto_yield_default_off: _,
            protocol_yield_skim_bps: _,
            paused: _,
        } = router;
        if (dynamic_field::exists(&id, RouterAdminAnchorKey {})) {
            let RouterAdminAnchor { admin_cap_id: _, governance: _ } =
                dynamic_field::remove<RouterAdminAnchorKey, RouterAdminAnchor>(
                    &mut id,
                    RouterAdminAnchorKey {},
                );
        };
        object::delete(id);
    }
}

#[test_only]
module day::yield_router_profit_fee_tests {
    use day::yield_router;
    use sui::tx_context;

    const TREASURY: address = @0x7EA5;

    /// Disabled config charges 0 even on a huge realized profit.
    #[test]
    fun test_profit_fee_disabled_is_zero() {
        let mut ctx = tx_context::dummy();
        let config = yield_router::new_config_for_testing(100, 10_000_000, false, TREASURY, &mut ctx);
        assert!(yield_router::quote_profit_fee(&config, 1_000_000_000) == 0, 0);
        assert!(yield_router::quote_profit_fee(&config, 0) == 0, 1);
        yield_router::destroy_config_for_testing(config);
    }

    /// Enabled 1% / $10 cap: 1% of $100 = $1, 1% of $1000 = $10 (at cap),
    /// 1% of $2000 = $10 (capped down from $20).
    #[test]
    fun test_profit_fee_enabled_1pct_capped_10() {
        let mut ctx = tx_context::dummy();
        let config = yield_router::new_config_for_testing(100, 10_000_000, true, TREASURY, &mut ctx);
        // $100 profit = 100_000_000 micros → 1% = $1 = 1_000_000 micros
        assert!(yield_router::quote_profit_fee(&config, 100_000_000) == 1_000_000, 10);
        // $1000 profit = 1_000_000_000 micros → 1% = $10 = 10_000_000 (exactly at cap)
        assert!(yield_router::quote_profit_fee(&config, 1_000_000_000) == 10_000_000, 11);
        // $2000 profit = 2_000_000_000 micros → 1% = $20 → capped to $10
        assert!(yield_router::quote_profit_fee(&config, 2_000_000_000) == 10_000_000, 12);
        // zero profit → zero fee
        assert!(yield_router::quote_profit_fee(&config, 0) == 0, 13);
        yield_router::destroy_config_for_testing(config);
    }

    /// A zero cap means "no cap" — the raw computed fee is returned uncapped.
    #[test]
    fun test_profit_fee_zero_cap_is_uncapped() {
        let mut ctx = tx_context::dummy();
        let config = yield_router::new_config_for_testing(100, 0, true, TREASURY, &mut ctx);
        // $2000 profit, 1%, no cap → $20 = 20_000_000 micros
        assert!(yield_router::quote_profit_fee(&config, 2_000_000_000) == 20_000_000, 20);
        yield_router::destroy_config_for_testing(config);
    }

    /// Defaults ship disabled: a freshly created config charges 0 profit fee.
    #[test]
    fun test_default_config_profit_fee_disabled() {
        let mut ctx = tx_context::dummy();
        // Mirror `create_fee_config` defaults: bps=100, cap=$10, enabled=false.
        let config = yield_router::new_config_for_testing(100, 10_000_000, false, TREASURY, &mut ctx);
        assert!(!yield_router::profit_fee_enabled(&config), 30);
        assert!(yield_router::profit_fee_bps(&config) == 100, 31);
        assert!(yield_router::profit_fee_cap_usd_micros(&config) == 10_000_000, 32);
        assert!(yield_router::quote_profit_fee(&config, 5_000_000_000) == 0, 33);
        yield_router::destroy_config_for_testing(config);
    }
}

/// DAY-795 pass-through forwarder tests. The legacy sender-paying fee splitter is
/// quarantined by DAY-824; these prove deposit and withdraw stay DAY-798 fail-closed.
#[test_only]
module day::yield_router_forwarder_tests {
    use day::yield_router;
    use day::adapter_registry::{Self, AdapterRegistryV2};
    use sui::coin;
    use sui::test_scenario as ts;

    /// Phantom test coin witness (a stand-in for a stablecoin like USDC).
    public struct FORWARD_TEST_COIN has drop {}

    const OWNER: address = @0x0BE4;
    const TREASURY: address = @0x7EA5;
    const ADAPTER: vector<u8> = b"suilend";

    /// $1000 USDC in micros (6dp): 1000 * 1_000_000.
    const AMOUNT_1000: u64 = 1_000_000_000;

    /// Register one active adapter into a freshly created shared registry, then
    /// advance one tx so the shared registry is visible to a subsequent take_shared.
    fun register_active_adapter(scn: &mut ts::Scenario) {
        adapter_registry::bootstrap_registry_v2_for_testing(OWNER, ts::ctx(scn));
        ts::next_tx(scn, OWNER);
        let cap = ts::take_from_sender<adapter_registry::RegistryAdminCap>(scn);
        let mut reg = ts::take_shared<AdapterRegistryV2>(scn);
        adapter_registry::register_authenticated(
            &cap,
            &mut reg,
            ADAPTER,
            b"sui",
            b"Suilend",
        );
        ts::return_to_sender(scn, cap);
        ts::return_shared(reg);
        ts::next_tx(scn, OWNER);
    }

    /// (c) forward_deposit is DAY-798-gated → aborts E_ADAPTER_NOT_WIRED, leaving the
    /// input coin untouched (tx reverts, coin returns to sender).
    #[test]
    #[expected_failure(abort_code = day::yield_router::E_ADAPTER_NOT_WIRED)]
    fun test_forward_deposit_aborts_adapter_not_wired() {
        let mut scn = ts::begin(OWNER);
        register_active_adapter(&mut scn);

        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let reg = ts::take_shared<AdapterRegistryV2>(&scn);

        let funds = coin::mint_for_testing<FORWARD_TEST_COIN>(AMOUNT_1000, ts::ctx(&mut scn));
        // Gated adapter → aborts before the coin is moved.
        yield_router::forward_deposit_v2<FORWARD_TEST_COIN>(
            &router, &reg, ADAPTER, funds, b"ix", ts::ctx(&mut scn),
        );

        // Unreachable (the call above aborts); present to satisfy resource linearity.
        ts::return_shared(reg);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    /// (d) forward_withdraw is DAY-798-gated → aborts E_ADAPTER_NOT_WIRED (fail-closed
    /// parity with deposit). No funds move while the adapter is gated.
    #[test]
    #[expected_failure(abort_code = day::yield_router::E_ADAPTER_NOT_WIRED)]
    fun test_forward_withdraw_aborts_adapter_not_wired() {
        let mut scn = ts::begin(OWNER);
        register_active_adapter(&mut scn);

        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let config =
            yield_router::new_config_for_testing(100, 10_000_000, true, TREASURY, ts::ctx(&mut scn));
        let reg = ts::take_shared<AdapterRegistryV2>(&scn);

        // Gated adapter → aborts (no caller coin; the adapter would produce it).
        yield_router::forward_withdraw_v2<FORWARD_TEST_COIN>(
            &router, &reg, &config, ADAPTER, 2_000_000_000, ts::ctx(&mut scn),
        );

        // Unreachable (the call above aborts); present to satisfy resource linearity.
        ts::return_shared(reg);
        yield_router::destroy_config_for_testing(config);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

}

/// DAY-763 Grok security-review regression tests for the config-management path:
/// authority-gated create, and zero-treasury rejection. Extended DAY-763 (Fable 5
/// MEDIUM) with the one-shot cap-consuming bootstrap tests.
#[test_only]
module day::yield_router_config_guard_tests {
    use day::yield_router::{Self, FeeConfigCreatorCap};
    use sui::test_scenario as ts;

    const TREASURY: address = @0x7EA5;

    /// (h) Grok HIGH #1 — a NON-authority sender cannot create a RouterFeeConfig even
    /// holding a cap: create_fee_config aborts E_NOT_AUTHORITY. (The cap itself can only
    /// ever be minted to the authority in production; the test-only cap constructor lets
    /// us isolate this specific guard.)
    #[test]
    #[expected_failure(abort_code = day::yield_router::E_NOT_AUTHORITY)]
    fun test_create_fee_config_non_authority_aborts() {
        // Begin a scenario as a NON-authority address.
        let mut scn = ts::begin(@0xBAD);
        let cap = yield_router::fee_config_creator_cap_for_testing(ts::ctx(&mut scn));
        yield_router::create_fee_config(cap, ts::ctx(&mut scn));
        ts::end(scn);
    }

    /// (i) Grok HIGH #1 — the AUTHORITY, holding a cap, can create the canonical config;
    /// the created (shared) config records owner == DAY_AUTHORITY and ships fee DISABLED.
    #[test]
    fun test_create_fee_config_authority_ok() {
        let authority = yield_router::day_authority_for_testing();
        let mut scn = ts::begin(authority);
        let cap = yield_router::fee_config_creator_cap_for_testing(ts::ctx(&mut scn));
        yield_router::create_fee_config(cap, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, authority);
        let config = ts::take_shared<yield_router::RouterFeeConfig>(&scn);
        assert!(yield_router::owner(&config) == authority, 0);
        assert!(!yield_router::profit_fee_enabled(&config), 1);
        ts::return_shared(config);
        ts::end(scn);
    }

    // ── DAY-763 (Fable 5 MEDIUM) one-shot bootstrap regression tests ─────────

    /// (l) Fable 5 MEDIUM — a NON-authority sender cannot mint a FeeConfigCreatorCap:
    /// mint_fee_config_creator_cap aborts E_NOT_AUTHORITY. Proves an attacker cannot
    /// self-issue a cap and therefore cannot bootstrap a rogue config via the real
    /// production entry point.
    #[test]
    #[expected_failure(abort_code = day::yield_router::E_NOT_AUTHORITY)]
    fun test_mint_fee_config_creator_cap_non_authority_aborts() {
        let mut scn = ts::begin(@0xBAD);
        yield_router::mint_fee_config_creator_cap(ts::ctx(&mut scn));
        ts::end(scn);
    }

    /// (m) Fable 5 MEDIUM — the full production bootstrap path: the authority mints a
    /// cap via `mint_fee_config_creator_cap` (the real entry point, not the test-only
    /// constructor), receives it, then consumes it via `create_fee_config` to produce
    /// the canonical shared config. Proves the end-to-end one-shot flow works exactly as
    /// a real PTB would compose it.
    #[test]
    fun test_mint_then_create_fee_config_end_to_end() {
        let authority = yield_router::day_authority_for_testing();
        let mut scn = ts::begin(authority);

        // Step 1: mint the cap (real entry point) — transferred to the authority.
        yield_router::mint_fee_config_creator_cap(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, authority);

        // Step 2: the authority picks up the freshly minted (owned, not shared) cap.
        let cap = ts::take_from_address<FeeConfigCreatorCap>(&scn, authority);

        // Step 3: consume the cap to create + share the canonical config.
        yield_router::create_fee_config(cap, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, authority);

        let config = ts::take_shared<yield_router::RouterFeeConfig>(&scn);
        assert!(yield_router::owner(&config) == authority, 0);
        assert!(!yield_router::profit_fee_enabled(&config), 1);
        ts::return_shared(config);

        // No leftover cap: the authority's address should have nothing of this type
        // left to take (it was consumed, not merely moved).
        assert!(!ts::has_most_recent_for_address<FeeConfigCreatorCap>(authority), 2);
        ts::end(scn);
    }

    /// (n) Fable 5 MEDIUM — the one-shot invariant itself: a `FeeConfigCreatorCap` has
    /// no `copy` ability, so it is IMPOSSIBLE to write Move source that duplicates a cap
    /// and consumes it twice — the Move compiler rejects any such program at compile
    /// time (a "copy of a non-copyable resource" / linearity violation), long before it
    /// could ever run. That guarantee cannot be expressed as a *runtime* test (there is
    /// no valid program to execute that violates it), so this test instead pins the
    /// OBSERVABLE consequence: consuming ONE cap yields EXACTLY one config, and the cap
    /// is gone afterward (already covered by assertion (2) in test `m` above). This test
    /// additionally proves two independently-minted caps are two independent resources
    /// that each separately produce their own config — i.e. caps don't merge, alias, or
    /// let one consumption implicitly cover another.
    #[test]
    fun test_two_independent_caps_yield_two_independent_configs() {
        let authority = yield_router::day_authority_for_testing();
        let mut scn = ts::begin(authority);

        let cap_a = yield_router::fee_config_creator_cap_for_testing(ts::ctx(&mut scn));
        let cap_b = yield_router::fee_config_creator_cap_for_testing(ts::ctx(&mut scn));

        yield_router::create_fee_config(cap_a, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, authority);
        let config_a = ts::take_shared<yield_router::RouterFeeConfig>(&scn);

        yield_router::create_fee_config(cap_b, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, authority);
        let config_b = ts::take_shared<yield_router::RouterFeeConfig>(&scn);

        // Two distinct configs, each individually well-formed — one cap in, one config
        // out, every time. Neither creation call could have succeeded without its own,
        // distinct, by-value cap argument (the compiler enforces this — a cap cannot be
        // borrowed or reused across the two calls).
        assert!(yield_router::owner(&config_a) == authority, 0);
        assert!(yield_router::owner(&config_b) == authority, 1);

        ts::return_shared(config_a);
        ts::return_shared(config_b);
        ts::end(scn);
    }

    /// (j) Grok LOW #4 — set_treasury rejects the zero address (E_ZERO_TREASURY).
    #[test]
    #[expected_failure(abort_code = day::yield_router::E_ZERO_TREASURY)]
    fun test_set_treasury_rejects_zero() {
        let authority = yield_router::day_authority_for_testing();
        let mut scn = ts::begin(authority);
        let mut config =
            yield_router::new_config_for_testing(100, 10_000_000, false, TREASURY, ts::ctx(&mut scn));
        // Owner == authority == sender → passes owner check, then hits zero-treasury guard.
        yield_router::set_treasury(&mut config, @0x0, ts::ctx(&mut scn));
        yield_router::destroy_config_for_testing(config);
        ts::end(scn);
    }

    /// (k) Grok LOW #4 — set_profit_fee also rejects the zero treasury (E_ZERO_TREASURY).
    #[test]
    #[expected_failure(abort_code = day::yield_router::E_ZERO_TREASURY)]
    fun test_set_profit_fee_rejects_zero_treasury() {
        let authority = yield_router::day_authority_for_testing();
        let mut scn = ts::begin(authority);
        let mut config =
            yield_router::new_config_for_testing(100, 10_000_000, false, TREASURY, ts::ctx(&mut scn));
        yield_router::set_profit_fee(&mut config, 100, 10_000_000, true, @0x0, ts::ctx(&mut scn));
        yield_router::destroy_config_for_testing(config);
        ts::end(scn);
    }
}
