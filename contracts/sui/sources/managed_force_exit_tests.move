// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::managed_force_exit_tests {
    use day::day::{Self as protocol, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::leader_authority;
    use day::leader_policy::{ExitModeLatch, LeaderPolicy};
    use day::managed_closeout::{Self, FrozenExitPot};
    use day::managed_force_exit;
    use day::managed_position::{Self, OpportunityAccounting, Position};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use sui::clock;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario as ts;

    const GOVERNANCE: address = @0x600D;
    const LEADER: address = @0x1EAD;
    const OWNER: address = @0xA11CE;
    const CRANK: address = @0xBAD;
    const STRATEGY: vector<u8> = b"dayop0000000849";
    const OPPORTUNITY: vector<u8> = b"dayop0000001849";

    public struct AdapterWitness has drop {}

    fun authority(): address { strategy_registry::day_authority_for_testing() }

    fun setup_policy(scn: &mut ts::Scenario): (ID, ID, ID, ID) {
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
        let ctx = ts::ctx(scn);
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<SUI>(&mut builder, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, OPPORTUNITY, ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 10_000, ctx);
        let digest = guardrails_v2::preview_hash(&builder);
        let guardrails_id = guardrails_v2::finalize_and_freeze(builder, digest, ctx);

        ts::next_tx(scn, GOVERNANCE);
        let mut registry = ts::take_shared<StrategyRegistry>(scn);
        let registry_id = strategy_registry::id(&registry);
        let cap = ts::take_from_address<AdminCap>(scn, GOVERNANCE);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let test_clock = clock::create_for_testing(ts::ctx(scn));
        strategy_registry::register_strategy(
            &mut registry,
            &cap,
            STRATEGY,
            LEADER,
            &guardrails,
            &test_clock,
            ts::ctx(scn),
        );
        let (policy_id, latch_id) = leader_authority::create_policy_and_latch(
            &mut registry,
            &cap,
            STRATEGY,
            true,
            &test_clock,
            ts::ctx(scn),
        );
        clock::destroy_for_testing(test_clock);
        ts::return_immutable(guardrails);
        ts::return_shared(registry);
        ts::return_to_address(GOVERNANCE, cap);
        (registry_id, guardrails_id, policy_id, latch_id)
    }

    fun create_and_share_consented_position(
        scn: &mut ts::Scenario,
        registry_id: ID,
        guardrails_id: ID,
        policy_id: ID,
    ): (ID, ID) {
        ts::next_tx(scn, OWNER);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let mut accounting =
            managed_position::new_policy_bound_accounting_for_testing<AdapterWitness, SUI>(
                OPPORTUNITY,
                registry_id,
                STRATEGY,
                guardrails_id,
                guardrails_v2::guardrails_hash(&guardrails),
                ts::ctx(scn),
            );
        let position = managed_position::record_policy_consented_deposit_for_testing<SUI>(
            &mut accounting,
            policy_id,
            100,
            ts::ctx(scn),
        );
        let accounting_id = managed_position::accounting_id(&accounting);
        let position_id = object::id(&position);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting,
            coin::mint_for_testing<SUI>(100, ts::ctx(scn)),
        );
        coin::burn_for_testing(deployed);
        managed_position::share_accounting_for_testing(accounting);
        managed_position::share_consented_position_for_testing(position);
        ts::return_immutable(guardrails);
        (accounting_id, position_id)
    }

    fun enter_exit_mode(
        scn: &mut ts::Scenario,
        guardrails_id: ID,
        policy_id: ID,
        latch_id: ID,
    ) {
        ts::next_tx(scn, LEADER);
        let registry = ts::take_shared<StrategyRegistry>(scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(scn, policy_id);
        let mut latch = ts::take_shared_by_id<ExitModeLatch>(scn, latch_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(scn));
        clock::set_for_testing(&mut test_clock, 2_000);
        leader_authority::enter_exit_mode(
            &registry,
            &guardrails,
            &policy,
            &mut latch,
            &test_clock,
            ts::ctx(scn),
        );
        clock::destroy_for_testing(test_clock);
        ts::return_shared(registry);
        ts::return_immutable(guardrails);
        ts::return_immutable(policy);
        ts::return_shared(latch);
    }

    #[test]
    fun permissionless_force_exit_pays_only_recorded_owner() {
        let mut scn = ts::begin(authority());
        let (registry_id, guardrails_id, policy_id, latch_id) = setup_policy(&mut scn);
        let (accounting_id, position_id) = create_and_share_consented_position(
            &mut scn,
            registry_id,
            guardrails_id,
            policy_id,
        );
        enter_exit_mode(&mut scn, guardrails_id, policy_id, latch_id);

        ts::next_tx(&mut scn, CRANK);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut accounting = ts::take_shared_by_id<OpportunityAccounting>(&scn, accounting_id);
        let mut position = ts::take_shared_by_id<Position>(&scn, position_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 3_000);
        let (ticket, pot) = managed_force_exit::prepare_consented_force_exit<SUI>(
            &registry,
            &guardrails,
            &policy,
            &latch,
            &accounting,
            &position,
            &test_clock,
            ts::ctx(&mut scn),
        );
        let witness = AdapterWitness {};
        let receipt = managed_force_exit::attest_adapter_return(
            &accounting,
            &position,
            ticket,
            &witness,
            option::some(coin::mint_for_testing<SUI>(100, ts::ctx(&mut scn))),
        );
        let (pot_id, claim_id) = managed_force_exit::fund_consented_force_exit(
            &mut accounting,
            pot,
            &mut position,
            receipt,
            ts::ctx(&mut scn),
        );
        assert!(managed_position::position_shares(&position) == 0, 0);
        assert!(managed_position::deployed_assets_micros(&accounting) == 0, 1);
        clock::destroy_for_testing(test_clock);
        ts::return_shared(registry);
        ts::return_immutable(guardrails);
        ts::return_immutable(policy);
        ts::return_shared(latch);
        ts::return_shared(accounting);
        ts::return_shared(position);

        ts::next_tx(&mut scn, CRANK);
        let mut pot = ts::take_shared_by_id<FrozenExitPot<SUI>>(&scn, pot_id);
        let mut settle_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut settle_clock, 303_001);
        let paid = managed_closeout::settle_frozen_exit_claim(
            &mut pot,
            claim_id,
            &settle_clock,
            ts::ctx(&mut scn),
        );
        assert!(paid == 100, 2);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(settle_clock);

        ts::next_tx(&mut scn, OWNER);
        let payout = ts::take_from_sender<Coin<SUI>>(&scn);
        assert!(coin::value(&payout) == 100, 3);
        coin::burn_for_testing(payout);
        let accounting = ts::take_shared_by_id<OpportunityAccounting>(&scn, accounting_id);
        let position = ts::take_shared_by_id<Position>(&scn, position_id);
        managed_position::destroy_accounting_for_testing(accounting);
        managed_position::destroy_position_for_testing(position);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::leader_policy::E_EXIT_MODE_NOT_ACTIVE)]
    fun force_exit_rejects_unentered_latch() {
        let mut scn = ts::begin(authority());
        let (registry_id, guardrails_id, policy_id, latch_id) = setup_policy(&mut scn);
        let (accounting_id, position_id) = create_and_share_consented_position(
            &mut scn,
            registry_id,
            guardrails_id,
            policy_id,
        );
        ts::next_tx(&mut scn, CRANK);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let accounting = ts::take_shared_by_id<OpportunityAccounting>(&scn, accounting_id);
        let position = ts::take_shared_by_id<Position>(&scn, position_id);
        let test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        let (_ticket, _pot) = managed_force_exit::prepare_consented_force_exit<SUI>(
            &registry,
            &guardrails,
            &policy,
            &latch,
            &accounting,
            &position,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = day::managed_position::E_NOT_DEPOSITOR)]
    fun shared_consent_never_weakens_owner_exit_authentication() {
        let mut scn = ts::begin(OWNER);
        let mut accounting = managed_position::new_managed_accounting_for_testing<SUI>(
            OPPORTUNITY,
            b"sui",
            STRATEGY,
            2_000,
            2_500,
            ts::ctx(&mut scn),
        );
        let position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            true,
            100,
            ts::ctx(&mut scn),
        );
        managed_position::share_accounting_for_testing(accounting);
        managed_position::publish_new_position_for_testing(position, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, CRANK);
        let mut accounting = ts::take_shared<OpportunityAccounting>(&scn);
        let mut position = ts::take_shared<Position>(&scn);
        let payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut accounting,
            &mut position,
            100,
            ts::ctx(&mut scn),
        );
        let (_, _, _, _, _, _, _) =
            managed_position::consume_owner_payout_for_testing(payout);
        abort 98
    }

    #[test]
    fun opt_out_position_remains_owner_held() {
        let mut scn = ts::begin(OWNER);
        let mut accounting = managed_position::new_managed_accounting_for_testing<SUI>(
            OPPORTUNITY,
            b"sui",
            STRATEGY,
            2_000,
            2_500,
            ts::ctx(&mut scn),
        );
        let position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            false,
            100,
            ts::ctx(&mut scn),
        );
        let position_id = object::id(&position);
        managed_position::publish_new_position_for_testing(position, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, OWNER);
        let position = ts::take_from_sender_by_id<Position>(&scn, position_id);
        assert!(!managed_position::leader_may_force_exit(&position), 10);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scn);
    }

    /// L1 (security review #868): opt-out / plain positions must hard-fail at
    /// prepare with E_INVALID_FORCE_EXIT_CONSENT — not only JS surface checks.
    #[test]
    #[expected_failure(abort_code = managed_position::E_INVALID_FORCE_EXIT_CONSENT)]
    fun prepare_force_exit_rejects_opt_out_position() {
        let mut scn = ts::begin(authority());
        let (registry_id, guardrails_id, policy_id, latch_id) = setup_policy(&mut scn);
        // Policy-bound ledger + depositor OPT-OUT (leader_may_force_exit=false).
        ts::next_tx(&mut scn, OWNER);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let mut accounting =
            managed_position::new_policy_bound_accounting_for_testing<AdapterWitness, SUI>(
                OPPORTUNITY,
                registry_id,
                STRATEGY,
                guardrails_id,
                guardrails_v2::guardrails_hash(&guardrails),
                ts::ctx(&mut scn),
            );
        let position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            false,
            100,
            ts::ctx(&mut scn),
        );
        assert!(!managed_position::leader_may_force_exit(&position), 20);
        let accounting_id = managed_position::accounting_id(&accounting);
        let position_id = object::id(&position);
        let deployed = managed_position::record_measured_deployment_for_testing(
            &mut accounting,
            coin::mint_for_testing<SUI>(100, ts::ctx(&mut scn)),
        );
        coin::burn_for_testing(deployed);
        managed_position::share_accounting_for_testing(accounting);
        managed_position::publish_new_position_for_testing(position, ts::ctx(&mut scn));
        ts::return_immutable(guardrails);

        enter_exit_mode(&mut scn, guardrails_id, policy_id, latch_id);

        ts::next_tx(&mut scn, CRANK);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let accounting = ts::take_shared_by_id<OpportunityAccounting>(&scn, accounting_id);
        // Opt-out remains owner-held (not shared).
        let position = ts::take_from_address_by_id<Position>(&scn, OWNER, position_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 3_000);
        let (_ticket, _pot) = managed_force_exit::prepare_consented_force_exit<SUI>(
            &registry,
            &guardrails,
            &policy,
            &latch,
            &accounting,
            &position,
            &test_clock,
            ts::ctx(&mut scn),
        );
        abort 97
    }

    /// L2 (security review #868): adapter proceeds > reserved basis is fail-closed
    /// until the fee waterfall is composed (no fee-free gain exit).
    #[test]
    #[expected_failure(abort_code = managed_closeout::E_FORCE_EXIT_GAIN_REQUIRES_RECONCILIATION)]
    fun fund_force_exit_rejects_positive_adapter_gain() {
        let mut scn = ts::begin(authority());
        let (registry_id, guardrails_id, policy_id, latch_id) = setup_policy(&mut scn);
        let (accounting_id, position_id) = create_and_share_consented_position(
            &mut scn,
            registry_id,
            guardrails_id,
            policy_id,
        );
        enter_exit_mode(&mut scn, guardrails_id, policy_id, latch_id);

        ts::next_tx(&mut scn, CRANK);
        let registry = ts::take_shared<StrategyRegistry>(&scn);
        let guardrails = ts::take_immutable_by_id<GuardrailsV2>(&scn, guardrails_id);
        let policy = ts::take_immutable_by_id<LeaderPolicy>(&scn, policy_id);
        let latch = ts::take_shared_by_id<ExitModeLatch>(&scn, latch_id);
        let mut accounting = ts::take_shared_by_id<OpportunityAccounting>(&scn, accounting_id);
        let mut position = ts::take_shared_by_id<Position>(&scn, position_id);
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scn));
        clock::set_for_testing(&mut test_clock, 3_000);
        let (ticket, pot) = managed_force_exit::prepare_consented_force_exit<SUI>(
            &registry,
            &guardrails,
            &policy,
            &latch,
            &accounting,
            &position,
            &test_clock,
            ts::ctx(&mut scn),
        );
        let witness = AdapterWitness {};
        // Reserved basis is 100 micros (deposit); adapter returns 150 → positive gain.
        let receipt = managed_force_exit::attest_adapter_return(
            &accounting,
            &position,
            ticket,
            &witness,
            option::some(coin::mint_for_testing<SUI>(150, ts::ctx(&mut scn))),
        );
        let (_pot_id, _claim_id) = managed_force_exit::fund_consented_force_exit(
            &mut accounting,
            pot,
            &mut position,
            receipt,
            ts::ctx(&mut scn),
        );
        abort 96
    }
}
