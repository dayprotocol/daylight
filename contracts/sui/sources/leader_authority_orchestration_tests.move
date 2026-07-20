// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
/// Regression coverage for the sole public DAY-849 composition path. This
/// deliberately invokes leader_authority, not the lower-level hub mint.
module day::leader_authority_orchestration_tests {
    use day::adapter_registry::{Self, AdapterRegistryV2, RegistryAdminCap};
    use day::day::{Self as protocol, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::hub_protocol::{Self, HubState};
    use day::leader_activity_log;
    use day::leader_authority;
    use day::leader_policy::{ExitModeLatch, LeaderPolicy};
    use day::managed_position::{Self, OpportunityAccounting};
    use day::managed_route::{Self, ReallocationRouteLeg};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use sui::clock;
    use sui::coin;
    use sui::test_scenario as ts;
    use std::hash;

    const GOVERNANCE: address = @0x600D;
    const LEADER: address = @0x1EAD;
    const STRATEGY: vector<u8> = b"dayop849";
    const FROM_OPPORTUNITY: vector<u8> = b"dayop0000000849";
    const TO_OPPORTUNITY: vector<u8> = b"dayop0000000850";
    const BASE_EID: u32 = 30_184;
    const BASE_TOKEN: vector<u8> = x"0101010101010101010101010101010101010101";
    const BASE_TOKEN_B: vector<u8> = x"0202020202020202020202020202020202020202";
    const ARBITRUM_TOKEN: vector<u8> = x"0303030303030303030303030303030303030303";

    public struct Asset has drop {}
    public struct AdapterWitness has drop {}

    fun authority(): address { strategy_registry::day_authority_for_testing() }

    fun setup(scn: &mut ts::Scenario): (ID, ID, ID, ID, ID, ID, ID, ID) {
        let config = protocol::new_config_for_testing(ts::ctx(scn));
        let config_id = object::id(&config);
        protocol::share_config_for_testing(config);
        ts::next_tx(scn, authority());
        let mut config = ts::take_shared_by_id<ProtocolConfig>(scn, config_id);
        strategy_registry::bootstrap_for_testing(&mut config, GOVERNANCE, ts::ctx(scn));
        let registry_id = option::destroy_some(protocol::canonical_strategy_registry_id(&config));
        ts::return_shared(config);

        ts::next_tx(scn, LEADER);
        let mut builder = guardrails_v2::new_builder(ts::ctx(scn));
        guardrails_v2::add_allowed_asset<Asset>(&mut builder, ts::ctx(scn));
        guardrails_v2::add_allowed_evm_asset(&mut builder, b"base", BASE_TOKEN, ts::ctx(scn));
        guardrails_v2::add_allowed_evm_asset(&mut builder, b"base", BASE_TOKEN_B, ts::ctx(scn));
        guardrails_v2::add_allowed_evm_asset(&mut builder, b"arbitrum", ARBITRUM_TOKEN, ts::ctx(scn));
        guardrails_v2::add_allowed_opportunity(&mut builder, FROM_OPPORTUNITY, ts::ctx(scn));
        guardrails_v2::add_allowed_opportunity(&mut builder, TO_OPPORTUNITY, ts::ctx(scn));
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ts::ctx(scn));
        guardrails_v2::add_allowed_chain(&mut builder, b"base", ts::ctx(scn));
        guardrails_v2::add_allowed_chain(&mut builder, b"arbitrum", ts::ctx(scn));
        guardrails_v2::set_max_allocation_bps(&mut builder, 5_000, ts::ctx(scn));
        let digest = guardrails_v2::preview_hash(&builder);
        let guardrails_id = guardrails_v2::finalize_and_freeze(builder, digest, ts::ctx(scn));

        ts::next_tx(scn, GOVERNANCE);
        let mut registry = ts::take_shared_by_id<StrategyRegistry>(scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        strategy_registry::register_strategy(
            &mut registry, &cap, STRATEGY, LEADER, &guardrails, &test_clock, ts::ctx(scn),
        );
        let (policy_id, latch_id) = leader_authority::create_policy_and_latch(
            &mut registry, &cap, STRATEGY, true, &test_clock, ts::ctx(scn),
        );
        clock::destroy_for_testing(test_clock);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);

        ts::next_tx(scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        hub_protocol::bootstrap_hub_state(&mut config, &registry, &cap, ts::ctx(scn));
        let hub_id = option::destroy_some(protocol::canonical_hub_state_id(&config));
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);

        ts::next_tx(scn, GOVERNANCE);
        adapter_registry::bootstrap_registry_v2_for_testing(GOVERNANCE, ts::ctx(scn));
        ts::next_tx(scn, GOVERNANCE);
        let mut config = ts::take_shared_by_id<ProtocolConfig>(scn, config_id);
        let mut registry = ts::take_shared_by_id<StrategyRegistry>(scn, registry_id);
        let admin_cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let mut adapters = ts::take_shared<AdapterRegistryV2>(scn);
        let adapter_cap = ts::take_from_address<RegistryAdminCap>(scn, GOVERNANCE);
        protocol::anchor_adapter_registry_v2(
            &mut config, object::id(&adapters), object::id(&adapter_cap), GOVERNANCE,
        );
        adapter_registry::register_authenticated(
            &adapter_cap, &mut adapters, b"leader-source", b"sui", b"leader source",
        );
        adapter_registry::register_authenticated(
            &adapter_cap, &mut adapters, b"leader-destination", b"base", b"leader destination",
        );
        let source_id = managed_position::create_managed_accounting<AdapterWitness, Asset>(
            &config, &registry, &admin_cap, &adapters, &guardrails, STRATEGY,
            FROM_OPPORTUNITY, b"sui", b"", b"leader-source", 0, 0, LEADER,
            @0xDA7, @0xADAE7, ts::ctx(scn),
        );
        let destination_id = managed_position::create_managed_accounting<AdapterWitness, Asset>(
            &config, &registry, &admin_cap, &adapters, &guardrails, STRATEGY,
            TO_OPPORTUNITY, b"base", BASE_TOKEN, b"leader-destination", 0, 0, LEADER,
            @0xDA7, @0xADAE7, ts::ctx(scn),
        );
        ts::return_shared(adapters);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_shared(config);
        ts::return_to_address(GOVERNANCE, admin_cap);
        ts::return_to_address(GOVERNANCE, adapter_cap);
        (config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id, source_id, destination_id)
    }

    fun seed_source(source: &mut OpportunityAccounting, ctx: &mut TxContext) {
        let position = managed_position::record_managed_local_deposit_for_testing<Asset>(
            source, false, 100, ctx,
        );
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            source, &witness, coin::mint_for_testing<Asset>(100, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(source, deployment));
        managed_position::destroy_position_for_testing(position);
    }

    fun route(
        source_id: ID,
        destination_id: ID,
        guardrails: &GuardrailsV2,
    ): vector<ReallocationRouteLeg> {
        let source_asset = guardrails_v2::sui_asset_binding<Asset>();
        let destination_asset = guardrails_v2::native_asset_binding_from_policy(
            guardrails, b"base", BASE_TOKEN,
        );
        route_with_destination_asset(source_id, destination_id, source_asset, destination_asset)
    }

    fun route_with_destination_asset(
        source_id: ID,
        destination_id: ID,
        source_asset: guardrails_v2::NativeAssetBinding,
        destination_asset: guardrails_v2::NativeAssetBinding,
    ): vector<ReallocationRouteLeg> {
        vector[
            managed_route::reallocation_withdraw_leg(source_id, source_asset, FROM_OPPORTUNITY),
            managed_route::reallocation_bridge_leg(
                object::id_from_address(@0xB1), source_asset, destination_asset,
            ),
            managed_route::reallocation_deposit_leg(
                destination_id, destination_asset, TO_OPPORTUNITY,
            ),
        ]
    }

    #[test]
    fun test_public_leaf_reserves_orders_and_returns_same_command() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id, source_id, destination_id) =
            setup(&mut scn);
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
        seed_source(&mut source, ts::ctx(&mut scn));
        let route = route(source_id, destination_id, &guardrails);
        let (canonical_route, _source_binding, _destination_binding) =
            managed_position::validated_reallocation_route_for_accountings(
                &source,
                &destination,
                &route,
                &guardrails,
                2_500,
            );
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let command = leader_authority::authorize_reallocation<Asset>(
            &config, &mut hub, &registry, &guardrails, &policy, &latch, &mut source,
            &destination, &route, 2_500, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        let (
            strategy_id, guardrails_hash, _guardrails_id, route_commitment, state_id, allocation_bps,
            source_opportunity, destination_opportunity, source_chain, destination_chain,
            source_native_asset, destination_native_asset, issued_at_ms, expires_at_ms,
        ) = hub_protocol::authorized_reallocate_audit_v1(&command);
        assert!(strategy_id == STRATEGY, 100);
        assert!(guardrails_hash == guardrails_v2::guardrails_hash(&guardrails), 101);
        assert!(vector::length(&route_commitment) == 32, 102);
        assert!(route_commitment == hash::sha2_256(canonical_route), 114);
        assert!(vector::length(&state_id) == 32, 103);
        assert!(allocation_bps == 2_500, 104);
        assert!(source_opportunity == FROM_OPPORTUNITY, 105);
        assert!(destination_opportunity == TO_OPPORTUNITY, 106);
        assert!(source_chain == b"sui", 107);
        assert!(destination_chain == b"base", 108);
        assert!(!vector::is_empty(&source_native_asset), 109);
        assert!(!vector::is_empty(&destination_native_asset), 110);
        assert!(issued_at_ms == 1_000 && expires_at_ms == 2_000, 111);
        let intent_id = hub_protocol::authorized_intent_id(&command);
        leader_activity_log::assert_last_ordered_event_for_testing(
            intent_id, LEADER, STRATEGY, guardrails_v2::id(&guardrails),
            guardrails_v2::guardrails_hash(&guardrails), route_commitment, state_id, 2_500,
            FROM_OPPORTUNITY, TO_OPPORTUNITY, b"sui", b"base", source_native_asset,
            destination_native_asset, 1_000, 2_000, 1_000,
        );
        let (dst_eid, payload) = hub_protocol::authorized_transport_message(&command);
        assert!(dst_eid == BASE_EID, 112);
        assert!(hub_protocol::assert_managed_reallocate_v1_message(dst_eid, &payload) == 2_000, 113);
        hub_protocol::destroy_authorized_for_testing(command);
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
    fun test_public_leaf_rejects_wrong_hub_before_accounting_reservation() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, guardrails_id, _hub_id, policy_id, latch_id, source_id, destination_id) =
            setup(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut wrong_hub = hub_protocol::new_hub_for_testing(ts::ctx(&mut scn));
        let route = route(source_id, destination_id, &guardrails);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let _command = leader_authority::authorize_reallocation<Asset>(
            &config, &mut wrong_hub, &registry, &guardrails, &policy, &latch, &mut source,
            &destination, &route, 2_500, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = 9, location = day::strategy_registry)]
    fun test_public_leaf_rejects_paused_strategy_before_accounting_reservation() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id, source_id, destination_id) =
            setup(&mut scn);
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        strategy_registry::pause_strategy(&mut registry, &cap, STRATEGY, ts::ctx(&mut scn));
        ts::return_to_address(GOVERNANCE, cap);
        ts::return_shared(registry);

        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let route = route(source_id, destination_id, &guardrails);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let _command = leader_authority::authorize_reallocation<Asset>(
            &config, &mut hub, &registry, &guardrails, &policy, &latch, &mut source,
            &destination, &route, 2_500, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ACCOUNTING_ASSET_MISMATCH)]
    fun test_public_leaf_rejects_base_to_arbitrum_endpoint_substitution_before_reservation() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id, source_id, destination_id) =
            setup(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let source_asset = guardrails_v2::sui_asset_binding<Asset>();
        let arbi = guardrails_v2::native_asset_binding_from_policy(
            &guardrails, b"arbitrum", ARBITRUM_TOKEN,
        );
        let route = route_with_destination_asset(source_id, destination_id, source_asset, arbi);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let _command = leader_authority::authorize_reallocation<Asset>(
            &config, &mut hub, &registry, &guardrails, &policy, &latch, &mut source,
            &destination, &route, 2_500, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        abort 199
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ACCOUNTING_ASSET_MISMATCH)]
    fun test_public_leaf_rejects_same_chain_token_substitution_before_reservation() {
        let mut scn = ts::begin(authority());
        let (config_id, registry_id, guardrails_id, hub_id, policy_id, latch_id, source_id, destination_id) =
            setup(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let config = ts::take_shared_by_id<ProtocolConfig>(&scn, config_id);
        let registry = ts::take_shared_by_id<StrategyRegistry>(&scn, registry_id);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut source = ts::take_shared_by_id<OpportunityAccounting>(&scn, source_id);
        let destination = ts::take_shared_by_id<OpportunityAccounting>(&scn, destination_id);
        let mut hub = ts::take_shared_by_id<HubState>(&scn, hub_id);
        let source_asset = guardrails_v2::sui_asset_binding<Asset>();
        let base_token_b = guardrails_v2::native_asset_binding_from_policy(
            &guardrails, b"base", BASE_TOKEN_B,
        );
        let route = route_with_destination_asset(source_id, destination_id, source_asset, base_token_b);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 1_000);
        let _command = leader_authority::authorize_reallocation<Asset>(
            &config, &mut hub, &registry, &guardrails, &policy, &latch, &mut source,
            &destination, &route, 2_500, 2_000, &test_clock, ts::ctx(&mut scn),
        );
        abort 199
    }
}
