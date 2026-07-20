// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::managed_closeout_hardening_tests {
    use day::managed_closeout;
    use day::managed_position;
    use day::managed_reallocation;
    use day::guardrails_v2;
    use std::hash;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario as ts;

    const ALICE: address = @0xA11CE;
    const BOB: address = @0xB0B;
    const ATTACKER: address = @0xBAD;
    const ADAPTER: address = @0xADAE7;
    const LEAD_FEES: address = @0x1EAD;
    const DAY_FEES: address = @0xDA7;
    const STRATEGY: vector<u8> = b"day-managed-top-one";
    const ROUTE: vector<u8> = x"2222222222222222222222222222222222222222222222222222222222222222";
    const BASE_TOKEN: vector<u8> = x"1111111111111111111111111111111111111111";
    const ARBITRUM_TOKEN: vector<u8> = x"2222222222222222222222222222222222222222";

    public struct AdapterWitness has drop {}
    public struct RemoteAccountingAsset has drop {}

    fun managed(
        opportunity: vector<u8>,
        ctx: &mut TxContext,
    ): managed_position::OpportunityAccounting {
        managed_with_strategy(opportunity, STRATEGY, ctx)
    }

    fun managed_with_strategy(
        opportunity: vector<u8>,
        strategy: vector<u8>,
        ctx: &mut TxContext,
    ): managed_position::OpportunityAccounting {
        managed_with_fee(opportunity, strategy, 2_000, ctx)
    }

    fun managed_with_fee(
        opportunity: vector<u8>,
        strategy: vector<u8>,
        lead_fee_bps: u64,
        ctx: &mut TxContext,
    ): managed_position::OpportunityAccounting {
        let mut accounting = managed_position::new_managed_accounting_for_testing<SUI>(
            opportunity, b"sui", strategy, lead_fee_bps, 2_500, ctx,
        );
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut accounting);
        accounting
    }

    #[test]
    #[expected_failure(abort_code = 4, location = day::managed_reallocation)]
    fun reservation_rejects_cross_strategy_destination() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed_with_strategy(b"dayop-source", STRATEGY, ctx);
        let destination = managed_with_strategy(b"dayop-destination", b"other-strategy", ctx);
        let source_position = deposit_and_deploy(&mut source, 100, ctx);
        let _reservation = managed_reallocation::start_reallocation<SUI>(
            &mut source, &destination, ROUTE, 10_000, ctx,
        );
        managed_position::destroy_position_for_testing(source_position);
        abort 999
    }

    fun deposit_and_deploy(
        accounting: &mut managed_position::OpportunityAccounting,
        amount: u64,
        ctx: &mut TxContext,
    ): managed_position::Position {
        let position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            accounting, false, amount as u128, ctx,
        );
        let witness = AdapterWitness {};
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            accounting,
            &witness,
            coin::mint_for_testing<SUI>(amount, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            accounting,
            deployment,
        ));
        position
    }

    #[test]
    #[expected_failure(abort_code = 3, location = day::managed_closeout)]
    fun production_frozen_exit_rejects_caller_extended_deadline() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let accounting = managed(b"dayop-source", ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        // Package policy is exactly five minutes. A sibling module cannot add
        // even one millisecond to delay the recorded owner's payout.
        let _pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 301_001, &test_clock, ctx,
        );
        abort 999
    }

    #[test]
    #[expected_failure(abort_code = 3, location = day::managed_closeout)]
    fun production_frozen_exit_rejects_caller_shortened_deadline() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let accounting = managed(b"dayop-source", ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        // The deadline is package policy, not a caller-selected range.
        let _pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 300_999, &test_clock, ctx,
        );
        abort 999
    }

    #[test]
    #[expected_failure(abort_code = 3, location = day::managed_closeout)]
    fun production_frozen_exit_rejects_deadline_overflow_boundary() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let accounting = managed(b"dayop-source", ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 18_446_744_073_709_251_616);
        let _pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 18_446_744_073_709_551_615, &test_clock, ctx,
        );
        abort 999
    }

    fun reserve_reallocation(
        source: &mut managed_position::OpportunityAccounting,
        destination: &managed_position::OpportunityAccounting,
        allocation_bps: u64,
        ctx: &mut TxContext,
    ): ID {
        let reservation = managed_reallocation::start_reallocation<SUI>(
            source, destination, ROUTE, allocation_bps, ctx,
        );
        let (
            state_id,
            source_id,
            destination_id,
            source_opportunity,
            destination_opportunity,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            canonical_route,
            route_commitment,
            source_native_asset_binding,
            destination_native_asset_binding,
            reserved_bps,
        ) = managed_reallocation::consume_reallocation_reservation(reservation);
        assert!(source_id == managed_position::accounting_id(source), 100);
        assert!(destination_id == managed_position::accounting_id(destination), 101);
        assert!(source_opportunity == managed_position::accounting_opportunity_id(source), 102);
        assert!(destination_opportunity == managed_position::accounting_opportunity_id(destination), 103);
        assert!(strategy_id == STRATEGY, 106);
        assert!(guardrails_id == *option::borrow(&managed_position::accounting_guardrails_id(source)), 107);
        assert!(guardrails_hash == *option::borrow(&managed_position::accounting_guardrails_hash(source)), 108);
        assert!(canonical_route == ROUTE, 104);
        assert!(route_commitment == hash::sha2_256(ROUTE), 109);
        assert!(guardrails_v2::same_native_asset_binding(
            &source_native_asset_binding,
            &managed_position::accounting_native_asset_binding(source),
        ), 110);
        assert!(guardrails_v2::same_native_asset_binding(
            &destination_native_asset_binding,
            &managed_position::accounting_native_asset_binding(destination),
        ), 111);
        assert!(reserved_bps == allocation_bps, 105);
        state_id
    }

    #[test]
    fun reservation_carries_only_accounting_derived_remote_assets_and_route_hash() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let base = guardrails_v2::evm_asset_binding(b"base", BASE_TOKEN);
        let arbitrum = guardrails_v2::evm_asset_binding(b"arbitrum", ARBITRUM_TOKEN);
        let mut source =
            managed_position::new_managed_accounting_with_native_binding_for_testing<RemoteAccountingAsset>(
                b"dayop-source",
                STRATEGY,
                base,
                ctx,
            );
        let destination =
            managed_position::new_managed_accounting_with_native_binding_for_testing<RemoteAccountingAsset>(
                b"dayop-destination",
                STRATEGY,
                arbitrum,
                ctx,
            );
        managed_position::bind_adapter_source_for_testing<AdapterWitness>(&mut source);
        let position = managed_position::record_managed_local_deposit_for_testing<RemoteAccountingAsset>(
            &mut source,
            false,
            100,
            ctx,
        );
        let deployment = managed_position::attest_adapter_deployment_for_testing(
            &source,
            &AdapterWitness {},
            coin::mint_for_testing<RemoteAccountingAsset>(100, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(
            &mut source,
            deployment,
        ));
        let canonical_route = b"canonical-route-derived-by-leaf";
        let reservation = managed_reallocation::start_reallocation<RemoteAccountingAsset>(
            &mut source,
            &destination,
            canonical_route,
            5_000,
            ctx,
        );
        let (
            _, _, _, _, _, _, _, _,
            carried_route,
            carried_commitment,
            source_binding,
            destination_binding,
            carried_allocation,
        ) = managed_reallocation::consume_reallocation_reservation(reservation);
        assert!(carried_route == canonical_route, 112);
        assert!(carried_commitment == hash::sha2_256(canonical_route), 113);
        assert!(guardrails_v2::same_native_asset_binding(&source_binding, &base), 114);
        assert!(guardrails_v2::same_native_asset_binding(&destination_binding, &arbitrum), 115);
        assert!(carried_allocation == 5_000, 116);

        ts::next_tx(&mut scenario, ALICE);
        let state = ts::take_shared<managed_reallocation::ReallocationState<RemoteAccountingAsset>>(
            &scenario,
        );
        managed_reallocation::destroy_for_testing(state);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 17, location = day::managed_closeout)]
    fun legacy_settlement_priced_exit_is_quarantined() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let mut position = deposit_and_deploy(&mut accounting, 10, ctx);
        let bob_position = deposit_and_deploy(&mut accounting, 10, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 301_000, &test_clock, ctx,
        );
        // Preparing metadata alone cannot burn either side of the ledger.
        assert!(managed_position::position_shares(&position) == 10, 1);
        assert!(managed_position::total_assets_micros(&accounting) == 20, 2);
        let purpose = object::id(&pot);
        let receipt = managed_position::attest_adapter_closeout_return_for_testing(
            &accounting,
            &AdapterWitness {},
            &position,
            10,
            purpose,
            option::some(coin::mint_for_testing<SUI>(9, ctx)),
        );
        let (_, claim_id) = managed_closeout::reserve_and_fund_frozen_exit_pot(
            &mut accounting,
            pot,
            &mut position,
            10,
            receipt,
            ctx,
        );
        assert!(managed_position::position_shares(&position) == 0, 3);
        assert!(managed_position::total_assets_micros(&accounting) == 10, 4);
        assert!(managed_position::position_shares(&bob_position) == 10, 6);
        clock::set_for_testing(&mut test_clock, 301_001);
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ATTACKER);
        let test_clock = ts::take_shared<Clock>(&scenario);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        assert!(managed_closeout::settle_frozen_exit_claim(
            &mut pot, claim_id, &test_clock, ts::ctx(&mut scenario),
        ) == 9, 5);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun consent_frozen_exit_uses_consent_price_after_shared_ledger_moves() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"day859-consent", ctx);
        let mut alice = deposit_and_deploy(&mut accounting, 100, ctx);
        let bob = deposit_and_deploy(&mut accounting, 100, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);

        let pot_id = managed_closeout::prepare_frozen_exit_pot_with_consent<SUI>(
            &mut accounting,
            &mut alice,
            100,
            301_000,
            &test_clock,
            ctx,
        );
        assert!(managed_position::position_shares(&alice) == 0, 200);
        assert!(managed_position::price_per_share_micros(&accounting) == 1_000_000, 201);
        clock::share_for_testing(test_clock);

        // A later shared-ledger return changes live PPS to 1.5. This must not
        // reprice Alice's already-consented claim.
        ts::next_tx(&mut scenario, BOB);
        managed_position::apply_full_reconciliation(&mut accounting, 150, 1_500_000);
        assert!(managed_position::price_per_share_micros(&accounting) > 1_000_000, 202);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &AdapterWitness {},
            pot_id,
            option::some(coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario))),
        );
        let claim_id = managed_closeout::fund_frozen_exit_pot_from_consent(
            &mut accounting,
            &mut pot,
            &mut alice,
            receipt,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 1_000_000, 203);
        clock::set_for_testing(&mut test_clock, 301_001);
        assert!(managed_closeout::settle_frozen_exit_claim(
            &mut pot,
            claim_id,
            &test_clock,
            ts::ctx(&mut scenario),
        ) == 100, 204);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 100, 205);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(alice);
        managed_position::destroy_position_for_testing(bob);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun consent_frozen_exit_shared_order_bob_then_alice_keeps_bob_snapshot() {
        let mut scenario = ts::begin(BOB);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"day859-consent-reverse", ctx);
        let mut bob = deposit_and_deploy(&mut accounting, 100, ctx);

        ts::next_tx(&mut scenario, ALICE);
        let alice = deposit_and_deploy(&mut accounting, 100, ts::ctx(&mut scenario));
        let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut test_clock, 1_000);
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, BOB);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let pot_id = managed_closeout::prepare_frozen_exit_pot_with_consent<SUI>(
            &mut accounting,
            &mut bob,
            100,
            301_000,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        managed_position::apply_full_reconciliation(&mut accounting, 150, 1_500_000);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &AdapterWitness {},
            pot_id,
            option::some(coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario))),
        );
        let claim_id = managed_closeout::fund_frozen_exit_pot_from_consent(
            &mut accounting,
            &mut pot,
            &mut bob,
            receipt,
            ts::ctx(&mut scenario),
        );
        clock::set_for_testing(&mut test_clock, 301_001);
        assert!(managed_closeout::settle_frozen_exit_claim(
            &mut pot, claim_id, &test_clock, ts::ctx(&mut scenario),
        ) == 100, 206);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, BOB);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 100, 207);
        coin::burn_for_testing(payout);
        managed_position::destroy_position_for_testing(bob);
        managed_position::destroy_position_for_testing(alice);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun consent_timeout_restores_owner_shares_and_exact_accounting_basis() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"day859-consent-cancel", ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let _pot_id = managed_closeout::prepare_frozen_exit_pot_with_consent<SUI>(
            &mut accounting,
            &mut position,
            100,
            301_000,
            &test_clock,
            ctx,
        );
        assert!(managed_position::position_shares(&position) == 0, 208);
        assert!(managed_position::total_assets_micros(&accounting) == 0, 209);
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        clock::set_for_testing(&mut test_clock, 301_001);
        managed_closeout::cancel_frozen_exit_pot_consent(
            &mut accounting,
            &pot,
            &mut position,
            &test_clock,
            ts::ctx(&mut scenario),
        );
        assert!(managed_position::position_shares(&position) == 100, 210);
        assert!(managed_position::total_assets_micros(&accounting) == 100, 211);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 17, location = day::managed_closeout)]
    fun legacy_managed_closeout_is_quarantined() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let mut alice_position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);
        let bob_position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 301_000, &test_clock, ctx,
        );
        let purpose = object::id(&pot);
        let receipt = managed_position::attest_adapter_closeout_return_for_testing(
            &accounting,
            &AdapterWitness {},
            &alice_position,
            100_000_000,
            purpose,
            option::some(coin::mint_for_testing<SUI>(120_000_000, ctx)),
        );
        let (_, claim_id) = managed_closeout::reserve_and_fund_frozen_exit_pot(
            &mut accounting,
            pot,
            &mut alice_position,
            100_000_000,
            receipt,
            ctx,
        );
        // Alice's authenticated 20m gain pays the exact nested 20% pool before
        // her claim is funded. Bob's 100m basis/value is untouched.
        assert!(managed_position::position_shares(&alice_position) == 0, 110);
        assert!(managed_position::position_value_micros(&accounting, &bob_position) == 100_000_000, 111);
        assert!(managed_position::total_assets_micros(&accounting) == 100_000_000, 112);
        clock::set_for_testing(&mut test_clock, 301_001);
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ATTACKER);
        let test_clock = ts::take_shared<Clock>(&scenario);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        assert!(managed_closeout::settle_frozen_exit_claim(
            &mut pot, claim_id, &test_clock, ts::ctx(&mut scenario),
        ) == 116_000_000, 113);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 116_000_000, 114);
        coin::burn_for_testing(payout);
        ts::next_tx(&mut scenario, LEAD_FEES);
        let lead_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&lead_fee) == 3_000_000, 115);
        coin::burn_for_testing(lead_fee);
        ts::next_tx(&mut scenario, DAY_FEES);
        let day_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&day_fee) == 1_000_000, 116);
        coin::burn_for_testing(day_fee);
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 17, location = day::managed_closeout)]
    fun legacy_closeout_receipt_selection_path_is_quarantined() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let mut position = deposit_and_deploy(&mut accounting, 10, ctx);
        let _bob_position = deposit_and_deploy(&mut accounting, 10, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 301_000, &test_clock, ctx,
        );
        let purpose = object::id(&pot);
        let receipt = managed_position::attest_adapter_closeout_return_for_testing(
            &accounting,
            &AdapterWitness {},
            &position,
            10,
            purpose,
            option::some(coin::mint_for_testing<SUI>(9, ctx)),
        );
        // Receipt commits 10 shares; selecting 5 must abort before any burn.
        let (_, _) = managed_closeout::reserve_and_fund_frozen_exit_pot(
            &mut accounting, pot, &mut position, 5, receipt, ctx,
        );
        abort 999
    }

    #[test]
    fun production_reallocation_partial_then_final_derives_gain() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let alice_position = deposit_and_deploy(&mut source, 100, ctx);
        let bob_position = deposit_and_deploy(&mut source, 100, ctx);
        let high_water_before = managed_position::high_water_pps(&source);
        let state_id = reserve_reallocation(
            &mut source, &destination, 5_000, ctx,
        );
        assert!(managed_position::in_transit_assets_micros(&source) == 100, 10);
        ts::next_tx(&mut scenario, ALICE);
        let first = managed_position::attest_adapter_return_for_testing(
            &source, &AdapterWitness {}, state_id,
            option::some(coin::mint_for_testing<SUI>(40, ts::ctx(&mut scenario))),
        );
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::settle_reallocation_chunk(
            &mut state, &mut source, &mut destination, first,
        );
        assert!(managed_reallocation::remaining_basis_micros(&state) == 60, 11);
        let final_receipt = managed_position::attest_adapter_return_for_testing(
            &source, &AdapterWitness {}, state_id,
            option::some(coin::mint_for_testing<SUI>(65, ts::ctx(&mut scenario))),
        );
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, final_receipt,
        );
        assert!(managed_reallocation::closed(&state), 12);
        assert!(managed_reallocation::realized_gain_micros(&state) == 5, 13);
        assert!(managed_reallocation::realized_loss_micros(&state) == 0, 14);
        assert!(managed_position::in_transit_assets_micros(&source) == 0, 15);
        assert!(managed_position::total_assets_micros(&source) == 205, 16);
        assert!(managed_position::total_assets_micros(&destination) == 0, 17);
        assert!(managed_reallocation::destination_deployed_micros(&state) == 105, 18);
        assert!(managed_position::position_shares(&alice_position) == 100, 19);
        assert!(managed_position::position_shares(&bob_position) == 100, 20);
        assert!(managed_position::high_water_pps(&source) == high_water_before, 21);
        managed_reallocation::destroy_for_testing(state);

        ts::next_tx(&mut scenario, ADAPTER);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    fun destination_spoke_return_funds_owner_exit_without_cross_ledger_shares() {
        let mut scenario = ts::begin(ALICE);
        let mut source = managed(b"dayop-source", ts::ctx(&mut scenario));
        let mut destination = managed(b"dayop-destination", ts::ctx(&mut scenario));
        let mut alice_position = deposit_and_deploy(
            &mut source, 100, ts::ctx(&mut scenario),
        );
        let bob_position = deposit_and_deploy(
            &mut source, 100, ts::ctx(&mut scenario),
        );
        let high_water_before = managed_position::high_water_pps(&source);
        let state_id = reserve_reallocation(
            &mut source, &destination, 5_000, ts::ctx(&mut scenario),
        );
        ts::next_tx(&mut scenario, ALICE);
        let first = managed_position::attest_adapter_return_for_testing(
            &source, &AdapterWitness {}, state_id,
            option::some(coin::mint_for_testing<SUI>(40, ts::ctx(&mut scenario))),
        );
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::settle_reallocation_chunk(
            &mut state, &mut source, &mut destination, first,
        );
        let final_receipt = managed_position::attest_adapter_return_for_testing(
            &source, &AdapterWitness {}, state_id,
            option::some(coin::mint_for_testing<SUI>(65, ts::ctx(&mut scenario))),
        );
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, final_receipt,
        );
        assert!(managed_position::total_shares(&source) == 200, 30);
        assert!(managed_position::total_shares(&destination) == 0, 31);
        assert!(managed_position::total_assets_micros(&destination) == 0, 32);
        assert!(managed_reallocation::destination_deployed_micros(&state) == 105, 33);

        // The two measured Coins went directly to the destination adapter.
        ts::next_tx(&mut scenario, ADAPTER);
        let mut returned = ts::take_from_sender<Coin<SUI>>(&scenario);
        coin::join(&mut returned, ts::take_from_sender<Coin<SUI>>(&scenario));
        transfer::public_transfer(returned, ALICE);

        // Destination return evidence is bound to the destination accounting's
        // adapter type/current nonce and to this state ID as its purpose.
        ts::next_tx(&mut scenario, ALICE);
        let returned = ts::take_from_sender<Coin<SUI>>(&scenario);
        let destination_receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(returned),
        );
        let authenticated = managed_reallocation::finalize_destination_return(
            &mut state,
            &mut source,
            &mut destination,
            destination_receipt,
        );
        assert!(managed_reallocation::destination_return_closed(&state), 34);
        assert!(managed_reallocation::destination_deployed_micros(&state) == 0, 35);
        assert!(managed_reallocation::destination_reconciled_micros(&state) == 105, 36);
        assert!(managed_position::liquid_assets_micros(&source) == 105, 37);
        assert!(managed_position::deployed_assets_micros(&source) == 100, 38);
        assert!(managed_position::total_assets_micros(&source) == 205, 39);
        assert!(managed_position::high_water_pps(&source) == high_water_before, 40);

        // Fee crystallization is mandatory before payout: the 5-micro gain
        // yields a 1-micro pool, then Alice receives her net pro-rata claim.
        let assessment = managed_closeout::crystallize_and_settle_reallocation_exit(
            &mut source,
            &mut alice_position,
            100,
            authenticated,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::fee_profit_micros(&assessment) == 5, 49);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 1, 50);
        assert!(managed_position::position_shares(&alice_position) == 0, 41);
        assert!(managed_position::position_shares(&bob_position) == 100, 42);
        assert!(managed_position::total_shares(&source) == 100, 43);
        assert!(managed_position::total_assets_micros(&source) == 104, 44);
        assert!(managed_position::liquid_assets_micros(&source) == 4, 45);
        assert!(managed_position::deployed_assets_micros(&source) == 100, 46);
        assert!(managed_position::convert_to_assets(100, 104, 100) == 100, 47);
        managed_reallocation::destroy_for_testing(state);

        ts::next_tx(&mut scenario, ALICE);
        let alice_payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&alice_payout) == 100, 48);
        coin::burn_for_testing(alice_payout);

        ts::next_tx(&mut scenario, LEAD_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));

        ts::next_tx(&mut scenario, ADAPTER);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = day::managed_reallocation)]
    fun partial_destination_return_fails_closed_before_fee_path() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let _source_position = deposit_and_deploy(&mut source, 100, ctx);
        let state_id = reserve_reallocation(&mut source, &destination, 10_000, ctx);

        let inbound = managed_position::attest_adapter_return_for_testing(
            &source,
            &AdapterWitness {},
            state_id,
            option::some(coin::mint_for_testing<SUI>(120, ctx)),
        );
        ts::next_tx(&mut scenario, ALICE);
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, inbound,
        );

        // A 119 partial followed by 1 final would leave the final Coin smaller
        // than the 4-unit fee on the aggregate 20 gain. Reject fragmentation
        // before consuming the receipt so no provisional fee can be paid and
        // the adapter can resubmit the full conclusive 120.
        ts::next_tx(&mut scenario, ADAPTER);
        let mut destination_assets = ts::take_from_sender<Coin<SUI>>(&scenario);
        let partial = coin::split(&mut destination_assets, 119, ts::ctx(&mut scenario));
        transfer::public_transfer(partial, ALICE);
        transfer::public_transfer(destination_assets, BOB);

        ts::next_tx(&mut scenario, ALICE);
        let partial = ts::take_from_sender<Coin<SUI>>(&scenario);
        let partial_receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(partial),
        );
        managed_reallocation::settle_destination_return_chunk(
            &mut state, &mut source, &mut destination, partial_receipt,
        );
        abort 999
    }

    #[test]
    fun conclusive_destination_return_derives_fee_after_final_loss() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let source_position = deposit_and_deploy(&mut source, 100, ctx);
        let state_id = reserve_reallocation(&mut source, &destination, 10_000, ctx);

        // The first leg reports 120 against 100 basis. The conclusive
        // destination receipt later returns only 100, proving the temporary 20
        // gain was fully offset and therefore carries no performance fee.
        let inbound = managed_position::attest_adapter_return_for_testing(
            &source,
            &AdapterWitness {},
            state_id,
            option::some(coin::mint_for_testing<SUI>(120, ctx)),
        );
        ts::next_tx(&mut scenario, ALICE);
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, inbound,
        );
        assert!(managed_position::total_assets_micros(&source) == 120, 120);

        ts::next_tx(&mut scenario, ADAPTER);
        let mut destination_assets = ts::take_from_sender<Coin<SUI>>(&scenario);
        let realized_loss = coin::split(&mut destination_assets, 20, ts::ctx(&mut scenario));
        coin::burn_for_testing(realized_loss);
        transfer::public_transfer(destination_assets, ALICE);

        ts::next_tx(&mut scenario, ALICE);
        let final_chunk = ts::take_from_sender<Coin<SUI>>(&scenario);
        let final_receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(final_chunk),
        );
        let authenticated = managed_reallocation::finalize_destination_return(
            &mut state, &mut source, &mut destination, final_receipt,
        );
        assert!(managed_reallocation::destination_return_closed(&state), 126);
        assert!(managed_reallocation::destination_deployed_micros(&state) == 0, 127);
        assert!(managed_reallocation::realized_gain_micros(&state) == 20, 128);
        assert!(managed_reallocation::realized_loss_micros(&state) == 20, 129);
        assert!(managed_position::total_assets_micros(&source) == 100, 130);

        let assessment = managed_closeout::crystallize_reallocation_fees(
            &mut source,
            authenticated,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::fee_profit_micros(&assessment) == 0, 131);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 0, 132);
        assert!(managed_closeout::fee_lead_micros(&assessment) == 0, 133);
        assert!(managed_closeout::fee_day_micros(&assessment) == 0, 134);
        assert!(!ts::has_most_recent_for_address<Coin<SUI>>(LEAD_FEES), 135);
        assert!(!ts::has_most_recent_for_address<Coin<SUI>>(DAY_FEES), 136);
        managed_reallocation::destroy_for_testing(state);

        ts::next_tx(&mut scenario, ADAPTER);
        let returned = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&returned) == 100, 137);
        coin::burn_for_testing(returned);
        managed_position::destroy_position_for_testing(source_position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    fun full_adapter_zero_return_never_blocks_ledger_profit() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);

        // A separately authenticated spoke closes 80m of deployed basis with
        // 120m, leaving 120m liquid and 20m still deployed. The final adapter
        // then proves that remaining 20m is a total loss. Net NAV is 120m
        // against 100m fee basis, but the final receipt carries no Coin from
        // which a fee can safely be split.
        managed_position::apply_measured_spoke_return(
            &mut accounting,
            80_000_000,
            120_000_000,
        );
        assert!(managed_position::liquid_assets_micros(&accounting) == 120_000_000, 138);
        assert!(managed_position::deployed_assets_micros(&accounting) == 20_000_000, 139);
        let accounting_id = managed_position::accounting_id(&accounting);
        let receipt: managed_position::AdapterReturnReceipt<AdapterWitness, SUI> =
            managed_position::attest_adapter_return_for_testing(
                &accounting,
                &AdapterWitness {},
                accounting_id,
                option::none<Coin<SUI>>(),
            );
        let (proceeds, assessment) = managed_closeout::reconcile_full_adapter_return(
            &mut accounting,
            receipt,
            ts::ctx(&mut scenario),
        );

        assert!(option::is_none(&proceeds), 140);
        option::destroy_none(proceeds);
        assert!(managed_closeout::fee_profit_micros(&assessment) == 20_000_000, 141);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 0, 142);
        assert!(managed_position::total_assets_micros(&accounting) == 120_000_000, 143);
        assert!(managed_position::fee_basis_assets_micros_for_package(&accounting)
            == 120_000_000, 144);
        assert!(!ts::has_most_recent_for_address<Coin<SUI>>(LEAD_FEES), 145);
        assert!(!ts::has_most_recent_for_address<Coin<SUI>>(DAY_FEES), 146);
        managed_position::settle_owner_exit(
            &mut accounting,
            &mut position,
            100_000_000,
            coin::mint_for_testing<SUI>(120_000_000, ts::ctx(&mut scenario)),
            ts::ctx(&mut scenario),
        );
        assert!(managed_position::position_shares(&position) == 0, 147);
        assert!(managed_position::total_assets_micros(&accounting) == 0, 148);

        ts::next_tx(&mut scenario, ALICE);
        let owner_proceeds = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&owner_proceeds) == 120_000_000, 149);
        coin::burn_for_testing(owner_proceeds);

        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun full_adapter_fee_never_exceeds_conclusive_return() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);

        // Net final NAV is 120m: 119m was already returned by another spoke,
        // and this last adapter proves only 1m of its remaining 20m basis. The
        // ledger-wide 20m profit derives a 4m fee, but collecting more than the
        // final 1m Coin would either abort finalization or require an unrelated
        // principal source. Only 1m is collected and the unsupported 3m is
        // forgiven when the epoch closes.
        managed_position::apply_measured_spoke_return(
            &mut accounting,
            80_000_000,
            119_000_000,
        );
        let accounting_id = managed_position::accounting_id(&accounting);
        let receipt: managed_position::AdapterReturnReceipt<AdapterWitness, SUI> =
            managed_position::attest_adapter_return_for_testing(
                &accounting,
                &AdapterWitness {},
                accounting_id,
                option::some(coin::mint_for_testing<SUI>(1_000_000, ctx)),
            );
        let (proceeds, assessment) = managed_closeout::reconcile_full_adapter_return(
            &mut accounting,
            receipt,
            ts::ctx(&mut scenario),
        );

        assert!(managed_closeout::fee_profit_micros(&assessment) == 20_000_000, 150);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 1_000_000, 151);
        assert!(managed_closeout::fee_lead_micros(&assessment) == 750_000, 152);
        assert!(managed_closeout::fee_day_micros(&assessment) == 250_000, 153);
        assert!(managed_closeout::fee_net_micros(&assessment) == 0, 154);
        let net = option::destroy_some(proceeds);
        assert!(coin::value(&net) == 0, 155);
        coin::burn_for_testing(net);
        assert!(managed_position::deployed_assets_micros(&accounting) == 0, 156);
        assert!(managed_position::total_assets_micros(&accounting) == 119_000_000, 157);
        assert!(managed_position::fee_basis_assets_micros_for_package(&accounting)
            == 119_000_000, 158);

        ts::next_tx(&mut scenario, LEAD_FEES);
        let lead_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&lead_fee) == 750_000, 159);
        coin::burn_for_testing(lead_fee);
        ts::next_tx(&mut scenario, DAY_FEES);
        let day_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&day_fee) == 250_000, 160);
        coin::burn_for_testing(day_fee);

        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    /// Sibling of full_adapter_fee_never_exceeds_conclusive_return for the
    /// reallocation crystallize path: ledger-wide profit can exceed the
    /// authenticated return Coin. Cap/forgo — never abort.
    #[test]
    fun crystallize_reallocation_fees_cap_to_authenticated_return() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let source_position = deposit_and_deploy(&mut source, 100_000_000, ctx);
        let state_id = reserve_reallocation(&mut source, &destination, 10_000, ctx);

        // Bank 20m ledger-wide profit via reallocation inbound (120 on 100 basis).
        let inbound = managed_position::attest_adapter_return_for_testing(
            &source,
            &AdapterWitness {},
            state_id,
            option::some(coin::mint_for_testing<SUI>(120_000_000, ctx)),
        );
        ts::next_tx(&mut scenario, ALICE);
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, inbound,
        );
        assert!(managed_position::total_assets_micros(&source) == 120_000_000, 200);

        // Destination returns only 1m (<< 4m derived 20% fee on 20m profit).
        ts::next_tx(&mut scenario, ADAPTER);
        let mut dest_assets = ts::take_from_sender<Coin<SUI>>(&scenario);
        let dust = coin::split(&mut dest_assets, 119_000_000, ts::ctx(&mut scenario));
        coin::burn_for_testing(dust);
        transfer::public_transfer(dest_assets, ALICE);
        ts::next_tx(&mut scenario, ALICE);
        let final_chunk = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&final_chunk) == 1_000_000, 201);
        let final_receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(final_chunk),
        );
        let authenticated = managed_reallocation::finalize_destination_return(
            &mut state, &mut source, &mut destination, final_receipt,
        );
        let assessment = managed_closeout::crystallize_reallocation_fees(
            &mut source,
            authenticated,
            ts::ctx(&mut scenario),
        );
        // Fee collection never exceeds the authenticated return Coin (1m).
        // Without the cap, ledger-wide profit would derive a larger fee and abort.
        let collected = managed_closeout::fee_lead_pool_micros(&assessment);
        assert!(collected <= 1_000_000, 202);
        assert!(managed_closeout::fee_net_micros(&assessment) == 1_000_000 - collected, 203);
        assert!(collected == managed_closeout::fee_lead_micros(&assessment)
            + managed_closeout::fee_day_micros(&assessment), 204);

        if (collected > 0) {
            ts::next_tx(&mut scenario, LEAD_FEES);
            if (ts::has_most_recent_for_address<Coin<SUI>>(LEAD_FEES)) {
                let lead_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
                coin::burn_for_testing(lead_fee);
            };
            ts::next_tx(&mut scenario, DAY_FEES);
            if (ts::has_most_recent_for_address<Coin<SUI>>(DAY_FEES)) {
                let day_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
                coin::burn_for_testing(day_fee);
            };
        };
        ts::next_tx(&mut scenario, ADAPTER);
        let net = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&net) == 1_000_000 - (collected as u64), 207);
        coin::burn_for_testing(net);

        managed_reallocation::destroy_for_testing(state);
        managed_position::destroy_position_for_testing(source_position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    fun new_subscription_never_pays_fee_on_pre_subscription_gain() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let alice_position = deposit_and_deploy(&mut source, 1_000_000_000, ctx);
        let state_id = reserve_reallocation(&mut source, &destination, 10_000, ctx);

        // One billion of authenticated gain accrues before Bob subscribes.
        let inbound = managed_position::attest_adapter_return_for_testing(
            &source,
            &AdapterWitness {},
            state_id,
            option::some(coin::mint_for_testing<SUI>(2_000_000_000, ctx)),
        );
        ts::next_tx(&mut scenario, ALICE);
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, inbound,
        );
        ts::next_tx(&mut scenario, ADAPTER);
        transfer::public_transfer(ts::take_from_sender<Coin<SUI>>(&scenario), ALICE);
        ts::next_tx(&mut scenario, ALICE);
        let returned = ts::take_from_sender<Coin<SUI>>(&scenario);
        let destination_receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(returned),
        );
        let authenticated = managed_reallocation::finalize_destination_return(
            &mut state,
            &mut source,
            &mut destination,
            destination_receipt,
        );
        let assessment = managed_closeout::crystallize_reallocation_fees(
            &mut source,
            authenticated,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::fee_profit_micros(&assessment) == 1_000_000_000, 50);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 200_000_000, 51);
        assert!(managed_position::total_assets_micros(&source) == 1_800_000_000, 52);
        managed_reallocation::destroy_for_testing(state);

        // Bob enters only after the incumbent's fee has been paid. His
        // immediate owner-authorized payout is his full 2b deposit less one
        // micro of deterministic virtual-offset floor dust, never Alice's fee.
        ts::next_tx(&mut scenario, BOB);
        let bob_position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut source,
            false,
            2_000_000_000,
            ts::ctx(&mut scenario),
        );
        assert!(managed_position::position_value_micros(&source, &bob_position) == 1_999_999_999, 53);
        let mut bob_position = bob_position;
        let bob_shares = managed_position::position_shares(&bob_position);
        let payout = managed_position::authorize_owner_exit_for_testing<SUI>(
            &mut source,
            &mut bob_position,
            bob_shares,
            ts::ctx(&mut scenario),
        );
        let (_, _, bob_destination, _, _, _, bob_assets) =
            managed_position::consume_owner_payout_for_testing(payout);
        assert!(bob_destination == BOB, 54);
        assert!(bob_assets == 1_999_999_999, 55);
        // The incumbent retains the net-of-fee value; Bob did not absorb any
        // part of the exact 200m waterfall.
        assert!(managed_position::position_value_micros(&source, &alice_position) == 1_799_999_201, 56);

        ts::next_tx(&mut scenario, ADAPTER);
        let net = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&net) == 1_800_000_000, 57);
        coin::burn_for_testing(net);
        ts::next_tx(&mut scenario, LEAD_FEES);
        let lead_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&lead_fee) == 150_000_000, 58);
        coin::burn_for_testing(lead_fee);
        ts::next_tx(&mut scenario, DAY_FEES);
        let day_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&day_fee) == 50_000_000, 59);
        coin::burn_for_testing(day_fee);
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 31, location = day::managed_position)]
    fun managed_subscription_rejects_uncrystallized_gain() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let _alice_position = deposit_and_deploy(&mut accounting, 100, ctx);
        let basis = managed_position::begin_measured_reallocation(&mut accounting, 10_000);
        managed_position::apply_measured_reallocation(&mut accounting, basis, 120);
        let _bob_position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting, false, 100, ctx,
        );
        abort 999
    }

    #[test]
    #[expected_failure(abort_code = 31, location = day::managed_position)]
    fun managed_subscription_rejects_incumbent_drawdown() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"dayop-source", ctx);
        let _alice_position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);

        // Alice's aggregate fee basis remains 100m while authenticated NAV is
        // only 80m. Bob may not inherit that 20m loss carry-forward.
        let basis = managed_position::begin_measured_reallocation(&mut accounting, 10_000);
        managed_position::apply_measured_reallocation(&mut accounting, basis, 80_000_000);
        let _bob_position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            false,
            80_000_000,
            ctx,
        );
        abort 999
    }

    #[test]
    fun zero_fee_managed_subscription_does_not_need_fee_epoch_equalization() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed_with_fee(b"dayop-source", STRATEGY, 0, ctx);
        let alice_position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);
        let basis = managed_position::begin_measured_reallocation(&mut accounting, 10_000);
        managed_position::apply_measured_reallocation(&mut accounting, basis, 80_000_000);

        ts::next_tx(&mut scenario, BOB);
        let bob_position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            &mut accounting,
            false,
            80_000_000,
            ts::ctx(&mut scenario),
        );
        assert!(managed_position::position_shares(&bob_position) > 0, 90);
        assert!(managed_position::position_value_micros(&accounting, &bob_position) >= 79_999_999, 91);

        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun authenticated_reallocation_exit_crystallizes_20_percent_fee_before_payout() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let mut position = deposit_and_deploy(&mut source, 100_000_000, ctx);
        let state_id = reserve_reallocation(&mut source, &destination, 10_000, ctx);

        let inbound = managed_position::attest_adapter_return_for_testing(
            &source,
            &AdapterWitness {},
            state_id,
            option::some(coin::mint_for_testing<SUI>(120_000_000, ctx)),
        );
        ts::next_tx(&mut scenario, ALICE);
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, inbound,
        );

        ts::next_tx(&mut scenario, ADAPTER);
        transfer::public_transfer(ts::take_from_sender<Coin<SUI>>(&scenario), ALICE);
        ts::next_tx(&mut scenario, ALICE);
        let returned = ts::take_from_sender<Coin<SUI>>(&scenario);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(returned),
        );
        let authenticated = managed_reallocation::finalize_destination_return(
            &mut state, &mut source, &mut destination, receipt,
        );
        let assessment = managed_closeout::crystallize_and_settle_reallocation_exit(
            &mut source,
            &mut position,
            100_000_000,
            authenticated,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::fee_profit_micros(&assessment) == 20_000_000, 60);
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 4_000_000, 61);
        assert!(managed_closeout::fee_lead_micros(&assessment) == 3_000_000, 62);
        assert!(managed_closeout::fee_day_micros(&assessment) == 1_000_000, 63);
        assert!(managed_position::position_shares(&position) == 0, 64);
        assert!(managed_position::total_assets_micros(&source) == 0, 65);
        managed_reallocation::destroy_for_testing(state);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 116_000_000, 66);
        coin::burn_for_testing(payout);
        ts::next_tx(&mut scenario, LEAD_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        ts::next_tx(&mut scenario, DAY_FEES);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        ts::next_tx(&mut scenario, ADAPTER);
        coin::burn_for_testing(ts::take_from_sender<Coin<SUI>>(&scenario));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    fun sequential_partial_exits_do_not_recreate_profit_after_crystallization() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let mut position = deposit_and_deploy(&mut source, 100_000_000, ctx);
        let state_id = reserve_reallocation(&mut source, &destination, 10_000, ctx);
        let inbound = managed_position::attest_adapter_return_for_testing(
            &source,
            &AdapterWitness {},
            state_id,
            option::some(coin::mint_for_testing<SUI>(120_000_000, ctx)),
        );
        ts::next_tx(&mut scenario, ALICE);
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, inbound,
        );
        ts::next_tx(&mut scenario, ADAPTER);
        transfer::public_transfer(ts::take_from_sender<Coin<SUI>>(&scenario), ALICE);
        ts::next_tx(&mut scenario, ALICE);
        let returned = ts::take_from_sender<Coin<SUI>>(&scenario);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &destination,
            &AdapterWitness {},
            state_id,
            option::some(returned),
        );
        let authenticated = managed_reallocation::finalize_destination_return(
            &mut state, &mut source, &mut destination, receipt,
        );
        let assessment = managed_closeout::crystallize_and_settle_reallocation_exit(
            &mut source,
            &mut position,
            50_000_000,
            authenticated,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::fee_lead_pool_micros(&assessment) == 4_000_000, 70);
        assert!(managed_position::position_shares(&position) == 50_000_000, 71);
        assert!(managed_position::total_assets_micros(&source) == 58_000_080, 72);
        assert!(managed_position::position_value_micros(&source, &position) == 57_999_920, 73);
        managed_reallocation::destroy_for_testing(state);

        // The remaining basis uses the same virtual-offset debit as assets, so
        // the second exit sees no fabricated gain, needs no second fee, and is
        // not blocked by the managed crystallization guard.
        ts::next_tx(&mut scenario, ADAPTER);
        transfer::public_transfer(ts::take_from_sender<Coin<SUI>>(&scenario), ALICE);
        ts::next_tx(&mut scenario, ALICE);
        let remaining = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&remaining) == 58_000_080, 74);
        managed_position::settle_owner_exit(
            &mut source,
            &mut position,
            50_000_000,
            remaining,
            ts::ctx(&mut scenario),
        );
        assert!(managed_position::position_shares(&position) == 0, 75);
        assert!(managed_position::total_assets_micros(&source) == 0, 76);

        ts::next_tx(&mut scenario, ALICE);
        let mut total_payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        coin::join(&mut total_payout, ts::take_from_sender<Coin<SUI>>(&scenario));
        assert!(coin::value(&total_payout) == 116_000_000, 77);
        coin::burn_for_testing(total_payout);
        ts::next_tx(&mut scenario, LEAD_FEES);
        let lead_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&lead_fee) == 3_000_000, 78);
        coin::burn_for_testing(lead_fee);
        ts::next_tx(&mut scenario, DAY_FEES);
        let day_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&day_fee) == 1_000_000, 79);
        coin::burn_for_testing(day_fee);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    #[test]
    fun production_reallocation_authenticated_none_derives_total_loss() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut source = managed(b"dayop-source", ctx);
        let mut destination = managed(b"dayop-destination", ctx);
        let source_position = deposit_and_deploy(&mut source, 10, ctx);
        let state_id = reserve_reallocation(
            &mut source, &destination, 10_000, ctx,
        );
        ts::next_tx(&mut scenario, ALICE);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &source, &AdapterWitness {}, state_id, option::none(),
        );
        let mut state = ts::take_shared<managed_reallocation::ReallocationState<SUI>>(&scenario);
        managed_reallocation::finalize_reallocation(
            &mut state, &mut source, &mut destination, receipt,
        );
        assert!(managed_reallocation::realized_loss_micros(&state) == 10, 20);
        assert!(managed_position::total_assets_micros(&source) == 0, 21);
        assert!(managed_position::total_assets_micros(&destination) == 0, 22);
        managed_reallocation::destroy_for_testing(state);
        managed_position::destroy_position_for_testing(source_position);
        managed_position::destroy_accounting_for_testing(source);
        managed_position::destroy_accounting_for_testing(destination);
        ts::end(scenario);
    }

    // ─── DAY-911 ─────────────────────────────────────────────────────────────

    /// Reproduction (#1): the legacy public(package) shells still abort 17, so a
    /// caller that only knows the pre-consent ABI cannot fund a pot. After the
    /// fix, the additive public surface is the only production path (next test).
    #[test]
    #[expected_failure(abort_code = 17, location = day::managed_closeout)]
    fun day911_legacy_prepare_still_unreachable_abort_17() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let accounting = managed(b"day911-legacy", ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let _pot = managed_closeout::prepare_frozen_exit_pot<SUI>(
            &accounting, 301_000, &test_clock, ctx,
        );
        abort 999
    }

    /// DAY-911 restore of `frozen_managed_exit_charges_gain_before_funding_owner_claim`
    /// on the consent path: public owner surface + nested fee waterfall.
    /// Alice consents 100m, adapter returns 120m → lead 3m + day 1m, Alice 100m
    /// frozen claim, 16m surplus dust to adapter dest (not socialized as fee skip).
    #[test]
    fun frozen_managed_exit_charges_gain_before_funding_owner_claim() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"day911-fees", ctx);
        let mut alice_position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);
        let bob_position = deposit_and_deploy(&mut accounting, 100_000_000, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);

        let pot_id = managed_closeout::owner_prepare_frozen_exit_with_consent<SUI>(
            &mut accounting,
            &mut alice_position,
            100_000_000,
            301_000,
            &test_clock,
            ctx,
        );
        assert!(managed_position::position_shares(&alice_position) == 0, 110);
        assert!(managed_position::position_value_micros(&accounting, &bob_position) == 100_000_000, 111);
        assert!(managed_position::total_assets_micros(&accounting) == 100_000_000, 112);
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &AdapterWitness {},
            pot_id,
            option::some(coin::mint_for_testing<SUI>(120_000_000, ts::ctx(&mut scenario))),
        );
        let claim_id = managed_closeout::owner_fund_frozen_exit_from_consent(
            &mut accounting,
            &mut pot,
            &mut alice_position,
            receipt,
            ts::ctx(&mut scenario),
        );
        assert!(managed_closeout::frozen_exit_pot_pps(&pot) == 1_000_000, 113);
        clock::set_for_testing(&mut test_clock, 301_001);
        assert!(managed_closeout::settle_frozen_exit_claim(
            &mut pot, claim_id, &test_clock, ts::ctx(&mut scenario),
        ) == 100_000_000, 114);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 100_000_000, 115);
        coin::burn_for_testing(payout);
        ts::next_tx(&mut scenario, LEAD_FEES);
        let lead_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&lead_fee) == 3_000_000, 116);
        coin::burn_for_testing(lead_fee);
        ts::next_tx(&mut scenario, DAY_FEES);
        let day_fee = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&day_fee) == 1_000_000, 117);
        coin::burn_for_testing(day_fee);
        // Surplus after owner claim + fees: 120 - 100 - 4 = 16m coin to adapter
        // dest AND credited onto the remaining-leg ledger (Bob holds 100% of it).
        ts::next_tx(&mut scenario, ADAPTER);
        let dust = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&dust) == 16_000_000, 118);
        coin::burn_for_testing(dust);
        // Dust is credited to remaining-leg deployed assets. Virtual-offset floor
        // means Bob's convertible value is just under 116m, never below his 100m.
        assert!(managed_position::total_assets_micros(&accounting) == 116_000_000, 119);
        assert!(managed_position::position_value_micros(&accounting, &bob_position) >= 100_000_000, 120);
        assert!(managed_position::position_value_micros(&accounting, &bob_position) < 116_000_000, 121);
        managed_position::destroy_position_for_testing(alice_position);
        managed_position::destroy_position_for_testing(bob_position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    /// DAY-911 #3: authenticated underfund funds the pot with measured gross
    /// (no abort-17, no cancel-restore phantom). Ledger already removed the
    /// full frozen basis at consent; shortfall is real loss, not re-credited.
    #[test]
    fun consent_underfunded_adapter_return_pays_measured_gross_not_phantom() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"day911-loss", ctx);
        let mut alice = deposit_and_deploy(&mut accounting, 100, ctx);
        let bob = deposit_and_deploy(&mut accounting, 100, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let pot_id = managed_closeout::owner_prepare_frozen_exit_with_consent<SUI>(
            &mut accounting, &mut alice, 100, 301_000, &test_clock, ctx,
        );
        // Consent removed Alice's full frozen claim from the ledger.
        assert!(managed_position::total_assets_micros(&accounting) == 100, 300);
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let mut pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        // Adapter realizes 80 of the 100 reserved — real loss of 20.
        let receipt = managed_position::attest_adapter_return_for_testing(
            &accounting,
            &AdapterWitness {},
            pot_id,
            option::some(coin::mint_for_testing<SUI>(80, ts::ctx(&mut scenario))),
        );
        let claim_id = managed_closeout::owner_fund_frozen_exit_from_consent(
            &mut accounting, &mut pot, &mut alice, receipt, ts::ctx(&mut scenario),
        );
        clock::set_for_testing(&mut test_clock, 301_001);
        assert!(managed_closeout::settle_frozen_exit_claim(
            &mut pot, claim_id, &test_clock, ts::ctx(&mut scenario),
        ) == 80, 301);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let payout = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&payout) == 80, 302);
        coin::burn_for_testing(payout);
        // Bob still holds 100; no phantom 20 reappeared on the ledger.
        assert!(managed_position::total_assets_micros(&accounting) == 100, 303);
        assert!(managed_position::position_value_micros(&accounting, &bob) == 100, 304);
        assert!(!ts::has_most_recent_for_address<Coin<SUI>>(LEAD_FEES), 305);
        assert!(!ts::has_most_recent_for_address<Coin<SUI>>(DAY_FEES), 306);
        managed_position::destroy_position_for_testing(alice);
        managed_position::destroy_position_for_testing(bob);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    /// DAY-911: public cancel surface after deadline restores exact basis when
    /// no authenticated return ever arrived (R3 non-arrival only).
    #[test]
    fun owner_public_cancel_restores_basis_after_deadline() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = managed(b"day911-cancel", ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let mut test_clock = clock::create_for_testing(ctx);
        clock::set_for_testing(&mut test_clock, 1_000);
        let _pot_id = managed_closeout::owner_prepare_frozen_exit_with_consent<SUI>(
            &mut accounting, &mut position, 100, 301_000, &test_clock, ctx,
        );
        clock::share_for_testing(test_clock);

        ts::next_tx(&mut scenario, ALICE);
        let pot = ts::take_shared<managed_closeout::FrozenExitPot<SUI>>(&scenario);
        let mut test_clock = ts::take_shared<Clock>(&scenario);
        clock::set_for_testing(&mut test_clock, 301_001);
        managed_closeout::owner_cancel_frozen_exit_consent(
            &mut accounting, &pot, &mut position, &test_clock, ts::ctx(&mut scenario),
        );
        assert!(managed_position::position_shares(&position) == 100, 310);
        assert!(managed_position::total_assets_micros(&accounting) == 100, 311);
        managed_closeout::destroy_frozen_exit_pot_for_testing(pot);
        clock::destroy_for_testing(test_clock);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }
}
