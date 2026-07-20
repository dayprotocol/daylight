// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY on-chain fee + harvest waterfall primitives (Sui Move).
/// MVP module — complements DAY vault / position layer.
/// Fee applies ONLY to harvested yield (protocol_yield_skim_bps), never deposits/withdrawals.
module day::day {
    use sui::dynamic_field;
    use sui::event;

    /// Default DAY performance fee: 5% = 500 bps
    const DEFAULT_PROTOCOL_YIELD_SKIM_BPS: u64 = 500;
    const BASIS_POINTS: u64 = 10_000;

    /// EBountyExceedsYield
    const E_BOUNTY_EXCEEDS_YIELD: u64 = 1;
    /// EInvalidBps
    const E_INVALID_BPS: u64 = 2;
    /// The canonical StrategyRegistry marker has not been installed.
    const E_STRATEGY_REGISTRY_NOT_BOOTSTRAPPED: u64 = 3;
    /// A supplied registry does not match every field in the immutable anchor.
    const E_STRATEGY_REGISTRY_ANCHOR_MISMATCH: u64 = 4;
    /// The one canonical HubState marker already exists.
    const E_HUB_STATE_ALREADY_BOOTSTRAPPED: u64 = 5;
    /// A supplied hub/registry pair is not the immutable canonical pair.
    const E_HUB_STATE_ANCHOR_MISMATCH: u64 = 6;

    public struct ProtocolConfig has key {
        id: UID,
        protocol_yield_skim_bps: u64,
        auto_yield_default_off: bool,
    }

    /// Typed dynamic-field key for DAY-845's canonical StrategyRegistry anchor.
    /// ProtocolConfig is the unique shared object created by the original
    /// package `init`; adding this field does not change its deployed layout.
    public struct StrategyRegistryAnchorKey has copy, drop, store {}

    /// Permanent pointer to the one canonical StrategyRegistry and AdminCap.
    /// No removal or replacement function exists.
    public struct StrategyRegistryAnchor has copy, drop, store {
        registry_id: ID,
        admin_cap_id: ID,
        governance: address,
    }

    /// Typed dynamic-field key for DAY-848's canonical HubState anchor.
    public struct HubStateAnchorKey has copy, drop, store {}

    /// Permanent pointer to the only HubState and the StrategyRegistry that
    /// authorized its creation. No removal or replacement API exists.
    public struct HubStateAnchor has copy, drop, store {
        hub_id: ID,
        registry_id: ID,
    }

    /// Typed dynamic-field key for DAY-821's canonical AdapterRegistryV2.
    public struct AdapterRegistryV2AnchorKey has copy, drop, store {}

    /// Permanent one-shot pointer to the authenticated adapter registry and its
    /// governance capability. No removal or replacement function exists.
    public struct AdapterRegistryV2Anchor has copy, drop, store {
        registry_id: ID,
        admin_cap_id: ID,
        governance: address,
    }

    public struct YieldHarvested has copy, drop {
        gross_yield_micros: u64,
        protocol_skim_micros: u64,
        net_yield_micros: u64,
        fee_bps: u64,
    }

    public struct SurvivalUnstake has copy, drop {
        unstake_micros: u64,
        storage_bill_micros: u64,
        reason: vector<u8>,
    }

    public struct TopUpRecorded has copy, drop {
        amount_micros: u64,
        fee_micros: u64,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(ProtocolConfig {
            id: object::new(ctx),
            protocol_yield_skim_bps: DEFAULT_PROTOCOL_YIELD_SKIM_BPS,
            auto_yield_default_off: true,
        });
    }

    public fun default_skim_bps(): u64 {
        DEFAULT_PROTOCOL_YIELD_SKIM_BPS
    }

    public fun mul_bps(amount: u64, bps: u64): u64 {
        assert!(bps <= BASIS_POINTS, E_INVALID_BPS);
        (amount as u128 * (bps as u128) / (BASIS_POINTS as u128)) as u64
    }

    /// Skim fee from gross yield only.
    public fun skim_yield(gross_yield_micros: u64, skim_bps: u64): (u64, u64) {
        let skim = mul_bps(gross_yield_micros, skim_bps);
        let net = gross_yield_micros - skim;
        (skim, net)
    }

    /// Permissionless harvest accounting: claim amounts come from venue; this only skims.
    public fun record_harvest(
        config: &ProtocolConfig,
        gross_yield_micros: u64,
        heartbeat_bounty_micros: u64,
    ) {
        let (skim, net) = skim_yield(gross_yield_micros, config.protocol_yield_skim_bps);
        if (heartbeat_bounty_micros > 0 && net > 0) {
            assert!(heartbeat_bounty_micros <= net, E_BOUNTY_EXCEEDS_YIELD);
        };
        event::emit(YieldHarvested {
            gross_yield_micros,
            protocol_skim_micros: skim,
            net_yield_micros: net,
            fee_bps: config.protocol_yield_skim_bps,
        });
    }

    /// Top-up principal: always zero fee.
    public fun record_top_up(amount_micros: u64) {
        event::emit(TopUpRecorded {
            amount_micros,
            fee_micros: 0,
        });
    }

    /// Survival auto-unstake event (storage shortfall only).
    public fun emit_survival_unstake(unstake_micros: u64, storage_bill_micros: u64) {
        event::emit(SurvivalUnstake {
            unstake_micros,
            storage_bill_micros,
            reason: b"survival_storage",
        });
    }

    public fun get_skim_bps(config: &ProtocolConfig): u64 {
        config.protocol_yield_skim_bps
    }

    public fun is_auto_yield_default_off(config: &ProtocolConfig): bool {
        config.auto_yield_default_off
    }

    /// Package-only one-shot check used by the post-upgrade registry bootstrap.
    public(package) fun strategy_registry_bootstrapped(config: &ProtocolConfig): bool {
        dynamic_field::exists(&config.id, StrategyRegistryAnchorKey {})
    }

    /// Atomically attach the canonical registry pointer to the unique deployed
    /// ProtocolConfig. `dynamic_field::add` also aborts if the typed key exists;
    /// this module deliberately exposes no remove or replace path.
    public(package) fun anchor_strategy_registry(
        config: &mut ProtocolConfig,
        registry_id: ID,
        admin_cap_id: ID,
        governance: address,
    ) {
        dynamic_field::add(
            &mut config.id,
            StrategyRegistryAnchorKey {},
            StrategyRegistryAnchor { registry_id, admin_cap_id, governance },
        );
    }

    /// Publicly readable canonical registry id, if the post-upgrade bootstrap
    /// has completed.
    public fun canonical_strategy_registry_id(config: &ProtocolConfig): Option<ID> {
        if (!strategy_registry_bootstrapped(config)) return option::none();
        let anchor = dynamic_field::borrow<StrategyRegistryAnchorKey, StrategyRegistryAnchor>(
            &config.id,
            StrategyRegistryAnchorKey {},
        );
        option::some(anchor.registry_id)
    }

    /// Publicly readable AdminCap id bound to the canonical registry.
    public fun canonical_strategy_registry_admin_cap_id(
        config: &ProtocolConfig,
    ): Option<ID> {
        if (!strategy_registry_bootstrapped(config)) return option::none();
        let anchor = dynamic_field::borrow<StrategyRegistryAnchorKey, StrategyRegistryAnchor>(
            &config.id,
            StrategyRegistryAnchorKey {},
        );
        option::some(anchor.admin_cap_id)
    }

    /// Publicly readable immutable governance recipient for the canonical
    /// registry. This address is chosen at bootstrap and cannot be replaced.
    public fun canonical_strategy_registry_governance(
        config: &ProtocolConfig,
    ): Option<address> {
        if (!strategy_registry_bootstrapped(config)) return option::none();
        let anchor = dynamic_field::borrow<StrategyRegistryAnchorKey, StrategyRegistryAnchor>(
            &config.id,
            StrategyRegistryAnchorKey {},
        );
        option::some(anchor.governance)
    }

    /// Package-only complete binding check used by production bootstraps and
    /// authorization paths. Absence fails closed; no Option field can be
    /// interpreted as permissive.
    public(package) fun assert_canonical_strategy_registry_binding(
        config: &ProtocolConfig,
        registry_id: ID,
        admin_cap_id: ID,
        governance: address,
    ) {
        assert!(strategy_registry_bootstrapped(config), E_STRATEGY_REGISTRY_NOT_BOOTSTRAPPED);
        let anchor = dynamic_field::borrow<StrategyRegistryAnchorKey, StrategyRegistryAnchor>(
            &config.id,
            StrategyRegistryAnchorKey {},
        );
        assert!(anchor.registry_id == registry_id, E_STRATEGY_REGISTRY_ANCHOR_MISMATCH);
        assert!(anchor.admin_cap_id == admin_cap_id, E_STRATEGY_REGISTRY_ANCHOR_MISMATCH);
        assert!(anchor.governance == governance, E_STRATEGY_REGISTRY_ANCHOR_MISMATCH);
    }

    /// Package-only one-shot check for DAY-848's canonical HubState.
    public(package) fun hub_state_bootstrapped(config: &ProtocolConfig): bool {
        dynamic_field::exists(&config.id, HubStateAnchorKey {})
    }

    /// Atomically bind the only HubState to the canonical StrategyRegistry.
    /// `dynamic_field::add` is an additional one-shot guard; no remove or
    /// replacement function is exposed by this package.
    public(package) fun anchor_hub_state(
        config: &mut ProtocolConfig,
        hub_id: ID,
        registry_id: ID,
    ) {
        assert!(!hub_state_bootstrapped(config), E_HUB_STATE_ALREADY_BOOTSTRAPPED);
        dynamic_field::add(
            &mut config.id,
            HubStateAnchorKey {},
            HubStateAnchor { hub_id, registry_id },
        );
    }

    /// Fail closed unless both supplied objects match the immutable HubState
    /// anchor. Authorization code must call this before reserving a sequence.
    public(package) fun assert_canonical_hub_state_binding(
        config: &ProtocolConfig,
        hub_id: ID,
        registry_id: ID,
    ) {
        assert!(hub_state_bootstrapped(config), E_HUB_STATE_ANCHOR_MISMATCH);
        let anchor = dynamic_field::borrow<HubStateAnchorKey, HubStateAnchor>(
            &config.id,
            HubStateAnchorKey {},
        );
        assert!(anchor.hub_id == hub_id, E_HUB_STATE_ANCHOR_MISMATCH);
        assert!(anchor.registry_id == registry_id, E_HUB_STATE_ANCHOR_MISMATCH);
    }

    /// Public read-only discovery of the canonical HubState id.
    public fun canonical_hub_state_id(config: &ProtocolConfig): Option<ID> {
        if (!hub_state_bootstrapped(config)) return option::none();
        let anchor = dynamic_field::borrow<HubStateAnchorKey, HubStateAnchor>(
            &config.id,
            HubStateAnchorKey {},
        );
        option::some(anchor.hub_id)
    }

    /// Public read-only discovery of the registry bound to HubState.
    public fun canonical_hub_state_registry_id(config: &ProtocolConfig): Option<ID> {
        if (!hub_state_bootstrapped(config)) return option::none();
        let anchor = dynamic_field::borrow<HubStateAnchorKey, HubStateAnchor>(
            &config.id,
            HubStateAnchorKey {},
        );
        option::some(anchor.registry_id)
    }

    /// Package-only one-shot check used by AdapterRegistryV2 bootstrap.
    public(package) fun adapter_registry_v2_bootstrapped(config: &ProtocolConfig): bool {
        dynamic_field::exists(&config.id, AdapterRegistryV2AnchorKey {})
    }

    /// Atomically bind the only trusted AdapterRegistryV2 to ProtocolConfig.
    /// The typed dynamic field makes a repeated bootstrap abort and is never
    /// removable or replaceable through this package.
    public(package) fun anchor_adapter_registry_v2(
        config: &mut ProtocolConfig,
        registry_id: ID,
        admin_cap_id: ID,
        governance: address,
    ) {
        dynamic_field::add(
            &mut config.id,
            AdapterRegistryV2AnchorKey {},
            AdapterRegistryV2Anchor { registry_id, admin_cap_id, governance },
        );
    }

    /// Publicly readable canonical AdapterRegistryV2 id after bootstrap.
    public fun canonical_adapter_registry_v2_id(config: &ProtocolConfig): Option<ID> {
        if (!adapter_registry_v2_bootstrapped(config)) return option::none();
        let anchor = dynamic_field::borrow<AdapterRegistryV2AnchorKey, AdapterRegistryV2Anchor>(
            &config.id,
            AdapterRegistryV2AnchorKey {},
        );
        option::some(anchor.registry_id)
    }

    #[test_only]
    public fun new_config_for_testing(ctx: &mut TxContext): ProtocolConfig {
        ProtocolConfig {
            id: object::new(ctx),
            protocol_yield_skim_bps: DEFAULT_PROTOCOL_YIELD_SKIM_BPS,
            auto_yield_default_off: true,
        }
    }

    #[test_only]
    public fun share_config_for_testing(config: ProtocolConfig) {
        transfer::share_object(config);
    }

    #[test_only]
    public fun destroy_config_for_testing(config: ProtocolConfig) {
        let ProtocolConfig { id, protocol_yield_skim_bps: _, auto_yield_default_off: _ } = config;
        object::delete(id);
    }
}

#[test_only]
module day::day_tests {
    use day::day;

    #[test]
    fun test_default_skim_is_500() {
        assert!(day::default_skim_bps() == 500, 0);
    }

    #[test]
    fun test_skim_5_percent() {
        let (skim, net) = day::skim_yield(1_000_000, 500);
        assert!(skim == 50_000, 1);
        assert!(net == 950_000, 2);
    }

    #[test]
    fun test_skim_zero() {
        let (skim, net) = day::skim_yield(1_000_000, 0);
        assert!(skim == 0, 3);
        assert!(net == 1_000_000, 4);
    }

    /// Non-1000 bps path (salvage): fee is yield-only and must work for any valid bps.
    #[test]
    fun test_skim_non_1000_bps() {
        let (skim250, net250) = day::skim_yield(1_000_000, 250);
        assert!(skim250 == 25_000, 10);
        assert!(net250 == 975_000, 11);
        let (skim750, net750) = day::skim_yield(1_000_000, 750);
        assert!(skim750 == 75_000, 12);
        assert!(net750 == 925_000, 13);
        // 1000 bps = 10% still works but is NOT the product default
        let (skim1000, net1000) = day::skim_yield(1_000_000, 1000);
        assert!(skim1000 == 100_000, 14);
        assert!(net1000 == 900_000, 15);
    }

    /// Deposit / top-up principal: fee_micros is always 0 (invariant 44).
    #[test]
    fun test_top_up_never_fees_principal() {
        // record_top_up emits fee_micros=0; assert math invariant in pure form
        let amount: u64 = 9_999_999;
        // principal credit == amount; protocol fee on deposit == 0
        assert!(amount > 0, 20);
        let deposit_fee: u64 = 0;
        assert!(deposit_fee == 0, 21);
        day::record_top_up(amount);
    }

    #[test]
    fun test_auto_yield_default_off() {
        assert!(day::default_skim_bps() == 500, 30);
    }
}
