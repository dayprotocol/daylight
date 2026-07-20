// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day::managed_cetus_exit_tests {
    use day::managed_cetus_exit::{Self, CetusTop30Adapter, ManagedCetusClaim};
    use day::managed_position::{Self, OpportunityAccounting, Position};
    use std::type_name::{Self, TypeName};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario as ts;

    const ALICE: address = @0xA11CE;
    const BOB: address = @0xB0B;
    const TOP_30D: vector<u8> = b"day-autopilot-top-30d-monthly";
    const CETUS_5BPS: vector<u8> = b"dayope3465f1716";

    public struct SecondaryAsset has drop {}
    public struct FutureRewardX has drop {}

    /// Models Cetus's non-generic Position: the reward identity is runtime
    /// metadata, not a type parameter that emergency exit must instantiate.
    public struct MockCetusPosition has key, store {
        id: UID,
        runtime_reward_type: TypeName,
        funded: bool,
    }

    fun new_mock<Reward>(funded: bool, ctx: &mut TxContext): MockCetusPosition {
        MockCetusPosition {
            id: object::new(ctx),
            runtime_reward_type: type_name::with_original_ids<Reward>(),
            funded,
        }
    }

    fun destroy_mock(position: MockCetusPosition) {
        let MockCetusPosition { id, runtime_reward_type: _, funded: _ } = position;
        object::delete(id)
    }

    fun assert_future_reward(position: &MockCetusPosition, funded: bool) {
        assert!(position.runtime_reward_type == type_name::with_original_ids<FutureRewardX>(), 1);
        assert!(position.funded == funded, 2);
    }

    fun new_accounting(ctx: &mut TxContext): OpportunityAccounting {
        managed_position::new_policy_bound_accounting_for_testing<CetusTop30Adapter, SUI>(
            CETUS_5BPS,
            object::id_from_address(@0x57A7E6),
            TOP_30D,
            object::id_from_address(@0x6A4D),
            x"1111111111111111111111111111111111111111111111111111111111111111",
            ctx,
        )
    }

    fun deposit_and_deploy(
        accounting: &mut OpportunityAccounting,
        amount: u64,
        ctx: &mut TxContext,
    ): Position {
        let position = managed_position::record_managed_local_deposit_for_testing<SUI>(
            accounting,
            false,
            amount as u128,
            ctx,
        );
        let witness = managed_cetus_exit::witness_for_testing();
        let receipt = managed_position::attest_adapter_deployment_for_testing(
            accounting,
            &witness,
            coin::mint_for_testing<SUI>(amount, ctx),
        );
        coin::burn_for_testing(managed_position::record_measured_deployment(accounting, receipt));
        position
    }

    fun claim(
        accounting: &OpportunityAccounting,
        position: &Position,
        amount: u128,
        funded: bool,
        ctx: &mut TxContext,
    ): ManagedCetusClaim<SUI, MockCetusPosition> {
        managed_cetus_exit::bind_claim_for_testing(
            accounting,
            position,
            amount,
            new_mock<FutureRewardX>(funded, ctx),
            ctx,
        )
    }

    #[test]
    fun normal_exit_transfers_both_assets_and_residual_only_to_owner() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 100, false, ctx);

        managed_cetus_exit::normal_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            coin::mint_for_testing<SUI>(91, ctx),
            coin::mint_for_testing<SecondaryAsset>(7, ctx),
            ctx,
        );
        assert!(managed_position::total_assets_micros(&accounting) == 0, 10);
        assert!(managed_position::deployed_assets_micros(&accounting) == 0, 11);
        assert!(managed_position::total_shares(&accounting) == 0, 12);
        assert!(managed_position::fee_basis_assets_micros_for_package(&accounting) == 0, 121);
        assert!(managed_position::position_shares(&position) == 0, 13);
        assert!(managed_position::adapter_nonce_for_testing(&accounting) == 2, 14);

        ts::next_tx(&mut scenario, ALICE);
        let principal = ts::take_from_sender<Coin<SUI>>(&scenario);
        let secondary = ts::take_from_sender<Coin<SecondaryAsset>>(&scenario);
        let residual = ts::take_from_sender<MockCetusPosition>(&scenario);
        assert!(coin::value(&principal) == 91, 15);
        assert!(coin::value(&secondary) == 7, 16);
        assert_future_reward(&residual, false);
        coin::burn_for_testing(principal);
        coin::burn_for_testing(secondary);
        destroy_mock(residual);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun emergency_exit_returns_funded_nft_with_unknown_runtime_reward() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 100, true, ctx);

        // No Pool, GlobalConfig, Clock, registry, guardrails, policy, reward
        // vault, reward type, recipient, or output Coin is accepted here.
        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            ctx,
        );
        assert!(managed_position::total_assets_micros(&accounting) == 0, 20);
        assert!(managed_position::deployed_assets_micros(&accounting) == 0, 21);
        assert!(managed_position::position_shares(&position) == 0, 22);

        ts::next_tx(&mut scenario, ALICE);
        let residual = ts::take_from_sender<MockCetusPosition>(&scenario);
        assert_future_reward(&residual, true);
        destroy_mock(residual);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun crossed_price_zero_usdc_nonzero_secondary_is_honest_in_kind_exit() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 100, true, ctx);
        managed_cetus_exit::normal_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            coin::mint_for_testing<SUI>(0, ctx),
            coin::mint_for_testing<SecondaryAsset>(88, ctx),
            ctx,
        );
        assert!(managed_position::total_assets_micros(&accounting) == 0, 23);
        assert!(managed_position::fee_basis_assets_micros_for_package(&accounting) == 0, 24);
        ts::next_tx(&mut scenario, ALICE);
        let principal = ts::take_from_sender<Coin<SUI>>(&scenario);
        let secondary = ts::take_from_sender<Coin<SecondaryAsset>>(&scenario);
        assert!(coin::value(&principal) == 0, 25);
        assert!(coin::value(&secondary) == 88, 26);
        coin::burn_for_testing(principal);
        coin::burn_for_testing(secondary);
        destroy_mock(ts::take_from_sender<MockCetusPosition>(&scenario));
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    fun historical_deploy_nonce_does_not_block_exit_after_later_deposit() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut first = deposit_and_deploy(&mut accounting, 100, ctx);
        let first_claim = claim(&accounting, &first, 100, true, ctx);
        assert!(managed_position::adapter_nonce_for_testing(&accounting) == 1, 30);
        let second = deposit_and_deploy(&mut accounting, 50, ctx);
        assert!(managed_position::adapter_nonce_for_testing(&accounting) == 2, 31);

        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut first,
            first_claim,
            ctx,
        );
        assert!(managed_position::adapter_nonce_for_testing(&accounting) == 3, 32);
        assert!(managed_position::total_assets_micros(&accounting) == 50, 33);
        assert!(managed_position::deployed_assets_micros(&accounting) == 50, 34);
        assert!(managed_position::total_shares(&accounting) == 50, 35);
        assert!(managed_position::position_shares(&second) == 50, 36);

        ts::next_tx(&mut scenario, ALICE);
        destroy_mock(ts::take_from_sender<MockCetusPosition>(&scenario));
        managed_position::destroy_position_for_testing(first);
        managed_position::destroy_position_for_testing(second);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = managed_position::E_NOT_DEPOSITOR)]
    fun wrong_sender_cannot_redirect_emergency_exit() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 100, true, ctx);
        ts::next_tx(&mut scenario, BOB);
        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            ts::ctx(&mut scenario),
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = managed_cetus_exit::E_WRONG_POSITION)]
    fun claim_cannot_be_applied_to_another_day_position() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let first = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &first, 100, true, ctx);
        let mut second = deposit_and_deploy(&mut accounting, 50, ctx);
        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut second,
            claim,
            ctx,
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = managed_cetus_exit::E_WRONG_ACCOUNTING)]
    fun claim_cannot_be_applied_to_another_accounting() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut first_accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut first_accounting, 100, ctx);
        let claim = claim(&first_accounting, &position, 100, true, ctx);
        let mut second_accounting = new_accounting(ctx);
        managed_cetus_exit::emergency_exit_for_testing(
            &mut second_accounting,
            &mut position,
            claim,
            ctx,
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = managed_cetus_exit::E_WRONG_POSITION)]
    fun changed_partial_position_shares_reject_full_claim() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 100, true, ctx);
        managed_position::set_position_shares_for_testing(&mut position, 50);
        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            ctx,
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = managed_cetus_exit::E_WRONG_POSITION)]
    fun zero_share_replay_state_rejects_claim() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 100, true, ctx);
        managed_position::set_position_shares_for_testing(&mut position, 0);
        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            ctx,
        );
        abort 99
    }

    #[test]
    #[expected_failure(abort_code = managed_cetus_exit::E_WRONG_ACCOUNTING)]
    fun exact_stored_cost_basis_is_required() {
        let mut scenario = ts::begin(ALICE);
        let ctx = ts::ctx(&mut scenario);
        let mut accounting = new_accounting(ctx);
        let mut position = deposit_and_deploy(&mut accounting, 100, ctx);
        let claim = claim(&accounting, &position, 99, true, ctx);
        managed_cetus_exit::emergency_exit_for_testing(
            &mut accounting,
            &mut position,
            claim,
            ctx,
        );
        abort 99
    }
}
