// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY StrategyRegistry — the on-chain source of truth for managed Strategies.
///
/// Each record permanently binds a Strategy id to its authenticated Lead and
/// frozen Guardrails object id/hash. Only lifecycle status can change. The
/// registry never holds principal: owner exit must not consult this object and
/// remains available while a Strategy is paused or retired.
module day::strategy_registry {
    use day::day::{Self, ProtocolConfig};
    use day::guardrails::{Self as guardrails_v1, Guardrails};
    use day::guardrails_v2::{Self, GuardrailsV2};
    use std::ascii;
    use std::type_name;
    use sui::clock::{Self, Clock};
    use sui::dynamic_field;
    use sui::event;
    use sui::package::UpgradeCap;
    use sui::table::{Self, Table};

    // ---- Authority ---------------------------------------------------------

    /// The current treasury/deployer EOA is explicitly forbidden as the
    /// AdminCap recipient. It may only authenticate bootstrap by supplying the
    /// canonical UpgradeCap it already owns; possession of an address alone is
    /// never sufficient.
    const DAY_AUTHORITY: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;
    const CANONICAL_UPGRADE_CAP: address =
        @0xfb7a7925da9332ab039cd7296828f5ebaef5ff7246f1bfa051d0a409fa15eb2d;
    const CANONICAL_PROTOCOL_CONFIG: address =
        @0xdcd2e53c6ebc03cea47bcfc656337f03bf64cf1069bb92419bb67f4969603bba;
    const TOP_30D_STRATEGY: vector<u8> = b"day-autopilot-top-30d-monthly";
    const TOP_30D_OPPORTUNITY: vector<u8> = b"dayope3465f1716";
    const TOP_30D_V1_GUARDRAILS: address =
        @0x789341ea271ad1171fe0d8b6df181c9d6cdbc21b518475246005ffa17db29cb8;
    const TOP_30D_V1_HASH: vector<u8> =
        x"76961077934bb9149397e1cd1aa6d9744a213fa2fec92b9ab98bdbb8099f9827";
    const TOP_ROI_STRATEGY: vector<u8> = b"day-autopilot-top-roi-10m-monthly";
    const TOP_ROI_OPPORTUNITY: vector<u8> = b"dayopbc1052eaa6";
    const TOP_ROI_V1_GUARDRAILS: address =
        @0x57964e0ec2609ef2d72cfea07f61afe1b3feb96c9dbc77951c2f8014fc0fe15b;
    const TOP_ROI_V1_HASH: vector<u8> =
        x"2d8d0d135e36755bcb00f3c01411dafe46735903333a9d0a4326ce3ef7b0f94c";
    const SAFE_PLUS_ROI_STRATEGY: vector<u8> = b"day-autopilot-safe-plus-roi";
    const SAFE_PLUS_ROI_OPPORTUNITY: vector<u8> = b"dayop487e57366b";
    const SAFE_PLUS_ROI_V1_GUARDRAILS: address =
        @0x75f3c8537f486afbd500c874e5c897cf84341a34dcd11916869d94658fea426a;
    const SAFE_PLUS_ROI_V1_HASH: vector<u8> =
        x"4349c76a59a6ba8dd8a13054f6b0670508c3b90f187351be5e9dfe87e93d93fd";
    const USDC_ORIGINAL_TYPE: vector<u8> =
        b"dba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";
    const USDY_ORIGINAL_TYPE: vector<u8> =
        b"960b531667636f39e85867775f52f6b1f220a058c4de786905bdf761e06a56bb::usdy::USDY";

    // ---- Lifecycle ---------------------------------------------------------

    const STATUS_ACTIVE: u8 = 0;
    const STATUS_PAUSED: u8 = 1;
    const STATUS_RETIRED: u8 = 2;

    // ---- Errors ------------------------------------------------------------

    const E_WRONG_UPGRADE_CAP: u64 = 1;
    const E_WRONG_ADMIN_CAP: u64 = 2;
    const E_ALREADY_REGISTERED: u64 = 3;
    const E_NOT_REGISTERED: u64 = 4;
    const E_INVALID_LIFECYCLE_TRANSITION: u64 = 5;
    const E_EMPTY_STRATEGY_ID: u64 = 6;
    const E_ZERO_LEADER: u64 = 7;
    const E_INVALID_GUARDRAILS: u64 = 8;
    const E_NOT_ACTIVE: u64 = 9;
    const E_ALREADY_BOOTSTRAPPED: u64 = 10;
    const E_LEADER_GUARDRAILS_MISMATCH: u64 = 11;
    const E_INVALID_GOVERNANCE: u64 = 12;
    const E_NOT_GOVERNANCE: u64 = 13;
    const E_WRONG_PROTOCOL_CONFIG: u64 = 14;
    const E_LEADER_POLICY_ALREADY_ANCHORED: u64 = 15;
    const E_WRONG_LEADER_POLICY_ANCHOR: u64 = 16;
    const E_GUARDRAILS_REFINEMENT_ALREADY_ANCHORED: u64 = 17;
    const E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR: u64 = 18;
    const E_WRONG_V1_GUARDRAILS: u64 = 19;
    const E_NOT_A_GUARDRAILS_REFINEMENT: u64 = 20;
    const E_WRONG_REFINEMENT_ASSET: u64 = 21;

    // ---- Objects -----------------------------------------------------------

    /// Shared index. Its fields are metadata only; it has no Coin or Balance.
    public struct StrategyRegistry has key {
        id: UID,
        strategies: Table<vector<u8>, StrategyRecord>,
        count: u64,
        /// Binds this registry to exactly one non-copyable AdminCap.
        admin_cap_id: ID,
        /// Immutable lifecycle authority selected at bootstrap. Must be a
        /// separate governance address, never the DAY treasury/deployer EOA.
        governance: address,
    }

    /// Permanent mutation authority for one StrategyRegistry, transferred to
    /// the explicit separate governance recipient at bootstrap. No `store`,
    /// `copy`, or `drop`: it cannot be publicly transferred, duplicated, or
    /// silently discarded.
    public struct AdminCap has key {
        id: UID,
    }

    /// Publicly readable managed Strategy metadata. All fields except `status`
    /// are written once by `register_strategy`; no mutation API exists for them.
    public struct StrategyRecord has store, copy, drop {
        strategy_id: vector<u8>,
        leader: address,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        status: u8,
        created_at: u64,
    }

    /// One immutable LeaderPolicy/ExitModeLatch pair per Strategy. The typed
    /// dynamic field is attached to the canonical StrategyRegistry without
    /// changing its deployed layout. No remove or replace API exists.
    public struct LeaderPolicyAnchorKey has copy, drop, store {
        strategy_id: vector<u8>,
    }

    public struct LeaderPolicyAnchor has copy, drop, store {
        policy_id: ID,
        latch_id: ID,
    }

    /// One-shot, non-replaceable proof that an executable V2 policy refines
    /// the exact immutable V1 Guardrails object approved for this Strategy.
    public struct GuardrailsRefinementAnchorKey has copy, drop, store {
        strategy_id: vector<u8>,
    }

    public struct GuardrailsRefinementAnchor has copy, drop, store {
        v1_guardrails_id: ID,
        v1_guardrails_hash: vector<u8>,
        v2_guardrails_id: ID,
        v2_guardrails_hash: vector<u8>,
    }

    // ---- Events ------------------------------------------------------------

    public struct RegistryBootstrapped has copy, drop {
        registry_id: ID,
        admin_cap_id: ID,
        governance: address,
    }

    public struct StrategyRegistered has copy, drop {
        strategy_id: vector<u8>,
        leader: address,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        created_at: u64,
    }

    public struct StrategyLifecycleChanged has copy, drop {
        strategy_id: vector<u8>,
        previous_status: u8,
        new_status: u8,
    }

    public struct Top30GuardrailsRefinementAnchored has copy, drop {
        registry_id: ID,
        strategy_id: vector<u8>,
        v1_guardrails_id: ID,
        v1_guardrails_hash: vector<u8>,
        v2_guardrails_id: ID,
        v2_guardrails_hash: vector<u8>,
    }

    public struct GuardrailsRefinementAnchored has copy, drop {
        registry_id: ID,
        strategy_id: vector<u8>,
        v1_guardrails_id: ID,
        v1_guardrails_hash: vector<u8>,
        v2_guardrails_id: ID,
        v2_guardrails_hash: vector<u8>,
    }

    // ---- Post-upgrade bootstrap -------------------------------------------

    /// Create the shared registry and its permanent AdminCap after the package
    /// upgrade. The unique ProtocolConfig created by the original package
    /// `init` holds a typed dynamic-field pointer to the canonical registry.
    /// That marker has no remove path, so a second bootstrap always aborts. The
    /// caller must supply the live package UpgradeCap and canonical ProtocolConfig,
    /// plus a nonzero governance recipient distinct from the DAY treasury/deployer
    /// EOA. No governance address is invented or hardcoded.
    public entry fun bootstrap(
        config: &mut ProtocolConfig,
        upgrade_cap: &UpgradeCap,
        governance: address,
        ctx: &mut TxContext,
    ) {
        assert_canonical_bootstrap_targets(
            object::id_address(upgrade_cap),
            object::id_address(config),
        );
        bootstrap_internal(config, governance, ctx);
    }

    fun bootstrap_internal(
        config: &mut ProtocolConfig,
        governance: address,
        ctx: &mut TxContext,
    ) {
        assert!(governance != @0x0 && governance != DAY_AUTHORITY, E_INVALID_GOVERNANCE);
        assert!(!day::strategy_registry_bootstrapped(config), E_ALREADY_BOOTSTRAPPED);

        let cap = AdminCap { id: object::new(ctx) };
        let admin_cap_id = object::id(&cap);
        let registry = StrategyRegistry {
            id: object::new(ctx),
            strategies: table::new(ctx),
            count: 0,
            admin_cap_id,
            governance,
        };
        let registry_id = object::id(&registry);

        day::anchor_strategy_registry(config, registry_id, admin_cap_id, governance);
        event::emit(RegistryBootstrapped { registry_id, admin_cap_id, governance });
        transfer::transfer(cap, governance);
        transfer::share_object(registry);
    }

    fun assert_canonical_bootstrap_targets(upgrade_cap_id: address, config_id: address) {
        assert!(upgrade_cap_id == CANONICAL_UPGRADE_CAP, E_WRONG_UPGRADE_CAP);
        assert!(config_id == CANONICAL_PROTOCOL_CONFIG, E_WRONG_PROTOCOL_CONFIG);
    }

    fun assert_admin(registry: &StrategyRegistry, cap: &AdminCap, ctx: &TxContext) {
        assert!(tx_context::sender(ctx) == registry.governance, E_NOT_GOVERNANCE);
        assert!(object::id(cap) == registry.admin_cap_id, E_WRONG_ADMIN_CAP);
    }

    // ---- Registration + lifecycle ----------------------------------------

    /// Register one managed Strategy. Its Lead and frozen Guardrails binding
    /// are immutable forever. The Guardrails object supplies both id and hash,
    /// preventing a caller from pairing unrelated values.
    public fun register_strategy(
        registry: &mut StrategyRegistry,
        cap: &AdminCap,
        strategy_id: vector<u8>,
        leader: address,
        guardrails: &GuardrailsV2,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert_admin(registry, cap, ctx);
        assert!(!vector::is_empty(&strategy_id), E_EMPTY_STRATEGY_ID);
        assert!(leader != @0x0, E_ZERO_LEADER);
        assert!(!table::contains(&registry.strategies, strategy_id), E_ALREADY_REGISTERED);
        assert!(guardrails_v2::verify_hash(guardrails), E_INVALID_GUARDRAILS);
        assert!(leader == guardrails_v2::strategy_lead(guardrails), E_LEADER_GUARDRAILS_MISMATCH);

        let guardrails_id = guardrails_v2::id(guardrails);
        let guardrails_hash = guardrails_v2::guardrails_hash(guardrails);
        assert_required_guardrails_refinement(
            registry,
            &strategy_id,
            guardrails_id,
            &guardrails_hash,
        );
        let created_at = clock::timestamp_ms(clock);
        table::add(
            &mut registry.strategies,
            strategy_id,
            StrategyRecord {
                strategy_id,
                leader,
                guardrails_id,
                guardrails_hash,
                status: STATUS_ACTIVE,
                created_at,
            },
        );
        registry.count = registry.count + 1;

        event::emit(StrategyRegistered {
            strategy_id,
            leader,
            guardrails_id,
            guardrails_hash,
            created_at,
        });
    }

    /// Pause new deposits and reallocations. Owner exit is intentionally not a
    /// registry-gated action and remains available.
    public fun pause_strategy(
        registry: &mut StrategyRegistry,
        cap: &AdminCap,
        strategy_id: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_admin(registry, cap, ctx);
        let record = borrow_record_mut(registry, strategy_id);
        assert!(record.status == STATUS_ACTIVE, E_INVALID_LIFECYCLE_TRANSITION);
        record.status = STATUS_PAUSED;
        event::emit(StrategyLifecycleChanged {
            strategy_id,
            previous_status: STATUS_ACTIVE,
            new_status: STATUS_PAUSED,
        });
    }

    /// Resume a paused Strategy. A retired Strategy is terminal and cannot be
    /// reactivated.
    public fun resume_strategy(
        registry: &mut StrategyRegistry,
        cap: &AdminCap,
        strategy_id: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_admin(registry, cap, ctx);
        let record = borrow_record_mut(registry, strategy_id);
        assert!(record.status == STATUS_PAUSED, E_INVALID_LIFECYCLE_TRANSITION);
        record.status = STATUS_ACTIVE;
        event::emit(StrategyLifecycleChanged {
            strategy_id,
            previous_status: STATUS_PAUSED,
            new_status: STATUS_ACTIVE,
        });
    }

    /// Permanently retire a Strategy from new deposits and reallocations. This
    /// cannot change its Lead or Guardrails and cannot block owner exit.
    public fun retire_strategy(
        registry: &mut StrategyRegistry,
        cap: &AdminCap,
        strategy_id: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_admin(registry, cap, ctx);
        let record = borrow_record_mut(registry, strategy_id);
        let previous_status = record.status;
        assert!(previous_status != STATUS_RETIRED, E_INVALID_LIFECYCLE_TRANSITION);
        record.status = STATUS_RETIRED;
        event::emit(StrategyLifecycleChanged {
            strategy_id,
            previous_status,
            new_status: STATUS_RETIRED,
        });
    }

    // ---- Fail-closed action gates -----------------------------------------

    public fun assert_accepts_new_deposit(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ) {
        assert!(status(registry, strategy_id) == STATUS_ACTIVE, E_NOT_ACTIVE);
    }

    public fun assert_accepts_reallocation(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ) {
        assert!(status(registry, strategy_id) == STATUS_ACTIVE, E_NOT_ACTIVE);
    }

    public fun accepts_new_deposit(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): bool {
        contains(registry, strategy_id) && status(registry, strategy_id) == STATUS_ACTIVE
    }

    public fun accepts_reallocation(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): bool {
        contains(registry, strategy_id) && status(registry, strategy_id) == STATUS_ACTIVE
    }

    // ---- Read API ----------------------------------------------------------

    public fun contains(registry: &StrategyRegistry, strategy_id: vector<u8>): bool {
        table::contains(&registry.strategies, strategy_id)
    }

    public fun record(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): &StrategyRecord {
        assert!(table::contains(&registry.strategies, strategy_id), E_NOT_REGISTERED);
        table::borrow(&registry.strategies, strategy_id)
    }

    fun borrow_record_mut(
        registry: &mut StrategyRegistry,
        strategy_id: vector<u8>,
    ): &mut StrategyRecord {
        assert!(table::contains(&registry.strategies, strategy_id), E_NOT_REGISTERED);
        table::borrow_mut(&mut registry.strategies, strategy_id)
    }

    public fun count(registry: &StrategyRegistry): u64 { registry.count }

    public fun id(registry: &StrategyRegistry): ID { object::id(registry) }

    public fun admin_cap_id(registry: &StrategyRegistry): ID { registry.admin_cap_id }

    public fun governance(registry: &StrategyRegistry): address { registry.governance }

    public fun strategy_id(record: &StrategyRecord): vector<u8> { record.strategy_id }

    public fun leader(record: &StrategyRecord): address { record.leader }

    public fun guardrails_id(record: &StrategyRecord): ID { record.guardrails_id }

    public fun guardrails_hash(record: &StrategyRecord): vector<u8> {
        record.guardrails_hash
    }

    public fun status(registry: &StrategyRegistry, strategy_id: vector<u8>): u8 {
        record(registry, strategy_id).status
    }

    public fun record_status(record: &StrategyRecord): u8 { record.status }

    fun assert_required_guardrails_refinement(
        registry: &StrategyRegistry,
        strategy_id: &vector<u8>,
        guardrails_id: ID,
        guardrails_hash: &vector<u8>,
    ) {
        if (
            strategy_id != &TOP_30D_STRATEGY &&
            strategy_id != &TOP_ROI_STRATEGY &&
            strategy_id != &SAFE_PLUS_ROI_STRATEGY
        ) return;
        let key = GuardrailsRefinementAnchorKey { strategy_id: *strategy_id };
        assert!(
            dynamic_field::exists(&registry.id, copy key),
            E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR,
        );
        let anchor = dynamic_field::borrow<
            GuardrailsRefinementAnchorKey,
            GuardrailsRefinementAnchor,
        >(&registry.id, key);
        let (expected_v1_id, expected_v1_hash) = if (strategy_id == &TOP_30D_STRATEGY) {
            (object::id_from_address(TOP_30D_V1_GUARDRAILS), TOP_30D_V1_HASH)
        } else if (strategy_id == &TOP_ROI_STRATEGY) {
            (object::id_from_address(TOP_ROI_V1_GUARDRAILS), TOP_ROI_V1_HASH)
        } else {
            (object::id_from_address(SAFE_PLUS_ROI_V1_GUARDRAILS), SAFE_PLUS_ROI_V1_HASH)
        };
        assert!(anchor.v1_guardrails_id == expected_v1_id, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
        assert!(anchor.v1_guardrails_hash == expected_v1_hash, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
        assert!(anchor.v2_guardrails_id == guardrails_id, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
        assert!(&anchor.v2_guardrails_hash == guardrails_hash, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
    }

    /// Prove the exact native-USDC/Sui/Cetus subset of the immutable top-30d
    /// V1 policy and permanently anchor it under Family-A governance.
    public fun anchor_top30_refinement<Principal>(
        registry: &mut StrategyRegistry,
        admin_cap: &AdminCap,
        v1: &Guardrails,
        v2: &GuardrailsV2,
        ctx: &TxContext,
    ) {
        assert_usdc<Principal>();
        assert!(object::id_address(v1) == TOP_30D_V1_GUARDRAILS, E_WRONG_V1_GUARDRAILS);
        assert_top30_refinement_shape<Principal>(v1, v2, true);
        let v1_id = guardrails_v1::id(v1);
        let v1_hash = guardrails_v1::guardrails_hash(v1);
        let v2_id = guardrails_v2::id(v2);
        let v2_hash = guardrails_v2::guardrails_hash(v2);
        anchor_guardrails_refinement(
            registry,
            admin_cap,
            TOP_30D_STRATEGY,
            v1_id,
            v1_hash,
            v2_id,
            v2_hash,
            ctx,
        );
        event::emit(Top30GuardrailsRefinementAnchored {
            registry_id: object::id(registry),
            strategy_id: TOP_30D_STRATEGY,
            v1_guardrails_id: v1_id,
            v1_guardrails_hash: v1_hash,
            v2_guardrails_id: v2_id,
            v2_guardrails_hash: v2_hash,
        });
    }

    /// Permanently bind the one exact Sui USDY leaf that is present in the
    /// immutable top-ROI policy. This proves scope only; it does not claim an
    /// USDY adapter, accounting object, or measured money path exists.
    public fun anchor_top_roi_refinement<Principal>(
        registry: &mut StrategyRegistry,
        admin_cap: &AdminCap,
        v1: &Guardrails,
        v2: &GuardrailsV2,
        ctx: &TxContext,
    ) {
        assert_exact_refinement_shape<Principal>(
            v1,
            v2,
            TOP_ROI_V1_GUARDRAILS,
            TOP_ROI_V1_HASH,
            b"USDY",
            USDY_ORIGINAL_TYPE,
            TOP_ROI_OPPORTUNITY,
            true,
            true,
        );
        anchor_and_emit_refinement(
            registry,
            admin_cap,
            TOP_ROI_STRATEGY,
            v1,
            v2,
            ctx,
        );
    }

    /// Bind safe-plus-ROI to its exact top-30d child handle. The nested money
    /// path remains independently fail-closed until nested accounting and its
    /// measured owner exit exist.
    public fun anchor_safe_plus_roi_refinement<Principal>(
        registry: &mut StrategyRegistry,
        admin_cap: &AdminCap,
        v1: &Guardrails,
        v2: &GuardrailsV2,
        ctx: &TxContext,
    ) {
        assert_exact_refinement_shape<Principal>(
            v1,
            v2,
            SAFE_PLUS_ROI_V1_GUARDRAILS,
            SAFE_PLUS_ROI_V1_HASH,
            b"USDC",
            USDC_ORIGINAL_TYPE,
            SAFE_PLUS_ROI_OPPORTUNITY,
            true,
            true,
        );
        anchor_and_emit_refinement(
            registry,
            admin_cap,
            SAFE_PLUS_ROI_STRATEGY,
            v1,
            v2,
            ctx,
        );
    }

    fun anchor_and_emit_refinement(
        registry: &mut StrategyRegistry,
        admin_cap: &AdminCap,
        strategy_id: vector<u8>,
        v1: &Guardrails,
        v2: &GuardrailsV2,
        ctx: &TxContext,
    ) {
        let v1_id = guardrails_v1::id(v1);
        let v1_hash = guardrails_v1::guardrails_hash(v1);
        let v2_id = guardrails_v2::id(v2);
        let v2_hash = guardrails_v2::guardrails_hash(v2);
        anchor_guardrails_refinement(
            registry,
            admin_cap,
            copy strategy_id,
            v1_id,
            copy v1_hash,
            v2_id,
            copy v2_hash,
            ctx,
        );
        event::emit(GuardrailsRefinementAnchored {
            registry_id: object::id(registry),
            strategy_id,
            v1_guardrails_id: v1_id,
            v1_guardrails_hash: v1_hash,
            v2_guardrails_id: v2_id,
            v2_guardrails_hash: v2_hash,
        });
    }

    fun assert_exact_refinement_shape<Principal>(
        v1: &Guardrails,
        v2: &GuardrailsV2,
        expected_v1: address,
        expected_hash: vector<u8>,
        expected_symbol: vector<u8>,
        expected_type: vector<u8>,
        opportunity: vector<u8>,
        require_pins: bool,
        require_type: bool,
    ) {
        if (require_pins) {
            assert!(object::id_address(v1) == expected_v1, E_WRONG_V1_GUARDRAILS);
            assert!(guardrails_v1::guardrails_hash(v1) == expected_hash, E_WRONG_V1_GUARDRAILS);
        };
        if (require_type) assert_original_type<Principal>(expected_type);
        assert!(guardrails_v1::verify_hash(v1), E_WRONG_V1_GUARDRAILS);
        assert!(guardrails_v2::verify_hash(v2), E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v1::strategy_lead(v1) == DAY_AUTHORITY, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::strategy_lead(v2) == DAY_AUTHORITY, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v1::asset_allowed(v1, expected_symbol), E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v1::allocation_allowed(v1, copy opportunity, 10_000), E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::asset_type_count(v2) == 1, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::opportunity_count(v2) == 1, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::chain_count(v2) == 1, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::max_allocation_bps(v2) == 10_000, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::allocation_allowed<Principal>(v2, opportunity, b"sui", 10_000), E_NOT_A_GUARDRAILS_REFINEMENT);
    }

    fun assert_original_type<Principal>(expected_type: vector<u8>) {
        let name = ascii::into_bytes(type_name::into_string(
            type_name::with_original_ids<Principal>(),
        ));
        assert!(name == expected_type, E_WRONG_REFINEMENT_ASSET);
    }

    #[test_only]
    public fun assert_top_roi_refinement_shape_for_testing<Principal>(
        v1: &Guardrails,
        v2: &GuardrailsV2,
    ) {
        assert_exact_refinement_shape<Principal>(
            v1,
            v2,
            @0x0,
            vector[],
            b"USDY",
            vector[],
            TOP_ROI_OPPORTUNITY,
            false,
            false,
        )
    }

    #[test_only]
    public fun assert_safe_plus_roi_refinement_shape_for_testing<Principal>(
        v1: &Guardrails,
        v2: &GuardrailsV2,
    ) {
        assert_exact_refinement_shape<Principal>(
            v1,
            v2,
            @0x0,
            vector[],
            b"USDC",
            vector[],
            SAFE_PLUS_ROI_OPPORTUNITY,
            false,
            false,
        )
    }

    fun assert_top30_refinement_shape<Principal>(
        v1: &Guardrails,
        v2: &GuardrailsV2,
        require_pinned_v1_hash: bool,
    ) {
        assert!(guardrails_v1::verify_hash(v1), E_WRONG_V1_GUARDRAILS);
        if (require_pinned_v1_hash) {
            assert!(guardrails_v1::guardrails_hash(v1) == TOP_30D_V1_HASH, E_WRONG_V1_GUARDRAILS);
        };
        assert!(guardrails_v2::verify_hash(v2), E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v1::strategy_lead(v1) == DAY_AUTHORITY, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::strategy_lead(v2) == DAY_AUTHORITY, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v1::asset_allowed(v1, b"USDC"), E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v1::allocation_allowed(v1, TOP_30D_OPPORTUNITY, 10_000), E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::asset_type_count(v2) == 1, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::opportunity_count(v2) == 1, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::chain_count(v2) == 1, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::max_allocation_bps(v2) == 10_000, E_NOT_A_GUARDRAILS_REFINEMENT);
        assert!(guardrails_v2::allocation_allowed<Principal>(
            v2,
            TOP_30D_OPPORTUNITY,
            b"sui",
            10_000,
        ), E_NOT_A_GUARDRAILS_REFINEMENT);
    }

    fun assert_usdc<Principal>() {
        let name = ascii::into_bytes(type_name::into_string(
            type_name::with_original_ids<Principal>(),
        ));
        assert!(name == USDC_ORIGINAL_TYPE, E_WRONG_REFINEMENT_ASSET);
    }

    #[test_only]
    public fun assert_top30_refinement_shape_for_testing<Principal>(
        v1: &Guardrails,
        v2: &GuardrailsV2,
    ) {
        assert_top30_refinement_shape<Principal>(v1, v2, false)
    }

    /// Internal one-shot write shared by the exact refinement entry and tests.
    /// Governance and AdminCap checks prevent unauthenticated provenance.
    public(package) fun anchor_guardrails_refinement(
        registry: &mut StrategyRegistry,
        cap: &AdminCap,
        strategy_id: vector<u8>,
        v1_guardrails_id: ID,
        v1_guardrails_hash: vector<u8>,
        v2_guardrails_id: ID,
        v2_guardrails_hash: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_admin(registry, cap, ctx);
        let key = GuardrailsRefinementAnchorKey { strategy_id };
        assert!(
            !dynamic_field::exists(&registry.id, copy key),
            E_GUARDRAILS_REFINEMENT_ALREADY_ANCHORED,
        );
        dynamic_field::add(
            &mut registry.id,
            key,
            GuardrailsRefinementAnchor {
                v1_guardrails_id,
                v1_guardrails_hash,
                v2_guardrails_id,
                v2_guardrails_hash,
            },
        );
    }

    public fun guardrails_refinement_anchored(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): bool {
        dynamic_field::exists(
            &registry.id,
            GuardrailsRefinementAnchorKey { strategy_id },
        )
    }

    public fun assert_canonical_guardrails_refinement(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
        v1_guardrails_id: ID,
        v1_guardrails_hash: vector<u8>,
        v2_guardrails_id: ID,
        v2_guardrails_hash: vector<u8>,
    ) {
        let key = GuardrailsRefinementAnchorKey { strategy_id };
        assert!(
            dynamic_field::exists(&registry.id, copy key),
            E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR,
        );
        let anchor = dynamic_field::borrow<
            GuardrailsRefinementAnchorKey,
            GuardrailsRefinementAnchor,
        >(&registry.id, key);
        assert!(anchor.v1_guardrails_id == v1_guardrails_id, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
        assert!(anchor.v1_guardrails_hash == v1_guardrails_hash, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
        assert!(anchor.v2_guardrails_id == v2_guardrails_id, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
        assert!(anchor.v2_guardrails_hash == v2_guardrails_hash, E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR);
    }

    /// Package-only one-shot write used by `leader_authority`. AdminCap and
    /// governance checks are repeated here so no sibling module can create an
    /// unauthenticated canonical policy anchor.
    public(package) fun anchor_leader_policy(
        registry: &mut StrategyRegistry,
        cap: &AdminCap,
        strategy_id: vector<u8>,
        policy_id: ID,
        latch_id: ID,
        ctx: &TxContext,
    ) {
        assert_admin(registry, cap, ctx);
        assert!(table::contains(&registry.strategies, copy strategy_id), E_NOT_REGISTERED);
        assert!(
            !dynamic_field::exists(
                &registry.id,
                LeaderPolicyAnchorKey { strategy_id: copy strategy_id },
            ),
            E_LEADER_POLICY_ALREADY_ANCHORED,
        );
        dynamic_field::add(
            &mut registry.id,
            LeaderPolicyAnchorKey { strategy_id },
            LeaderPolicyAnchor { policy_id, latch_id },
        );
    }

    public(package) fun assert_canonical_leader_policy_and_latch(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
        policy_id: ID,
        latch_id: ID,
    ) {
        let key = LeaderPolicyAnchorKey { strategy_id };
        assert!(dynamic_field::exists(&registry.id, copy key), E_WRONG_LEADER_POLICY_ANCHOR);
        let anchor = dynamic_field::borrow<LeaderPolicyAnchorKey, LeaderPolicyAnchor>(
            &registry.id,
            key,
        );
        assert!(anchor.policy_id == policy_id, E_WRONG_LEADER_POLICY_ANCHOR);
        assert!(anchor.latch_id == latch_id, E_WRONG_LEADER_POLICY_ANCHOR);
    }

    public fun leader_policy_anchored(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): bool {
        dynamic_field::exists(&registry.id, LeaderPolicyAnchorKey { strategy_id })
    }

    public fun canonical_leader_policy_id(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): Option<ID> {
        let key = LeaderPolicyAnchorKey { strategy_id };
        if (!dynamic_field::exists(&registry.id, copy key)) return option::none();
        let anchor = dynamic_field::borrow<LeaderPolicyAnchorKey, LeaderPolicyAnchor>(
            &registry.id,
            key,
        );
        option::some(anchor.policy_id)
    }

    public fun canonical_exit_mode_latch_id(
        registry: &StrategyRegistry,
        strategy_id: vector<u8>,
    ): Option<ID> {
        let key = LeaderPolicyAnchorKey { strategy_id };
        if (!dynamic_field::exists(&registry.id, copy key)) return option::none();
        let anchor = dynamic_field::borrow<LeaderPolicyAnchorKey, LeaderPolicyAnchor>(
            &registry.id,
            key,
        );
        option::some(anchor.latch_id)
    }

    public fun created_at(record: &StrategyRecord): u64 { record.created_at }

    public fun active_status(): u8 { STATUS_ACTIVE }

    public fun paused_status(): u8 { STATUS_PAUSED }

    public fun retired_status(): u8 { STATUS_RETIRED }

    #[test_only]
    public fun day_authority_for_testing(): address { DAY_AUTHORITY }

    #[test_only]
    public fun bootstrap_for_testing(
        config: &mut ProtocolConfig,
        governance: address,
        ctx: &mut TxContext,
    ) {
        bootstrap_internal(config, governance, ctx);
    }

    #[test_only]
    public fun assert_canonical_bootstrap_targets_for_testing(
        upgrade_cap_id: address,
        config_id: address,
    ) {
        assert_canonical_bootstrap_targets(upgrade_cap_id, config_id);
    }

    #[test_only]
    public fun canonical_upgrade_cap_for_testing(): address { CANONICAL_UPGRADE_CAP }

    #[test_only]
    public fun canonical_protocol_config_for_testing(): address { CANONICAL_PROTOCOL_CONFIG }

    #[test_only]
    public fun admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
        AdminCap { id: object::new(ctx) }
    }
}
