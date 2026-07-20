// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::strategy_registry_tests {
    use day::day::{Self as protocol, ProtocolConfig};
    use day::guardrails;
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use std::hash;
    use sui::clock;
    use sui::package;
    use sui::test_scenario as ts;

    const BAD: address = @0xBAD;
    const GOVERNANCE: address = @0x600D;
    const LEADER: address = @0x1EAD;
    const STRATEGY: vector<u8> = b"dayop845";

    public struct TestAsset has drop {}
    public struct TestUsdc has drop {}

    fun authority(): address { strategy_registry::day_authority_for_testing() }

    fun create_frozen_guardrails(scn: &mut ts::Scenario): ID {
        let ctx = ts::ctx(scn);
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<TestAsset>(&mut builder, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop0000000845", ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_and_freeze(builder, digest, ctx)
    }

    fun top30_v1(ctx: &mut TxContext): guardrails::Guardrails {
        let preimage = b"top30-v1-test";
        guardrails::new_for_testing(
            hash::sha2_256(preimage),
            preimage,
            vector[b"USDC", b"USDT"],
            vector[b"dayope3465f1716", b"dayopcf12d529f5"],
            10_000,
            ctx,
        )
    }

    fun top30_v2(opportunity: vector<u8>, ctx: &mut TxContext): GuardrailsV2 {
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<TestUsdc>(&mut builder, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, opportunity, ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_for_testing(builder, digest, ctx)
    }

    fun exact_v1(
        symbol: vector<u8>,
        opportunity: vector<u8>,
        ctx: &mut TxContext,
    ): guardrails::Guardrails {
        let preimage = b"sibling-v1-test";
        guardrails::new_for_testing(
            hash::sha2_256(preimage),
            preimage,
            vector[symbol],
            vector[opportunity],
            10_000,
            ctx,
        )
    }

    #[test]
    fun top_roi_exact_usdy_leaf_is_accepted() {
        let mut ctx = tx_context::new_from_hint(authority(), 11, 11, 11, 11);
        let old = exact_v1(b"USDY", b"dayopbc1052eaa6", &mut ctx);
        let refined = top30_v2(b"dayopbc1052eaa6", &mut ctx);
        strategy_registry::assert_top_roi_refinement_shape_for_testing<TestUsdc>(&old, &refined);
        guardrails::destroy_for_testing(old);
        guardrails_v2::destroy_for_testing(refined);
    }

    #[test]
    fun safe_plus_exact_child_leaf_is_accepted() {
        let mut ctx = tx_context::new_from_hint(authority(), 12, 12, 12, 12);
        let old = exact_v1(b"USDC", b"dayop487e57366b", &mut ctx);
        let refined = top30_v2(b"dayop487e57366b", &mut ctx);
        strategy_registry::assert_safe_plus_roi_refinement_shape_for_testing<TestUsdc>(&old, &refined);
        guardrails::destroy_for_testing(old);
        guardrails_v2::destroy_for_testing(refined);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_A_GUARDRAILS_REFINEMENT)]
    fun sibling_refinement_cannot_substitute_another_leaf() {
        let mut ctx = tx_context::new_from_hint(authority(), 13, 13, 13, 13);
        let old = exact_v1(b"USDY", b"dayopbc1052eaa6", &mut ctx);
        let widened = top30_v2(b"dayop487e57366b", &mut ctx);
        strategy_registry::assert_top_roi_refinement_shape_for_testing<TestUsdc>(&old, &widened);
        guardrails::destroy_for_testing(old);
        guardrails_v2::destroy_for_testing(widened);
    }

    #[test]
    fun top30_exact_single_leaf_subset_is_accepted() {
        let mut ctx = tx_context::new_from_hint(authority(), 1, 1, 1, 1);
        let old = top30_v1(&mut ctx);
        let refined = top30_v2(b"dayope3465f1716", &mut ctx);
        strategy_registry::assert_top30_refinement_shape_for_testing<TestUsdc>(&old, &refined);
        guardrails::destroy_for_testing(old);
        guardrails_v2::destroy_for_testing(refined);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_A_GUARDRAILS_REFINEMENT)]
    fun top30_opportunity_outside_v1_is_rejected() {
        let mut ctx = tx_context::new_from_hint(authority(), 2, 2, 2, 2);
        let old = top30_v1(&mut ctx);
        let widened = top30_v2(b"dayop0000000001", &mut ctx);
        strategy_registry::assert_top30_refinement_shape_for_testing<TestUsdc>(&old, &widened);
        guardrails::destroy_for_testing(old);
        guardrails_v2::destroy_for_testing(widened);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_WRONG_GUARDRAILS_REFINEMENT_ANCHOR)]
    fun top30_strategy_registration_requires_the_one_shot_anchor() {
        let mut scn = ts::begin(authority());
        bootstrap_only(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let guardrails_id = create_frozen_guardrails(&mut scn);
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let clock = clock::create_for_testing(ts::ctx(&mut scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            b"day-autopilot-top-30d-monthly",
            LEADER,
            &guardrails,
            &clock,
            ts::ctx(&mut scn),
        );
        clock::destroy_for_testing(clock);
        ts::return_immutable(guardrails);
        ts::return_to_address(GOVERNANCE, cap);
        ts::return_shared(registry);
        ts::end(scn);
    }

    /// Create the test ProtocolConfig, then run the production bootstrap path.
    /// The function returns after the new shared registry and owned cap become
    /// available in the next transaction.
    fun bootstrap_only(scn: &mut ts::Scenario) {
        let config = protocol::new_config_for_testing(ts::ctx(scn));
        protocol::share_config_for_testing(config);
        ts::next_tx(scn, authority());

        let mut config = ts::take_shared<ProtocolConfig>(scn);
        strategy_registry::bootstrap_for_testing(&mut config, GOVERNANCE, ts::ctx(scn));
        ts::return_shared(config);
        ts::next_tx(scn, authority());
    }

    /// Bootstrap and register one Strategy through the production authority
    /// path, then leave the registry/cap in scenario storage at `initial_status`.
    fun bootstrap_registered(scn: &mut ts::Scenario, initial_status: u8) {
        bootstrap_only(scn);

        // Guardrails are created and frozen by the Lead, so the registration
        // must authenticate that same address.
        ts::next_tx(scn, LEADER);
        let guardrails_id = create_frozen_guardrails(scn);
        ts::next_tx(scn, GOVERNANCE);

        let mut registry = ts::take_shared<StrategyRegistry>(scn);
        let cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(scn));
        clock::set_for_testing(&mut test_clock, 4_242);

        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(scn),
        );
        if (initial_status == strategy_registry::paused_status()) {
            strategy_registry::pause_strategy(
                &mut registry, &cap, STRATEGY, ts::ctx(scn),
            );
        } else if (initial_status == strategy_registry::retired_status()) {
            strategy_registry::retire_strategy(
                &mut registry, &cap, STRATEGY, ts::ctx(scn),
            );
        };

        ts::return_immutable(guardrails);
        clock::destroy_for_testing(test_clock);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_WRONG_UPGRADE_CAP)]
    fun test_bootstrap_rejects_noncanonical_upgrade_cap() {
        let mut scn = ts::begin(BAD);
        let config = protocol::new_config_for_testing(ts::ctx(&mut scn));
        protocol::share_config_for_testing(config);
        ts::next_tx(&mut scn, BAD);
        let mut config = ts::take_shared<ProtocolConfig>(&scn);
        let fake_cap = package::test_publish(object::id_from_address(@0xBAD), ts::ctx(&mut scn));
        strategy_registry::bootstrap(
            &mut config,
            &fake_cap,
            GOVERNANCE,
            ts::ctx(&mut scn),
        );
        transfer::public_transfer(fake_cap, BAD);
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    fun test_canonical_bootstrap_targets_are_accepted() {
        strategy_registry::assert_canonical_bootstrap_targets_for_testing(
            strategy_registry::canonical_upgrade_cap_for_testing(),
            strategy_registry::canonical_protocol_config_for_testing(),
        );
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_WRONG_PROTOCOL_CONFIG)]
    fun test_bootstrap_rejects_noncanonical_protocol_config() {
        strategy_registry::assert_canonical_bootstrap_targets_for_testing(
            strategy_registry::canonical_upgrade_cap_for_testing(),
            @0xBAD,
        );
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_INVALID_GOVERNANCE)]
    fun test_treasury_eoa_rejected_as_governance_recipient() {
        let mut scn = ts::begin(authority());
        let config = protocol::new_config_for_testing(ts::ctx(&mut scn));
        protocol::share_config_for_testing(config);
        ts::next_tx(&mut scn, authority());
        let mut config = ts::take_shared<ProtocolConfig>(&scn);
        strategy_registry::bootstrap_for_testing(&mut config, authority(), ts::ctx(&mut scn));
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_INVALID_GOVERNANCE)]
    fun test_zero_governance_recipient_rejected() {
        let mut scn = ts::begin(authority());
        let config = protocol::new_config_for_testing(ts::ctx(&mut scn));
        protocol::share_config_for_testing(config);
        ts::next_tx(&mut scn, authority());
        let mut config = ts::take_shared<ProtocolConfig>(&scn);
        strategy_registry::bootstrap_for_testing(&mut config, @0x0, ts::ctx(&mut scn));
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    fun test_admin_cap_lands_at_explicit_governance() {
        let mut scn = ts::begin(authority());
        bootstrap_only(&mut scn);
        assert!(ts::has_most_recent_for_address<AdminCap>(GOVERNANCE), 0);
        assert!(!ts::has_most_recent_for_address<AdminCap>(authority()), 1);
        let config = ts::take_shared<ProtocolConfig>(&scn);
        assert!(
            protocol::canonical_strategy_registry_governance(&config) ==
                option::some(GOVERNANCE),
            2,
        );
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_ALREADY_BOOTSTRAPPED)]
    fun test_repeated_bootstrap_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_only(&mut scn);
        let mut config = ts::take_shared<ProtocolConfig>(&scn);
        strategy_registry::bootstrap_for_testing(&mut config, GOVERNANCE, ts::ctx(&mut scn));
        ts::return_shared(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_GOVERNANCE)]
    fun test_unauthorized_register_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_only(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let guardrails_id = create_frozen_guardrails(&mut scn);
        ts::next_tx(&mut scn, BAD);

        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scn),
        );
        ts::return_immutable(guardrails);
        clock::destroy_for_testing(test_clock);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_GOVERNANCE)]
    fun test_unauthorized_pause_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::active_status());
        ts::next_tx(&mut scn, BAD);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        strategy_registry::pause_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_GOVERNANCE)]
    fun test_unauthorized_resume_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::paused_status());
        ts::next_tx(&mut scn, BAD);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        strategy_registry::resume_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_GOVERNANCE)]
    fun test_unauthorized_retire_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::active_status());
        ts::next_tx(&mut scn, BAD);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        strategy_registry::retire_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_WRONG_ADMIN_CAP)]
    fun test_wrong_registry_admin_cap_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::active_status());
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let wrong_cap = strategy_registry::admin_cap_for_testing(ts::ctx(&mut scn));
        strategy_registry::pause_strategy(
            &mut registry, &wrong_cap, STRATEGY, ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, wrong_cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_GOVERNANCE)]
    fun test_day_authority_without_governance_cap_cannot_mutate() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::active_status());
        ts::next_tx(&mut scn, authority());
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let treasury_cap = strategy_registry::admin_cap_for_testing(ts::ctx(&mut scn));
        strategy_registry::pause_strategy(
            &mut registry, &treasury_cap, STRATEGY, ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        ts::return_to_address(authority(), treasury_cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_LEADER_GUARDRAILS_MISMATCH)]
    fun test_leader_must_match_guardrails_creator() {
        let mut scn = ts::begin(authority());
        bootstrap_only(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let guardrails_id = create_frozen_guardrails(&mut scn);
        ts::next_tx(&mut scn, GOVERNANCE);

        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            b"dayop-mismatch",
            @0x2,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scn),
        );
        ts::return_immutable(guardrails);
        clock::destroy_for_testing(test_clock);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_ALREADY_REGISTERED)]
    fun test_duplicate_strategy_id_aborts() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::active_status());
        ts::next_tx(&mut scn, GOVERNANCE);

        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let guardrails_id = strategy_registry::guardrails_id(
            strategy_registry::record(&registry, STRATEGY),
        );
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scn),
        );
        ts::return_immutable(guardrails);
        clock::destroy_for_testing(test_clock);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_ACTIVE)]
    fun test_paused_strategy_rejects_new_deposit() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::paused_status());
        ts::next_tx(&mut scn, authority());
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        strategy_registry::assert_accepts_new_deposit(&registry, STRATEGY);
        ts::return_shared(registry);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_NOT_ACTIVE)]
    fun test_retired_strategy_rejects_reallocation() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::retired_status());
        ts::next_tx(&mut scn, authority());
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        strategy_registry::assert_accepts_reallocation(&registry, STRATEGY);
        ts::return_shared(registry);
        ts::end(scn);
    }

    #[test]
    fun test_governance_with_bound_cap_can_mutate_and_record_stays_immutable() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::active_status());
        ts::next_tx(&mut scn, GOVERNANCE);

        let config = ts::take_shared<ProtocolConfig>(&scn);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        assert!(
            protocol::canonical_strategy_registry_id(&config) ==
                option::some(strategy_registry::id(&registry)),
            18,
        );
        assert!(
            protocol::canonical_strategy_registry_admin_cap_id(&config) ==
                option::some(strategy_registry::admin_cap_id(&registry)),
            19,
        );
        assert!(
            protocol::canonical_strategy_registry_governance(&config) ==
                option::some(GOVERNANCE),
            20,
        );
        assert!(strategy_registry::governance(&registry) == GOVERNANCE, 21);
        let expected_guardrails_id;
        let expected_guardrails_hash;
        {
            let record = strategy_registry::record(&registry, STRATEGY);
            assert!(strategy_registry::strategy_id(record) == STRATEGY, 0);
            assert!(strategy_registry::leader(record) == LEADER, 1);
            expected_guardrails_id = strategy_registry::guardrails_id(record);
            expected_guardrails_hash = strategy_registry::guardrails_hash(record);
            assert!(vector::length(&expected_guardrails_hash) == 32, 2);
            assert!(strategy_registry::created_at(record) == 4_242, 3);
            assert!(strategy_registry::record_status(record) == strategy_registry::active_status(), 4);
        };
        assert!(strategy_registry::count(&registry) == 1, 5);
        strategy_registry::assert_accepts_new_deposit(&registry, STRATEGY);
        strategy_registry::assert_accepts_reallocation(&registry, STRATEGY);
        assert!(strategy_registry::accepts_new_deposit(&registry, STRATEGY), 6);
        assert!(strategy_registry::accepts_reallocation(&registry, STRATEGY), 7);

        strategy_registry::pause_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        assert!(!strategy_registry::accepts_new_deposit(&registry, STRATEGY), 8);
        assert!(!strategy_registry::accepts_reallocation(&registry, STRATEGY), 9);

        strategy_registry::resume_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        assert!(strategy_registry::accepts_new_deposit(&registry, STRATEGY), 10);

        strategy_registry::retire_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        assert!(strategy_registry::status(&registry, STRATEGY) == strategy_registry::retired_status(), 11);
        assert!(!strategy_registry::accepts_new_deposit(&registry, STRATEGY), 12);
        assert!(!strategy_registry::accepts_reallocation(&registry, STRATEGY), 13);

        // Lifecycle changes cannot rewrite the immutable Lead, Guardrails, or
        // creation timestamp. Owner exit is outside this registry entirely.
        {
            let record = strategy_registry::record(&registry, STRATEGY);
            assert!(strategy_registry::leader(record) == LEADER, 14);
            assert!(strategy_registry::guardrails_id(record) == expected_guardrails_id, 15);
            assert!(strategy_registry::guardrails_hash(record) == expected_guardrails_hash, 16);
            assert!(strategy_registry::created_at(record) == 4_242, 17);
        };

        ts::return_shared(config);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_INVALID_LIFECYCLE_TRANSITION)]
    fun test_retired_strategy_cannot_resume() {
        let mut scn = ts::begin(authority());
        bootstrap_registered(&mut scn, strategy_registry::retired_status());
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        strategy_registry::resume_strategy(
            &mut registry, &cap, STRATEGY, ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        ts::end(scn);
    }
}
