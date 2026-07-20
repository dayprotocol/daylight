// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::leader_authority_tests {
    use day::day::{Self as protocol, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::leader_authority;
    use day::leader_policy::{ExitModeLatch, LeaderPolicy};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use sui::clock;
    use sui::test_scenario as ts;

    const GOVERNANCE: address = @0x600D;
    const LEADER: address = @0x1EAD;
    const ATTACKER: address = @0xBAD;
    const STRATEGY: vector<u8> = b"dayop0000000849";
    const STRATEGY_TWO: vector<u8> = b"dayop0000000850";
    const OPPORTUNITY: vector<u8> = b"dayop0000001849";
    const LIFECYCLE_ACTIVE: u8 = 0;
    const LIFECYCLE_PAUSED: u8 = 1;
    const LIFECYCLE_RETIRED: u8 = 2;

    public struct Asset has drop {}

    fun authority(): address { strategy_registry::day_authority_for_testing() }

    fun create_guardrails(scn: &mut ts::Scenario): ID {
        let ctx = ts::ctx(scn);
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<Asset>(&mut builder, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        guardrails_v2::finalize_and_freeze(builder, digest, ctx)
    }

    fun setup(
        scn: &mut ts::Scenario,
        consent: bool,
        lifecycle: u8,
    ): (ID, ID, ID) {
        let config = protocol::new_config_for_testing(ts::ctx(scn));
        protocol::share_config_for_testing(config);
        ts::next_tx(scn, authority());

        let mut config = ts::take_shared<ProtocolConfig>(scn);
        strategy_registry::bootstrap_for_testing(
            &mut config,
            GOVERNANCE,
            ts::ctx(scn),
        );
        ts::return_shared(config);

        ts::next_tx(scn, LEADER);
        let guardrails_id = create_guardrails(scn);

        ts::next_tx(scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(scn);
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
        if (lifecycle == LIFECYCLE_PAUSED) {
            strategy_registry::pause_strategy(
                &mut registry,
                &cap,
                STRATEGY,
                ts::ctx(scn),
            );
        } else if (lifecycle == LIFECYCLE_RETIRED) {
            strategy_registry::retire_strategy(
                &mut registry,
                &cap,
                STRATEGY,
                ts::ctx(scn),
            );
        };
        let (policy_id, latch_id) = leader_authority::create_policy_and_latch(
            &mut registry,
            &cap,
            STRATEGY,
            consent,
            &test_clock,
            ts::ctx(scn),
        );
        assert!(
            strategy_registry::canonical_leader_policy_id(&registry, STRATEGY)
                == option::some(policy_id),
            90,
        );
        assert!(
            strategy_registry::canonical_exit_mode_latch_id(&registry, STRATEGY)
                == option::some(latch_id),
            91,
        );
        leader_authority::assert_last_policy_created_event_for_testing(
            policy_id,
            latch_id,
            strategy_registry::id(&registry),
            STRATEGY,
            consent,
            1_000,
        );
        clock::destroy_for_testing(test_clock);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        (guardrails_id, policy_id, latch_id)
    }

    #[test]
    fun test_verified_leader_enters_one_way_exit_mode() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(&mut scn, true, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, LEADER);

        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 2_000);

        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        assert!(leader_authority::policy_id(&policy) == policy_id, 0);
        assert!(leader_authority::policy_strategy_id(&policy) == STRATEGY, 1);
        assert!(leader_authority::leader_may_force_exit(&policy), 2);
        assert!(leader_authority::latch_policy_id(&latch) == policy_id, 3);
        assert!(leader_authority::exit_mode_entered(&latch), 4);
        assert!(leader_authority::exit_mode_entered_at_ms(&latch) == 2_000, 5);
        leader_authority::assert_last_exit_mode_event_for_testing(
            policy_id,
            STRATEGY,
            LEADER,
            2_000,
        );

        ts::return_shared(registry);
        ts::return_immutable(guardrails);
        ts::return_immutable(policy);
        ts::return_shared(latch);
        clock::destroy_for_testing(test_clock);
        ts::end(scn);
    }

    #[test]
    fun test_pause_cannot_block_consented_force_exit() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(&mut scn, true, LIFECYCLE_PAUSED);
        ts::next_tx(&mut scn, LEADER);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        assert!(leader_authority::exit_mode_entered(&latch), 0);
        ts::return_shared(registry);
        ts::return_immutable(guardrails);
        ts::return_immutable(policy);
        ts::return_shared(latch);
        clock::destroy_for_testing(test_clock);
        ts::end(scn);
    }

    #[test]
    fun test_retirement_cannot_block_consented_force_exit() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(&mut scn, true, LIFECYCLE_RETIRED);
        ts::next_tx(&mut scn, LEADER);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        assert!(leader_authority::exit_mode_entered(&latch), 0);
        ts::return_shared(registry);
        ts::return_immutable(guardrails);
        ts::return_immutable(policy);
        ts::return_shared(latch);
        clock::destroy_for_testing(test_clock);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::leader_policy::E_NOT_LEADER)]
    fun test_caller_cannot_assert_leader_identity() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(&mut scn, true, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, ATTACKER);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::leader_policy::E_FORCE_EXIT_NOT_CONSENTED)]
    fun test_absent_force_exit_consent_fails_closed() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(&mut scn, false, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, LEADER);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::leader_policy::E_EXIT_MODE_ACTIVE)]
    fun test_exit_mode_cannot_be_reset_or_entered_twice() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(&mut scn, true, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, LEADER);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::leader_authority::E_POLICY_ALREADY_EXISTS)]
    fun test_conflicting_policy_and_split_latch_cannot_be_created() {
        let mut scn = ts::begin(authority());
        let (_, _, _) = setup(&mut scn, true, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::create_policy_and_latch(
            &mut registry,
            &cap,
            STRATEGY,
            false,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::leader_authority::E_WRONG_ADMIN_CAP)]
    fun test_foreign_admin_cap_cannot_create_policy() {
        let mut scn = ts::begin(authority());
        let (_, _, _) = setup(&mut scn, true, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let foreign_cap = strategy_registry::admin_cap_for_testing(ts::ctx(&mut scn));
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::create_policy_and_latch(
            &mut registry,
            &foreign_cap,
            STRATEGY,
            true,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::leader_policy::E_WRONG_GUARDRAILS)]
    fun test_foreign_guardrails_cannot_enter_exit_mode() {
        let mut scn = ts::begin(authority());
        let (_, policy_id, latch_id) = setup(&mut scn, true, LIFECYCLE_ACTIVE);
        ts::next_tx(&mut scn, LEADER);
        let foreign_guardrails_id = create_guardrails(&mut scn);
        ts::next_tx(&mut scn, LEADER);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let foreign_guardrails = ts::take_immutable_by_id<GuardrailsV2>(
            &scn,
            foreign_guardrails_id,
        );
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        leader_authority::enter_exit_mode(
            &registry,
            &foreign_guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_WRONG_LEADER_POLICY_ANCHOR)]
    fun test_missing_policy_anchor_fails_closed() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, policy_id, latch_id) = setup(
            &mut scn,
            true,
            LIFECYCLE_ACTIVE,
        );
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY_TWO,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scn),
        );
        strategy_registry::assert_canonical_leader_policy_and_latch(
            &registry,
            STRATEGY_TWO,
            policy_id,
            latch_id,
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::strategy_registry::E_WRONG_LEADER_POLICY_ANCHOR)]
    fun test_cross_wired_policy_and_latch_ids_fail_closed() {
        let mut scn = ts::begin(authority());
        let (guardrails_id, first_policy_id, first_latch_id) = setup(
            &mut scn,
            true,
            LIFECYCLE_ACTIVE,
        );
        ts::next_tx(&mut scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(&scn);
        let cap = ts::take_from_address<AdminCap>(&scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY_TWO,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(&mut scn),
        );
        let (_second_policy_id, _second_latch_id) = leader_authority::create_policy_and_latch(
            &mut registry,
            &cap,
            STRATEGY_TWO,
            true,
            &test_clock,
            ts::ctx(&mut scn),
        );
        strategy_registry::assert_canonical_leader_policy_and_latch(
            &registry,
            STRATEGY_TWO,
            first_policy_id,
            first_latch_id,
        );
        abort 99
    }
}
