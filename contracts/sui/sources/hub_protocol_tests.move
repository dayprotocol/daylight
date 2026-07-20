// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::hub_protocol_tests {
    use call::call_cap;
    use day::adapter_registry::{Self, AdapterRegistryV2, RegistryAdminCap};
    use day::day::{Self as protocol, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2, NativeAssetBinding};
    use day::hub_protocol::{Self, ExitModeCommand, HubState, ReallocateCommand};
    use day::leader_activity_log;
    use day::leader_authority;
    use day::leader_policy::{Self, ExitModeLatch, LeaderPolicy};
    use day::managed_position::{Self, OpportunityAccounting};
    use day::managed_reallocation;
    use day::managed_route::{Self, ReallocationRouteLeg};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use std::ascii;
    use std::type_name;
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui::test_scenario as ts;

    const BASE_EID: u32 = 30_184;
    const ARBITRUM_EID: u32 = 30_110;
    const SOLANA_EID: u32 = 30_168;
    // DAY-903: six-chain EVM expansion.
    const ETHEREUM_EID: u32 = 30_101;
    const BSC_EID: u32 = 30_102;
    const POLYGON_EID: u32 = 30_109;
    const MONAD_EID: u32 = 30_390;
    const PLASMA_EID: u32 = 30_383;
    const ROBINHOOD_EID: u32 = 30_416;
    const STRATEGY: vector<u8> = b"dayop848";
    const FROM_OPPORTUNITY: vector<u8> = b"dayop0000000001";
    const TO_OPPORTUNITY: vector<u8> = b"dayop0000000002";
    const HASH: vector<u8> = x"1111111111111111111111111111111111111111111111111111111111111111";
    const PEER: vector<u8> = x"2222222222222222222222222222222222222222222222222222222222222222";
    const ROGUE_PEER: vector<u8> = x"3333333333333333333333333333333333333333333333333333333333333333";
    const GOVERNANCE: address = @0x600D;
    const GOVERNANCE_ALT: address = @0x600E;
    const LEADER: address = @0x1EAD;
    const ROGUE: address = @0xBAD;
    const BASE_TOKEN: vector<u8> = x"0101010101010101010101010101010101010101";

    public struct TestAsset has drop {}
    public struct AlternateAsset has drop {}
    public struct AdapterWitness has drop {}

    fun authority(): address { strategy_registry::day_authority_for_testing() }

    /// Install one canonical StrategyRegistry and return its config/registry
    /// ids after the shared registry and owned AdminCap become available.
    fun bootstrap_registry(
        scn: &mut ts::Scenario,
        governance: address,
    ): (ID, ID) {
        let config = protocol::new_config_for_testing(ts::ctx(scn));
        let config_id = object::id(&config);
        protocol::share_config_for_testing(config);
        ts::next_tx(scn, authority());

        let mut config = ts::take_shared_by_id<ProtocolConfig>(scn, config_id);
        strategy_registry::bootstrap_for_testing(&mut config, governance, ts::ctx(scn));
        let registry_id = option::destroy_some(
            protocol::canonical_strategy_registry_id(&config),
        );
        ts::return_shared(config);
        ts::next_tx(scn, authority());
        (config_id, registry_id)
    }

    fun asset_type_bytes<Asset>(): vector<u8> {
        ascii::into_bytes(type_name::into_string(type_name::with_original_ids<Asset>()))
    }

    fun destination_chain(spoke_eid: u32): vector<u8> {
        if (spoke_eid == BASE_EID) b"base" else b"arbitrum"
    }

    fun setup(): (HubState, Clock) {
        let mut ctx = tx_context::dummy();
        let hub = hub_protocol::new_hub_for_testing(&mut ctx);
        let mut clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 1_000);
        (hub, clock)
    }

    fun reallocate(hub: &mut HubState, clock: &Clock, spoke_eid: u32): ReallocateCommand {
        reallocate_with_expiry(hub, clock, spoke_eid, 2_000)
    }

    fun reallocate_with_expiry(
        hub: &mut HubState,
        clock: &Clock,
        spoke_eid: u32,
        expires_at_ms: u64,
    ): ReallocateCommand {
        hub_protocol::prepare_reallocate(
            hub,
            spoke_eid,
            STRATEGY,
            HASH,
            b"sui",
            destination_chain(spoke_eid),
            asset_type_bytes<TestAsset>(),
            asset_type_bytes<TestAsset>(),
            b"sui-suilend-usdc",
            b"base-morpho-usdc",
            2_500,
            expires_at_ms,
            clock,
        )
    }

    fun cleanup(hub: HubState, clock: Clock) {
        hub_protocol::destroy_hub_for_testing(hub);
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_legit_governance_bootstraps_and_anchors_canonical_hub() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        ts::next_tx(&mut scn, GOVERNANCE);

        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(&mut scn),
        );
        let hub_id = option::destroy_some(protocol::canonical_hub_state_id(&config));
        assert!(
            protocol::canonical_hub_state_registry_id(&config) == option::some(registry_id),
            0,
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);

        ts::next_tx(&mut scn, GOVERNANCE);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        hub_protocol::assert_canonical_hub_and_registry(&config, &hub, &registry);
        ts::return_shared(hub);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    fun test_governance_binds_one_typed_package_call_cap() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, _guardrails_id, hub_id) =
            bootstrap_validated_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, GOVERNANCE);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let admin = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let oapp_call_cap = call_cap::new_package_cap_for_test(ts::ctx(&mut scn));
        hub_protocol::bind_layerzero_oapp_call_cap(
            &config,
            &mut hub,
            &registry,
            &admin,
            &oapp_call_cap,
            ts::ctx(&mut scn),
        );
        transfer::public_transfer(oapp_call_cap, GOVERNANCE);
        ts::return_to_address(GOVERNANCE, admin);
        ts::return_shared(hub);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = 26, location = day::hub_protocol)]
    fun test_binding_rejects_individual_call_cap() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, _guardrails_id, hub_id) =
            bootstrap_validated_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, GOVERNANCE);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let admin = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let individual = call_cap::new_individual_cap(ts::ctx(&mut scn));
        hub_protocol::bind_layerzero_oapp_call_cap(
            &config,
            &mut hub,
            &registry,
            &admin,
            &individual,
            ts::ctx(&mut scn),
        );
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = 23, location = day::hub_protocol)]
    fun test_binding_rejects_non_governance_sender() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, _guardrails_id, hub_id) =
            bootstrap_validated_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, ROGUE);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let admin = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let package_cap = call_cap::new_package_cap_for_test(ts::ctx(&mut scn));
        hub_protocol::bind_layerzero_oapp_call_cap(
            &config,
            &mut hub,
            &registry,
            &admin,
            &package_cap,
            ts::ctx(&mut scn),
        );
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = 24, location = day::hub_protocol)]
    fun test_binding_rejects_rebind() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, _guardrails_id, hub_id) =
            bootstrap_validated_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, GOVERNANCE);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let admin = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let first = call_cap::new_package_cap_for_test(ts::ctx(&mut scn));
        let second = call_cap::new_package_cap_for_test(ts::ctx(&mut scn));
        hub_protocol::bind_layerzero_oapp_call_cap(
            &config,
            &mut hub,
            &registry,
            &admin,
            &first,
            ts::ctx(&mut scn),
        );
        hub_protocol::bind_layerzero_oapp_call_cap(
            &config,
            &mut hub,
            &registry,
            &admin,
            &second,
            ts::ctx(&mut scn),
        );
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_REGISTRY_NOT_BOOTSTRAPPED)]
    fun test_bootstrap_rejects_missing_registry_anchor() {
        let mut scn = ts::begin(authority());
        let orphan_config = protocol::new_config_for_testing(ts::ctx(&mut scn));
        let orphan_config_id = object::id(&orphan_config);
        protocol::share_config_for_testing(orphan_config);
        let (_config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        ts::next_tx(&mut scn, GOVERNANCE);

        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, orphan_config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(&mut scn),
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::day::E_STRATEGY_REGISTRY_ANCHOR_MISMATCH)]
    fun test_bootstrap_rejects_wrong_registry() {
        let mut scn = ts::begin(authority());
        let (config_id, _registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        let (_other_config_id, other_registry_id) = bootstrap_registry(&mut scn, GOVERNANCE_ALT);
        ts::next_tx(&mut scn, GOVERNANCE_ALT);

        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, other_registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE_ALT);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(&mut scn),
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE_ALT, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_WRONG_ADMIN_CAP)]
    fun test_bootstrap_rejects_wrong_admin_cap() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        ts::next_tx(&mut scn, GOVERNANCE);

        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let fake_cap = strategy_registry::admin_cap_for_testing(ts::ctx(&mut scn));
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &fake_cap,
            ts::ctx(&mut scn),
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, fake_cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_NOT_GOVERNANCE)]
    fun test_bootstrap_rejects_wrong_governance_sender() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        ts::next_tx(&mut scn, ROGUE);

        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(&mut scn),
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::day::E_HUB_STATE_ALREADY_BOOTSTRAPPED)]
    fun test_bootstrap_rejects_second_hub() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        ts::next_tx(&mut scn, GOVERNANCE);

        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(&mut scn),
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);

        ts::next_tx(&mut scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(&mut scn),
        );
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::day::E_HUB_STATE_ANCHOR_MISMATCH)]
    fun test_authorization_binding_rejects_wrong_hub_id() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let hub = hub_protocol::new_hub_for_testing(ts::ctx(&mut scn));
        protocol::anchor_hub_state(
            &mut config,
            object::id_from_address(@0xBAD),
            registry_id,
        );
        hub_protocol::assert_canonical_hub_and_registry(&config, &hub, &registry);
        hub_protocol::destroy_hub_for_testing(hub);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::day::E_HUB_STATE_ANCHOR_MISMATCH)]
    fun test_authorization_binding_rejects_wrong_registry_id() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id) = bootstrap_registry(&mut scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let hub = hub_protocol::new_hub_for_testing(ts::ctx(&mut scn));
        protocol::anchor_hub_state(
            &mut config,
            object::id(&hub),
            object::id_from_address(@0xBAD),
        );
        hub_protocol::assert_canonical_hub_and_registry(&config, &hub, &registry);
        hub_protocol::destroy_hub_for_testing(hub);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::end(scn);
    }
    /// Full canonical object graph used by the semantic authorizer tests. The
    /// remote binding is inserted into, and recovered from, frozen policy; no
    /// caller-fabricated chain/token descriptor reaches authorization.
    fun bootstrap_validated_authorizer_stack(
        scn: &mut ts::Scenario,
    ): (ID, ID, ID, ID) {
        let (config_id, registry_id) = bootstrap_registry(scn, GOVERNANCE);

        ts::next_tx(scn, LEADER);
        let ctx = ts::ctx(scn);
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<TestAsset>(&mut builder, ctx);
        guardrails_v2::add_allowed_asset<AlternateAsset>(&mut builder, ctx);
        guardrails_v2::add_allowed_evm_asset(&mut builder, b"base", BASE_TOKEN, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, FROM_OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, TO_OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"base", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 5_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        let guardrails_id = guardrails_v2::finalize_and_freeze(builder, digest, ctx);

        ts::next_tx(scn, GOVERNANCE);
        let mut registry = ts::take_shared_by_id<StrategyRegistry>(scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(scn),
        );
        clock::destroy_for_testing(test_clock);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);

        ts::next_tx(scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(
            &mut config,
            &registry,
            &cap,
            ts::ctx(scn),
        );
        let hub_id = option::destroy_some(protocol::canonical_hub_state_id(&config));
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        (config_id, registry_id, guardrails_id, hub_id)
    }

    fun bootstrap_semantic_authorizer_stack(
        scn: &mut ts::Scenario,
    ): (ID, ID, ID, ID, ID, ID, ID, ID) {
        let (config_id, registry_id, guardrails_id, hub_id) =
            bootstrap_validated_authorizer_stack(scn);

        ts::next_tx(scn, GOVERNANCE);
        adapter_registry::bootstrap_registry_v2_for_testing(
            GOVERNANCE,
            ts::ctx(scn),
        );

        ts::next_tx(scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(scn, config_id);
        let mut registry = ts::take_shared_by_id<StrategyRegistry>(scn, registry_id);
        let admin_cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let mut adapters = ts::take_shared<AdapterRegistryV2>(scn);
        let adapter_cap = ts::take_from_address<RegistryAdminCap>(scn, GOVERNANCE);
        protocol::anchor_adapter_registry_v2(
            &mut config,
            object::id(&adapters),
            object::id(&adapter_cap),
            GOVERNANCE,
        );
        adapter_registry::register_authenticated(
            &adapter_cap,
            &mut adapters,
            b"test-source-adapter",
            b"sui",
            b"Test source adapter",
        );
        adapter_registry::register_authenticated(
            &adapter_cap,
            &mut adapters,
            b"test-destination-adapter",
            b"base",
            b"Test destination adapter",
        );
        let mut test_clock = clock::create_for_testing(ts::ctx(scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let (policy_id, latch_id) = leader_authority::create_policy_and_latch(
            &mut registry,
            &admin_cap,
            STRATEGY,
            true,
            &test_clock,
            ts::ctx(scn),
        );
        let source_accounting_id =
            managed_position::create_managed_accounting<AdapterWitness, TestAsset>(
                &config,
                &registry,
                &admin_cap,
                &adapters,
                &guardrails,
                STRATEGY,
                FROM_OPPORTUNITY,
                b"sui",
                vector[],
                b"test-source-adapter",
                0,
                0,
                @0x1EAD,
                @0xDA7,
                @0xADAE7,
                ts::ctx(scn),
            );
        let destination_accounting_id =
            managed_position::create_managed_accounting<AdapterWitness, TestAsset>(
                &config,
                &registry,
                &admin_cap,
                &adapters,
                &guardrails,
                STRATEGY,
                TO_OPPORTUNITY,
                b"base",
                BASE_TOKEN,
                b"test-destination-adapter",
                0,
                0,
                @0x1EAD,
                @0xDA7,
                @0xADAE7,
                ts::ctx(scn),
            );
        clock::destroy_for_testing(test_clock);
        ts::return_shared(adapters);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::return_to_address(GOVERNANCE, admin_cap);
        ts::return_to_address(GOVERNANCE, adapter_cap);
        (
            config_id,
            registry_id,
            guardrails_id,
            hub_id,
            policy_id,
            latch_id,
            source_accounting_id,
            destination_accounting_id,
        )
    }

    fun seed_deployed_source(
        source: &mut OpportunityAccounting,
        ctx: &mut TxContext,
    ) {
        let position = managed_position::record_managed_local_deposit_for_testing<TestAsset>(
            source,
            false,
            100,
            ctx,
        );
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            source,
            &witness,
            coin::mint_for_testing<TestAsset>(100, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            source,
            deployment,
        ));
        managed_position::destroy_position_for_testing(position);
    }

    fun semantic_route(
        source_accounting_id: ID,
        destination_accounting_id: ID,
        source_asset: NativeAssetBinding,
        destination_asset: NativeAssetBinding,
        with_intermediate_swaps: bool,
    ): vector<ReallocationRouteLeg> {
        let mut route = vector[managed_route::reallocation_withdraw_leg(
            source_accounting_id,
            source_asset,
            FROM_OPPORTUNITY,
        )];
        if (with_intermediate_swaps) {
            let alternate = guardrails_v2::sui_asset_binding<AlternateAsset>();
            route.push_back(managed_route::reallocation_swap_leg(
                object::id_from_address(@0xA1),
                source_asset,
                alternate,
            ));
            route.push_back(managed_route::reallocation_swap_leg(
                object::id_from_address(@0xA2),
                alternate,
                source_asset,
            ));
        };
        route.push_back(managed_route::reallocation_bridge_leg(
            object::id_from_address(@0xB1),
            source_asset,
            destination_asset,
        ));
        route.push_back(managed_route::reallocation_deposit_leg(
            destination_accounting_id,
            destination_asset,
            TO_OPPORTUNITY,
        ));
        route
    }

    fun semantic_proofs(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &ExitModeLatch,
        source: &mut OpportunityAccounting,
        destination: &OpportunityAccounting,
        with_intermediate_swaps: bool,
        ctx: &mut TxContext,
    ): (
        leader_policy::ReallocationPolicyWitness,
        managed_reallocation::ReallocationReservation<TestAsset>,
    ) {
        let source_id = managed_position::accounting_id(source);
        let destination_id = managed_position::accounting_id(destination);
        let source_asset = guardrails_v2::sui_asset_binding<TestAsset>();
        let destination_asset =
            guardrails_v2::native_asset_binding_from_policy(guardrails, b"base", BASE_TOKEN);
        let route = semantic_route(
            source_id,
            destination_id,
            source_asset,
            destination_asset,
            with_intermediate_swaps,
        );
        let (canonical_route, _source_asset, _destination_asset) =
            managed_position::validated_reallocation_route_for_accountings(
                source,
                destination,
                &route,
                guardrails,
                2_500,
            );
        let policy_witness = leader_policy::issue_reallocation_witness(
            registry,
            guardrails,
            policy,
            latch,
            2_500,
            source_id,
            FROM_OPPORTUNITY,
            destination_id,
            TO_OPPORTUNITY,
            ctx,
        );
        let reservation = managed_reallocation::start_reallocation<TestAsset>(
            source,
            destination,
            canonical_route,
            2_500,
            ctx,
        );
        (policy_witness, reservation)
    }

    #[test]
    fun test_semantic_authorizer_emits_command_derived_ordered_event() {
        let mut scn = ts::begin(authority());
        let (
            config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id,
            source_id, destination_id,
        ) = bootstrap_semantic_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        hub_protocol::bind_oapp_call_cap_for_testing(&mut hub, @0x0A99);
        seed_deployed_source(&mut source, ts::ctx(&mut scn));
        let (policy_witness, reservation) = semantic_proofs(
            &registry,
            &guardrails,
            &policy,
            &latch,
            &mut source,
            &destination,
            false,
            ts::ctx(&mut scn),
        );
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let authorized = hub_protocol::authorize_validated_reallocation<TestAsset>(
            &config,
            &mut hub,
            &registry,
            &guardrails,
            policy_witness,
            reservation,
            2_000,
            &test_clock,
            ts::ctx(&mut scn),
        );
        let (
            audit_strategy_id,
            audit_guardrails_hash,
            audit_guardrails_id,
            audit_route_commitment,
            audit_reallocation_state_id,
            audit_allocation_bps,
            audit_source_opportunity_id,
            audit_destination_opportunity_id,
            audit_source_chain_id,
            audit_destination_chain_id,
            audit_source_native_asset,
            audit_destination_native_asset,
            audit_issued_at_ms,
            audit_expires_at_ms,
        ) = hub_protocol::authorized_reallocate_audit_v1(&authorized);
        assert!(audit_strategy_id == STRATEGY, 100);
        assert!(audit_guardrails_hash == guardrails_v2::guardrails_hash(&guardrails), 101);
        assert!(vector::length(&audit_guardrails_id) == 32, 102);
        assert!(vector::length(&audit_route_commitment) == 32, 103);
        assert!(vector::length(&audit_reallocation_state_id) == 32, 104);
        assert!(audit_allocation_bps == 2_500, 105);
        assert!(audit_source_opportunity_id == FROM_OPPORTUNITY, 106);
        assert!(audit_destination_opportunity_id == TO_OPPORTUNITY, 107);
        assert!(audit_source_chain_id == b"sui", 108);
        assert!(audit_destination_chain_id == b"base", 109);
        assert!(!vector::is_empty(&audit_source_native_asset), 110);
        assert!(!vector::is_empty(&audit_destination_native_asset), 111);
        assert!(audit_issued_at_ms == 1_000, 112);
        assert!(audit_expires_at_ms == 2_000, 113);
        let (dst_eid, payload) = hub_protocol::authorized_transport_message(&authorized);
        assert!(dst_eid == BASE_EID, 114);
        assert!(hub_protocol::assert_managed_reallocate_v1_message(dst_eid, &payload) == 2_000, 115);
        let intent_id = hub_protocol::authorized_intent_id(&authorized);
        assert!(vector::length(&intent_id) == 32, 116);
        leader_activity_log::record_ordered(
            &authorized,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scn),
        );
        leader_activity_log::assert_last_ordered_event_for_testing(
            intent_id,
            LEADER,
            audit_strategy_id,
            guardrails_v2::id(&guardrails),
            audit_guardrails_hash,
            audit_route_commitment,
            audit_reallocation_state_id,
            audit_allocation_bps,
            audit_source_opportunity_id,
            audit_destination_opportunity_id,
            audit_source_chain_id,
            audit_destination_chain_id,
            audit_source_native_asset,
            audit_destination_native_asset,
            audit_issued_at_ms,
            audit_expires_at_ms,
            1_000,
        );
        hub_protocol::destroy_authorized_for_testing(authorized);

        clock::destroy_for_testing(test_clock);
        ts::return_shared(hub);
        ts::return_shared(destination);
        ts::return_shared(source);
        ts::return_shared(latch);
        ts::return_immutable(policy);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::day::E_HUB_STATE_ANCHOR_MISMATCH)]
    fun test_semantic_authorizer_rejects_wrong_hub_before_sequence_mutation() {
        let mut scn = ts::begin(authority());
        let (
            config_id, registry_id, guardrails_id, _hub_id, policy_id, latch_id,
            source_id, destination_id,
        ) = bootstrap_semantic_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut wrong_hub = hub_protocol::new_hub_for_testing(ts::ctx(&mut scn));
        hub_protocol::bind_oapp_call_cap_for_testing(&mut wrong_hub, @0x0A99);
        seed_deployed_source(&mut source, ts::ctx(&mut scn));
        let (policy_witness, reservation) = semantic_proofs(
            &registry, &guardrails, &policy, &latch, &mut source, &destination,
            false, ts::ctx(&mut scn),
        );
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let authorized = hub_protocol::authorize_validated_reallocation<TestAsset>(
            &config, &mut wrong_hub, &registry, &guardrails, policy_witness,
            reservation, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        hub_protocol::destroy_authorized_for_testing(authorized);
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = day::day::E_STRATEGY_REGISTRY_ANCHOR_MISMATCH)]
    fun test_semantic_authorizer_rejects_wrong_registry_before_sequence_mutation() {
        let mut scn = ts::begin(authority());
        let (
            config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id,
            source_id, destination_id,
        ) = bootstrap_semantic_authorizer_stack(&mut scn);
        let (_other_config_id, other_registry_id) = bootstrap_registry(&mut scn, GOVERNANCE_ALT);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let other_registry = ts::take_shared_by_id<StrategyRegistry>(&scn, other_registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        hub_protocol::bind_oapp_call_cap_for_testing(&mut hub, @0x0A99);
        seed_deployed_source(&mut source, ts::ctx(&mut scn));
        let (policy_witness, reservation) = semantic_proofs(
            &registry, &guardrails, &policy, &latch, &mut source, &destination,
            false, ts::ctx(&mut scn),
        );
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let authorized = hub_protocol::authorize_validated_reallocation<TestAsset>(
            &config, &mut hub, &other_registry, &guardrails, policy_witness,
            reservation, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        hub_protocol::destroy_authorized_for_testing(authorized);
        abort 199
    }

    #[test]
    fun test_semantic_authorizer_commits_every_intermediate_route_leg() {
        let mut scn = ts::begin(authority());
        let (
            config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id,
            source_id, destination_id,
        ) = bootstrap_semantic_authorizer_stack(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        hub_protocol::bind_oapp_call_cap_for_testing(&mut hub, @0x0A99);
        seed_deployed_source(&mut source, ts::ctx(&mut scn));
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);

        let (first_policy, first_reservation) = semantic_proofs(
            &registry, &guardrails, &policy, &latch, &mut source, &destination,
            false, ts::ctx(&mut scn),
        );
        let first = hub_protocol::authorize_validated_reallocation<TestAsset>(
            &config, &mut hub, &registry, &guardrails, first_policy,
            first_reservation, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        let (_, _, _, first_route, _, _, _, _, _, _, _, _, _, _) =
            hub_protocol::authorized_reallocate_audit_v1(&first);
        let (_, first_payload) = hub_protocol::authorized_transport_message(&first);
        let first_intent = hub_protocol::authorized_intent_id(&first);
        hub_protocol::destroy_authorized_for_testing(first);

        hub_protocol::set_next_sequence_for_testing(&mut hub, BASE_EID, 0);
        let (second_policy, second_reservation) = semantic_proofs(
            &registry, &guardrails, &policy, &latch, &mut source, &destination,
            true, ts::ctx(&mut scn),
        );
        let second = hub_protocol::authorize_validated_reallocation<TestAsset>(
            &config, &mut hub, &registry, &guardrails, second_policy,
            second_reservation, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        let (_, _, _, second_route, _, _, _, _, _, _, _, _, _, _) =
            hub_protocol::authorized_reallocate_audit_v1(&second);
        let (_, second_payload) = hub_protocol::authorized_transport_message(&second);
        let second_intent = hub_protocol::authorized_intent_id(&second);
        assert!(first_route != second_route, 120);
        assert!(first_payload != second_payload, 121);
        assert!(first_intent != second_intent, 122);
        hub_protocol::destroy_authorized_for_testing(second);

        clock::destroy_for_testing(test_clock);
        ts::return_shared(hub);
        ts::return_shared(destination);
        ts::return_shared(source);
        ts::return_shared(latch);
        ts::return_immutable(policy);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    fun test_managed_wire_full_schema_round_trips_through_canonical_decoder() {
        let payload = hub_protocol::managed_reallocate_v1_bytes_for_testing(
            BASE_EID,
            1,
            7,
            1_000,
            2_000,
            STRATEGY,
            HASH,
            HASH,
            b"sui",
            b"base",
            b"sui-native-asset",
            b"base-native-asset",
            FROM_OPPORTUNITY,
            TO_OPPORTUNITY,
            2_500,
            HASH,
            HASH,
        );
        assert!(
            hub_protocol::assert_managed_reallocate_v1_message(BASE_EID, &payload) == 2_000,
            100,
        );
    }

    #[test]
    #[expected_failure(abort_code = 10, location = day::hub_protocol)]
    fun test_managed_wire_rejects_destination_substitution() {
        let payload = hub_protocol::managed_reallocate_v1_bytes_for_testing(
            BASE_EID,
            1,
            7,
            1_000,
            2_000,
            STRATEGY,
            HASH,
            HASH,
            b"sui",
            b"base",
            b"sui-native-asset",
            b"base-native-asset",
            FROM_OPPORTUNITY,
            TO_OPPORTUNITY,
            2_500,
            HASH,
            HASH,
        );
        let _ = hub_protocol::assert_managed_reallocate_v1_message(ARBITRUM_EID, &payload);
        abort 199
    }

    #[test]
    fun test_destination_chain_mapping_is_exact_and_pinned() {
        assert!(hub_protocol::layerzero_eid_for_chain(b"base") == BASE_EID, 0);
        assert!(hub_protocol::layerzero_eid_for_chain(b"arbitrum") == ARBITRUM_EID, 1);
        assert!(hub_protocol::layerzero_eid_for_chain(b"solana") == SOLANA_EID, 2);
        // DAY-903: six-chain EVM expansion.
        assert!(hub_protocol::layerzero_eid_for_chain(b"ethereum") == ETHEREUM_EID, 3);
        assert!(hub_protocol::layerzero_eid_for_chain(b"bsc") == BSC_EID, 4);
        assert!(hub_protocol::layerzero_eid_for_chain(b"polygon") == POLYGON_EID, 5);
        assert!(hub_protocol::layerzero_eid_for_chain(b"monad") == MONAD_EID, 6);
        assert!(hub_protocol::layerzero_eid_for_chain(b"plasma") == PLASMA_EID, 7);
        assert!(hub_protocol::layerzero_eid_for_chain(b"robinhood") == ROBINHOOD_EID, 8);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_UNSUPPORTED_DESTINATION_CHAIN)]
    fun test_unknown_destination_chain_fails_closed() {
        let _ = hub_protocol::layerzero_eid_for_chain(b"Base");
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_UNSUPPORTED_DESTINATION_CHAIN)]
    fun test_unsupported_destination_chain_still_fails_closed() {
        // DAY-903: a chain outside the expanded pinned set still aborts.
        let _ = hub_protocol::layerzero_eid_for_chain(b"tron");
    }

    #[test]
    fun test_exit_mode_remains_codec_only_without_authorized_transport() {
        let (mut hub, clock) = setup();
        let command: ExitModeCommand = hub_protocol::prepare_exit_mode(
            &mut hub, BASE_EID, STRATEGY, HASH, 2_000, &clock,
        );

        // The only transport accessor requires AuthorizedHubCommand. This
        // codec/reference value cannot be converted to that private type.
        assert!(!vector::is_empty(&hub_protocol::exit_mode_bytes(&command)), 0);
        cleanup(hub, clock);
    }

    #[test]
    fun test_canonical_commands_are_deterministic_and_domain_separated() {
        let (mut hub, clock) = setup();
        let (mut twin_hub, twin_clock) = setup();
        let first = reallocate(&mut hub, &clock, BASE_EID);
        let twin = reallocate(&mut twin_hub, &twin_clock, BASE_EID);
        let exit = hub_protocol::prepare_exit_mode(
            &mut hub, BASE_EID, STRATEGY, HASH, 2_000, &clock,
        );

        assert!(hub_protocol::reallocate_sequence(&first) == 0, 0);
        assert!(hub_protocol::exit_mode_sequence(&exit) == 1, 1);
        assert!(hub_protocol::reallocate_spoke_eid(&first) == BASE_EID, 2);
        assert!(hub_protocol::reallocate_bytes(&first) == hub_protocol::reallocate_bytes(&twin), 3);
        assert!(hub_protocol::reallocate_hash(&first) != hub_protocol::exit_mode_hash(&exit), 4);
        assert!(vector::length(&hub_protocol::reallocate_hash(&first)) == 32, 5);
        cleanup(hub, clock);
        cleanup(twin_hub, twin_clock);
    }

    #[test]
    fun test_sequences_are_independent_per_spoke() {
        let (mut hub, clock) = setup();
        let base0 = reallocate(&mut hub, &clock, BASE_EID);
        let arb0 = reallocate(&mut hub, &clock, ARBITRUM_EID);
        let base1 = reallocate(&mut hub, &clock, BASE_EID);

        assert!(hub_protocol::reallocate_sequence(&base0) == 0, 0);
        assert!(hub_protocol::reallocate_sequence(&arb0) == 0, 1);
        assert!(hub_protocol::reallocate_sequence(&base1) == 1, 2);
        cleanup(hub, clock);
    }

    #[test]
    fun test_valid_layerzero_provenance_and_ordered_delivery() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);

        assert!(hub_protocol::provenance_matches(
            hub_protocol::sui_layerzero_eid(), PEER, PEER,
        ), 0);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox,
            hub_protocol::sui_layerzero_eid(),
            PEER,
            &command,
            1_500,
        );
        assert!(hub_protocol::inbox_next_sequence(&inbox) == 1, 1);
        cleanup(hub, clock);
    }

    #[test]
    fun test_exit_mode_has_same_provenance_replay_and_expiry_gate() {
        let (mut hub, clock) = setup();
        let command = hub_protocol::prepare_exit_mode(
            &mut hub, BASE_EID, STRATEGY, HASH, 2_000, &clock,
        );
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_exit_mode_and_consume(
            &mut inbox,
            hub_protocol::sui_layerzero_eid(),
            PEER,
            &command,
            2_000,
        );
        assert!(hub_protocol::inbox_next_sequence(&inbox) == 1, 0);
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_INVALID_PROVENANCE)]
    fun test_rogue_peer_fails_closed() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox,
            hub_protocol::sui_layerzero_eid(),
            ROGUE_PEER,
            &command,
            1_500,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_INVALID_PROVENANCE)]
    fun test_non_sui_source_fails_closed() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, ARBITRUM_EID, PEER, &command, 1_500,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_REPLAY_OR_GAP)]
    fun test_replay_fails_closed() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &command, 1_500,
        );
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &command, 1_500,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_REPLAY_OR_GAP)]
    fun test_out_of_order_gap_fails_closed() {
        let (mut hub, clock) = setup();
        let first = reallocate(&mut hub, &clock, BASE_EID);
        let second = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &second, 1_500,
        );
        let _ = first;
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_WRONG_SPOKE)]
    fun test_cross_spoke_replay_fails_closed() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(ARBITRUM_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &command, 1_500,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_EXPIRED)]
    fun test_expired_command_fails_closed() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &command, 2_001,
        );
        cleanup(hub, clock);
    }

    /// The router v4 ABI exposed these public functions. They stay present so
    /// a compatible upgrade can succeed, but must not advance a nonce outside
    /// the authenticated OApp completion flow.
    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_LEGACY_SKIP_QUARANTINED)]
    fun test_legacy_reallocate_skip_is_quarantined() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::skip_expired_reallocate_and_consume(
            &mut inbox,
            hub_protocol::sui_layerzero_eid(),
            PEER,
            &command,
            2_001,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_LEGACY_SKIP_QUARANTINED)]
    fun test_legacy_exit_mode_skip_is_quarantined() {
        let (mut hub, clock) = setup();
        let command = hub_protocol::prepare_exit_mode(
            &mut hub, BASE_EID, STRATEGY, HASH, 2_000, &clock,
        );
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::skip_expired_exit_mode_and_consume(
            &mut inbox,
            hub_protocol::sui_layerzero_eid(),
            PEER,
            &command,
            2_001,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_UNKNOWN_ACTION)]
    fun test_unknown_action_fails_closed() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let malformed = hub_protocol::copy_reallocate_with_action_for_testing(&command, 255);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &malformed, 1_500,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_SAME_OPPORTUNITY)]
    fun test_same_source_and_target_rejected() {
        let (mut hub, clock) = setup();
        let command = hub_protocol::prepare_reallocate(
            &mut hub,
            BASE_EID,
            STRATEGY,
            HASH,
            b"sui",
            b"base",
            asset_type_bytes<TestAsset>(),
            asset_type_bytes<TestAsset>(),
            b"sui-suilend-usdc",
            b"sui-suilend-usdc",
            2_500,
            2_000,
            &clock,
        );
        let _ = command;
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_INVALID_BPS)]
    fun test_zero_allocation_rejected() {
        let (mut hub, clock) = setup();
        let command = hub_protocol::prepare_reallocate(
            &mut hub,
            BASE_EID,
            STRATEGY,
            HASH,
            b"sui",
            b"base",
            asset_type_bytes<TestAsset>(),
            asset_type_bytes<TestAsset>(),
            b"sui-suilend-usdc",
            b"base-morpho-usdc",
            0,
            2_000,
            &clock,
        );
        let _ = command;
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_INVALID_EXPIRY)]
    fun test_non_future_expiry_rejected_at_hub() {
        let (mut hub, clock) = setup();
        let command = hub_protocol::prepare_exit_mode(
            &mut hub, BASE_EID, STRATEGY, HASH, 1_000, &clock,
        );
        let _ = command;
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_INVALID_GUARDRAILS_HASH)]
    fun test_bad_guardrails_hash_rejected_at_hub() {
        let (mut hub, clock) = setup();
        let command = hub_protocol::prepare_exit_mode(
            &mut hub, BASE_EID, STRATEGY, x"abcd", 2_000, &clock,
        );
        let _ = command;
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_INVALID_EXPIRY)]
    fun test_future_issued_time_fails_closed_at_spoke() {
        let (mut hub, clock) = setup();
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let mut inbox = hub_protocol::new_inbox_for_testing(BASE_EID, PEER);
        hub_protocol::verify_reallocate_and_consume(
            &mut inbox, hub_protocol::sui_layerzero_eid(), PEER, &command, 999,
        );
        cleanup(hub, clock);
    }

    #[test]
    #[expected_failure(abort_code = day::hub_protocol::E_SEQUENCE_EXHAUSTED)]
    fun test_sequence_exhaustion_fails_closed() {
        let (mut hub, clock) = setup();
        hub_protocol::set_next_sequence_for_testing(
            &mut hub, BASE_EID, 18_446_744_073_709_551_615,
        );
        let command = reallocate(&mut hub, &clock, BASE_EID);
        let _ = command;
        cleanup(hub, clock);
    }
}
