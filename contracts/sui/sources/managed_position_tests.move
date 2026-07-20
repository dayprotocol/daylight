// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-846/849/859-862 position, closeout, and accounting regressions.
#[test_only]
module day::managed_position_tests {
    use day::adapter_registry::{Self, AdapterRegistryV2, RegistryAdminCap};
    use day::day::{Self as protocol, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::leader_authority;
    use day::leader_policy::LeaderPolicy;
    use day::managed_closeout;
    use day::managed_position;
    use day::managed_route;
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use std::type_name;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use std::hash;
    use sui::sui::SUI;
    use sui::test_scenario as ts;

    const ALICE: address = @0xA11CE;
    const BOB: address = @0xB0B;
    const CAROL: address = @0xCA201;
    const ATTACKER: address = @0xBAD;
    const ADAPTER: address = @0xADAE7;
    const LEAD_FEES: address = @0x1EAD;
    const DAY_FEES: address = @0xDA7;
    const STRATEGY: vector<u8> = b"day-managed-top-one";
    const ROUTE: vector<u8> = x"2222222222222222222222222222222222222222222222222222222222222222";
    const SOURCE_OPPORTUNITY: vector<u8> = b"dayop0000000501";
    const DESTINATION_OPPORTUNITY: vector<u8> = b"dayop000000d357";
    const BASE_TOKEN_A: vector<u8> = x"1111111111111111111111111111111111111111";
    const BASE_TOKEN_B: vector<u8> = x"2222222222222222222222222222222222222222";
    const ARBITRUM_TOKEN_A: vector<u8> = x"1111111111111111111111111111111111111111";

    public struct AdapterWitness has drop {}
    public struct WrongAdapterWitness has drop {}
    public struct OtherAsset has drop {}
    public struct OtherAssetB has drop {}

    fun id(value: address): ID { object::id_from_address(value) }

    fun authority(): address { strategy_registry::day_authority_for_testing() }

    fun create_frozen_guardrails(scenario: &mut ts::Scenario): ID {
        let ctx = ts::ctx(scenario);
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<SUI>(&mut builder, ctx);
        guardrails_v2::add_allowed_opportunity(
            &mut builder,
            b"dayop0000000001",
            ctx,
        );
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_and_freeze(builder, digest, ctx)
    }

    fun route_guardrails(ctx: &mut TxContext): GuardrailsV2 {
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<SUI>(&mut builder, ctx);
        guardrails_v2::add_allowed_asset<OtherAsset>(&mut builder, ctx);
        guardrails_v2::add_allowed_asset<OtherAssetB>(&mut builder, ctx);
        guardrails_v2::add_allowed_solana_asset(
            &mut builder,
            x"0101010101010101010101010101010101010101010101010101010101010101",
            ctx,
        );
        guardrails_v2::add_allowed_opportunity(
            &mut builder,
            SOURCE_OPPORTUNITY,
            ctx,
        );
        guardrails_v2::add_allowed_opportunity(
            &mut builder,
            DESTINATION_OPPORTUNITY,
            ctx,
        );
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_for_testing(builder, digest, ctx)
    }

    fun cross_chain_route_guardrails(ctx: &mut TxContext): GuardrailsV2 {
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<SUI>(&mut builder, ctx);
        guardrails_v2::add_allowed_solana_asset(
            &mut builder,
            x"0101010101010101010101010101010101010101010101010101010101010101",
            ctx,
        );
        guardrails_v2::add_allowed_opportunity(&mut builder, SOURCE_OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, DESTINATION_OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"solana", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_for_testing(builder, digest, ctx)
    }

    fun evm_route_guardrails(ctx: &mut TxContext): GuardrailsV2 {
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<OtherAsset>(&mut builder, ctx);
        guardrails_v2::add_allowed_evm_asset(&mut builder, b"base", BASE_TOKEN_A, ctx);
        guardrails_v2::add_allowed_evm_asset(&mut builder, b"base", BASE_TOKEN_B, ctx);
        guardrails_v2::add_allowed_evm_asset(
            &mut builder,
            b"arbitrum",
            ARBITRUM_TOKEN_A,
            ctx,
        );
        guardrails_v2::add_allowed_opportunity(&mut builder, SOURCE_OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, DESTINATION_OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"base", ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"arbitrum", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_for_testing(builder, digest, ctx)
    }

    fun validate_route_for_testing(
        route: &vector<managed_route::ReallocationRouteLeg>,
        source_id: ID,
        destination_id: ID,
        ctx: &mut TxContext,
    ): vector<u8> {
        let guardrails = route_guardrails(ctx);
        let (bytes, _, _) = managed_route::validated_reallocation_route_canonical_v1(
            route,
            &guardrails,
            10_000,
            source_id,
            SOURCE_OPPORTUNITY,
            destination_id,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
        bytes
    }

    fun plain(ctx: &mut TxContext): managed_position::OpportunityAccounting {
        managed_position::new_accounting_for_testing<SUI>(
            b"dayop0000000001", b"sui", ctx,
        )
    }

    fun managed(
        opportunity: vector<u8>,
        ctx: &mut TxContext,
    ): managed_position::OpportunityAccounting {
        managed_position::new_managed_accounting_for_testing<SUI>(
            opportunity, b"sui", STRATEGY, 2_000, 2_500, ctx,
        )
    }

    fun plain_deposit(
        accounting: &mut managed_position::OpportunityAccounting,
        amount: u128,
        ctx: &mut TxContext,
    ): managed_position::Position {
        managed_position::record_local_deposit_for_testing<SUI>(
            accounting, option::none(), option::none(), amount, ctx,
        )
    }

    fun managed_deposit(
        accounting: &mut managed_position::OpportunityAccounting,
        consent: bool,
        ctx: &mut TxContext,
    ): managed_position::Position {
        managed_position::record_managed_local_deposit_for_testing<SUI>(
            accounting,
            consent,
            100_000_000,
            ctx,
        )
    }

    /// TestScenario serializes shared-object transactions, so exercise both
    /// sender orders explicitly. This catches lost updates / second-mint PPS
    /// drift without assuming address-owned object serialization.
    fun assert_shared_equal_subscriptions(first: address, second: address) {
        let mut scenario = ts::begin(first);
        let accounting = plain(ts::ctx(&mut scenario));
        let accounting_id = object::id(&accounting);
        managed_position::share_accounting_for_testing(accounting);

        ts::next_tx(&mut scenario, first);
        let mut accounting = ts::take_shared_by_id<managed_position::OpportunityAccounting>(
            &scenario,
            accounting_id,
        );
        let (first_position_id, first_coin) = managed_position::record_local_deposit(
            &mut accounting,
            coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        coin::burn_for_testing(first_coin);
        ts::return_shared(accounting);

        ts::next_tx(&mut scenario, second);
        let mut accounting = ts::take_shared_by_id<managed_position::OpportunityAccounting>(
            &scenario,
            accounting_id,
        );
        let (second_position_id, second_coin) = managed_position::record_local_deposit(
            &mut accounting,
            coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        coin::burn_for_testing(second_coin);
        ts::return_shared(accounting);

        ts::next_tx(&mut scenario, first);
        let accounting = ts::take_shared_by_id<managed_position::OpportunityAccounting>(
            &scenario,
            accounting_id,
        );
        let first_position = ts::take_shared_by_id<managed_position::Position>(
            &scenario,
            first_position_id,
        );
        let second_position = ts::take_shared_by_id<managed_position::Position>(
            &scenario,
            second_position_id,
        );
        assert!(managed_position::position_shares(&first_position) == 100, 200);
        assert!(managed_position::position_shares(&second_position) == 100, 201);
        assert!(managed_position::position_value_micros(&accounting, &first_position) == 100, 202);
        assert!(managed_position::position_value_micros(&accounting, &second_position) == 100, 203);
        assert!(managed_position::total_assets_micros(&accounting) == 200, 204);
        assert!(managed_position::total_shares(&accounting) == 200, 205);
        assert!(managed_position::recorded_payout_destination(&first_position) == first, 206);
        assert!(managed_position::recorded_payout_destination(&second_position) == second, 207);
        managed_position::destroy_position_for_testing(first_position);
        managed_position::destroy_position_for_testing(second_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_shared_position_equal_subscriptions_alice_then_bob() {
        assert_shared_equal_subscriptions(ALICE, BOB);
    }

    #[test]
    fun test_shared_position_equal_subscriptions_bob_then_alice() {
        assert_shared_equal_subscriptions(BOB, ALICE);
    }

    #[test]
    fun test_plain_position_fails_closed_for_managed_and_force_exit() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 100_000_000, ctx);
        assert!(managed_position::strategy_id(&position) == option::none(), 0);
        assert!(!managed_position::leader_may_force_exit(&position), 1);
        assert!(managed_position::force_exit_policy_id(&position) == option::none(), 2);
        assert!(!managed_position::matches_managed_policy(&position, STRATEGY, id(@0x6A4D)), 3);
        assert!(!managed_position::matches_force_exit_policy(
            &position, STRATEGY, id(@0x6A4D), id(@0xF04CE),
        ), 4);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_PRIMITIVE_ADAPTER_WITNESS)]
    fun test_primitive_adapter_witness_is_rejected() {
        managed_position::assert_adapter_witness_for_testing<u64>();
    }

    #[test]
    fun test_production_deposit_measures_coin_and_records_owner() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let (position_id, in_flight) = managed_position::record_local_deposit(
            &mut accounting,
            coin::mint_for_testing<SUI>(100_000_000, ctx),
            ctx,
        );
        assert!(coin::value(&in_flight) == 100_000_000, 5);
        assert!(managed_position::total_assets_micros(&accounting) == 100_000_000, 6);
        coin::burn_for_testing(in_flight);
        ts::next_tx(&mut scenario, ALICE);
        let position = ts::take_shared_by_id<managed_position::Position>(
            &scenario, position_id,
        );
        assert!(managed_position::recorded_payout_destination(&position) == ALICE, 7);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_production_accounting_creation_binds_canonical_authority() {
        let mut scenario = ts::begin(authority());
        let config = protocol::new_config_for_testing(ts::ctx(&mut scenario));
        protocol::share_config_for_testing(config);
        ts::next_tx(&mut scenario, authority());
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        strategy_registry::bootstrap_for_testing(
            &mut config,
            ALICE,
            ts::ctx(&mut scenario),
        );
        adapter_registry::bootstrap_registry_v2_for_testing(
            ALICE,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(config);

        ts::next_tx(&mut scenario, BOB);
        let guardrails_id = create_frozen_guardrails(&mut scenario);

        ts::next_tx(&mut scenario, ALICE);
        let mut config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut registry = ts::take_shared<StrategyRegistry>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(
            &scenario,
            guardrails_id,
        );
        let test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
        strategy_registry::register_strategy(
            &mut registry,
            &admin_cap,
            STRATEGY,
            BOB,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        let (policy_id, _) = leader_authority::create_policy_and_latch(
            &mut registry,
            &admin_cap,
            STRATEGY,
            true,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        clock::destroy_for_testing(test_clock);

        let mut adapters = ts::take_shared<AdapterRegistryV2>(&scenario);
        let adapter_cap = ts::take_from_sender<RegistryAdminCap>(&scenario);
        protocol::anchor_adapter_registry_v2(
            &mut config,
            object::id(&adapters),
            object::id(&adapter_cap),
            ALICE,
        );
        adapter_registry::register_authenticated(
            &adapter_cap,
            &mut adapters,
            b"test-adapter",
            b"sui",
            b"Test adapter",
        );
        let registry_id = strategy_registry::id(&registry);
        let accounting_id = managed_position::create_managed_accounting<AdapterWitness, SUI>(
            &config,
            &registry,
            &admin_cap,
            &adapters,
            &guardrails,
            STRATEGY,
            b"dayop0000000001",
            b"sui",
            vector[],
            b"test-adapter",
            2_000,
            2_500,
            LEAD_FEES,
            DAY_FEES,
            ADAPTER,
            ts::ctx(&mut scenario),
        );
        ts::return_immutable(guardrails);
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_shared(adapters);
        ts::return_to_sender(&mut scenario, admin_cap);
        ts::return_to_sender(&mut scenario, adapter_cap);

        ts::next_tx(&mut scenario, ALICE);
        let mut accounting = ts::take_shared_by_id<managed_position::OpportunityAccounting>(
            &scenario,
            accounting_id,
        );
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let registry = ts::take_shared<StrategyRegistry>(&scenario);
        let adapters = ts::take_shared<AdapterRegistryV2>(&scenario);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scenario, guardrails_id);
        assert!(
            managed_position::accounting_strategy_registry_id(&accounting)
                == option::some(registry_id),
            8,
        );
        assert!(
            managed_position::accounting_strategy_id(&accounting)
                == option::some(STRATEGY),
            9,
        );
        assert!(managed_position::adapter_nonce_for_testing(&accounting) == 0, 10);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scenario, policy_id);
        let (position_id, in_flight) = managed_position::record_managed_local_deposit(
            &mut accounting,
            &config,
            &registry,
            &guardrails,
            &adapters,
            &policy,
            10_000,
            coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        coin::burn_for_testing(in_flight);
        ts::return_immutable(policy);
        ts::return_immutable(guardrails);
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_shared(adapters);
        ts::return_shared(accounting);

        ts::next_tx(&mut scenario, ALICE);
        let mut accounting = ts::take_shared_by_id<managed_position::OpportunityAccounting>(
            &scenario,
            accounting_id,
        );
        let mut position = ts::take_shared_by_id<managed_position::Position>(
            &scenario,
            position_id,
        );
        assert!(managed_position::force_exit_policy_id(&position) == option::some(policy_id), 11);
        assert!(managed_position::leader_may_force_exit(&position), 12);
        assert!(managed_position::position_shares(&position) == 100, 13);

        // R3: lifecycle/adapter disable blocks future deployment but never an
        // authenticated return or the recorded owner's exit.
        let config = ts::take_shared<ProtocolConfig>(&scenario);
        let mut registry = ts::take_shared<StrategyRegistry>(&scenario);
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut adapters = ts::take_shared<AdapterRegistryV2>(&scenario);
        let adapter_cap = ts::take_from_sender<RegistryAdminCap>(&scenario);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scenario, guardrails_id);
        strategy_registry::pause_strategy(
            &mut registry,
            &admin_cap,
            STRATEGY,
            ts::ctx(&mut scenario),
        );
        adapter_registry::set_active_authenticated(
            &adapter_cap,
            &mut adapters,
            b"test-adapter",
            false,
        );
        let witness = AdapterWitness {};
        let receipt = managed_position::attest_adapter_return<AdapterWitness, SUI>(
            &accounting,
            &config,
            &registry,
            &guardrails,
            &adapters,
            &witness,
            accounting_id,
            option::none(),
        );
        option::destroy_none(managed_position::consume_adapter_full_return(
            &mut accounting,
            accounting_id,
            receipt,
        ));
        let payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting,
            &mut position,
            100,
            ts::ctx(&mut scenario),
        );
        let (_, _, destination, _, _, _, amount) =
            managed_position::consume_owner_payout_for_testing(payout);
        assert!(destination == ALICE && amount == 100, 14);
        ts::return_immutable(guardrails);
        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_shared(adapters);
        ts::return_to_sender(&mut scenario, admin_cap);
        ts::return_to_sender(&mut scenario, adapter_cap);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_managed_position_pins_registry_key_and_deposit_time_consent() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let position = managed_deposit(&mut accounting, true, ctx);
        assert!(managed_position::strategy_id(&position) == option::some(STRATEGY), 10);
        assert!(managed_position::matches_managed_policy(&position, STRATEGY, id(@0x6A4D)), 11);
        assert!(managed_position::matches_force_exit_policy(
            &position, STRATEGY, id(@0x6A4D), id(@0x1EAD),
        ), 12);
        assert!(!managed_position::matches_force_exit_policy(
            &position, STRATEGY, id(@0x6A4D), id(@0xBAD),
        ), 13);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_managed_position_without_consent_cannot_be_forced() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let position = managed_deposit(&mut accounting, false, ctx);
        assert!(managed_position::matches_managed_policy(&position, STRATEGY, id(@0x6A4D)), 20);
        assert!(!managed_position::matches_force_exit_policy(
            &position, STRATEGY, id(@0x6A4D), id(@0xF04CE),
        ), 21);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_INVALID_FORCE_EXIT_CONSENT)]
    fun test_plain_position_rejects_force_exit_consent() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            true,
            1,
            ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_route_uses_one_strict_native_binding_union() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let mint = x"0101010101010101010101010101010101010101010101010101010101010101";
        let sol = guardrails_v2::solana_asset_binding(mint);
        let route = vector[
            managed_route::bridge_leg(id(@0xB1), sui, sol),
            managed_route::bridge_leg(id(@0xB2), sol, sui),
            managed_route::deposit_leg<SUI>(
                managed_position::accounting_id(&accounting), b"dayop0000000001",
            ),
        ];
        let position = managed_position::record_local_deposit_with_verified_route_for_testing<SUI>(
            &mut accounting, route, false, 100, ctx,
        );
        let legs = managed_position::entry_route_legs(&position);
        assert!(managed_position::route_leg_source_chain(vector::borrow(&legs, 0)) == b"sui", 30);
        assert!(managed_position::route_leg_destination_chain(vector::borrow(&legs, 0)) == b"solana", 31);
        assert!(managed_position::route_leg_target_opportunity(vector::borrow(&legs, 2))
            == option::some(b"dayop0000000001"), 32);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_reallocation_commitment_binds_every_intermediate_native_identity() {
        let mut ctx = tx_context::new_from_hint(ALICE, 1, 1, 1, 1);
        let guardrails = route_guardrails(&mut ctx);
        let source_id = id(@0x501);
        let destination_id = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let middle_a = guardrails_v2::sui_asset_binding<OtherAsset>();
        let middle_b = guardrails_v2::sui_asset_binding<OtherAssetB>();
        let route_a = vector[
            managed_route::reallocation_withdraw_leg(source_id, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_swap_leg(id(@0xA1), sui, middle_a),
            managed_route::reallocation_swap_leg(id(@0xA2), middle_a, sui),
            managed_route::reallocation_deposit_leg(destination_id, sui, DESTINATION_OPPORTUNITY),
        ];
        let route_b = vector[
            managed_route::reallocation_withdraw_leg(source_id, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_swap_leg(id(@0xA1), sui, middle_b),
            managed_route::reallocation_swap_leg(id(@0xA2), middle_b, sui),
            managed_route::reallocation_deposit_leg(destination_id, sui, DESTINATION_OPPORTUNITY),
        ];
        let (bytes_a, _, _) = managed_route::validated_reallocation_route_canonical_v1(
            &route_a,
            &guardrails,
            10_000,
            source_id,
            SOURCE_OPPORTUNITY,
            destination_id,
            DESTINATION_OPPORTUNITY,
        );
        let (bytes_b, _, _) = managed_route::validated_reallocation_route_canonical_v1(
            &route_b,
            &guardrails,
            10_000,
            source_id,
            SOURCE_OPPORTUNITY,
            destination_id,
            DESTINATION_OPPORTUNITY,
        );
        assert!(hash::sha2_256(bytes_a) != hash::sha2_256(bytes_b), 33);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_SAME_ROUTE_ENDPOINT)]
    fun test_reallocation_rejects_same_source_and_destination_context() {
        let mut ctx = tx_context::new_from_hint(ALICE, 2, 2, 2, 2);
        let endpoint = id(@0x501);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(endpoint, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(endpoint, sui, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, endpoint, endpoint, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_SAME_OPPORTUNITY_ENDPOINT)]
    fun test_reallocation_rejects_same_source_and_destination_opportunity() {
        let mut ctx = tx_context::new_from_hint(ALICE, 16, 16, 16, 16);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(destination, sui, SOURCE_OPPORTUNITY),
        ];
        let guardrails = route_guardrails(&mut ctx);
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_000,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            SOURCE_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ROUTE_NOT_WITHDRAW)]
    fun test_reallocation_rejects_missing_withdraw_first() {
        let mut ctx = tx_context::new_from_hint(ALICE, 3, 3, 3, 3);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_swap_leg(source, sui, sui),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ROUTE_NOT_DEPOSIT)]
    fun test_reallocation_rejects_missing_deposit_last() {
        let mut ctx = tx_context::new_from_hint(ALICE, 4, 4, 4, 4);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_swap_leg(destination, sui, sui),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_DUPLICATE_LEG_ID)]
    fun test_reallocation_rejects_duplicate_leg_id() {
        let mut ctx = tx_context::new_from_hint(ALICE, 5, 5, 5, 5);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_swap_leg(source, sui, sui),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_UNKNOWN_LEG_KIND)]
    fun test_reallocation_rejects_unknown_intermediate_kind() {
        let mut ctx = tx_context::new_from_hint(ALICE, 6, 6, 6, 6);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_leg_for_testing(
                id(@0xA1), 99, sui, sui, option::none(),
            ),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_AMBIGUOUS_ENDPOINT)]
    fun test_reallocation_rejects_ambiguous_intermediate_endpoint() {
        let mut ctx = tx_context::new_from_hint(ALICE, 7, 7, 7, 7);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_leg_for_testing(
                id(@0xA1), 1, sui, sui, option::some(b"hidden-endpoint"),
            ),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_MISSING_ENDPOINT)]
    fun test_reallocation_rejects_missing_endpoint_proof() {
        let mut ctx = tx_context::new_from_hint(ALICE, 8, 8, 8, 8);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_leg_for_testing(
                source, 4, sui, sui, option::none(),
            ),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ROUTE_TARGET_MISMATCH)]
    fun test_reallocation_rejects_substituted_endpoint_binding() {
        let mut ctx = tx_context::new_from_hint(ALICE, 22, 22, 22, 22);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let substituted = guardrails_v2::sui_asset_binding<OtherAsset>();
        // IDs, opportunities, allocation and policy remain canonical. Only the
        // source endpoint binding is substituted; a WITHDRAW may never rewrite
        // the asset between its two sides.
        let route = vector[
            managed_route::reallocation_leg_for_testing(
                source,
                4,
                sui,
                substituted,
                option::some(SOURCE_OPPORTUNITY),
            ),
            managed_route::reallocation_deposit_leg(
                destination,
                substituted,
                DESTINATION_OPPORTUNITY,
            ),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_000,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_DISCONNECTED_ROUTE)]
    fun test_reallocation_rejects_disconnected_adjacency() {
        let mut ctx = tx_context::new_from_hint(ALICE, 9, 9, 9, 9);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let other = guardrails_v2::sui_asset_binding<OtherAsset>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_swap_leg(id(@0xA1), other, other),
            managed_route::reallocation_deposit_leg(destination, other, DESTINATION_OPPORTUNITY),
        ];
        validate_route_for_testing(&route, source, destination, &mut ctx);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_ASSET_NOT_ALLOWED)]
    fun test_reallocation_rejects_unallowed_intermediate_asset() {
        let mut ctx = tx_context::new_from_hint(ALICE, 10, 10, 10, 10);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let unallowed = guardrails_v2::sui_asset_binding<WrongAdapterWitness>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_swap_leg(id(@0xA1), sui, unallowed),
            managed_route::reallocation_swap_leg(id(@0xA2), unallowed, sui),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_000,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_CHAIN_NOT_ALLOWED)]
    fun test_reallocation_rejects_unallowed_intermediate_chain() {
        let mut ctx = tx_context::new_from_hint(ALICE, 11, 11, 11, 11);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let sol = guardrails_v2::solana_asset_binding(
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_bridge_leg(id(@0xB1), sui, sol),
            managed_route::reallocation_bridge_leg(id(@0xB2), sol, sui),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_000,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_OPPORTUNITY_NOT_ALLOWED)]
    fun test_reallocation_rejects_unallowed_source_opportunity() {
        let mut ctx = tx_context::new_from_hint(ALICE, 12, 12, 12, 12);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let bad_source = b"dayop0000000bad";
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, bad_source),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_000,
            source,
            bad_source,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_OPPORTUNITY_NOT_ALLOWED)]
    fun test_reallocation_rejects_unallowed_destination_opportunity() {
        let mut ctx = tx_context::new_from_hint(ALICE, 13, 13, 13, 13);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let bad_destination = b"dayop0000000bad";
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(destination, sui, bad_destination),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_000,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            bad_destination,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_ALLOCATION_EXCEEDED)]
    fun test_reallocation_rejects_allocation_above_guardrail_max() {
        let mut ctx = tx_context::new_from_hint(ALICE, 14, 14, 14, 14);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            10_001,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_ALLOCATION_EXCEEDED)]
    fun test_reallocation_rejects_zero_allocation() {
        let mut ctx = tx_context::new_from_hint(ALICE, 17, 17, 17, 17);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            0,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    fun test_reallocation_accepts_allowed_sui_to_solana_route() {
        let mut ctx = tx_context::new_from_hint(ALICE, 18, 18, 18, 18);
        let guardrails = cross_chain_route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let sol = guardrails_v2::solana_asset_binding(
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_bridge_leg(id(@0xB1), sui, sol),
            managed_route::reallocation_deposit_leg(destination, sol, DESTINATION_OPPORTUNITY),
        ];
        let (bytes, source_binding, destination_binding) =
            managed_route::validated_reallocation_route_canonical_v1(
            &route,
            &guardrails,
            5_000,
            source,
            SOURCE_OPPORTUNITY,
            destination,
            DESTINATION_OPPORTUNITY,
        );
        assert!(!vector::is_empty(&bytes), 138);
        assert!(guardrails_v2::same_native_asset_binding(&source_binding, &sui), 140);
        assert!(guardrails_v2::same_native_asset_binding(&destination_binding, &sol), 141);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    fun test_accounting_bound_reallocation_accepts_exact_remote_endpoints() {
        let mut ctx = tx_context::new_from_hint(ALICE, 118, 118, 118, 118);
        let guardrails = evm_route_guardrails(&mut ctx);
        let base = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN_A);
        let arbitrum = guardrails_v2::evm_asset_binding(
            b"arbitrum",
            ARBITRUM_TOKEN_A,
        );
        let source = managed_position::new_managed_accounting_with_native_binding_for_testing<OtherAsset>(
            SOURCE_OPPORTUNITY,
            STRATEGY,
            base,
            &mut ctx,
        );
        let destination = managed_position::new_managed_accounting_with_native_binding_for_testing<OtherAsset>(
            DESTINATION_OPPORTUNITY,
            STRATEGY,
            arbitrum,
            &mut ctx,
        );
        let source_id = managed_position::accounting_id(&source);
        let destination_id = managed_position::accounting_id(&destination);
        let route = vector[
            managed_route::reallocation_withdraw_leg(
                source_id,
                base,
                SOURCE_OPPORTUNITY,
            ),
            managed_route::reallocation_bridge_leg(id(@0xB1), base, arbitrum),
            managed_route::reallocation_deposit_leg(
                destination_id,
                arbitrum,
                DESTINATION_OPPORTUNITY,
            ),
        ];
        let (bytes, source_binding, destination_binding) =
            managed_position::validated_reallocation_route_for_accountings(
                &source,
                &destination,
                &route,
                &guardrails,
                5_000,
            );
        assert!(!vector::is_empty(&bytes), 146);
        assert!(guardrails_v2::same_native_asset_binding(&source_binding, &base), 147);
        assert!(guardrails_v2::same_native_asset_binding(&destination_binding, &arbitrum), 148);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    fun test_remote_accounting_selects_exact_token_from_multi_token_policy() {
        let mut ctx = tx_context::new_from_hint(ALICE, 121, 121, 121, 121);
        let guardrails = evm_route_guardrails(&mut ctx);
        let accounting = managed_position::new_managed_remote_accounting_from_policy_for_testing<OtherAsset>(
            &guardrails,
            SOURCE_OPPORTUNITY,
            STRATEGY,
            b"base",
            BASE_TOKEN_B,
            &mut ctx,
        );
        let stored = managed_position::accounting_native_asset_binding(&accounting);
        let expected = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN_B);
        let other = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN_A);
        assert!(guardrails_v2::same_native_asset_binding(&stored, &expected), 149);
        assert!(!guardrails_v2::same_native_asset_binding(&stored, &other), 150);
        managed_position::destroy_accounting_for_testing(accounting);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = guardrails_v2::E_REMOTE_ASSET_NOT_CONFIGURED)]
    fun test_remote_accounting_rejects_native_id_absent_from_policy() {
        let mut ctx = tx_context::new_from_hint(ALICE, 122, 122, 122, 122);
        let guardrails = evm_route_guardrails(&mut ctx);
        let accounting = managed_position::new_managed_remote_accounting_from_policy_for_testing<OtherAsset>(
            &guardrails,
            SOURCE_OPPORTUNITY,
            STRATEGY,
            b"base",
            x"3333333333333333333333333333333333333333",
            &mut ctx,
        );
        managed_position::destroy_accounting_for_testing(accounting);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ACCOUNTING_ASSET_MISMATCH)]
    fun test_accounting_bound_reallocation_rejects_base_to_arbitrum_chain_substitution() {
        let mut ctx = tx_context::new_from_hint(ALICE, 119, 119, 119, 119);
        let guardrails = evm_route_guardrails(&mut ctx);
        let base = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN_A);
        let arbitrum = guardrails_v2::evm_asset_binding(
            b"arbitrum",
            ARBITRUM_TOKEN_A,
        );
        let source = managed_position::new_managed_accounting_with_native_binding_for_testing<OtherAsset>(
            SOURCE_OPPORTUNITY,
            STRATEGY,
            base,
            &mut ctx,
        );
        let destination = managed_position::new_managed_accounting_with_native_binding_for_testing<OtherAsset>(
            DESTINATION_OPPORTUNITY,
            STRATEGY,
            arbitrum,
            &mut ctx,
        );
        let source_id = managed_position::accounting_id(&source);
        let destination_id = managed_position::accounting_id(&destination);
        // IDs, opportunities, allocation and policy are exact. Only the first
        // endpoint chain is substituted from stored Base to Arbitrum.
        let route = vector[
            managed_route::reallocation_withdraw_leg(
                source_id,
                arbitrum,
                SOURCE_OPPORTUNITY,
            ),
            managed_route::reallocation_deposit_leg(
                destination_id,
                arbitrum,
                DESTINATION_OPPORTUNITY,
            ),
        ];
        managed_position::validated_reallocation_route_for_accountings(
            &source,
            &destination,
            &route,
            &guardrails,
            5_000,
        );
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ACCOUNTING_ASSET_MISMATCH)]
    fun test_accounting_bound_reallocation_rejects_same_chain_token_substitution() {
        let mut ctx = tx_context::new_from_hint(ALICE, 120, 120, 120, 120);
        let guardrails = evm_route_guardrails(&mut ctx);
        let token_a = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN_A);
        let token_b = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN_B);
        let source = managed_position::new_managed_accounting_with_native_binding_for_testing<OtherAsset>(
            SOURCE_OPPORTUNITY,
            STRATEGY,
            token_a,
            &mut ctx,
        );
        let destination = managed_position::new_managed_accounting_with_native_binding_for_testing<OtherAsset>(
            DESTINATION_OPPORTUNITY,
            STRATEGY,
            token_b,
            &mut ctx,
        );
        let source_id = managed_position::accounting_id(&source);
        let destination_id = managed_position::accounting_id(&destination);
        // Both tokens are policy-allowed on Base. The route-only proof would
        // accept token B; the accounting-aware proof rejects substituting it
        // for the exact token A stored on the source ledger.
        let route = vector[
            managed_route::reallocation_withdraw_leg(
                source_id,
                token_b,
                SOURCE_OPPORTUNITY,
            ),
            managed_route::reallocation_deposit_leg(
                destination_id,
                token_b,
                DESTINATION_OPPORTUNITY,
            ),
        ];
        managed_position::validated_reallocation_route_for_accountings(
            &source,
            &destination,
            &route,
            &guardrails,
            5_000,
        );
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    fun test_reallocation_canonical_bytes_are_deterministic() {
        let mut ctx = tx_context::new_from_hint(ALICE, 19, 19, 19, 19);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        let (bytes_a, source_a, destination_a) =
            managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails, 5_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        let (bytes_b, source_b, destination_b) =
            managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails, 5_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        assert!(bytes_a == bytes_b, 139);
        assert!(guardrails_v2::same_native_asset_binding(&source_a, &source_b), 142);
        assert!(guardrails_v2::same_native_asset_binding(&destination_a, &destination_b), 143);
        assert!(guardrails_v2::same_native_asset_binding(&source_a, &sui), 144);
        assert!(guardrails_v2::same_native_asset_binding(&destination_a, &sui), 145);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_DISCONNECTED_ROUTE)]
    fun test_reallocation_rejects_cross_chain_swap_kind() {
        let mut ctx = tx_context::new_from_hint(ALICE, 20, 20, 20, 20);
        let guardrails = cross_chain_route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let sol = guardrails_v2::solana_asset_binding(
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_leg_for_testing(id(@0xB1), 1, sui, sol, option::none()),
            managed_route::reallocation_deposit_leg(destination, sol, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails, 5_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_REMOTE_ASSET_IDENTITY)]
    fun test_reallocation_rejects_same_chain_bridge_kind() {
        let mut ctx = tx_context::new_from_hint(ALICE, 21, 21, 21, 21);
        let guardrails = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_leg_for_testing(id(@0xB1), 2, sui, sui, option::none()),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails, 5_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    fun test_reallocation_commitment_binds_guardrails_id_and_allocation() {
        let mut ctx = tx_context::new_from_hint(ALICE, 15, 15, 15, 15);
        let guardrails_a = route_guardrails(&mut ctx);
        let guardrails_b = route_guardrails(&mut ctx);
        let source = id(@0x501);
        let destination = id(@0xD357);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::reallocation_withdraw_leg(source, sui, SOURCE_OPPORTUNITY),
            managed_route::reallocation_deposit_leg(destination, sui, DESTINATION_OPPORTUNITY),
        ];
        let (bytes_a_5k, _, _) = managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails_a, 5_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        let (bytes_a_10k, _, _) = managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails_a, 10_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        let (bytes_b_5k, _, _) = managed_route::validated_reallocation_route_canonical_v1(
            &route, &guardrails_b, 5_000, source, SOURCE_OPPORTUNITY,
            destination, DESTINATION_OPPORTUNITY,
        );
        assert!(guardrails_v2::guardrails_hash(&guardrails_a)
            == guardrails_v2::guardrails_hash(&guardrails_b), 134);
        assert!(guardrails_v2::id(&guardrails_a) != guardrails_v2::id(&guardrails_b), 135);
        assert!(hash::sha2_256(bytes_a_5k) != hash::sha2_256(bytes_a_10k), 136);
        assert!(hash::sha2_256(bytes_a_10k) != hash::sha2_256(bytes_b_5k), 137);
        guardrails_v2::destroy_for_testing(guardrails_a);
        guardrails_v2::destroy_for_testing(guardrails_b);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_DUPLICATE_LEG_ID)]
    fun test_route_rejects_duplicate_leg_identity() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let duplicate = managed_position::accounting_id(&accounting);
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let route = vector[
            managed_route::swap_leg(duplicate, sui, sui),
            managed_route::deposit_leg<SUI>(duplicate, b"dayop0000000001"),
        ];
        let position = managed_position::record_local_deposit_with_verified_route_for_testing<SUI>(
            &mut accounting, route, false, 100, ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_DISCONNECTED_ROUTE)]
    fun test_route_rejects_disconnected_leg_source() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let route = vector[
            managed_route::swap_leg(
                id(@0xD150),
                guardrails_v2::sui_asset_binding<SUI>(),
                guardrails_v2::sui_asset_binding<OtherAsset>(),
            ),
            managed_route::deposit_leg<SUI>(
                managed_position::accounting_id(&accounting), b"dayop0000000001",
            ),
        ];
        let position = managed_position::record_local_deposit_with_verified_route_for_testing<SUI>(
            &mut accounting, route, false, 100, ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ROUTE_NOT_DEPOSIT)]
    fun test_route_rejects_deposit_before_terminal_leg() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let route = vector[
            managed_route::deposit_leg<SUI>(id(@0xD3A0), b"dayop0000000002"),
            managed_route::deposit_leg<SUI>(
                managed_position::accounting_id(&accounting), b"dayop0000000001",
            ),
        ];
        let position = managed_position::record_local_deposit_with_verified_route_for_testing<SUI>(
            &mut accounting, route, false, 100, ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_route::E_ROUTE_TARGET_MISMATCH)]
    fun test_route_rejects_destination_only_substitution() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let route = vector[managed_route::deposit_leg<SUI>(
            managed_position::accounting_id(&accounting), b"dayop0000000002",
        )];
        let position = managed_position::record_local_deposit_with_verified_route_for_testing<SUI>(
            &mut accounting, route, false, 100, ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_INVALID_POLICY_BINDING)]
    fun test_rejects_strategy_without_guardrails() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = managed_position::record_local_deposit_for_testing<SUI>(
            &mut accounting, option::some(id(@0x51A7)), option::none(), 100, ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_INVALID_POLICY_BINDING)]
    fun test_rejects_guardrails_without_strategy() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = managed_position::record_local_deposit_for_testing<SUI>(
            &mut accounting, option::none(), option::some(id(@0x6A4D)), 100, ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_production_deployment_consumes_source_and_nonce_bound_receipt() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 100, ctx);
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let witness = AdapterWitness {};
        let receipt = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &witness,
            coin::mint_for_testing<SUI>(100, ctx),
        );
        let deployed = managed_position::record_measured_deployment(
            &mut accounting,
            receipt,
        );
        assert!(managed_position::adapter_nonce_for_testing(&accounting) == 1, 34);
        assert!(managed_position::deployed_assets_micros(&accounting) == 100, 35);
        coin::burn_for_testing(deployed);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_WRONG_ADAPTER_SOURCE)]
    fun test_production_deployment_rejects_wrong_adapter_source() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 100, ctx);
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let wrong = WrongAdapterWitness {};
        let receipt = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &wrong,
            coin::mint_for_testing<SUI>(100, ctx),
        );
        let deployed = managed_position::record_measured_deployment(
            &mut accounting,
            receipt,
        );
        coin::burn_for_testing(deployed);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_WRONG_ADAPTER_NONCE)]
    fun test_production_adapter_return_rejects_stale_nonce_replay() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 100, ctx);
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &witness,
            coin::mint_for_testing<SUI>(100, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            &mut accounting,
            deployment,
        ));
        let accounting_id = managed_position::accounting_id(&accounting);
        let first = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &witness,
            accounting_id,
            option::some(coin::mint_for_testing<SUI>(100, ctx)),
        );
        let replay = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &witness,
            accounting_id,
            option::some(coin::mint_for_testing<SUI>(100, ctx)),
        );
        let (net, _) = managed_closeout::reconcile_full_adapter_return(
            &mut accounting,
            first,
            ctx,
        );
        coin::burn_for_testing(option::destroy_some(net));
        let (replayed, _) = managed_closeout::reconcile_full_adapter_return(
            &mut accounting,
            replay,
            ctx,
        );
        coin::burn_for_testing(option::destroy_some(replayed));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_WRONG_ACCOUNTING)]
    fun test_production_adapter_return_rejects_wrong_purpose() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 100, ctx);
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &witness,
            coin::mint_for_testing<SUI>(100, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            &mut accounting,
            deployment,
        ));
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &witness,
            id(@0xBAD),
            option::some(coin::mint_for_testing<SUI>(100, ctx)),
        );
        let (net, _) = managed_closeout::reconcile_full_adapter_return(
            &mut accounting,
            receipt,
            ctx,
        );
        coin::burn_for_testing(option::destroy_some(net));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_liquid_deployed_total_invariant_is_preserved_by_measured_coin() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 100_000_000, ctx);
        let coin = coin::mint_for_testing<SUI>(60_000_000, ctx);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin,
        );
        assert!(managed_position::liquid_assets_micros(&accounting) == 40_000_000, 40);
        assert!(managed_position::deployed_assets_micros(&accounting) == 60_000_000, 41);
        assert!(managed_position::total_assets_micros(&accounting) == 100_000_000, 42);
        coin::burn_for_testing(deployed);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_nested_fees_are_derived_from_measured_profit_and_high_water() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let position = managed_deposit(&mut accounting, false, ctx);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin::mint_for_testing<SUI>(100_000_000, ctx),
        );
        coin::burn_for_testing(deployed);
        let (net, assessment) = managed_closeout::reconcile_full_adapter_return_for_testing(
            &mut accounting,
            AdapterWitness {},
            coin::mint_for_testing<SUI>(120_000_000, ctx),
            ctx,
        );
        assert!(managed_closeout::fee_profit_micros(&assessment) == 20_000_000, 50);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 4_000_000, 51);
        assert!(managed_closeout::fee_day_micros(&assessment) == 1_000_000, 52);
        assert!(managed_closeout::fee_lead_micros(&assessment) == 3_000_000, 53);
        assert!(managed_closeout::fee_net_micros(&assessment) == 116_000_000, 54);
        assert!(coin::value(&net) == 116_000_000, 55);
        assert!(managed_position::total_assets_micros(&accounting) == 116_000_000, 56);
        assert!(managed_position::total_assets_micros(&accounting)
            == managed_position::liquid_assets_micros(&accounting)
                + managed_position::deployed_assets_micros(&accounting), 57);
        coin::burn_for_testing(net);
        ts::next_tx(&mut scenario, LEAD_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        ts::next_tx(&mut scenario, DAY_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_loss_recovery_below_high_water_is_not_double_charged() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let position = managed_deposit(&mut accounting, false, ctx);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin::mint_for_testing<SUI>(100_000_000, ctx),
        );
        coin::burn_for_testing(deployed);
        let (first, _) = managed_closeout::reconcile_full_adapter_return_for_testing(
            &mut accounting, AdapterWitness {},
            coin::mint_for_testing<SUI>(120_000_000, ctx), ctx,
        );
        coin::burn_for_testing(first);
        let hwm = managed_position::high_water_pps(&accounting);

        let deployed_loss = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin::mint_for_testing<SUI>(116_000_000, ctx),
        );
        coin::burn_for_testing(deployed_loss);
        let (loss, loss_fee) = managed_closeout::reconcile_full_adapter_return_for_testing(
            &mut accounting, AdapterWitness {},
            coin::mint_for_testing<SUI>(108_000_000, ctx), ctx,
        );
        assert!(managed_closeout::fee_profit_micros(&loss_fee) == 0, 60);
        assert!(managed_position::high_water_pps(&accounting) == hwm, 61);
        coin::burn_for_testing(loss);

        let deployed_recovery = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin::mint_for_testing<SUI>(108_000_000, ctx),
        );
        coin::burn_for_testing(deployed_recovery);
        let (recovery, recovery_fee) = managed_closeout::reconcile_full_adapter_return_for_testing(
            &mut accounting, AdapterWitness {},
            coin::mint_for_testing<SUI>(116_000_000, ctx), ctx,
        );
        assert!(managed_closeout::fee_profit_micros(&recovery_fee) == 0, 62);
        coin::burn_for_testing(recovery);

        ts::next_tx(&mut scenario, LEAD_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        ts::next_tx(&mut scenario, DAY_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_zero_lead_fee_means_zero_total_fee() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed_position::new_managed_accounting_for_testing<SUI>(
            b"dayop0000000001", b"sui", STRATEGY, 0, 5_000, ctx,
        );
        let position = managed_deposit(&mut accounting, false, ctx);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin::mint_for_testing<SUI>(100_000_000, ctx),
        );
        coin::burn_for_testing(deployed);
        let (net, assessment) = managed_closeout::reconcile_full_adapter_return_for_testing(
            &mut accounting, AdapterWitness {},
            coin::mint_for_testing<SUI>(120_000_000, ctx), ctx,
        );
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 0, 63);
        assert!(managed_closeout::fee_lead_micros(&assessment) == 0, 64);
        assert!(managed_closeout::fee_day_micros(&assessment) == 0, 65);
        assert!(coin::value(&net) == 120_000_000, 66);
        coin::burn_for_testing(net);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_same_ledger_reallocation_preserves_alice_and_bob_claims_and_frozen_pps() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            id(@0xACC),
            b"dayop0000000001",
            b"dayop0000000002",
            200_000_000,
            200_000_000,
            ADAPTER,
        );
        let alice_shares = 100_000_000;
        let bob_shares = 100_000_000;
        let mut receipt = managed_closeout::new_receipt_for_testing(
            &mut ledger,
            b"dayop0000000002",
            ROUTE,
            5_000,
            2_000,
            1_000,
            ctx,
        );
        assert!(managed_closeout::receipt_frozen_assets_micros(&receipt) == 100_000_000, 70);
        assert!(managed_closeout::receipt_frozen_price_pps(&receipt) == 1_000_000, 71);
        assert!(managed_closeout::receipt_route_commitment(&receipt) == ROUTE, 72);
        assert!(managed_closeout::ledger_total_assets_micros(&ledger) == 200_000_000, 73);
        assert!(managed_closeout::ledger_in_transit_micros(&ledger) == 100_000_000, 74);
        assert!(managed_closeout::ledger_position_value_micros(&ledger, alice_shares)
            == 100_000_000, 75);
        assert!(managed_closeout::ledger_position_value_micros(&ledger, bob_shares)
            == 100_000_000, 76);

        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_500);
        let first = managed_closeout::measure_reallocation_settlement_for_testing(
            &receipt, AdapterWitness {}, coin::mint_for_testing<SUI>(60_000_000, ctx),
        );
        managed_closeout::settle_reallocation_chunk_for_testing(
            &mut receipt,
            &mut ledger,
            first,
            &test_clock,
        );
        assert!(managed_closeout::receipt_remaining_micros(&receipt) == 40_000_000, 77);
        assert!(managed_closeout::ledger_price_per_share_micros(&ledger)
            == managed_closeout::receipt_frozen_price_pps(&receipt), 78);
        assert!(managed_closeout::ledger_position_value_micros(&ledger, alice_shares)
            == 100_000_000, 79);
        assert!(managed_closeout::ledger_position_value_micros(&ledger, bob_shares)
            == 100_000_000, 80);

        clock::set_for_testing(&mut test_clock, 2_001);
        let second = managed_closeout::measure_reallocation_settlement_for_testing(
            &receipt, AdapterWitness {}, coin::mint_for_testing<SUI>(40_000_000, ctx),
        );
        managed_closeout::self_settle_reallocation_remainder_for_testing(
            &mut receipt,
            &mut ledger,
            second,
            &test_clock,
        );
        assert!(managed_closeout::receipt_closed(&receipt), 81);
        assert!(managed_closeout::ledger_total_assets_micros(&ledger) == 200_000_000, 82);
        assert!(managed_closeout::ledger_in_transit_micros(&ledger) == 0, 83);
        assert!(managed_closeout::ledger_position_value_micros(&ledger, alice_shares)
            == 100_000_000, 84);
        assert!(managed_closeout::ledger_position_value_micros(&ledger, bob_shares)
            == 100_000_000, 85);
        let (source_deployed, source_transit) =
            managed_closeout::ledger_allocation_lot_for_testing(
                &ledger, b"dayop0000000001",
        );
        let (target_deployed, target_transit) =
            managed_closeout::ledger_allocation_lot_for_testing(
                &ledger, b"dayop0000000002",
        );
        assert!(source_deployed == 100_000_000 && source_transit == 0, 86);
        assert!(target_deployed == 100_000_000 && target_transit == 0, 87);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ADAPTER);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_closeout::destroy_receipt_for_testing(receipt);
        ts::end(scenario);
    }

    #[test]
    fun test_shared_exit_pot_persists_and_permissionless_crank_pays_recorded_owner() {
        let mut scenario = ts::begin(ALICE);
        let (mut accounting, alice_position) = {
            let ctx = ts::ctx(&mut scenario);
            let mut accounting = plain(ctx);
            let position = plain_deposit(&mut accounting, 100_000_000, ctx);
            (accounting, position)
        };

        ts::next_tx(&mut scenario, BOB);
        let bob_position = plain_deposit(
            &mut accounting, 100_000_000, ts::ctx(&mut scenario),
        );
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            managed_position::accounting_id(&accounting),
            b"dayop0000000001",
            b"dayop0000000002",
            managed_position::total_assets_micros(&accounting),
            managed_position::total_shares(&accounting),
            ADAPTER,
        );
        let mut pot = managed_closeout::new_frozen_exit_pot_for_testing<SUI>(
            &ledger, 2_000, 1_000, ts::ctx(&mut scenario),
        );
        let batch_a = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger,
            &mut pot,
            &alice_position,
            managed_position::position_shares(&alice_position),
            ts::ctx(&mut scenario),
        );
        let batch_b = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger,
            &mut pot,
            &bob_position,
            managed_position::position_shares(&bob_position),
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_claim_assets(&pot, batch_a) == 100_000_000, 95);
        assert!(managed_closeout::frozen_exit_claim_assets(&pot, batch_b) == 100_000_000, 96);
        managed_closeout::share_frozen_exit_pot_for_testing(pot);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ADAPTER);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        managed_closeout::fund_frozen_exit_pot_for_testing(
            &mut pot,
            &mut ledger,
            coin::mint_for_testing<SUI>(190_000_000, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 950_000, 97);
        ts::return_shared(pot);

        // An unrelated caller cranks in reverse reservation order after the
        // deadline. Each claim still pays the owner recorded in its Position.
        ts::next_tx(&mut scenario, ATTACKER);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        clock::set_for_testing(&mut test_clock, 2_001);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let paid_b = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot, &mut ledger, batch_b, &test_clock, ts::ctx(&mut scenario),
        );
        ts::return_shared(test_clock);
        ts::return_shared(pot);

        ts::next_tx(&mut scenario, ATTACKER);
        let test_clock = ts::take_shared<Clock>(&scenario);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let paid_a = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot, &mut ledger, batch_a, &test_clock, ts::ctx(&mut scenario),
        );
        assert!(paid_a == 95_000_000, 98);
        assert!(paid_b == 95_000_000, 99);
        ts::return_shared(test_clock);
        ts::return_shared(pot);

        ts::next_tx(&mut scenario, ALICE);
        let alice_paid = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&alice_paid) == 95_000_000, 100);
        coin::burn_for_testing(alice_paid);

        ts::next_tx(&mut scenario, BOB);
        let bob_paid = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&bob_paid) == 95_000_000, 101);
        coin::burn_for_testing(bob_paid);
        let pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let test_clock = ts::take_shared<Clock>(&scenario);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_reverse_order_nondivisible_exit_credits_dust_to_remaining_leg() {
        let mut scenario = ts::begin(ALICE);
        let (mut accounting, first_position) = {
            let ctx = ts::ctx(&mut scenario);
            let mut accounting = plain(ctx);
            let position = plain_deposit(&mut accounting, 1, ctx);
            (accounting, position)
        };

        ts::next_tx(&mut scenario, BOB);
        let terminal_position = plain_deposit(
            &mut accounting, 2, ts::ctx(&mut scenario),
        );

        ts::next_tx(&mut scenario, CAROL);
        let remaining_position = plain_deposit(
            &mut accounting, 1, ts::ctx(&mut scenario),
        );
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            managed_position::accounting_id(&accounting),
            b"dayop0000000001",
            b"dayop0000000002",
            managed_position::total_assets_micros(&accounting),
            managed_position::total_shares(&accounting),
            ADAPTER,
        );
        let mut pot = managed_closeout::new_frozen_exit_pot_for_testing<SUI>(
            &ledger, 2_000, 1_000, ts::ctx(&mut scenario),
        );
        let first = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger,
            &mut pot,
            &first_position,
            1,
            ts::ctx(&mut scenario),
        );
        let terminal = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger,
            &mut pot,
            &terminal_position,
            2,
            ts::ctx(&mut scenario),
        );
        managed_closeout::fund_frozen_exit_pot_for_testing(
            &mut pot,
            &mut ledger,
            coin::mint_for_testing<SUI>(2, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 666_666, 102);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut test_clock, 2_001);

        // Terminal claim settles first. Cumulative share intervals allocate
        // every measured micro exactly once, independent of crank order.
        let terminal_paid = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot,
            &mut ledger,
            terminal,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        let first_paid = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot,
            &mut ledger,
            first,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        assert!(terminal_paid == 2, 103);
        assert!(first_paid == 0, 104);
        assert!(managed_closeout::ledger_total_assets_micros(&ledger) == 1, 105);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let alice_paid = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&alice_paid) == 0, 107);
        coin::burn_for_testing(alice_paid);

        ts::next_tx(&mut scenario, BOB);
        let bob_paid = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&bob_paid) == 2, 108);
        coin::burn_for_testing(bob_paid);
        managed_position::destroy_position_for_testing(first_position);
        managed_position::destroy_position_for_testing(terminal_position);
        managed_position::destroy_position_for_testing(remaining_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_frozen_exit_pot_closes_after_total_loss() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 10, ctx);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            managed_position::accounting_id(&accounting),
            b"dayop0000000001",
            b"dayop0000000002",
            managed_position::total_assets_micros(&accounting),
            managed_position::total_shares(&accounting),
            ADAPTER,
        );
        let mut pot = managed_closeout::new_frozen_exit_pot_for_testing<SUI>(
            &ledger, 2_000, 1_000, ctx,
        );
        let claim = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger, &mut pot, &position, 10, ctx,
        );
        managed_closeout::fund_frozen_exit_pot_for_testing(
            &mut pot,
            &mut ledger,
            coin::mint_for_testing<SUI>(0, ctx),
            ctx,
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 0, 109);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 2_001);
        let paid = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot, &mut ledger, claim, &test_clock, ctx,
        );
        assert!(paid == 0, 110);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 0, 111);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_frozen_exit_pot_accepts_measured_gain_above_reserved_basis() {
        let mut scenario = ts::begin(ALICE);
        let (mut accounting, alice_position) = {
            let ctx = ts::ctx(&mut scenario);
            let mut accounting = plain(ctx);
            let position = plain_deposit(&mut accounting, 1, ctx);
            (accounting, position)
        };

        ts::next_tx(&mut scenario, BOB);
        let bob_position = plain_deposit(&mut accounting, 1, ts::ctx(&mut scenario));
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            managed_position::accounting_id(&accounting),
            b"dayop0000000001",
            b"dayop0000000002",
            managed_position::total_assets_micros(&accounting),
            managed_position::total_shares(&accounting),
            ADAPTER,
        );
        let mut pot = managed_closeout::new_frozen_exit_pot_for_testing<SUI>(
            &ledger, 2_000, 1_000, ts::ctx(&mut scenario),
        );
        let claim = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger, &mut pot, &alice_position, 1, ts::ctx(&mut scenario),
        );
        managed_closeout::fund_frozen_exit_pot_for_testing(
            &mut pot,
            &mut ledger,
            coin::mint_for_testing<SUI>(2, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 2_000_000, 112);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut test_clock, 2_001);
        let paid = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot,
            &mut ledger,
            claim,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        assert!(paid == 2, 113);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 2, 114);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_production_frozen_exit_accepts_authenticated_total_loss() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let mut position = plain_deposit(&mut accounting, 10, ctx);
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &witness,
            coin::mint_for_testing<SUI>(10, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            &mut accounting,
            deployment,
        ));
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot_id = managed_closeout::open_frozen_exit_pot<SUI>(
            &accounting,
            2_000,
            &test_clock,
            ctx,
        );
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let claim = managed_closeout::reserve_frozen_exit_claim(
            &mut accounting,
            &mut pot,
            &mut position,
            10,
            ts::ctx(&mut scenario),
        );
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &witness,
            pot_id,
            option::none(),
        );
        managed_closeout::fund_frozen_exit_pot(
            &mut accounting,
            &mut pot,
            receipt,
            ts::ctx(&mut scenario),
        );
        clock::set_for_testing(&mut test_clock, 2_001);
        let paid = managed_closeout::settle_frozen_exit_claim(
            &mut pot,
            claim,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        assert!(paid == 0, 115);
        assert!(managed_position::position_shares(&position) == 0, 116);
        assert!(managed_position::total_assets_micros(&accounting) == 0, 117);
        assert!(managed_position::total_shares(&accounting) == 0, 118);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 0, 119);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_production_frozen_exit_accepts_authenticated_positive_gain() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let mut position = plain_deposit(&mut accounting, 10, ctx);
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &witness,
            coin::mint_for_testing<SUI>(10, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            &mut accounting,
            deployment,
        ));
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot_id = managed_closeout::open_frozen_exit_pot<SUI>(
            &accounting,
            2_000,
            &test_clock,
            ctx,
        );
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let claim = managed_closeout::reserve_frozen_exit_claim(
            &mut accounting,
            &mut pot,
            &mut position,
            10,
            ts::ctx(&mut scenario),
        );
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &witness,
            pot_id,
            option::some(coin::mint_for_testing<SUI>(12, ts::ctx(&mut scenario))),
        );
        managed_closeout::fund_frozen_exit_pot(
            &mut accounting,
            &mut pot,
            receipt,
            ts::ctx(&mut scenario),
        );
        clock::set_for_testing(&mut test_clock, 2_001);
        let paid = managed_closeout::settle_frozen_exit_claim(
            &mut pot,
            claim,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        assert!(paid == 12, 120);
        assert!(managed_position::position_shares(&position) == 0, 121);
        assert!(managed_position::total_assets_micros(&accounting) == 0, 122);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 12, 123);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_production_frozen_exit_credits_dust_before_reverse_order_cranks() {
        let mut scenario = ts::begin(ALICE);
        let (mut accounting, mut alice_position) = {
            let ctx = ts::ctx(&mut scenario);
            let mut accounting = plain(ctx);
            let position = plain_deposit(&mut accounting, 1, ctx);
            (accounting, position)
        };
        ts::next_tx(&mut scenario, BOB);
        let mut bob_position = plain_deposit(
            &mut accounting,
            2,
            ts::ctx(&mut scenario),
        );
        ts::next_tx(&mut scenario, CAROL);
        let remaining_position = plain_deposit(
            &mut accounting,
            1,
            ts::ctx(&mut scenario),
        );
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            &accounting,
            &witness,
            coin::mint_for_testing<SUI>(4, ts::ctx(&mut scenario)),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            &mut accounting,
            deployment,
        ));
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot_id = managed_closeout::open_frozen_exit_pot<SUI>(
            &accounting,
            2_000,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let alice_claim = managed_closeout::reserve_frozen_exit_claim(
            &mut accounting,
            &mut pot,
            &mut alice_position,
            1,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(pot);

        ts::next_tx(&mut scenario, BOB);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let bob_claim = managed_closeout::reserve_frozen_exit_claim(
            &mut accounting,
            &mut pot,
            &mut bob_position,
            2,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(pot);

        ts::next_tx(&mut scenario, ADAPTER);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &witness,
            pot_id,
            option::some(coin::mint_for_testing<SUI>(2, ts::ctx(&mut scenario))),
        );
        managed_closeout::fund_frozen_exit_pot(
            &mut accounting,
            &mut pot,
            receipt,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 666_666, 124);
        // Cumulative intervals assign all measured proceeds to the reserved
        // shares; the unreserved holder retains exactly its original basis.
        assert!(managed_position::total_assets_micros(&accounting) == 1, 125);
        assert!(managed_position::liquid_assets_micros(&accounting) == 0, 126);
        assert!(managed_position::deployed_assets_micros(&accounting) == 1, 127);
        assert!(managed_position::total_shares(&accounting) == 1, 128);
        clock::set_for_testing(&mut test_clock, 2_001);
        ts::return_shared(test_clock);
        ts::return_shared(pot);

        ts::next_tx(&mut scenario, ATTACKER);
        let test_clock = ts::take_shared<Clock>(&scenario);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let bob_paid = managed_closeout::settle_frozen_exit_claim(
            &mut pot,
            bob_claim,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        ts::return_shared(test_clock);
        ts::return_shared(pot);

        ts::next_tx(&mut scenario, ATTACKER);
        let test_clock = ts::take_shared<Clock>(&scenario);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let alice_paid = managed_closeout::settle_frozen_exit_claim(
            &mut pot,
            alice_claim,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        assert!(bob_paid == 2, 129);
        assert!(alice_paid == 0, 130);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let alice_payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&alice_payout) == 0, 132);
        coin::burn_for_testing(alice_payout);
        ts::next_tx(&mut scenario, BOB);
        let bob_payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&bob_payout) == 2, 133);
        coin::burn_for_testing(bob_payout);
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_position_for_testing(remaining_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_closeout::E_SELF_SETTLE_NOT_READY)]
    fun test_permissionless_exit_crank_rejects_before_recorded_deadline() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 10, ctx);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            managed_position::accounting_id(&accounting),
            b"dayop0000000001",
            b"dayop0000000002",
            managed_position::total_assets_micros(&accounting),
            managed_position::total_shares(&accounting),
            ADAPTER,
        );
        let mut pot = managed_closeout::new_frozen_exit_pot_for_testing<SUI>(
            &ledger, 2_000, 1_000, ctx,
        );
        let claim = managed_closeout::reserve_frozen_exit_claim_for_testing(
            &mut ledger, &mut pot, &position, 10, ctx,
        );
        managed_closeout::fund_frozen_exit_pot_for_testing(
            &mut pot,
            &mut ledger,
            coin::mint_for_testing<SUI>(10, ctx),
            ctx,
        );
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_999);
        let _ = managed_closeout::settle_frozen_exit_claim_for_testing(
            &mut pot, &mut ledger, claim, &test_clock, ctx,
        );
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_closeout::E_RECEIPT_OVER_SETTLED)]
    fun test_receipt_rejects_over_settlement() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            id(@0xACC), b"dayop0000000001", b"dayop0000000002",
            100_000_000, 100_000_000, ADAPTER,
        );
        let mut receipt = managed_closeout::new_receipt_for_testing(
            &mut ledger, b"dayop0000000002", ROUTE, 5_000, 2_000, 1_000, ctx,
        );
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_500);
        let settlement = managed_closeout::measure_reallocation_settlement_for_testing(
            &receipt, AdapterWitness {}, coin::mint_for_testing<SUI>(50_000_001, ctx),
        );
        managed_closeout::settle_reallocation_chunk_for_testing(
            &mut receipt,
            &mut ledger,
            settlement,
            &test_clock,
        );
        clock::destroy_for_testing(test_clock);
        managed_closeout::destroy_receipt_for_testing(receipt);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_closeout::E_RECEIPT_CLOSED)]
    fun test_closed_receipt_cannot_issue_a_replay_proof() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            id(@0xACC), b"dayop0000000001", b"dayop0000000002",
            100_000_000, 100_000_000, ADAPTER,
        );
        let mut receipt = managed_closeout::new_receipt_for_testing(
            &mut ledger, b"dayop0000000002", ROUTE, 5_000, 2_000, 1_000, ctx,
        );
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_500);
        let settlement = managed_closeout::measure_reallocation_settlement_for_testing(
            &receipt, AdapterWitness {}, coin::mint_for_testing<SUI>(50_000_000, ctx),
        );
        managed_closeout::settle_reallocation_chunk_for_testing(
            &mut receipt, &mut ledger, settlement, &test_clock,
        );
        let replay = managed_closeout::measure_reallocation_settlement_for_testing(
            &receipt, AdapterWitness {}, coin::mint_for_testing<SUI>(1, ctx),
        );
        managed_closeout::settle_reallocation_chunk_for_testing(
            &mut receipt, &mut ledger, replay, &test_clock,
        );
        clock::destroy_for_testing(test_clock);
        managed_closeout::destroy_receipt_for_testing(receipt);
        ts::end(scenario);
    }

    #[test]
    fun test_final_witness_closes_measured_shortfall_without_donation() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            id(@0xACC), b"dayop0000000001", b"dayop0000000002",
            100_000_000, 100_000_000, ADAPTER,
        );
        let mut receipt = managed_closeout::new_receipt_for_testing(
            &mut ledger, b"dayop0000000002", ROUTE, 5_000, 2_000, 1_000, ctx,
        );
        let final_settlement = managed_closeout::measure_final_reallocation_settlement_for_testing(
            &receipt,
            AdapterWitness {},
            option::some(coin::mint_for_testing<SUI>(45_000_000, ctx)),
        );
        managed_closeout::finalize_reallocation_for_testing(
            &mut receipt, &mut ledger, final_settlement,
        );
        assert!(managed_closeout::receipt_closed(&receipt), 88);
        assert!(managed_closeout::receipt_realized_loss_micros(&receipt) == 5_000_000, 89);
        assert!(managed_closeout::ledger_in_transit_micros(&ledger) == 0, 90);
        assert!(managed_closeout::ledger_total_assets_micros(&ledger) == 95_000_000, 91);
        let (source_deployed, source_transit) =
            managed_closeout::ledger_allocation_lot_for_testing(
                &ledger, b"dayop0000000001",
        );
        let (target_deployed, target_transit) =
            managed_closeout::ledger_allocation_lot_for_testing(
                &ledger, b"dayop0000000002",
        );
        assert!(source_deployed == 50_000_000 && source_transit == 0, 92);
        assert!(target_deployed == 45_000_000 && target_transit == 0, 93);
        // 45m target + 0 source-return + 5m loss + 0 remaining = 50m basis.
        assert!(target_deployed + managed_closeout::receipt_realized_loss_micros(&receipt)
            == managed_closeout::receipt_frozen_assets_micros(&receipt), 94);
        let after_loss = managed_closeout::new_receipt_for_testing(
            &mut ledger, b"dayop0000000002", ROUTE, 10_000, 3_000, 2_000, ctx,
        );
        // High-water remains 1.0, but a new batch freezes the current 0.95 PPS.
        assert!(managed_closeout::receipt_frozen_price_pps(&after_loss) == 950_000, 95);
        ts::next_tx(&mut scenario, ADAPTER);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_closeout::destroy_receipt_for_testing(receipt);
        managed_closeout::destroy_receipt_for_testing(after_loss);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_closeout::E_WRONG_ASSET)]
    fun test_receipt_cannot_credit_a_different_asset_type() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut ledger = managed_closeout::new_reallocation_ledger_for_testing<SUI>(
            id(@0xACC), b"dayop0000000001", b"dayop0000000002",
            100_000_000, 100_000_000, ADAPTER,
        );
        let mut receipt = managed_closeout::new_receipt_for_testing(
            &mut ledger, b"dayop0000000002", ROUTE, 5_000, 2_000, 1_000, ctx,
        );
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_500);
        let forged = managed_closeout::measure_reallocation_settlement_for_testing(
            &receipt, AdapterWitness {}, coin::mint_for_testing<OtherAsset>(1, ctx),
        );
        managed_closeout::settle_reallocation_chunk_for_testing(
            &mut receipt, &mut ledger, forged, &test_clock,
        );
        clock::destroy_for_testing(test_clock);
        managed_closeout::destroy_receipt_for_testing(receipt);
        ts::end(scenario);
    }

    #[test]
    fun test_owner_exit_debits_only_the_measured_deployed_source_bucket() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let mut position = plain_deposit(&mut accounting, 100_000_000, ctx);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting, coin::mint_for_testing<SUI>(60_000_000, ctx),
        );
        coin::burn_for_testing(deployed);
        managed_position::settle_owner_exit_from_measured_sources_for_testing(
            &mut accounting,
            &mut position,
            50_000_000,
            managed_position::liquid_exit_proceeds_for_testing(coin::zero<SUI>(ctx)),
            managed_position::deployed_exit_proceeds_for_testing(
                coin::mint_for_testing<SUI>(50_000_000, ctx),
            ),
            ctx,
        );
        assert!(managed_position::total_assets_micros(&accounting) == 50_000_000, 80);
        assert!(managed_position::liquid_assets_micros(&accounting) == 40_000_000, 81);
        assert!(managed_position::deployed_assets_micros(&accounting) == 10_000_000, 82);
        ts::next_tx(&mut scenario, ALICE);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_PAYOUT_AMOUNT_MISMATCH)]
    fun test_owner_exit_rejects_unreconciled_source_components() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let mut position = plain_deposit(&mut accounting, 100_000_000, ctx);
        managed_position::settle_owner_exit_from_measured_sources_for_testing(
            &mut accounting,
            &mut position,
            40_000_000,
            managed_position::liquid_exit_proceeds_for_testing(
                coin::mint_for_testing<SUI>(39_999_999, ctx),
            ),
            managed_position::deployed_exit_proceeds_for_testing(coin::zero<SUI>(ctx)),
            ctx,
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_WRONG_ACCOUNTING)]
    fun test_position_cannot_exit_against_another_ledger() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting_a = plain(ctx);
        let mut accounting_b = managed_position::new_accounting_for_testing<SUI>(
            b"dayop0000000002", b"sui", ctx,
        );
        let mut position = plain_deposit(&mut accounting_a, 100_000_000, ctx);
        let payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting_b, &mut position, 1, ctx,
        );
        let (_, _, _, _, _, _, _) =
            managed_position::consume_owner_payout_for_testing(payout);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting_a);
        managed_position::destroy_accounting_for_testing(accounting_b);
        ts::end(scenario);
    }

    #[test]
    fun test_recorded_destination_exit_has_no_lifecycle_dependency() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let mut position = managed_deposit(&mut accounting, false, ctx);
        let payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting, &mut position, 40_000_000, ctx,
        );
        let (_, _, destination, _, _, _, assets) =
            managed_position::consume_owner_payout_for_testing(payout);
        assert!(destination == ALICE, 103);
        assert!(assets == 40_000_000, 104);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_profitable_managed_owner_can_exit_without_crystallizer_or_leader() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let mut position = managed_deposit(&mut accounting, false, ctx);
        assert!(managed_position::recorded_payout_destination(&position) == ALICE, 116);

        // Authenticated NAV has gained 20m while aggregate fee basis remains
        // 100m. R3 requires the owner-local exit to remain available without a
        // leader, keeper, Guardrails object, registry, or fee crystallizer.
        managed_position::set_total_assets_for_testing(&mut accounting, 120_000_000);
        let shares = managed_position::position_shares(&position);
        managed_position::settle_owner_exit(
            &mut accounting,
            &mut position,
            shares,
            coin::mint_for_testing<SUI>(120_000_000, ctx),
            ctx,
        );
        assert!(managed_position::position_shares(&position) == 0, 117);
        assert!(managed_position::total_assets_micros(&accounting) == 0, 118);

        // The only recipient is the Position's immutable payout destination.
        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 120_000_000, 119);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_FEE_CRYSTALLIZATION_REQUIRED)]
    fun test_profitable_managed_epoch_still_rejects_new_subscription() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop0000000001", ctx);
        let _alice_position = managed_deposit(&mut accounting, false, ctx);
        managed_position::set_total_assets_for_testing(&mut accounting, 120_000_000);

        ts::next_tx(&mut scenario, BOB);
        let _bob_position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            false,
            100_000_000,
            ts::ctx(&mut scenario),
        );
        abort 999
    }

    #[test]
    fun test_o1_ledger_tracks_two_holders_without_holder_iteration() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let alice = plain_deposit(&mut accounting, 100_000_000, ctx);
        let bob = plain_deposit(&mut accounting, 100_000_000, ctx);
        assert!(managed_position::total_assets_micros(&accounting) == 200_000_000, 105);
        assert!(managed_position::total_shares(&accounting) == 200_000_000, 106);
        assert!(managed_position::position_value_micros(&accounting, &alice) == 100_000_000, 107);
        assert!(managed_position::position_value_micros(&accounting, &bob) == 100_000_000, 108);
        managed_position::destroy_position_for_testing(alice);
        managed_position::destroy_position_for_testing(bob);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_day860_two_partial_exits_preserve_floor_pps_and_stayer_claims() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let alice = plain_deposit(&mut accounting, 100_000_000, ctx);
        let mut bob = plain_deposit(&mut accounting, 100_000_000, ctx);
        let mut carol = plain_deposit(&mut accounting, 100_000_000, ctx);
        let dave = plain_deposit(&mut accounting, 100_000_000, ctx);
        managed_position::set_total_assets_for_testing(&mut accounting, 440_000_000);
        assert!(managed_position::price_per_share_micros(&accounting) == 1_099_999, 109);

        let bob_shares = managed_position::position_shares(&bob);
        let bob_payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting, &mut bob, bob_shares, ctx,
        );
        let (_, _, _, _, _, _, bob_assets) =
            managed_position::consume_owner_payout_for_testing(bob_payout);
        assert!(bob_assets == 109_999_975, 110);
        assert!(managed_position::price_per_share_micros(&accounting) == 1_099_999, 111);

        let carol_shares = managed_position::position_shares(&carol);
        let carol_payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting, &mut carol, carol_shares, ctx,
        );
        let (_, _, _, _, _, _, carol_assets) =
            managed_position::consume_owner_payout_for_testing(carol_payout);
        assert!(carol_assets == 109_999_975, 112);
        assert!(managed_position::price_per_share_micros(&accounting) == 1_099_999, 113);
        assert!(managed_position::position_value_micros(&accounting, &alice) == 109_999_975, 114);
        assert!(managed_position::position_value_micros(&accounting, &dave) == 109_999_975, 115);
        managed_position::destroy_position_for_testing(alice);
        managed_position::destroy_position_for_testing(bob);
        managed_position::destroy_position_for_testing(carol);
        managed_position::destroy_position_for_testing(dave);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_day863_spoke_ledgers_never_share_nav_or_pps() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut sui_accounting = plain(ctx);
        let solana_accounting = managed_position::new_plain_accounting_with_native_binding_for_testing<SUI>(
            b"dayop0000000002",
            guardrails_v2::solana_asset_binding(
                x"0101010101010101010101010101010101010101010101010101010101010101",
            ),
            ctx,
        );
        let mut solana_accounting = solana_accounting;
        let sui_position = plain_deposit(&mut sui_accounting, 100_000_000, ctx);
        let solana_position = plain_deposit(&mut solana_accounting, 100_000_000, ctx);

        // A measured gain on the Sui spoke is internal to that accounting
        // object. It cannot reprice the independent Solana spoke ledger.
        managed_position::set_total_assets_for_testing(&mut sui_accounting, 200_000_000);
        assert!(managed_position::price_per_share_micros(&sui_accounting) > 1_000_000, 208);
        assert!(managed_position::price_per_share_micros(&solana_accounting) == 1_000_000, 209);
        assert!(managed_position::position_value_micros(
            &solana_accounting,
            &solana_position,
        ) == 100_000_000, 210);

        // A new Solana-spoke subscription prices from only Solana's own
        // pre-mutation totals, not a strategy/global or Sui-spoke PPS.
        let solana_second = plain_deposit(&mut solana_accounting, 100_000_000, ctx);
        assert!(managed_position::position_shares(&solana_second) == 100_000_000, 211);
        assert!(managed_position::total_assets_micros(&solana_accounting) == 200_000_000, 212);
        assert!(managed_position::total_shares(&solana_accounting) == 200_000_000, 213);
        assert!(managed_position::total_assets_micros(&sui_accounting) == 200_000_000, 214);
        assert!(managed_position::total_shares(&sui_accounting) == 100_000_000, 215);

        managed_position::destroy_position_for_testing(sui_position);
        managed_position::destroy_position_for_testing(solana_position);
        managed_position::destroy_position_for_testing(solana_second);
        managed_position::destroy_accounting_for_testing(sui_accounting);
        managed_position::destroy_accounting_for_testing(solana_accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_NOT_DEPOSITOR)]
    fun test_owner_exit_cannot_be_redirected_by_non_owner() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let mut position = plain_deposit(&mut accounting, 100, ctx);
        ts::next_tx(&mut scenario, ATTACKER);
        let payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting, &mut position, 1, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _) =
            managed_position::consume_owner_payout_for_testing(payout);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun test_virtual_offset_floor_math_stays_u128_with_u256_intermediates() {
        assert!(managed_position::convert_to_shares(100_000_000, 0, 0) == 100_000_000, 90);
        assert!(managed_position::convert_to_assets(
            100_000_000, 110_000_000, 100_000_000,
        ) == 109_999_900, 91);
        assert!(type_name::with_original_ids<SUI>() == type_name::with_original_ids<SUI>(), 92);
    }

    #[test]
    fun test_day860_donation_vector_stays_pool_favoring_and_external_coin_cannot_set_nav() {
        // Canonical 1000/1000 virtual-offset vector. Even if an authenticated
        // ledger mark were 100m above a 1-micro first deposit, the victim still
        // mints nonzero shares and the attacker cannot extract the donation.
        assert!(managed_position::convert_to_shares(1, 0, 0) == 1, 216);
        assert!(managed_position::convert_to_shares(200_000_000, 100_000_001, 1) == 2_001, 217);
        assert!(managed_position::convert_to_assets(1, 300_000_001, 2_002) == 99_933, 218);
        assert!(managed_position::convert_to_assets(2_001, 299_900_068, 2_001) == 199_967_356, 219);

        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = plain(ctx);
        let position = plain_deposit(&mut accounting, 1, ctx);
        let assets_before = managed_position::total_assets_micros(&accounting);
        let pps_before = managed_position::price_per_share_micros(&accounting);

        // A Coin that was not consumed by an authenticated accounting mutation
        // is an external donation. It cannot alter total_assets or PPS.
        let unrelated_coin = coin::mint_for_testing<SUI>(100_000_000, ctx);
        assert!(managed_position::total_assets_micros(&accounting) == assets_before, 220);
        assert!(managed_position::price_per_share_micros(&accounting) == pps_before, 221);
        coin::burn_for_testing(unrelated_coin);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }
}
