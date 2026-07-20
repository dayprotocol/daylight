// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-846 position record and per-spoke opportunity accounting.
///
/// This is the shared accounting foundation for both plain opportunities and
/// managed opportunities. `strategy_id == none` is the structural absence of
/// leader authority; `strategy_id == some` requires a pinned Guardrails id.
///
/// Security invariants:
///   - the depositor and payout destination are the transaction sender at open;
///     no caller-supplied owner or payout destination exists;
///   - owner exit has NO destination argument and derives it from the Position;
///   - owner exit has NO StrategyRegistry, Guardrails, leader, quote, or DAY API
///     dependency, so lifecycle pause/retire cannot block it;
///   - accounting stores internally reconciled total assets and never owns a
///     Coin or Balance, so principal can transit but cannot rest here;
///   - there is no caller-supplied profit or raw-balance NAV path;
///   - every Position pins its local accounting object, opportunity, origin,
///     optional strategy, and optional Guardrails object for its lifetime.
///
/// Production mutation hooks are `public(package)`: a wired adapter/forwarder
/// must prove the actual asset movement before calling them. Until DAY-798 wires
/// that authenticated path, arbitrary public callers cannot fabricate deposits,
/// TVL, yield, or exits in this ledger.
module day::managed_position {
    use day::adapter_registry::{Self, AdapterRegistryV2};
    use day::day::{Self, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2, NativeAssetBinding};
    use day::leader_policy::{Self, EnteredExitModeAuthorization, LeaderPolicy};
    use day::managed_math;
    use day::managed_route::{Self, RouteLegBinding};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use std::type_name::{Self, TypeName};
    use sui::coin::{Self, Coin};
    use sui::dynamic_object_field;
    use sui::event;

    const PPS_SCALE: u128 = 1_000_000;
    const BASIS_POINTS: u64 = 10_000;
    const HASH_LEN: u64 = 32;

    const E_ZERO_AMOUNT: u64 = 1;
    const E_ZERO_SHARES: u64 = 2;
    const E_NOT_DEPOSITOR: u64 = 3;
    const E_INSUFFICIENT_SHARES: u64 = 4;
    const E_WRONG_ACCOUNTING: u64 = 5;
    const E_WRONG_ORIGIN_ASSET: u64 = 6;
    const E_INVALID_POLICY_BINDING: u64 = 7;
    const E_EMPTY_OPPORTUNITY: u64 = 8;
    const E_EMPTY_CHAIN: u64 = 9;
    const E_ASSET_UNDERFLOW: u64 = 10;
    const E_SHARE_UNDERFLOW: u64 = 16;
    const E_PAYOUT_AMOUNT_MISMATCH: u64 = 17;
    const E_ACCOUNTING_INVARIANT: u64 = 19;
    const E_INVALID_FEE_POLICY: u64 = 20;
    const E_INSUFFICIENT_LIQUID: u64 = 21;
    const E_INSUFFICIENT_DEPLOYED: u64 = 22;
    const E_WRONG_STRATEGY: u64 = 23;
    const E_INVALID_FORCE_EXIT_CONSENT: u64 = 24;
    const E_SOURCE_PROOF_REQUIRED: u64 = 26;
    const E_WRONG_CANONICAL_AUTHORITY: u64 = 27;
    const E_WRONG_ADAPTER_SOURCE: u64 = 28;
    const E_WRONG_ADAPTER_NONCE: u64 = 29;
    const E_PRIMITIVE_ADAPTER_WITNESS: u64 = 30;
    const E_FEE_CRYSTALLIZATION_REQUIRED: u64 = 31;
    /// Force-exit ticket/receipt failed an exact identity check.
    const E_INVALID_FORCE_EXIT_TICKET: u64 = 32;
    /// Force-exit settle_after_ms is not strictly after now (or pot mismatch).
    const E_INVALID_FORCE_EXIT_DEADLINE: u64 = 33;

    /// O(1) per-spoke accounting for one opportunity and one native asset type.
    /// This object contains accounting only: no Coin<T>, Balance<T>, or custody.
    public struct OpportunityAccounting has key {
        id: UID,
        /// Canonical on-chain-resolvable opportunity identifier.
        opportunity_id: vector<u8>,
        /// Chain whose contract owns this ledger (for this module, Sui).
        spoke_chain: vector<u8>,
        /// Original-id TypeName is stable across package upgrades.
        accounting_asset: TypeName,
        /// Exact chain-native asset identity for this opportunity endpoint.
        /// Sui values are VM-derived original TypeNames; remote values are
        /// copied only from the hash-bound frozen Guardrails policy.
        native_asset_binding: NativeAssetBinding,
        /// Canonical StrategyRegistry key. `none` is a plain opportunity leg.
        strategy_id: Option<vector<u8>>,
        /// Exact ProtocolConfig and registry AdminCap anchors proven at managed
        /// accounting creation. Both are absent for a plain opportunity.
        protocol_config_id: Option<ID>,
        registry_admin_cap_id: Option<ID>,
        /// Exact canonical registry that authenticated the managed strategy.
        /// `none` is a plain opportunity leg.
        strategy_registry_id: Option<ID>,
        /// Frozen GuardrailsV2 binding. Both are absent for a plain leg and
        /// present for a managed leg; the hash is derived from the object.
        guardrails_id: Option<ID>,
        guardrails_hash: Option<vector<u8>>,
        /// Canonical AdapterRegistryV2 and exact reviewed adapter binding.
        adapter_registry_id: ID,
        adapter_id: vector<u8>,
        adapter_source: TypeName,
        /// Monotonic sequence consumed by every deployment/return receipt.
        adapter_nonce: u64,
        /// Authenticated in-flight/local liquidity, measured from Coin<T> on
        /// production mutations rather than asserted by a keeper.
        liquid_assets_micros: u128,
        /// Adapter deployment basis. Production mutation remains fail-closed
        /// until a reviewed adapter supplies a nonce-bound receipt; tests model
        /// the invariant without claiming DAY-862 production completion.
        deployed_assets_micros: u128,
        /// Basis committed to an authenticated reallocation receipt but not
        /// yet reconciled at the destination.
        in_transit_assets_micros: u128,
        /// Always exactly liquid + deployed + in-transit on every mutation.
        total_assets_micros: u128,
        total_shares: u128,
        /// Aggregate fee-exempt asset basis for the current shares. Unlike a
        /// lone global PPS this can be increased by a new subscription without
        /// erasing accrued profit or charging the newcomer for old gain.
        fee_basis_assets_micros: u128,
        /// Net-of-fee high-water price per share for this strategy/opportunity leg.
        high_water_pps: u128,
        lead_fee_bps: u64,
        day_share_bps: u64,
        lead_fee_destination: address,
        day_fee_destination: address,
        adapter_destination: address,
    }

    /// Owner-held claim. All routing and payout bindings are immutable; only
    /// `shares` decreases during an owner-authorized exit.
    public struct Position has key {
        id: UID,
        /// Exact local leg/accounting object this claim belongs to.
        leg_accounting_id: ID,
        /// Copied from the accounting object so indexers can query without DAY.
        opportunity_id: vector<u8>,
        /// Every swap/bridge/deposit leg used to open this claim, in order.
        /// The final descriptor must be this Position's deposit opportunity.
        entry_route_legs: vector<RouteLegBinding>,
        /// Origin wallet and the only signer allowed to burn shares.
        depositor: address,
        /// The ONLY payout destination. It is never accepted as an exit input.
        payout_destination: address,
        /// Origin chain and token are frozen at deposit.
        origin_chain: vector<u8>,
        origin_asset: TypeName,
        /// none = plain opportunity and therefore no leader authority.
        strategy_id: Option<vector<u8>>,
        /// Pinned policy for managed positions; none exactly when strategy is none.
        guardrails_id: Option<ID>,
        /// Immutable deposit-time owner consent. A leader can never force an
        /// exit for a plain position or a managed position that did not opt in.
        leader_may_force_exit: bool,
        /// Frozen policy object authorizing the exact force-exit semantics.
        /// Present iff `leader_may_force_exit` is true.
        force_exit_policy_id: Option<ID>,
        shares: u128,
    }

    /// One delayed frozen-exit consent for a Position. It is a dynamic child of
    /// the Position, so the deployed Position layout remains unchanged. The
    /// reservation is created by the owner at consent time and consumed only by
    /// the package closeout path bound to `pot_id`.
    public struct FrozenExitConsent<phantom T> has key, store {
        id: UID,
        pot_id: ID,
        accounting_id: ID,
        accounting_asset: TypeName,
        position_id: ID,
        shares: u128,
        frozen_assets_micros: u128,
        frozen_pps: u128,
        reserved_fee_basis_micros: u128,
        fee_basis_before_micros: u128,
        high_water_before_pps: u128,
        payout_destination: address,
        self_settle_deadline_ms: u64,
    }

    public struct FrozenExitConsentKey has copy, drop, store {}

    /// Linear settlement instruction. A package forwarder consumes this and
    /// transfers the returned principal to `destination`. Private fields make it
    /// impossible for a caller to fabricate or rewrite the destination.
    public struct OwnerPayout<phantom T> {
        position_id: ID,
        leg_accounting_id: ID,
        destination: address,
        origin_chain: vector<u8>,
        origin_asset: TypeName,
        shares_burned: u128,
        assets_micros: u128,
    }

    /// Linear destination proof for a full-position in-kind exit. It carries
    /// no asset, price, NAV, profit, loss, or caller-selected recipient. The
    /// adapter can only obtain it after the normal owner authorization burns
    /// every share and removes the exact principal-denominated deployed basis.
    public struct InKindOwnerPayout<phantom T> {
        position_id: ID,
        leg_accounting_id: ID,
        destination: address,
        shares_burned: u128,
        cost_basis_micros: u128,
        terminal_adapter_nonce: u64,
    }

    /// Linear, source-typed proceeds. Constructors are package-only so a Coin
    /// cannot be relabelled as venue proceeds by an external caller.
    public struct LiquidExitProceeds<phantom T> { proceeds: Coin<T> }
    public struct DeployedExitProceeds<phantom T> { proceeds: Coin<T> }

    /// Non-copyable deployment evidence issued by the exact reviewed package
    /// adapter type bound when this accounting object was created.
    public struct AdapterDeploymentReceipt<phantom AdapterWitness, phantom T> {
        accounting_id: ID,
        adapter_source: TypeName,
        nonce: u64,
        in_flight: Coin<T>,
    }

    /// Non-copyable full-return evidence. `none` is an authenticated total loss;
    /// no caller supplies a loss or profit number.
    public struct AdapterReturnReceipt<phantom AdapterWitness, phantom T> {
        accounting_id: ID,
        purpose_id: ID,
        adapter_source: TypeName,
        nonce: u64,
        proceeds: Option<Coin<T>>,
    }

    /// Owner-closeout evidence bound to the exact position, share selection,
    /// and internally-derived reserved basis. A generic/full-pool return cannot
    /// be reassigned to an arbitrary claim.
    public struct AdapterCloseoutReturnReceipt<phantom AdapterWitness, phantom T> {
        accounting_id: ID,
        purpose_id: ID,
        position_id: ID,
        shares: u128,
        /// Gross NAV claim used to reconcile the share burn.
        reserved_assets_micros: u128,
        /// Fee-exempt basis for exactly those shares. This is distinct from
        /// gross NAV when profit accrued before the closeout receipt.
        reserved_fee_basis_micros: u128,
        adapter_source: TypeName,
        nonce: u64,
        proceeds: Option<Coin<T>>,
    }

    /// No-abilities authorization for exactly one full, consented Position under
    /// entered Exit Mode. Every field is derived from canonical objects or
    /// internal accounting; there is no caller payout, shares, amount, profit,
    /// or deadline input. DAY-849 force-sell / force-withdraw-everyone share this
    /// one primitive (leader chooses WHEN, never WHERE).
    public struct ConsentedForceExitTicket<phantom T> {
        registry_id: ID,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        policy_id: ID,
        latch_id: ID,
        entered_at_ms: u64,
        accounting_id: ID,
        position_id: ID,
        pot_id: ID,
        accounting_asset: TypeName,
        native_asset_binding: NativeAssetBinding,
        adapter_source: TypeName,
        adapter_nonce: u64,
        shares: u128,
        reserved_basis_micros: u128,
        settle_after_ms: u64,
    }

    /// Source-typed adapter receipt produced only by package adapter code after
    /// consuming the exact force-exit ticket. The measured Coin/none remains
    /// linear, and all authorization facts travel with it to settlement.
    /// Destination is deliberately absent — settlement copies
    /// `position.payout_destination` only.
    public struct ForceExitAdapterReceipt<phantom AdapterWitness, phantom T> {
        registry_id: ID,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        policy_id: ID,
        latch_id: ID,
        entered_at_ms: u64,
        accounting_id: ID,
        position_id: ID,
        pot_id: ID,
        accounting_asset: TypeName,
        native_asset_binding: NativeAssetBinding,
        adapter_source: TypeName,
        adapter_nonce: u64,
        shares: u128,
        reserved_basis_micros: u128,
        settle_after_ms: u64,
        proceeds: Option<Coin<T>>,
    }

    public struct PositionOpened has copy, drop {
        position_id: ID,
        leg_accounting_id: ID,
        opportunity_id: vector<u8>,
        entry_route_legs: vector<RouteLegBinding>,
        depositor: address,
        payout_destination: address,
        origin_chain: vector<u8>,
        origin_asset: TypeName,
        strategy_id: Option<vector<u8>>,
        guardrails_id: Option<ID>,
        leader_may_force_exit: bool,
        force_exit_policy_id: Option<ID>,
        assets_micros: u128,
        shares_minted: u128,
    }

    public struct OwnerExitRecorded has copy, drop {
        position_id: ID,
        leg_accounting_id: ID,
        /// Recorded Position destination, never tx sender or a function input.
        payout_destination: address,
        origin_chain: vector<u8>,
        origin_asset: TypeName,
        shares_burned: u128,
        assets_micros: u128,
    }

    /// Accounting-only fact for a multi-asset/in-kind exit. Unlike
    /// OwnerExitRecorded, `cost_basis_removed_micros` is explicitly not an
    /// assertion that this amount of the origin asset was paid to the owner.
    public struct InKindCostBasisRemoved has copy, drop {
        position_id: ID,
        leg_accounting_id: ID,
        payout_destination: address,
        shares_burned: u128,
        cost_basis_removed_micros: u128,
        terminal_adapter_nonce: u64,
    }

    public struct AccountingCreated has copy, drop {
        accounting_id: ID,
        strategy_registry_id: ID,
        strategy_id: vector<u8>,
        opportunity_id: vector<u8>,
        guardrails_id: ID,
        adapter_registry_id: ID,
        adapter_id: vector<u8>,
        adapter_source: TypeName,
    }

    fun new_accounting<T>(
        opportunity_id: vector<u8>,
        spoke_chain: vector<u8>,
        strategy_id: Option<vector<u8>>,
        protocol_config_id: Option<ID>,
        registry_admin_cap_id: Option<ID>,
        strategy_registry_id: Option<ID>,
        guardrails_id: Option<ID>,
        guardrails_hash: Option<vector<u8>>,
        native_asset_binding: NativeAssetBinding,
        adapter_registry_id: ID,
        adapter_id: vector<u8>,
        adapter_source: TypeName,
        lead_fee_bps: u64,
        day_share_bps: u64,
        lead_fee_destination: address,
        day_fee_destination: address,
        adapter_destination: address,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        assert!(!vector::is_empty(&opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&spoke_chain), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&adapter_id), E_WRONG_ADAPTER_SOURCE);
        assert!(adapter_destination != @0x0, E_INVALID_FEE_POLICY);
        guardrails_v2::assert_native_asset_binding(&native_asset_binding);
        assert!(
            guardrails_v2::native_asset_chain_id(&native_asset_binding) == spoke_chain,
            E_WRONG_ORIGIN_ASSET,
        );
        if (option::is_some(&strategy_id)) {
            assert!(!vector::is_empty(option::borrow(&strategy_id)), E_WRONG_STRATEGY);
            assert!(lead_fee_bps <= BASIS_POINTS && day_share_bps <= BASIS_POINTS, E_INVALID_FEE_POLICY);
            assert!(lead_fee_destination != @0x0 && day_fee_destination != @0x0, E_INVALID_FEE_POLICY);
            assert!(option::is_some(&guardrails_id), E_INVALID_POLICY_BINDING);
            assert!(option::is_some(&guardrails_hash), E_INVALID_POLICY_BINDING);
            assert!(option::is_some(&strategy_registry_id), E_INVALID_POLICY_BINDING);
            assert!(option::is_some(&protocol_config_id), E_INVALID_POLICY_BINDING);
            assert!(option::is_some(&registry_admin_cap_id), E_INVALID_POLICY_BINDING);
            assert!(vector::length(option::borrow(&guardrails_hash)) == HASH_LEN, E_INVALID_POLICY_BINDING);
        } else {
            assert!(lead_fee_bps == 0 && day_share_bps == 0, E_INVALID_FEE_POLICY);
            assert!(lead_fee_destination == @0x0 && day_fee_destination == @0x0, E_INVALID_FEE_POLICY);
            assert!(!option::is_some(&guardrails_id), E_INVALID_POLICY_BINDING);
            assert!(!option::is_some(&guardrails_hash), E_INVALID_POLICY_BINDING);
            assert!(!option::is_some(&strategy_registry_id), E_INVALID_POLICY_BINDING);
            assert!(!option::is_some(&protocol_config_id), E_INVALID_POLICY_BINDING);
            assert!(!option::is_some(&registry_admin_cap_id), E_INVALID_POLICY_BINDING);
        };
        OpportunityAccounting {
            id: object::new(ctx),
            opportunity_id,
            spoke_chain,
            accounting_asset: type_name::with_original_ids<T>(),
            native_asset_binding,
            strategy_id,
            protocol_config_id,
            registry_admin_cap_id,
            strategy_registry_id,
            guardrails_id,
            guardrails_hash,
            adapter_registry_id,
            adapter_id,
            adapter_source,
            adapter_nonce: 0,
            liquid_assets_micros: 0,
            deployed_assets_micros: 0,
            in_transit_assets_micros: 0,
            total_assets_micros: 0,
            total_shares: 0,
            fee_basis_assets_micros: 0,
            high_water_pps: PPS_SCALE,
            lead_fee_bps,
            day_share_bps,
            lead_fee_destination,
            day_fee_destination,
            adapter_destination,
        }
    }

    /// Create and share one managed accounting object under the canonical
    /// StrategyRegistry authority. Governance chooses fee destinations and the
    /// reviewed package adapter type, but cannot forge the immutable strategy,
    /// Guardrails, or registry bindings copied from canonical chain state.
    ///
    /// This source can ship before governance is selected: no capability is
    /// minted or transferred here, and the function is unusable until the
    /// existing one-shot registry bootstrap sends AdminCap to that recipient.
    public fun create_managed_accounting<AdapterWitness: drop, T>(
        config: &ProtocolConfig,
        strategy_registry: &StrategyRegistry,
        admin_cap: &AdminCap,
        adapters: &AdapterRegistryV2,
        guardrails: &GuardrailsV2,
        strategy_id: vector<u8>,
        opportunity_id: vector<u8>,
        spoke_chain: vector<u8>,
        remote_native_id: vector<u8>,
        adapter_id: vector<u8>,
        lead_fee_bps: u64,
        day_share_bps: u64,
        lead_fee_destination: address,
        day_fee_destination: address,
        adapter_destination: address,
        ctx: &mut TxContext,
    ): ID {
        let native_asset_binding = resolve_managed_native_asset_binding<T>(
            guardrails,
            spoke_chain,
            remote_native_id,
        );
        create_managed_accounting_with_binding<AdapterWitness, T>(
            config,
            strategy_registry,
            admin_cap,
            adapters,
            guardrails,
            strategy_id,
            opportunity_id,
            spoke_chain,
            native_asset_binding,
            adapter_id,
            lead_fee_bps,
            day_share_bps,
            lead_fee_destination,
            day_fee_destination,
            adapter_destination,
            ctx,
        )
    }

    fun resolve_managed_native_asset_binding<T>(
        guardrails: &GuardrailsV2,
        spoke_chain: vector<u8>,
        remote_native_id: vector<u8>,
    ): NativeAssetBinding {
        if (spoke_chain == b"sui") {
            assert!(vector::is_empty(&remote_native_id), E_WRONG_ORIGIN_ASSET);
            guardrails_v2::sui_asset_binding<T>()
        } else {
            // remote_native_id is only an exact lookup key. The returned and
            // stored binding is copied from the hash-bound frozen policy.
            guardrails_v2::native_asset_binding_from_policy(
                guardrails,
                spoke_chain,
                remote_native_id,
            )
        }
    }

    fun create_managed_accounting_with_binding<AdapterWitness: drop, T>(
        config: &ProtocolConfig,
        strategy_registry: &StrategyRegistry,
        admin_cap: &AdminCap,
        adapters: &AdapterRegistryV2,
        guardrails: &GuardrailsV2,
        strategy_id: vector<u8>,
        opportunity_id: vector<u8>,
        spoke_chain: vector<u8>,
        native_asset_binding: NativeAssetBinding,
        adapter_id: vector<u8>,
        lead_fee_bps: u64,
        day_share_bps: u64,
        lead_fee_destination: address,
        day_fee_destination: address,
        adapter_destination: address,
        ctx: &mut TxContext,
    ): ID {
        assert_canonical_accounting_authority(
            config,
            strategy_registry,
            admin_cap,
            adapters,
            ctx,
        );
        assert_nonprimitive_adapter_witness<AdapterWitness>();
        let adapter_source = type_name::with_original_ids<AdapterWitness>();
        strategy_registry::assert_accepts_new_deposit(strategy_registry, strategy_id);
        adapter_registry::assert_active_v2_on_chain(adapters, adapter_id, spoke_chain);
        let record = strategy_registry::record(strategy_registry, strategy_id);
        let guardrails_id = strategy_registry::guardrails_id(record);
        let guardrails_hash = strategy_registry::guardrails_hash(record);
        assert!(guardrails_v2::verify_hash(guardrails), E_INVALID_POLICY_BINDING);
        assert!(guardrails_v2::id(guardrails) == guardrails_id, E_INVALID_POLICY_BINDING);
        assert!(guardrails_v2::guardrails_hash(guardrails) == guardrails_hash, E_INVALID_POLICY_BINDING);
        guardrails_v2::assert_allocation_allowed<T>(
            guardrails,
            opportunity_id,
            spoke_chain,
            1,
        );
        guardrails_v2::assert_native_allocation_allowed(
            guardrails,
            &native_asset_binding,
            opportunity_id,
            1,
        );
        let accounting = new_accounting<T>(
            opportunity_id,
            spoke_chain,
            option::some(strategy_id),
            option::some(object::id(config)),
            option::some(object::id(admin_cap)),
            option::some(object::id(strategy_registry)),
            option::some(guardrails_id),
            option::some(guardrails_hash),
            native_asset_binding,
            object::id(adapters),
            adapter_id,
            adapter_source,
            lead_fee_bps,
            day_share_bps,
            lead_fee_destination,
            day_fee_destination,
            adapter_destination,
            ctx,
        );
        let accounting_id = object::id(&accounting);
        event::emit(AccountingCreated {
            accounting_id,
            strategy_registry_id: object::id(strategy_registry),
            strategy_id: strategy_registry::strategy_id(record),
            opportunity_id: accounting.opportunity_id,
            guardrails_id,
            adapter_registry_id: object::id(adapters),
            adapter_id: accounting.adapter_id,
            adapter_source: type_name::with_original_ids<AdapterWitness>(),
        });
        transfer::share_object(accounting);
        accounting_id
    }

    fun assert_canonical_accounting_authority(
        config: &ProtocolConfig,
        registry: &StrategyRegistry,
        cap: &AdminCap,
        adapters: &AdapterRegistryV2,
        ctx: &TxContext,
    ) {
        let canonical_registry = day::canonical_strategy_registry_id(config);
        let canonical_cap = day::canonical_strategy_registry_admin_cap_id(config);
        let canonical_adapters = day::canonical_adapter_registry_v2_id(config);
        assert!(option::is_some(&canonical_registry), E_WRONG_CANONICAL_AUTHORITY);
        assert!(option::is_some(&canonical_cap), E_WRONG_CANONICAL_AUTHORITY);
        assert!(option::is_some(&canonical_adapters), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&canonical_registry) == object::id(registry), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&canonical_cap) == object::id(cap), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&canonical_adapters) == object::id(adapters), E_WRONG_CANONICAL_AUTHORITY);
        assert!(strategy_registry::governance(registry) == tx_context::sender(ctx), E_WRONG_CANONICAL_AUTHORITY);
    }

    /// Record a locally authenticated deposit after a package adapter proves
    /// actual-received assets. Owner/destination/origin come from trusted state,
    /// never free parameters. This module transfers the non-publicly-transferable
    /// Position directly to the transaction sender and returns its id.
    public(package) fun record_local_deposit<T>(
        accounting: &mut OpportunityAccounting,
        in_flight: Coin<T>,
        ctx: &mut TxContext,
    ): (ID, Coin<T>) {
        assert_plain_accounting(accounting);
        let assets_received_micros = coin::value(&in_flight) as u128;
        let route = vector[managed_route::deposit_leg<T>(
            object::id(accounting),
            accounting.opportunity_id,
        )];
        let id = record_and_share_local_deposit<T>(
            accounting,
            route,
            option::none(),
            assets_received_micros,
            ctx,
        );
        (id, in_flight)
    }

    /// Managed deposit path. The caller supplies the immutable LeaderPolicy
    /// object itself, never an asserted id. Registry and Strategy must exactly
    /// match the canonical bindings stored at accounting creation. The policy
    /// id is recorded only when its frozen disclosure grants force-exit consent.
    public(package) fun record_managed_local_deposit<T>(
        accounting: &mut OpportunityAccounting,
        config: &ProtocolConfig,
        strategy_registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
        policy: &LeaderPolicy,
        allocation_bps: u64,
        in_flight: Coin<T>,
        ctx: &mut TxContext,
    ): (ID, Coin<T>) {
        assert_current_managed_authority<T>(
            accounting,
            config,
            strategy_registry,
            guardrails,
            adapters,
            allocation_bps,
        );
        let force_exit_policy_id = validated_force_exit_policy_id(accounting, policy);
        let assets_received_micros = coin::value(&in_flight) as u128;
        let route = vector[managed_route::deposit_leg<T>(
            object::id(accounting),
            accounting.opportunity_id,
        )];
        managed_route::assert_managed_entry_route_allowed<T>(
            &route,
            guardrails,
            allocation_bps,
            object::id(accounting),
            accounting.accounting_asset,
            accounting.opportunity_id,
        );
        let id = record_and_share_local_deposit<T>(
            accounting,
            route,
            force_exit_policy_id,
            assets_received_micros,
            ctx,
        );
        (id, in_flight)
    }

    /// Full entry-route hook for DAY-844. The composing package path must first
    /// enforce Guardrails on every descriptor, then pass the exact ordered leg
    /// identities here. This module fail-closes unknown/duplicate legs and binds
    /// the terminal deposit to the accounting opportunity.
    public(package) fun record_local_deposit_with_verified_route<T>(
        accounting: &mut OpportunityAccounting,
        entry_route_legs: vector<RouteLegBinding>,
        in_flight: Coin<T>,
        ctx: &mut TxContext,
    ): (ID, Coin<T>) {
        assert_plain_accounting(accounting);
        let assets_received_micros = coin::value(&in_flight) as u128;
        let id = record_and_share_local_deposit<T>(
            accounting,
            entry_route_legs,
            option::none(),
            assets_received_micros,
            ctx,
        );
        (id, in_flight)
    }

    public(package) fun record_managed_local_deposit_with_verified_route<T>(
        accounting: &mut OpportunityAccounting,
        config: &ProtocolConfig,
        strategy_registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
        policy: &LeaderPolicy,
        entry_route_legs: vector<RouteLegBinding>,
        allocation_bps: u64,
        in_flight: Coin<T>,
        ctx: &mut TxContext,
    ): (ID, Coin<T>) {
        assert_current_managed_authority<T>(
            accounting,
            config,
            strategy_registry,
            guardrails,
            adapters,
            allocation_bps,
        );
        let force_exit_policy_id = validated_force_exit_policy_id(accounting, policy);
        managed_route::assert_managed_entry_route_allowed<T>(
            &entry_route_legs,
            guardrails,
            allocation_bps,
            object::id(accounting),
            accounting.accounting_asset,
            accounting.opportunity_id,
        );
        let assets_received_micros = coin::value(&in_flight) as u128;
        let id = record_and_share_local_deposit<T>(
            accounting,
            entry_route_legs,
            force_exit_policy_id,
            assets_received_micros,
            ctx,
        );
        (id, in_flight)
    }

    fun assert_plain_accounting(accounting: &OpportunityAccounting) {
        assert!(!option::is_some(&accounting.strategy_id), E_INVALID_POLICY_BINDING);
        assert!(!option::is_some(&accounting.strategy_registry_id), E_INVALID_POLICY_BINDING);
    }

    /// Re-prove every mutable authority and the exact frozen policy on every
    /// managed money-path call. Stored ids are only historical bindings; the
    /// live objects and current lifecycle/adapter state remain mandatory.
    fun assert_current_managed_authority<T>(
        accounting: &OpportunityAccounting,
        config: &ProtocolConfig,
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
        allocation_bps: u64,
    ) {
        let strategy_id = assert_canonical_managed_binding<T>(
            accounting,
            config,
            registry,
            guardrails,
            adapters,
        );
        strategy_registry::assert_accepts_new_deposit(registry, strategy_id);
        adapter_registry::assert_active_v2_on_chain(
            adapters,
            accounting.adapter_id,
            accounting.spoke_chain,
        );
        guardrails_v2::assert_allocation_allowed<T>(
            guardrails,
            accounting.opportunity_id,
            accounting.spoke_chain,
            allocation_bps,
        );
    }

    /// Canonical recovery proof deliberately excludes lifecycle and adapter
    /// active-state gates. Pausing, retirement, or disabling future deployment
    /// must never strand an existing owner's authenticated return/exit (R3).
    fun assert_canonical_managed_binding<T>(
        accounting: &OpportunityAccounting,
        config: &ProtocolConfig,
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
    ): vector<u8> {
        assert!(option::is_some(&accounting.protocol_config_id), E_INVALID_POLICY_BINDING);
        assert!(option::is_some(&accounting.registry_admin_cap_id), E_INVALID_POLICY_BINDING);
        assert!(option::is_some(&accounting.strategy_registry_id), E_INVALID_POLICY_BINDING);
        assert!(option::is_some(&accounting.strategy_id), E_INVALID_POLICY_BINDING);
        assert!(option::is_some(&accounting.guardrails_id), E_INVALID_POLICY_BINDING);
        assert!(option::is_some(&accounting.guardrails_hash), E_INVALID_POLICY_BINDING);
        assert!(*option::borrow(&accounting.protocol_config_id) == object::id(config), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&accounting.strategy_registry_id) == object::id(registry), E_WRONG_CANONICAL_AUTHORITY);
        assert!(accounting.adapter_registry_id == object::id(adapters), E_WRONG_CANONICAL_AUTHORITY);
        let canonical_registry = day::canonical_strategy_registry_id(config);
        let canonical_cap = day::canonical_strategy_registry_admin_cap_id(config);
        let canonical_adapters = day::canonical_adapter_registry_v2_id(config);
        assert!(option::is_some(&canonical_registry), E_WRONG_CANONICAL_AUTHORITY);
        assert!(option::is_some(&canonical_cap), E_WRONG_CANONICAL_AUTHORITY);
        assert!(option::is_some(&canonical_adapters), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&canonical_registry) == object::id(registry), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&canonical_cap) == *option::borrow(&accounting.registry_admin_cap_id), E_WRONG_CANONICAL_AUTHORITY);
        assert!(*option::borrow(&canonical_adapters) == object::id(adapters), E_WRONG_CANONICAL_AUTHORITY);
        let strategy_id = *option::borrow(&accounting.strategy_id);
        let record = strategy_registry::record(registry, strategy_id);
        assert!(strategy_registry::guardrails_id(record) == guardrails_v2::id(guardrails), E_INVALID_POLICY_BINDING);
        assert!(strategy_registry::guardrails_hash(record) == guardrails_v2::guardrails_hash(guardrails), E_INVALID_POLICY_BINDING);
        assert!(*option::borrow(&accounting.guardrails_id) == guardrails_v2::id(guardrails), E_INVALID_POLICY_BINDING);
        assert!(*option::borrow(&accounting.guardrails_hash) == guardrails_v2::guardrails_hash(guardrails), E_INVALID_POLICY_BINDING);
        assert!(guardrails_v2::verify_hash(guardrails), E_INVALID_POLICY_BINDING);
        assert!(accounting.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ORIGIN_ASSET);
        strategy_id
    }

    fun validated_force_exit_policy_id(
        accounting: &OpportunityAccounting,
        policy: &LeaderPolicy,
    ): Option<ID> {
        assert!(option::is_some(&accounting.strategy_id), E_INVALID_POLICY_BINDING);
        assert!(option::is_some(&accounting.strategy_registry_id), E_INVALID_POLICY_BINDING);
        assert!(
            *option::borrow(&accounting.strategy_registry_id)
                == leader_policy::policy_registry_id(policy),
            E_INVALID_POLICY_BINDING,
        );
        assert!(
            *option::borrow(&accounting.strategy_id)
                == leader_policy::policy_strategy_id(policy),
            E_WRONG_STRATEGY,
        );
        if (leader_policy::leader_may_force_exit(policy)) {
            option::some(leader_policy::policy_id(policy))
        } else {
            option::none()
        }
    }

    /// Position is shared in the transaction that creates it. It has no
    /// `store`, so no late-share or address-transfer path exists. Every
    /// mutation remains field-/receipt-authorized; shared ownership is never
    /// authorization.
    fun record_and_share_local_deposit<T>(
        accounting: &mut OpportunityAccounting,
        entry_route_legs: vector<RouteLegBinding>,
        force_exit_policy_id: Option<ID>,
        assets_received_micros: u128,
        ctx: &mut TxContext,
    ): ID {
        let position = record_local_deposit_internal<T>(
            accounting,
            entry_route_legs,
            force_exit_policy_id,
            assets_received_micros,
            ctx,
        );
        let id = object::id(&position);
        transfer::share_object(position);
        id
    }

    fun record_local_deposit_internal<T>(
        accounting: &mut OpportunityAccounting,
        entry_route_legs: vector<RouteLegBinding>,
        force_exit_policy_id: Option<ID>,
        assets_received_micros: u128,
        ctx: &mut TxContext,
    ): Position {
        assert!(assets_received_micros > 0, E_ZERO_AMOUNT);
        assert!(accounting.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ORIGIN_ASSET);
        assert_policy_binding(
            &accounting.strategy_id,
            &force_exit_policy_id,
        );
        // Managed subscriptions require a clean fee epoch. A gain must first
        // pay the immutable waterfall; a drawdown must first recover to basis.
        // Admitting a newcomer on either side transfers the incumbent's fee or
        // loss carry-forward because this ledger intentionally has one O(1)
        // aggregate basis rather than per-position fee lots.
        if (option::is_some(&accounting.strategy_id) && accounting.lead_fee_bps > 0) {
            assert!(
                accounting.total_assets_micros == accounting.fee_basis_assets_micros,
                E_FEE_CRYSTALLIZATION_REQUIRED,
            );
        };
        managed_route::assert_bound_to_accounting<T>(
            &entry_route_legs,
            object::id(accounting),
            accounting.accounting_asset,
            accounting.opportunity_id,
        );

        let shares = convert_to_shares(
            assets_received_micros,
            accounting.total_assets_micros,
            accounting.total_shares,
        );
        assert!(shares > 0, E_ZERO_SHARES);

        accounting.liquid_assets_micros = accounting.liquid_assets_micros + assets_received_micros;
        accounting.total_assets_micros = accounting.total_assets_micros + assets_received_micros;
        accounting.total_shares = accounting.total_shares + shares;
        // Equalization: preserve all pre-subscription accrued profit while
        // adding exactly the newcomer's measured assets to fee-exempt basis.
        accounting.fee_basis_assets_micros = accounting.fee_basis_assets_micros
            + assets_received_micros;
        accounting.high_water_pps = price_per_share_ceil_from_totals(
            accounting.fee_basis_assets_micros,
            accounting.total_shares,
        );
        assert_accounting_invariant(accounting);

        let owner = tx_context::sender(ctx);
        let leader_may_force_exit = option::is_some(&force_exit_policy_id);
        let position = Position {
            id: object::new(ctx),
            leg_accounting_id: object::id(accounting),
            opportunity_id: accounting.opportunity_id,
            entry_route_legs,
            depositor: owner,
            payout_destination: owner,
            origin_chain: accounting.spoke_chain,
            origin_asset: accounting.accounting_asset,
            strategy_id: accounting.strategy_id,
            guardrails_id: accounting.guardrails_id,
            leader_may_force_exit,
            // Exact immutable LeaderPolicy identity supplied by the reviewed
            // DAY-849 path. Never substitute the Guardrails object id.
            force_exit_policy_id,
            shares,
        };
        event::emit(PositionOpened {
            position_id: object::id(&position),
            leg_accounting_id: position.leg_accounting_id,
            opportunity_id: position.opportunity_id,
            entry_route_legs: position.entry_route_legs,
            depositor: position.depositor,
            payout_destination: position.payout_destination,
            origin_chain: position.origin_chain,
            origin_asset: position.origin_asset,
            strategy_id: position.strategy_id,
            guardrails_id: position.guardrails_id,
            leader_may_force_exit: position.leader_may_force_exit,
            force_exit_policy_id: position.force_exit_policy_id,
            assets_micros: assets_received_micros,
            shares_minted: shares,
        });
        position
    }

    /// Owner-local exit accounting. There is deliberately NO payout destination,
    /// StrategyRegistry, Guardrails, leader, quote, or hub argument. The package
    /// forwarder must atomically consume the resulting OwnerPayout<T> while
    /// transferring actual venue proceeds to its recorded destination.
    fun authorize_owner_exit<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        shares: u128,
        liquid_debit: u128,
        deployed_debit: u128,
        ctx: &TxContext,
    ): OwnerPayout<T> {
        assert!(tx_context::sender(ctx) == position.depositor, E_NOT_DEPOSITOR);
        assert!(object::id(accounting) == position.leg_accounting_id, E_WRONG_ACCOUNTING);
        assert!(type_name::with_original_ids<T>() == position.origin_asset, E_WRONG_ORIGIN_ASSET);
        assert!(shares > 0, E_ZERO_SHARES);
        assert!(position.shares >= shares, E_INSUFFICIENT_SHARES);
        assert!(accounting.total_shares >= shares, E_SHARE_UNDERFLOW);

        // R3: a depositor's owner-local exit cannot depend on a leader or
        // keeper first crystallizing a profitable managed epoch. Subscription
        // remains fail-closed above while the epoch is dirty; exit does not.

        let assets = if (shares == accounting.total_shares) {
            // The final holder receives exact remaining NAV; virtual-offset
            // rounding must not strand the terminal dust.
            accounting.total_assets_micros
        } else {
            convert_to_assets(
                shares,
                accounting.total_assets_micros,
                accounting.total_shares,
            )
        };
        assert!(assets > 0, E_ZERO_AMOUNT);
        assert!(accounting.total_assets_micros >= assets, E_ASSET_UNDERFLOW);
        assert!(liquid_debit + deployed_debit == assets, E_PAYOUT_AMOUNT_MISMATCH);
        assert!(accounting.liquid_assets_micros >= liquid_debit, E_INSUFFICIENT_LIQUID);
        assert!(accounting.deployed_assets_micros >= deployed_debit, E_INSUFFICIENT_DEPLOYED);

        let shares_before = accounting.total_shares;
        position.shares = position.shares - shares;
        accounting.total_shares = accounting.total_shares - shares;
        reduce_fee_basis_for_burn(accounting, shares, shares_before);
        accounting.liquid_assets_micros = accounting.liquid_assets_micros - liquid_debit;
        accounting.deployed_assets_micros = accounting.deployed_assets_micros - deployed_debit;
        accounting.total_assets_micros = accounting.total_assets_micros - assets;
        assert_accounting_invariant(accounting);

        // R2: both event and linear payout use the Position field. Never replace
        // this with tx_context::sender(ctx) or a caller/message parameter.
        let destination = position.payout_destination;
        event::emit(OwnerExitRecorded {
            position_id: object::id(position),
            leg_accounting_id: position.leg_accounting_id,
            payout_destination: destination,
            origin_chain: position.origin_chain,
            origin_asset: position.origin_asset,
            shares_burned: shares,
            assets_micros: assets,
        });
        OwnerPayout<T> {
            position_id: object::id(position),
            leg_accounting_id: position.leg_accounting_id,
            destination,
            origin_chain: position.origin_chain,
            origin_asset: position.origin_asset,
            shares_burned: shares,
            assets_micros: assets,
        }
    }

    /// Atomic money-path hook for a wired package adapter. `proceeds` is a linear
    /// Coin<T> produced by the authenticated venue withdrawal in this same PTB.
    /// Its exact value must match internal share accounting, then this module
    /// transfers it to the Position's recorded destination. Reading the in-flight
    /// Coin verifies settlement; it is never used to derive NAV (R8).
    public(package) fun settle_owner_exit<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        shares: u128,
        proceeds: Coin<T>,
        ctx: &mut TxContext,
    ) {
        // This package-only path is deliberately liquid-only. A deployed venue
        // must first issue and reconcile its source-bound full-return receipt;
        // owner exit itself never depends on registry, leader, or lifecycle.
        let liquid_debit = coin::value(&proceeds) as u128;
        let payout = authorize_owner_exit<T>(
            accounting,
            position,
            shares,
            liquid_debit,
            0,
            ctx,
        );
        let OwnerPayout {
            position_id: _,
            leg_accounting_id: _,
            destination,
            origin_chain: _,
            origin_asset: _,
            shares_burned: _,
            assets_micros: _,
        } = payout;
        transfer::public_transfer(proceeds, destination);
    }

    /// Owner-sovereign full-position settlement for venues whose conclusive
    /// return is not denominated solely in the accounting asset. This is a
    /// distinct exact-lot mutation: it does not reuse the single-asset owner
    /// exit, reconciliation, or closeout paths and never compares a historical
    /// deployment nonce with the global current nonce. Later deposits may have
    /// advanced that nonce without invalidating this owner's escape.
    public(package) fun authorize_full_owner_in_kind_exit<AdapterWitness: drop, T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        _adapter_witness: &AdapterWitness,
        claim_cost_basis_micros: u128,
        ctx: &TxContext,
    ): InKindOwnerPayout<T> {
        assert_adapter_source<AdapterWitness, T>(accounting);
        assert!(tx_context::sender(ctx) == position.depositor, E_NOT_DEPOSITOR);
        assert!(object::id(accounting) == position.leg_accounting_id, E_WRONG_ACCOUNTING);
        assert!(type_name::with_original_ids<T>() == position.origin_asset, E_WRONG_ORIGIN_ASSET);
        let shares = position.shares;
        assert!(shares > 0, E_ZERO_SHARES);
        assert!(accounting.total_shares >= shares, E_SHARE_UNDERFLOW);
        assert!(claim_cost_basis_micros > 0, E_ZERO_AMOUNT);
        assert!(accounting.deployed_assets_micros >= claim_cost_basis_micros, E_INSUFFICIENT_DEPLOYED);
        assert!(accounting.total_assets_micros >= claim_cost_basis_micros, E_ASSET_UNDERFLOW);
        let shares_before = accounting.total_shares;
        position.shares = 0;
        accounting.total_shares = accounting.total_shares - shares;
        reduce_fee_basis_for_burn(accounting, shares, shares_before);
        accounting.deployed_assets_micros = accounting.deployed_assets_micros
            - claim_cost_basis_micros;
        accounting.total_assets_micros = accounting.total_assets_micros
            - claim_cost_basis_micros;
        accounting.adapter_nonce = accounting.adapter_nonce + 1;
        assert_accounting_invariant(accounting);
        let position_id = object::id(position);
        let leg_accounting_id = position.leg_accounting_id;
        let destination = position.payout_destination;
        event::emit(InKindCostBasisRemoved {
            position_id,
            leg_accounting_id,
            payout_destination: destination,
            shares_burned: shares,
            cost_basis_removed_micros: claim_cost_basis_micros,
            terminal_adapter_nonce: accounting.adapter_nonce,
        });
        InKindOwnerPayout<T> {
            position_id,
            leg_accounting_id,
            destination,
            shares_burned: shares,
            cost_basis_micros: claim_cost_basis_micros,
            terminal_adapter_nonce: accounting.adapter_nonce,
        }
    }

    /// Consume the private-destination proof. Keeping this destructuring in the
    /// accounting module prevents an adapter from constructing or rewriting a
    /// payout destination while still allowing it to emit venue-specific facts.
    public(package) fun consume_in_kind_owner_payout<T>(
        payout: InKindOwnerPayout<T>,
    ): (ID, ID, address, u128, u128, u64) {
        let InKindOwnerPayout {
            position_id,
            leg_accounting_id,
            destination,
            shares_burned,
            cost_basis_micros,
            terminal_adapter_nonce,
        } = payout;
        (
            position_id,
            leg_accounting_id,
            destination,
            shares_burned,
            cost_basis_micros,
            terminal_adapter_nonce,
        )
    }

    #[test_only]
    public fun settle_owner_exit_from_measured_sources_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        shares: u128,
        liquid: LiquidExitProceeds<T>,
        deployed: DeployedExitProceeds<T>,
        ctx: &mut TxContext,
    ) {
        let LiquidExitProceeds { proceeds: mut liquid_coin } = liquid;
        let DeployedExitProceeds { proceeds: deployed_coin } = deployed;
        let liquid_debit = coin::value(&liquid_coin) as u128;
        let deployed_debit = coin::value(&deployed_coin) as u128;
        let payout = authorize_owner_exit<T>(
            accounting,
            position,
            shares,
            liquid_debit,
            deployed_debit,
            ctx,
        );
        let OwnerPayout {
            position_id: _,
            leg_accounting_id: _,
            destination,
            origin_chain: _,
            origin_asset: _,
            shares_burned: _,
            assets_micros,
        } = payout;
        assert!(liquid_debit + deployed_debit == assets_micros, E_PAYOUT_AMOUNT_MISMATCH);
        coin::join(&mut liquid_coin, deployed_coin);
        // R2: payout destination comes only from Position through OwnerPayout.
        transfer::public_transfer(liquid_coin, destination);
    }

    /// Issue deployment evidence from reviewed package adapter code. The proof
    /// commits the accounting object, exact adapter source type, asset type, and
    /// current nonce while retaining the measured Coin linearly.
    public(package) fun attest_adapter_deployment<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        config: &ProtocolConfig,
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
        _adapter_witness: &AdapterWitness,
        allocation_bps: u64,
        in_flight: Coin<T>,
    ): AdapterDeploymentReceipt<AdapterWitness, T> {
        assert_current_managed_authority<T>(
            accounting,
            config,
            registry,
            guardrails,
            adapters,
            allocation_bps,
        );
        attest_adapter_deployment_internal(accounting, in_flight)
    }

    fun attest_adapter_deployment_internal<AdapterWitness, T>(
        accounting: &OpportunityAccounting,
        in_flight: Coin<T>,
    ): AdapterDeploymentReceipt<AdapterWitness, T> {
        assert_adapter_source<AdapterWitness, T>(accounting);
        let amount = coin::value(&in_flight) as u128;
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(accounting.liquid_assets_micros >= amount, E_INSUFFICIENT_LIQUID);
        AdapterDeploymentReceipt {
            accounting_id: object::id(accounting),
            adapter_source: type_name::with_original_ids<AdapterWitness>(),
            nonce: accounting.adapter_nonce,
            in_flight,
        }
    }

    /// Consume exact deployment evidence once. Replaying or reordering a proof
    /// fails the nonce check; a receipt from another adapter/accounting object
    /// fails before any accounting mutation.
    public(package) fun record_measured_deployment<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        receipt: AdapterDeploymentReceipt<AdapterWitness, T>,
    ): Coin<T> {
        let AdapterDeploymentReceipt {
            accounting_id,
            adapter_source,
            nonce,
            in_flight,
        } = receipt;
        assert_adapter_receipt<AdapterWitness, T>(
            accounting,
            accounting_id,
            adapter_source,
            nonce,
        );
        let amount = coin::value(&in_flight) as u128;
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(accounting.liquid_assets_micros >= amount, E_INSUFFICIENT_LIQUID);
        accounting.liquid_assets_micros = accounting.liquid_assets_micros - amount;
        accounting.deployed_assets_micros = accounting.deployed_assets_micros + amount;
        accounting.adapter_nonce = accounting.adapter_nonce + 1;
        assert_accounting_invariant(accounting);
        in_flight
    }

    /// Package adapter attestation for a conclusive full return. `none` is a
    /// source-authenticated total loss, while `some` carries the measured Coin.
    public(package) fun attest_adapter_return<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        config: &ProtocolConfig,
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
        _adapter_witness: &AdapterWitness,
        purpose_id: ID,
        proceeds: Option<Coin<T>>,
    ): AdapterReturnReceipt<AdapterWitness, T> {
        let _ = assert_canonical_managed_binding<T>(
            accounting,
            config,
            registry,
            guardrails,
            adapters,
        );
        attest_adapter_return_internal(accounting, purpose_id, proceeds)
    }

    fun attest_adapter_return_internal<AdapterWitness, T>(
        accounting: &OpportunityAccounting,
        purpose_id: ID,
        proceeds: Option<Coin<T>>,
    ): AdapterReturnReceipt<AdapterWitness, T> {
        assert_adapter_source<AdapterWitness, T>(accounting);
        AdapterReturnReceipt {
            accounting_id: object::id(accounting),
            purpose_id,
            adapter_source: type_name::with_original_ids<AdapterWitness>(),
            nonce: accounting.adapter_nonce,
            proceeds,
        }
    }

    /// Verify and consume one full-return receipt for fee/closeout code. The
    /// nonce advances before the caller applies reconciliation, atomically in
    /// the same transaction.
    public(package) fun consume_adapter_full_return<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        expected_purpose_id: ID,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
    ): Option<Coin<T>> {
        let AdapterReturnReceipt {
            accounting_id,
            purpose_id,
            adapter_source,
            nonce,
            proceeds,
        } = receipt;
        assert_adapter_receipt<AdapterWitness, T>(
            accounting,
            accounting_id,
            adapter_source,
            nonce,
        );
        assert!(purpose_id == expected_purpose_id, E_WRONG_ACCOUNTING);
        accounting.adapter_nonce = accounting.adapter_nonce + 1;
        proceeds
    }

    /// Produce recovery evidence for one exact owner request. This deliberately
    /// excludes lifecycle/registry gates (R3), but the package adapter type,
    /// owner sender, accounting, position, shares, derived basis, nonce, asset,
    /// and purpose are all committed into the linear receipt.
    public(package) fun attest_adapter_closeout_return<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        _adapter_witness: &AdapterWitness,
        position: &Position,
        shares: u128,
        purpose_id: ID,
        proceeds: Option<Coin<T>>,
        ctx: &TxContext,
    ): AdapterCloseoutReturnReceipt<AdapterWitness, T> {
        assert!(tx_context::sender(ctx) == position.depositor, E_NOT_DEPOSITOR);
        attest_adapter_closeout_return_internal(
            accounting, position, shares, purpose_id, proceeds,
        )
    }

    fun attest_adapter_closeout_return_internal<AdapterWitness, T>(
        accounting: &OpportunityAccounting,
        position: &Position,
        shares: u128,
        purpose_id: ID,
        proceeds: Option<Coin<T>>,
    ): AdapterCloseoutReturnReceipt<AdapterWitness, T> {
        assert_adapter_source<AdapterWitness, T>(accounting);
        let reserved_assets_micros = preview_deployed_exit_basis<T>(
            accounting, position, shares,
        );
        let reserved_fee_basis_micros = if (shares == accounting.total_shares) {
            accounting.fee_basis_assets_micros
        } else {
            convert_to_assets(
                shares,
                accounting.fee_basis_assets_micros,
                accounting.total_shares,
            )
        };
        AdapterCloseoutReturnReceipt {
            accounting_id: object::id(accounting),
            purpose_id,
            position_id: object::id(position),
            shares,
            reserved_assets_micros,
            reserved_fee_basis_micros,
            adapter_source: type_name::with_original_ids<AdapterWitness>(),
            nonce: accounting.adapter_nonce,
            proceeds,
        }
    }

    public(package) fun consume_adapter_closeout_return<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        expected_purpose_id: ID,
        expected_position_id: ID,
        expected_shares: u128,
        receipt: AdapterCloseoutReturnReceipt<AdapterWitness, T>,
    ): (u128, u128, Option<Coin<T>>) {
        let AdapterCloseoutReturnReceipt {
            accounting_id,
            purpose_id,
            position_id,
            shares,
            reserved_assets_micros,
            reserved_fee_basis_micros,
            adapter_source,
            nonce,
            proceeds,
        } = receipt;
        assert_adapter_receipt<AdapterWitness, T>(
            accounting, accounting_id, adapter_source, nonce,
        );
        assert!(purpose_id == expected_purpose_id, E_WRONG_ACCOUNTING);
        assert!(position_id == expected_position_id, E_WRONG_ACCOUNTING);
        assert!(shares == expected_shares, E_PAYOUT_AMOUNT_MISMATCH);
        accounting.adapter_nonce = accounting.adapter_nonce + 1;
        (reserved_assets_micros, reserved_fee_basis_micros, proceeds)
    }

    /// Bind canonical entered Exit Mode to one real, full Position. This is a
    /// purpose-specific authorization, not a generic sender-bypass helper.
    /// Shares/basis/destination are derived only from live Position/accounting;
    /// the pot id and fixed settle deadline are package-supplied bindings.
    public(package) fun authorize_consented_force_exit<T>(
        accounting: &OpportunityAccounting,
        position: &Position,
        authorization: EnteredExitModeAuthorization,
        pot_id: ID,
        settle_after_ms: u64,
        now_ms: u64,
    ): ConsentedForceExitTicket<T> {
        let (
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id,
            entered_at_ms,
        ) = leader_policy::consume_entered_exit_mode_authorization(authorization);
        assert!(settle_after_ms > now_ms, E_INVALID_FORCE_EXIT_DEADLINE);
        assert!(object::id(accounting) == position.leg_accounting_id, E_WRONG_ACCOUNTING);
        assert!(accounting.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ORIGIN_ASSET);
        assert!(option::is_some(&accounting.strategy_registry_id), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.strategy_id), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.guardrails_id), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.guardrails_hash), E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.strategy_registry_id) == registry_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.strategy_id) == strategy_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.guardrails_id) == guardrails_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.guardrails_hash) == guardrails_hash, E_INVALID_FORCE_EXIT_TICKET);
        assert!(
            matches_force_exit_policy(position, copy strategy_id, guardrails_id, policy_id),
            E_INVALID_FORCE_EXIT_CONSENT,
        );
        let shares = position.shares;
        assert!(shares > 0, E_ZERO_SHARES);
        // Until the authenticated fee waterfall is composed into this path, an
        // accrued managed gain must reconcile first rather than exiting free.
        assert!(
            accounting.total_assets_micros <= accounting.fee_basis_assets_micros,
            E_FEE_CRYSTALLIZATION_REQUIRED,
        );
        let reserved_basis_micros = preview_deployed_exit_basis<T>(
            accounting,
            position,
            shares,
        );
        ConsentedForceExitTicket<T> {
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id,
            entered_at_ms,
            accounting_id: object::id(accounting),
            position_id: object::id(position),
            pot_id,
            accounting_asset: accounting.accounting_asset,
            native_asset_binding: accounting.native_asset_binding,
            adapter_source: accounting.adapter_source,
            adapter_nonce: accounting.adapter_nonce,
            shares,
            reserved_basis_micros,
            settle_after_ms,
        }
    }

    /// Future reviewed adapter boundary. The adapter supplies only its package
    /// witness and measured Coin/none; all authorization facts travel with the
    /// ticket. Destination remains absent on purpose.
    public(package) fun attest_force_exit_adapter_return<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        position: &Position,
        ticket: ConsentedForceExitTicket<T>,
        _adapter_witness: &AdapterWitness,
        proceeds: Option<Coin<T>>,
    ): ForceExitAdapterReceipt<AdapterWitness, T> {
        let ConsentedForceExitTicket {
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id,
            entered_at_ms,
            accounting_id,
            position_id,
            pot_id,
            accounting_asset,
            native_asset_binding,
            adapter_source,
            adapter_nonce,
            shares,
            reserved_basis_micros,
            settle_after_ms,
        } = ticket;
        assert_adapter_receipt<AdapterWitness, T>(
            accounting,
            accounting_id,
            adapter_source,
            adapter_nonce,
        );
        assert!(position_id == object::id(position), E_INVALID_FORCE_EXIT_TICKET);
        assert!(position.shares == shares, E_INVALID_FORCE_EXIT_TICKET);
        assert!(accounting.accounting_asset == accounting_asset, E_INVALID_FORCE_EXIT_TICKET);
        assert!(guardrails_v2::same_native_asset_binding(
            &accounting.native_asset_binding,
            &native_asset_binding,
        ), E_INVALID_FORCE_EXIT_TICKET);
        assert!(
            preview_deployed_exit_basis<T>(accounting, position, shares) == reserved_basis_micros,
            E_INVALID_FORCE_EXIT_TICKET,
        );
        ForceExitAdapterReceipt<AdapterWitness, T> {
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id,
            entered_at_ms,
            accounting_id,
            position_id,
            pot_id,
            accounting_asset,
            native_asset_binding,
            adapter_source,
            adapter_nonce,
            shares,
            reserved_basis_micros,
            settle_after_ms,
            proceeds,
        }
    }

    /// Consume one exact force receipt and reserve its full Position without a
    /// sender check. The only sender-bypass is this no-abilities receipt path;
    /// owner exit continues through the independent sender-authenticated path.
    /// Payout destination is ALWAYS `position.payout_destination`.
    public(package) fun consume_and_reserve_consented_force_exit<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        expected_pot_id: ID,
        expected_settle_after_ms: u64,
        receipt: ForceExitAdapterReceipt<AdapterWitness, T>,
    ): (address, u128, u128, Option<Coin<T>>) {
        let ForceExitAdapterReceipt {
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id: _,
            entered_at_ms: _,
            accounting_id,
            position_id,
            pot_id,
            accounting_asset,
            native_asset_binding,
            adapter_source,
            adapter_nonce,
            shares,
            reserved_basis_micros,
            settle_after_ms,
            proceeds,
        } = receipt;
        assert_adapter_receipt<AdapterWitness, T>(
            accounting,
            accounting_id,
            adapter_source,
            adapter_nonce,
        );
        assert!(pot_id == expected_pot_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(settle_after_ms == expected_settle_after_ms, E_INVALID_FORCE_EXIT_DEADLINE);
        assert!(position_id == object::id(position), E_INVALID_FORCE_EXIT_TICKET);
        assert!(accounting.accounting_asset == accounting_asset, E_INVALID_FORCE_EXIT_TICKET);
        assert!(guardrails_v2::same_native_asset_binding(
            &accounting.native_asset_binding,
            &native_asset_binding,
        ), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.strategy_registry_id), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.strategy_id), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.guardrails_id), E_INVALID_FORCE_EXIT_TICKET);
        assert!(option::is_some(&accounting.guardrails_hash), E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.strategy_registry_id) == registry_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.strategy_id) == strategy_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.guardrails_id) == guardrails_id, E_INVALID_FORCE_EXIT_TICKET);
        assert!(*option::borrow(&accounting.guardrails_hash) == guardrails_hash, E_INVALID_FORCE_EXIT_TICKET);
        assert!(
            matches_force_exit_policy(position, strategy_id, guardrails_id, policy_id),
            E_INVALID_FORCE_EXIT_CONSENT,
        );
        assert!(shares > 0 && shares == position.shares, E_INVALID_FORCE_EXIT_TICKET);
        assert!(
            reserved_basis_micros == preview_deployed_exit_basis<T>(accounting, position, shares),
            E_INVALID_FORCE_EXIT_TICKET,
        );
        assert!(
            accounting.total_assets_micros <= accounting.fee_basis_assets_micros,
            E_FEE_CRYSTALLIZATION_REQUIRED,
        );

        let shares_before = accounting.total_shares;
        position.shares = 0;
        accounting.total_shares = accounting.total_shares - shares;
        reduce_fee_basis_for_burn(accounting, shares, shares_before);
        accounting.deployed_assets_micros = accounting.deployed_assets_micros - reserved_basis_micros;
        accounting.total_assets_micros = accounting.total_assets_micros - reserved_basis_micros;
        accounting.adapter_nonce = accounting.adapter_nonce + 1;
        assert_accounting_invariant(accounting);
        let destination = position.payout_destination;
        event::emit(OwnerExitRecorded {
            position_id,
            leg_accounting_id: position.leg_accounting_id,
            payout_destination: destination,
            origin_chain: position.origin_chain,
            origin_asset: position.origin_asset,
            shares_burned: shares,
            assets_micros: reserved_basis_micros,
        });
        (destination, shares, reserved_basis_micros, proceeds)
    }

    fun assert_adapter_source<AdapterWitness, T>(accounting: &OpportunityAccounting) {
        assert_nonprimitive_adapter_witness<AdapterWitness>();
        assert!(accounting.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ORIGIN_ASSET);
        assert!(accounting.adapter_source == type_name::with_original_ids<AdapterWitness>(), E_WRONG_ADAPTER_SOURCE);
    }

    /// Package adapters call this before venue interaction so an active byte
    /// label cannot be paired with an unrelated reviewed witness type.
    public(package) fun assert_exact_adapter_binding<AdapterWitness, T>(
        accounting: &OpportunityAccounting,
        expected_adapter_id: vector<u8>,
    ) {
        assert_adapter_source<AdapterWitness, T>(accounting);
        assert!(accounting.adapter_id == expected_adapter_id, E_WRONG_ADAPTER_SOURCE);
    }

    fun assert_nonprimitive_adapter_witness<AdapterWitness>() {
        assert!(
            !type_name::is_primitive(&type_name::with_original_ids<AdapterWitness>()),
            E_PRIMITIVE_ADAPTER_WITNESS,
        );
    }

    #[test_only]
    public fun assert_adapter_witness_for_testing<AdapterWitness>() {
        assert_nonprimitive_adapter_witness<AdapterWitness>()
    }

    fun assert_adapter_receipt<AdapterWitness, T>(
        accounting: &OpportunityAccounting,
        accounting_id: ID,
        adapter_source: TypeName,
        nonce: u64,
    ) {
        assert_adapter_source<AdapterWitness, T>(accounting);
        assert!(accounting_id == object::id(accounting), E_WRONG_ACCOUNTING);
        assert!(adapter_source == accounting.adapter_source, E_WRONG_ADAPTER_SOURCE);
        assert!(nonce == accounting.adapter_nonce, E_WRONG_ADAPTER_NONCE);
    }

    #[test_only]
    public fun attest_adapter_deployment_for_testing<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        _adapter_witness: &AdapterWitness,
        in_flight: Coin<T>,
    ): AdapterDeploymentReceipt<AdapterWitness, T> {
        attest_adapter_deployment_internal(accounting, in_flight)
    }

    #[test_only]
    public fun attest_adapter_return_for_testing<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        _adapter_witness: &AdapterWitness,
        purpose_id: ID,
        proceeds: Option<Coin<T>>,
    ): AdapterReturnReceipt<AdapterWitness, T> {
        attest_adapter_return_internal(accounting, purpose_id, proceeds)
    }

    #[test_only]
    public fun attest_adapter_closeout_return_for_testing<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        _adapter_witness: &AdapterWitness,
        position: &Position,
        shares: u128,
        purpose_id: ID,
        proceeds: Option<Coin<T>>,
    ): AdapterCloseoutReturnReceipt<AdapterWitness, T> {
        attest_adapter_closeout_return_internal(
            accounting, position, shares, purpose_id, proceeds,
        )
    }

    #[test_only]
    public fun record_measured_deployment_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        in_flight: Coin<T>,
    ): Coin<T> {
        assert!(accounting.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ORIGIN_ASSET);
        let amount = coin::value(&in_flight) as u128;
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(accounting.liquid_assets_micros >= amount, E_INSUFFICIENT_LIQUID);
        accounting.liquid_assets_micros = accounting.liquid_assets_micros - amount;
        accounting.deployed_assets_micros = accounting.deployed_assets_micros + amount;
        assert_accounting_invariant(accounting);
        in_flight
    }

    #[test_only]
    public fun bind_adapter_source_for_testing<AdapterWitness>(
        accounting: &mut OpportunityAccounting,
    ) {
        accounting.adapter_source = type_name::with_original_ids<AdapterWitness>();
    }

    #[test_only]
    public fun adapter_nonce_for_testing(accounting: &OpportunityAccounting): u64 {
        accounting.adapter_nonce
    }

    #[test_only]
    public fun consume_owner_payout_for_testing<T>(
        payout: OwnerPayout<T>,
    ): (ID, ID, address, vector<u8>, TypeName, u128, u128) {
        let OwnerPayout {
            position_id,
            leg_accounting_id,
            destination,
            origin_chain,
            origin_asset,
            shares_burned,
            assets_micros,
        } = payout;
        (
            position_id,
            leg_accounting_id,
            destination,
            origin_chain,
            origin_asset,
            shares_burned,
            assets_micros,
        )
    }

    /// Floor conversion. u256 intermediates prevent multiplication overflow;
    /// u128 storage/return matches the accounting design and fails closed if an
    /// impossible result cannot fit.
    public fun convert_to_shares(
        assets_micros: u128,
        total_assets_micros: u128,
        total_shares: u128,
    ): u128 {
        managed_math::to_shares(assets_micros, total_assets_micros, total_shares)
    }

    /// Floor conversion. Exiting users receive no more than their proportional
    /// claim; sub-micro dust remains for stayers rather than a treasury.
    public fun convert_to_assets(
        shares: u128,
        total_assets_micros: u128,
        total_shares: u128,
    ): u128 {
        managed_math::to_assets(shares, total_assets_micros, total_shares)
    }

    public fun price_per_share_micros(accounting: &OpportunityAccounting): u128 {
        price_per_share_from_totals(accounting.total_assets_micros, accounting.total_shares)
    }

    fun price_per_share_from_totals(total_assets_micros: u128, total_shares: u128): u128 {
        managed_math::price_per_share(total_assets_micros, total_shares)
    }

    public(package) fun fee_policy_for_package(
        accounting: &OpportunityAccounting,
    ): (u64, u64, address, address) {
        (
            accounting.lead_fee_bps,
            accounting.day_share_bps,
            accounting.lead_fee_destination,
            accounting.day_fee_destination,
        )
    }

    public(package) fun fee_basis_assets_micros_for_package(
        accounting: &OpportunityAccounting,
    ): u128 { accounting.fee_basis_assets_micros }

    public(package) fun adapter_destination_for_package(
        accounting: &OpportunityAccounting,
    ): address { accounting.adapter_destination }

    public(package) fun apply_full_reconciliation(
        accounting: &mut OpportunityAccounting,
        measured_net_return: u128,
        new_high_water_pps: u128,
    ) {
        assert!(accounting.in_transit_assets_micros == 0, E_SOURCE_PROOF_REQUIRED);
        accounting.deployed_assets_micros = 0;
        accounting.liquid_assets_micros = accounting.liquid_assets_micros + measured_net_return;
        accounting.total_assets_micros = accounting.liquid_assets_micros;
        if (accounting.total_assets_micros > accounting.fee_basis_assets_micros) {
            accounting.fee_basis_assets_micros = accounting.total_assets_micros;
        };
        accounting.high_water_pps = new_high_water_pps;
        assert_accounting_invariant(accounting);
    }

    /// Apply a fee amount derived by managed_closeout from authenticated state.
    /// No profit or NAV input is accepted; the only mutation is the exact Coin
    /// value already split to the immutable fee destinations.
    public(package) fun apply_fee_crystallization(
        accounting: &mut OpportunityAccounting,
        total_fees: u128,
    ) {
        assert!(accounting.liquid_assets_micros >= total_fees, E_INSUFFICIENT_LIQUID);
        assert!(accounting.total_assets_micros >= total_fees, E_ASSET_UNDERFLOW);
        accounting.liquid_assets_micros = accounting.liquid_assets_micros - total_fees;
        accounting.total_assets_micros = accounting.total_assets_micros - total_fees;
        // Crystallization resets the aggregate fee basis to net NAV. Loss basis
        // remains higher only when there was no feeable profit.
        if (accounting.total_assets_micros > accounting.fee_basis_assets_micros) {
            accounting.fee_basis_assets_micros = accounting.total_assets_micros;
        };
        accounting.high_water_pps = price_per_share_ceil_from_totals(
            accounting.fee_basis_assets_micros,
            accounting.total_shares,
        );
        assert_accounting_invariant(accounting);
    }

    /// Move a policy-selected basis into transit without accepting a raw amount.
    public(package) fun begin_measured_reallocation(
        accounting: &mut OpportunityAccounting,
        allocation_bps: u64,
    ): u128 {
        assert!(allocation_bps > 0 && allocation_bps <= BASIS_POINTS, E_INVALID_FEE_POLICY);
        let basis = (((accounting.deployed_assets_micros as u256)
            * (allocation_bps as u256)) / (BASIS_POINTS as u256)) as u128;
        assert!(basis > 0, E_ZERO_AMOUNT);
        accounting.deployed_assets_micros = accounting.deployed_assets_micros - basis;
        accounting.in_transit_assets_micros = accounting.in_transit_assets_micros + basis;
        assert_accounting_invariant(accounting);
        basis
    }

    /// Close transit at source and credit only the measured destination Coin.
    public(package) fun apply_measured_reallocation(
        accounting: &mut OpportunityAccounting,
        basis: u128,
        measured_return: u128,
    ) {
        assert!(accounting.in_transit_assets_micros >= basis, E_ASSET_UNDERFLOW);
        accounting.in_transit_assets_micros = accounting.in_transit_assets_micros - basis;
        accounting.deployed_assets_micros = accounting.deployed_assets_micros + measured_return;
        accounting.total_assets_micros = accounting.total_assets_micros - basis + measured_return;
        // Reallocation is not fee reconciliation. Preserve the previous HWM so
        // any measured gain remains feeable at the authenticated fee waterfall.
        assert_accounting_invariant(accounting);
    }

    /// Reconcile value deployed on a destination spoke back into the one
    /// canonical parent share ledger. The caller cannot assert either basis or
    /// profit: `managed_reallocation` derives both from its state and the
    /// measured Coin/none carried by a destination-bound adapter receipt.
    public(package) fun apply_measured_spoke_return(
        accounting: &mut OpportunityAccounting,
        deployed_basis: u128,
        measured_return: u128,
    ) {
        assert!(accounting.deployed_assets_micros >= deployed_basis, E_ASSET_UNDERFLOW);
        accounting.deployed_assets_micros = accounting.deployed_assets_micros - deployed_basis;
        accounting.liquid_assets_micros = accounting.liquid_assets_micros + measured_return;
        accounting.total_assets_micros = accounting.total_assets_micros
            - deployed_basis + measured_return;
        // A spoke return is not fee reconciliation. Preserve the previous HWM
        // so measured gain remains feeable by the authenticated waterfall.
        assert_accounting_invariant(accounting);
    }

    /// Reserve one owner's deployed claim for a frozen closeout. The owner and
    /// payout destination come only from Position. This removes both shares and
    /// their frozen basis from the live leg before the adapter return is priced.
    public(package) fun reserve_deployed_exit_for_closeout<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        shares: u128,
        ctx: &TxContext,
    ): u128 {
        assert!(tx_context::sender(ctx) == position.depositor, E_NOT_DEPOSITOR);
        let reserved_assets = preview_deployed_exit_basis<T>(accounting, position, shares);
        let shares_before = accounting.total_shares;
        position.shares = position.shares - shares;
        accounting.total_shares = accounting.total_shares - shares;
        reduce_fee_basis_for_burn(accounting, shares, shares_before);
        accounting.deployed_assets_micros = accounting.deployed_assets_micros - reserved_assets;
        accounting.total_assets_micros = accounting.total_assets_micros - reserved_assets;
        assert_accounting_invariant(accounting);
        reserved_assets
    }

    /// Owner-authorized delayed-closeout consent. Unlike the legacy atomic
    /// path, this freezes and removes the exact claim before a later adapter
    /// return can move the ledger PPS. Only one pending consent may exist for a
    /// Position, preventing a second closeout from reusing its shares.
    public(package) fun reserve_deployed_exit_for_frozen_consent<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        pot_id: ID,
        shares: u128,
        self_settle_deadline_ms: u64,
        ctx: &mut TxContext,
    ) {
        assert!(tx_context::sender(ctx) == position.depositor, E_NOT_DEPOSITOR);
        assert!(
            !dynamic_object_field::exists_(&position.id, FrozenExitConsentKey {}),
            E_INVALID_FORCE_EXIT_CONSENT,
        );
        let frozen_pps = price_per_share_micros(accounting);
        let fee_basis_before_micros = accounting.fee_basis_assets_micros;
        let high_water_before_pps = accounting.high_water_pps;
        let reserved_fee_basis_micros = if (shares == accounting.total_shares) {
            accounting.fee_basis_assets_micros
        } else {
            convert_to_assets(shares, accounting.fee_basis_assets_micros, accounting.total_shares)
        };
        let frozen_assets_micros = reserve_deployed_exit_for_closeout<T>(
            accounting, position, shares, ctx,
        );
        let consent = FrozenExitConsent<T> {
            id: object::new(ctx),
            pot_id,
            accounting_id: object::id(accounting),
            accounting_asset: accounting.accounting_asset,
            position_id: object::id(position),
            shares,
            frozen_assets_micros,
            frozen_pps,
            reserved_fee_basis_micros,
            fee_basis_before_micros,
            high_water_before_pps,
            payout_destination: position.payout_destination,
            self_settle_deadline_ms,
        };
        dynamic_object_field::add(&mut position.id, FrozenExitConsentKey {}, consent);
    }

    /// Consume the exact consent sidecar once. The caller receives only facts
    /// derived at consent; it cannot substitute current accounting totals,
    /// shares, price, or payout destination.
    public(package) fun consume_frozen_exit_consent<T>(
        accounting: &OpportunityAccounting,
        position: &mut Position,
        expected_pot_id: ID,
    ): (u128, u128, u128, u128, address) {
        assert!(dynamic_object_field::exists_(&position.id, FrozenExitConsentKey {}), E_INVALID_FORCE_EXIT_CONSENT);
        let FrozenExitConsent {
            id,
            pot_id,
            accounting_id,
            accounting_asset,
            position_id,
            shares,
            frozen_assets_micros,
            frozen_pps,
            reserved_fee_basis_micros,
            fee_basis_before_micros: _,
            high_water_before_pps: _,
            payout_destination,
            self_settle_deadline_ms: _,
        } = dynamic_object_field::remove<FrozenExitConsentKey, FrozenExitConsent<T>>(
            &mut position.id, FrozenExitConsentKey {},
        );
        assert!(pot_id == expected_pot_id, E_INVALID_FORCE_EXIT_CONSENT);
        assert!(accounting_id == object::id(accounting), E_WRONG_ACCOUNTING);
        assert!(accounting_asset == accounting.accounting_asset, E_WRONG_ORIGIN_ASSET);
        assert!(position_id == object::id(position), E_WRONG_ACCOUNTING);
        object::delete(id);
        (shares, frozen_assets_micros, frozen_pps, reserved_fee_basis_micros, payout_destination)
    }

    /// R3 recovery for an adapter return that never arrives. This restores the
    /// exact pre-consent accounting basis and Position shares, and remains
    /// owner-authorized even though Positions are shared.
    public(package) fun cancel_frozen_exit_consent<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        expected_pot_id: ID,
        now_ms: u64,
        ctx: &TxContext,
    ) {
        assert!(tx_context::sender(ctx) == position.depositor, E_NOT_DEPOSITOR);
        assert!(dynamic_object_field::exists_(&position.id, FrozenExitConsentKey {}), E_INVALID_FORCE_EXIT_CONSENT);
        let FrozenExitConsent {
            id,
            pot_id,
            accounting_id,
            accounting_asset,
            position_id,
            shares,
            frozen_assets_micros,
            frozen_pps: _,
            reserved_fee_basis_micros: _,
            fee_basis_before_micros,
            high_water_before_pps,
            payout_destination: _,
            self_settle_deadline_ms,
        } = dynamic_object_field::remove<FrozenExitConsentKey, FrozenExitConsent<T>>(
            &mut position.id, FrozenExitConsentKey {},
        );
        assert!(pot_id == expected_pot_id, E_INVALID_FORCE_EXIT_CONSENT);
        assert!(accounting_id == object::id(accounting), E_WRONG_ACCOUNTING);
        assert!(accounting_asset == accounting.accounting_asset, E_WRONG_ORIGIN_ASSET);
        assert!(position_id == object::id(position), E_WRONG_ACCOUNTING);
        assert!(now_ms > self_settle_deadline_ms, E_INVALID_FORCE_EXIT_CONSENT);
        position.shares = position.shares + shares;
        accounting.total_shares = accounting.total_shares + shares;
        accounting.deployed_assets_micros = accounting.deployed_assets_micros + frozen_assets_micros;
        accounting.total_assets_micros = accounting.total_assets_micros + frozen_assets_micros;
        accounting.fee_basis_assets_micros = fee_basis_before_micros;
        accounting.high_water_pps = high_water_before_pps;
        assert_accounting_invariant(accounting);
        object::delete(id);
    }

    fun preview_deployed_exit_basis<T>(
        accounting: &OpportunityAccounting,
        position: &Position,
        shares: u128,
    ): u128 {
        assert!(object::id(accounting) == position.leg_accounting_id, E_WRONG_ACCOUNTING);
        assert!(type_name::with_original_ids<T>() == position.origin_asset, E_WRONG_ORIGIN_ASSET);
        assert!(shares > 0, E_ZERO_SHARES);
        assert!(position.shares >= shares, E_INSUFFICIENT_SHARES);
        assert!(accounting.total_shares >= shares, E_SHARE_UNDERFLOW);
        let reserved_assets = convert_to_assets(
            shares,
            accounting.total_assets_micros,
            accounting.total_shares,
        );
        assert!(accounting.deployed_assets_micros >= reserved_assets, E_INSUFFICIENT_DEPLOYED);
        reserved_assets
    }

    fun reduce_fee_basis_for_burn(
        accounting: &mut OpportunityAccounting,
        shares_burned: u128,
        shares_before: u128,
    ) {
        let basis_reduction = if (shares_burned == shares_before) {
            accounting.fee_basis_assets_micros
        } else {
            // Use exactly the same virtual-offset conversion as the matching
            // asset debit. A raw pro-rata reduction can remove more basis than
            // assets after floor rounding, manufacturing feeable profit for
            // the remaining holders and making their next exit abort.
            convert_to_assets(
                shares_burned,
                accounting.fee_basis_assets_micros,
                shares_before,
            )
        };
        accounting.fee_basis_assets_micros = accounting.fee_basis_assets_micros
            - basis_reduction;
        accounting.high_water_pps = price_per_share_ceil_from_totals(
            accounting.fee_basis_assets_micros,
            accounting.total_shares,
        );
    }

    fun price_per_share_ceil_from_totals(total_assets: u128, total_shares: u128): u128 {
        if (total_shares == 0) return PPS_SCALE;
        let numerator = ((total_assets as u256) + 1_000) * (PPS_SCALE as u256);
        let denominator = (total_shares as u256) + 1_000;
        (((numerator + denominator - 1) / denominator) as u128)
    }

    /// Credit floor-rounding dust to the remaining leg, never to the caller,
    /// treasury, or whichever exit claim happens to settle last.
    public(package) fun credit_remaining_leg_dust(
        accounting: &mut OpportunityAccounting,
        dust_micros: u128,
    ) {
        // The matching Coin is transferred back to the bound adapter destination
        // in the same transaction, so this remains deployed value, not local
        // liquidity. Classifying it as liquid would let a later owner exit debit
        // assets that are not locally available.
        accounting.deployed_assets_micros = accounting.deployed_assets_micros + dust_micros;
        accounting.total_assets_micros = accounting.total_assets_micros + dust_micros;
        assert_accounting_invariant(accounting);
    }

    #[test_only]
    public fun apply_full_reconciliation_for_testing(
        accounting: &mut OpportunityAccounting,
        measured_net_return: u128,
        new_high_water_pps: u128,
    ) {
        apply_full_reconciliation(accounting, measured_net_return, new_high_water_pps)
    }

    #[test_only]
    public fun set_total_assets_for_testing(
        accounting: &mut OpportunityAccounting,
        total_assets_micros: u128,
    ) {
        assert!(accounting.deployed_assets_micros == 0, E_SOURCE_PROOF_REQUIRED);
        accounting.liquid_assets_micros = total_assets_micros;
        accounting.total_assets_micros = total_assets_micros;
        assert_accounting_invariant(accounting);
    }

    fun assert_accounting_invariant(accounting: &OpportunityAccounting) {
        guardrails_v2::assert_native_asset_binding(&accounting.native_asset_binding);
        assert!(
            guardrails_v2::native_asset_chain_id(&accounting.native_asset_binding)
                == accounting.spoke_chain,
            E_WRONG_ORIGIN_ASSET,
        );
        assert!(
            accounting.total_assets_micros
                == accounting.liquid_assets_micros
                    + accounting.deployed_assets_micros
                    + accounting.in_transit_assets_micros,
            E_ACCOUNTING_INVARIANT,
        );
    }

    fun assert_policy_binding(
        strategy_id: &Option<vector<u8>>,
        force_exit_policy_id: &Option<ID>,
    ) {
        if (!option::is_some(strategy_id)) {
            assert!(!option::is_some(force_exit_policy_id), E_INVALID_FORCE_EXIT_CONSENT);
            return
        };
        assert!(!vector::is_empty(option::borrow(strategy_id)), E_WRONG_STRATEGY);
    }

    /// Managed authorization must match both immutable ids. A plain position
    /// always returns false, so it cannot accidentally acquire leader authority.
    public fun matches_managed_policy(
        position: &Position,
        strategy_id: vector<u8>,
        guardrails_id: ID,
    ): bool {
        if (!option::is_some(&position.strategy_id)) return false;
        if (!option::is_some(&position.guardrails_id)) return false;
        *option::borrow(&position.strategy_id) == strategy_id
            && *option::borrow(&position.guardrails_id) == guardrails_id
    }

    /// DAY-849 force-exit gate. Plain positions and managed positions without
    /// frozen deposit-time consent always fail closed.
    public fun matches_force_exit_policy(
        position: &Position,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        force_exit_policy_id: ID,
    ): bool {
        position.leader_may_force_exit
            && matches_managed_policy(position, strategy_id, guardrails_id)
            && option::is_some(&position.force_exit_policy_id)
            && *option::borrow(&position.force_exit_policy_id) == force_exit_policy_id
    }

    // Read-only chain-state surface (R9).
    public fun accounting_id(accounting: &OpportunityAccounting): ID { object::id(accounting) }
    public fun accounting_opportunity_id(accounting: &OpportunityAccounting): vector<u8> {
        accounting.opportunity_id
    }
    public fun accounting_asset(accounting: &OpportunityAccounting): TypeName {
        accounting.accounting_asset
    }
    /// Package-only because executable authorization must compare this value
    /// directly with the validated route; external callers never supply an
    /// asset identity to the money path.
    public(package) fun accounting_native_asset_binding(
        accounting: &OpportunityAccounting,
    ): NativeAssetBinding {
        accounting.native_asset_binding
    }
    /// Single accounting-aware route proof for the leader leaf. The caller
    /// supplies the real source/destination objects, never endpoint asset
    /// bytes. IDs, opportunities and exact native bindings are all derived
    /// from those immutable ledgers in this call.
    public(package) fun validated_reallocation_route_for_accountings(
        source: &OpportunityAccounting,
        destination: &OpportunityAccounting,
        route: &vector<managed_route::ReallocationRouteLeg>,
        guardrails: &GuardrailsV2,
        allocation_bps: u64,
    ): (vector<u8>, NativeAssetBinding, NativeAssetBinding) {
        managed_route::validated_accounting_reallocation_route_canonical_v1(
            route,
            guardrails,
            allocation_bps,
            object::id(source),
            source.opportunity_id,
            &source.native_asset_binding,
            object::id(destination),
            destination.opportunity_id,
            &destination.native_asset_binding,
        )
    }
    public fun total_assets_micros(accounting: &OpportunityAccounting): u128 {
        accounting.total_assets_micros
    }
    public fun liquid_assets_micros(accounting: &OpportunityAccounting): u128 {
        accounting.liquid_assets_micros
    }
    public fun deployed_assets_micros(accounting: &OpportunityAccounting): u128 {
        accounting.deployed_assets_micros
    }
    public fun in_transit_assets_micros(accounting: &OpportunityAccounting): u128 {
        accounting.in_transit_assets_micros
    }
    public fun accounting_strategy_id(accounting: &OpportunityAccounting): Option<vector<u8>> {
        accounting.strategy_id
    }
    public fun accounting_guardrails_id(accounting: &OpportunityAccounting): Option<ID> {
        accounting.guardrails_id
    }
    public fun accounting_guardrails_hash(accounting: &OpportunityAccounting): Option<vector<u8>> {
        accounting.guardrails_hash
    }
    public fun high_water_pps(accounting: &OpportunityAccounting): u128 {
        accounting.high_water_pps
    }
    public fun total_shares(accounting: &OpportunityAccounting): u128 { accounting.total_shares }
    public(package) fun adapter_nonce_for_package(accounting: &OpportunityAccounting): u64 {
        accounting.adapter_nonce
    }
    public fun leg_accounting_id(position: &Position): ID { position.leg_accounting_id }
    public fun entry_route_legs(position: &Position): vector<RouteLegBinding> {
        position.entry_route_legs
    }
    public fun route_leg_source_chain(leg: &RouteLegBinding): vector<u8> {
        managed_route::source_chain(leg)
    }
    public fun route_leg_destination_chain(leg: &RouteLegBinding): vector<u8> {
        managed_route::destination_chain(leg)
    }
    public fun route_leg_target_opportunity(leg: &RouteLegBinding): Option<vector<u8>> {
        managed_route::target_opportunity(leg)
    }
    public fun recorded_payout_destination(position: &Position): address {
        position.payout_destination
    }
    public fun strategy_id(position: &Position): Option<vector<u8>> { position.strategy_id }
    public fun accounting_strategy_registry_id(
        accounting: &OpportunityAccounting,
    ): Option<ID> { accounting.strategy_registry_id }
    public fun guardrails_id(position: &Position): Option<ID> { position.guardrails_id }
    public fun leader_may_force_exit(position: &Position): bool {
        position.leader_may_force_exit
    }
    public fun force_exit_policy_id(position: &Position): Option<ID> {
        position.force_exit_policy_id
    }
    public fun position_shares(position: &Position): u128 { position.shares }
    public fun position_value_micros(
        accounting: &OpportunityAccounting,
        position: &Position,
    ): u128 {
        assert!(object::id(accounting) == position.leg_accounting_id, E_WRONG_ACCOUNTING);
        if (position.shares == 0) return 0;
        convert_to_assets(
            position.shares,
            accounting.total_assets_micros,
            accounting.total_shares,
        )
    }

    #[test_only]
    public fun new_accounting_for_testing<T>(
        opportunity_id: vector<u8>,
        spoke_chain: vector<u8>,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        new_accounting<T>(
            opportunity_id,
            spoke_chain,
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            guardrails_v2::sui_asset_binding<T>(),
            object::id_from_address(@0xADA),
            b"test-adapter",
            type_name::with_original_ids<T>(),
            0,
            0,
            @0x0,
            @0x0,
            @0xADAE7,
            ctx,
        )
    }

    /// Test-only remote-spoke fixture. Production accounting creation resolves
    /// the native binding from frozen policy; this helper exists solely to
    /// prove that independent spoke ledgers cannot share a PPS/NAV.
    #[test_only]
    public fun new_plain_accounting_with_native_binding_for_testing<T>(
        opportunity_id: vector<u8>,
        native_asset_binding: NativeAssetBinding,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        let spoke_chain = guardrails_v2::native_asset_chain_id(&native_asset_binding);
        new_accounting<T>(
            opportunity_id,
            spoke_chain,
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            option::none(),
            native_asset_binding,
            object::id_from_address(@0xADA),
            b"test-adapter",
            type_name::with_original_ids<T>(),
            0,
            0,
            @0x0,
            @0x0,
            @0xADAE7,
            ctx,
        )
    }

    #[test_only]
    public fun new_managed_accounting_for_testing<T>(
        opportunity_id: vector<u8>,
        spoke_chain: vector<u8>,
        strategy_id: vector<u8>,
        lead_fee_bps: u64,
        day_share_bps: u64,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        new_accounting<T>(
            opportunity_id,
            spoke_chain,
            option::some(strategy_id),
            option::some(object::id_from_address(@0xC0F1)),
            option::some(object::id_from_address(@0xAD1)),
            option::some(object::id_from_address(@0x57A7E6)),
            option::some(object::id_from_address(@0x6A4D)),
            option::some(x"1111111111111111111111111111111111111111111111111111111111111111"),
            guardrails_v2::sui_asset_binding<T>(),
            object::id_from_address(@0xADA),
            b"test-adapter",
            type_name::with_original_ids<T>(),
            lead_fee_bps,
            day_share_bps,
            @0x1EAD,
            @0xDA7,
            @0xADAE7,
            ctx,
        )
    }

    /// Policy-bound accounting fixture for DAY-849 force-exit package tests.
    /// Adapter witness type is the live adapter_source (not the asset type).
    #[test_only]
    public fun new_policy_bound_accounting_for_testing<AdapterWitness, T>(
        opportunity_id: vector<u8>,
        strategy_registry_id: ID,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        new_accounting<T>(
            opportunity_id,
            b"sui",
            option::some(strategy_id),
            option::some(object::id_from_address(@0xC0F1)),
            option::some(object::id_from_address(@0xAD1)),
            option::some(strategy_registry_id),
            option::some(guardrails_id),
            option::some(guardrails_hash),
            guardrails_v2::sui_asset_binding<T>(),
            object::id_from_address(@0xADA),
            b"test-adapter",
            type_name::with_original_ids<AdapterWitness>(),
            0,
            0,
            @0x1EAD,
            @0xDA7,
            @0xADAE7,
            ctx,
        )
    }

    #[test_only]
    public fun new_managed_accounting_with_native_binding_for_testing<T>(
        opportunity_id: vector<u8>,
        strategy_id: vector<u8>,
        native_asset_binding: NativeAssetBinding,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        let spoke_chain = guardrails_v2::native_asset_chain_id(&native_asset_binding);
        new_accounting<T>(
            opportunity_id,
            spoke_chain,
            option::some(strategy_id),
            option::some(object::id_from_address(@0xC0F1)),
            option::some(object::id_from_address(@0xAD1)),
            option::some(object::id_from_address(@0x57A7E6)),
            option::some(object::id_from_address(@0x6A4D)),
            option::some(x"1111111111111111111111111111111111111111111111111111111111111111"),
            native_asset_binding,
            object::id_from_address(@0xADA),
            b"test-adapter",
            type_name::with_original_ids<T>(),
            0,
            0,
            @0x1EAD,
            @0xDA7,
            @0xADAE7,
            ctx,
        )
    }

    #[test_only]
    public fun new_managed_remote_accounting_from_policy_for_testing<T>(
        guardrails: &GuardrailsV2,
        opportunity_id: vector<u8>,
        strategy_id: vector<u8>,
        spoke_chain: vector<u8>,
        remote_native_id: vector<u8>,
        ctx: &mut TxContext,
    ): OpportunityAccounting {
        let binding = resolve_managed_native_asset_binding<T>(
            guardrails,
            spoke_chain,
            remote_native_id,
        );
        new_managed_accounting_with_native_binding_for_testing<T>(
            opportunity_id,
            strategy_id,
            binding,
            ctx,
        )
    }

    #[test_only]
    public fun share_accounting_for_testing(accounting: OpportunityAccounting) {
        transfer::share_object(accounting);
    }

    #[test_only]
    public fun record_local_deposit_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        strategy_id: Option<ID>,
        guardrails_id: Option<ID>,
        assets_received_micros: u128,
        ctx: &mut TxContext,
    ): Position {
        // Compatibility helper for legacy-router security tests. Managed tests
        // use the explicit consent helper below so an absent field never grants
        // leader authority.
        assert!(!option::is_some(&strategy_id), E_INVALID_POLICY_BINDING);
        assert!(!option::is_some(&guardrails_id), E_INVALID_POLICY_BINDING);
        let route = vector[managed_route::deposit_leg<T>(
            object::id(accounting),
            accounting.opportunity_id,
        )];
        record_local_deposit_internal<T>(
            accounting,
            route,
            option::none(),
            assets_received_micros,
            ctx,
        )
    }

    #[test_only]
    public fun record_managed_local_deposit_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        leader_may_force_exit: bool,
        assets_received_micros: u128,
        ctx: &mut TxContext,
    ): Position {
        let route = vector[managed_route::deposit_leg<T>(
            object::id(accounting),
            accounting.opportunity_id,
        )];
        record_local_deposit_internal<T>(
            accounting,
            route,
            if (leader_may_force_exit) {
                option::some(object::id_from_address(@0x1EAD))
            } else {
                option::none()
            },
            assets_received_micros,
            ctx,
        )
    }

    /// Deposit with the exact frozen LeaderPolicy id (not a placeholder).
    #[test_only]
    public fun record_policy_consented_deposit_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        policy_id: ID,
        assets_received_micros: u128,
        ctx: &mut TxContext,
    ): Position {
        let route = vector[managed_route::deposit_leg<T>(
            object::id(accounting),
            accounting.opportunity_id,
        )];
        record_local_deposit_internal<T>(
            accounting,
            route,
            option::some(policy_id),
            assets_received_micros,
            ctx,
        )
    }

    #[test_only]
    public fun share_consented_position_for_testing(position: Position) {
        assert!(position.leader_may_force_exit, E_INVALID_FORCE_EXIT_CONSENT);
        transfer::share_object(position)
    }

    #[test_only]
    public fun publish_new_position_for_testing(position: Position, ctx: &TxContext) {
        // Mirror production: share consented Positions, transfer opt-outs.
        if (position.leader_may_force_exit) {
            transfer::share_object(position)
        } else {
            transfer::transfer(position, tx_context::sender(ctx))
        }
    }

    #[test_only]
    public fun record_local_deposit_with_verified_route_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        entry_route_legs: vector<RouteLegBinding>,
        leader_may_force_exit: bool,
        assets_received_micros: u128,
        ctx: &mut TxContext,
    ): Position {
        record_local_deposit_internal<T>(
            accounting,
            entry_route_legs,
            if (leader_may_force_exit) {
                option::some(object::id_from_address(@0x1EAD))
            } else {
                option::none()
            },
            assets_received_micros,
            ctx,
        )
    }

    #[test_only]
    public fun authorize_owner_exit_for_testing<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut Position,
        shares: u128,
        ctx: &TxContext,
    ): OwnerPayout<T> {
        let assets = convert_to_assets(
            shares,
            accounting.total_assets_micros,
            accounting.total_shares,
        );
        authorize_owner_exit<T>(accounting, position, shares, assets, 0, ctx)
    }

    #[test_only]
    public fun liquid_exit_proceeds_for_testing<T>(proceeds: Coin<T>): LiquidExitProceeds<T> {
        LiquidExitProceeds { proceeds }
    }

    #[test_only]
    public fun deployed_exit_proceeds_for_testing<T>(
        proceeds: Coin<T>,
    ): DeployedExitProceeds<T> {
        DeployedExitProceeds { proceeds }
    }

    #[test_only]
    public fun destroy_accounting_for_testing(accounting: OpportunityAccounting) {
        let OpportunityAccounting {
            id,
            opportunity_id: _,
            spoke_chain: _,
            accounting_asset: _,
            native_asset_binding: _,
            strategy_id: _,
            protocol_config_id: _,
            registry_admin_cap_id: _,
            strategy_registry_id: _,
            guardrails_id: _,
            guardrails_hash: _,
            adapter_registry_id: _,
            adapter_id: _,
            adapter_source: _,
            adapter_nonce: _,
            liquid_assets_micros: _,
            deployed_assets_micros: _,
            in_transit_assets_micros: _,
            total_assets_micros: _,
            total_shares: _,
            fee_basis_assets_micros: _,
            high_water_pps: _,
            lead_fee_bps: _,
            day_share_bps: _,
            lead_fee_destination: _,
            day_fee_destination: _,
            adapter_destination: _,
        } = accounting;
        object::delete(id);
    }

    #[test_only]
    public fun destroy_position_for_testing(position: Position) {
        let Position {
            id,
            leg_accounting_id: _,
            opportunity_id: _,
            entry_route_legs: _,
            depositor: _,
            payout_destination: _,
            origin_chain: _,
            origin_asset: _,
            strategy_id: _,
            guardrails_id: _,
            leader_may_force_exit: _,
            force_exit_policy_id: _,
            shares: _,
        } = position;
        object::delete(id);
    }

    #[test_only]
    public fun set_position_shares_for_testing(position: &mut Position, shares: u128) {
        position.shares = shares
    }

}
