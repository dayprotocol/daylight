// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-824 / DAY-829 / DAY-831 adversarial regression proofs.
#[test_only]
module day::yield_router_security_tests {
    use day::adapter_registry::{Self, AdapterRegistry, AdapterRegistryV2};
    use day::managed_position::{Self, OpportunityAccounting, Position};
    use day::yield_router;
    use sui::coin;
    use sui::test_scenario as ts;

    public struct TEST_COIN has drop {}

    const OWNER: address = @0x0BE4;
    const KEEPER: address = @0xC0DE;
    const GOVERNANCE: address = @0xA11CE;
    const TREASURY_DEPLOYER: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;
    const ADAPTER: vector<u8> = b"suilend";
    const AMOUNT: u64 = 1_000_000;

    fun bootstrap_active_registry(scn: &mut ts::Scenario, admin: address) {
        adapter_registry::bootstrap_registry_v2_for_testing(admin, ts::ctx(scn));
        ts::next_tx(scn, admin);
        let cap = ts::take_from_sender<adapter_registry::RegistryAdminCap>(scn);
        let mut registry = ts::take_shared<AdapterRegistryV2>(scn);
        adapter_registry::register_authenticated(
            &cap,
            &mut registry,
            ADAPTER,
            b"sui",
            b"Suilend",
        );
        ts::return_to_sender(scn, cap);
        ts::return_shared(registry);
        ts::next_tx(scn, admin);
    }

    fun position_for_owner(ctx: &mut TxContext): (OpportunityAccounting, Position) {
        let mut accounting = managed_position::new_accounting_for_testing<TEST_COIN>(
            b"test-opportunity",
            b"sui",
            ctx,
        );
        let position = managed_position::record_local_deposit_for_testing<TEST_COIN>(
            &mut accounting,
            option::none<ID>(),
            option::none<ID>(),
            AMOUNT as u128,
            ctx,
        );
        (accounting, position)
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_AUTHENTICATED_PLAN_REQUIRED)]
    fun test_legacy_deposit_event_entry_fails_closed() {
        let mut scn = ts::begin(KEEPER);
        adapter_registry::create(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, KEEPER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let registry = ts::take_shared<AdapterRegistry>(&scn);
        yield_router::plan_deposit(&router, &registry, ADAPTER, AMOUNT, OWNER, false);
        ts::return_shared(registry);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_AUTHENTICATED_PLAN_REQUIRED)]
    fun test_legacy_withdraw_event_entry_fails_closed() {
        let mut scn = ts::begin(KEEPER);
        adapter_registry::create(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, KEEPER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let registry = ts::take_shared<AdapterRegistry>(&scn);
        yield_router::plan_withdraw(&router, &registry, ADAPTER, AMOUNT, OWNER);
        ts::return_shared(registry);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_AUTHENTICATED_PLAN_REQUIRED)]
    fun test_legacy_harvest_event_entry_fails_closed() {
        let mut scn = ts::begin(KEEPER);
        adapter_registry::create(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, KEEPER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let registry = ts::take_shared<AdapterRegistry>(&scn);
        yield_router::plan_harvest_skim(&router, &registry, ADAPTER, AMOUNT, OWNER);
        ts::return_shared(registry);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_NOT_OWNER)]
    fun test_v2_deposit_rejects_forged_owner() {
        let mut scn = ts::begin(KEEPER);
        bootstrap_active_registry(&mut scn, KEEPER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let registry = ts::take_shared<AdapterRegistryV2>(&scn);
        yield_router::plan_deposit_v2(
            &router,
            &registry,
            ADAPTER,
            AMOUNT,
            OWNER,
            false,
            ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    fun test_v2_deposit_accepts_authenticated_owner() {
        let mut scn = ts::begin(OWNER);
        bootstrap_active_registry(&mut scn, OWNER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let registry = ts::take_shared<AdapterRegistryV2>(&scn);
        yield_router::plan_deposit_v2(
            &router,
            &registry,
            ADAPTER,
            AMOUNT,
            OWNER,
            false,
            ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_WRONG_ROUTER)]
    fun test_non_admin_cap_cannot_pause_foreign_router() {
        let mut ctx = tx_context::new_from_hint(GOVERNANCE, 4, 0, 0, 0);
        let mut authorized_router = yield_router::new_router_for_testing(&mut ctx);
        let cap = yield_router::bootstrap_router_admin_for_testing(
            &mut authorized_router,
            GOVERNANCE,
            &mut ctx,
        );
        let mut foreign_router = yield_router::new_router_for_testing(&mut ctx);
        yield_router::set_paused(&cap, &mut foreign_router, true);
        yield_router::destroy_for_testing(foreign_router);
        yield_router::destroy_router_admin_cap_for_testing(cap);
        yield_router::destroy_for_testing(authorized_router);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_INVALID_GOVERNANCE_RECIPIENT)]
    fun test_router_admin_rejects_deployer_treasury_recipient() {
        let mut ctx = tx_context::new_from_hint(GOVERNANCE, 5, 0, 0, 0);
        let mut router = yield_router::new_router_for_testing(&mut ctx);
        let cap = yield_router::bootstrap_router_admin_for_testing(
            &mut router,
            TREASURY_DEPLOYER,
            &mut ctx,
        );
        yield_router::destroy_router_admin_cap_for_testing(cap);
        yield_router::destroy_for_testing(router);
    }

    #[test]
    fun test_owner_withdraw_intent_succeeds_while_paused() {
        let mut scn = ts::begin(OWNER);
        bootstrap_active_registry(&mut scn, OWNER);
        let mut router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let cap = yield_router::bootstrap_router_admin_for_testing(
            &mut router,
            GOVERNANCE,
            ts::ctx(&mut scn),
        );
        yield_router::set_paused(&cap, &mut router, true);
        assert!(yield_router::is_paused(&router), 0);

        let registry = ts::take_shared<AdapterRegistryV2>(&scn);
        yield_router::plan_withdraw_authenticated_v2(
            &router,
            &registry,
            ADAPTER,
            AMOUNT,
            OWNER,
            ts::ctx(&mut scn),
        );

        ts::return_shared(registry);
        yield_router::destroy_router_admin_cap_for_testing(cap);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_STRATEGY_OFF)]
    fun test_pause_blocks_new_deposit() {
        let mut scn = ts::begin(OWNER);
        bootstrap_active_registry(&mut scn, OWNER);
        let mut router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let cap = yield_router::bootstrap_router_admin_for_testing(
            &mut router,
            GOVERNANCE,
            ts::ctx(&mut scn),
        );
        yield_router::set_paused(&cap, &mut router, true);
        let registry = ts::take_shared<AdapterRegistryV2>(&scn);
        yield_router::plan_deposit_v2(
            &router,
            &registry,
            ADAPTER,
            AMOUNT,
            OWNER,
            false,
            ts::ctx(&mut scn),
        );
        ts::return_shared(registry);
        yield_router::destroy_router_admin_cap_for_testing(cap);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::yield_router::E_RECORDED_POSITION_REQUIRED)]
    fun test_legacy_sender_derived_fee_split_fails_closed() {
        let mut ctx = tx_context::new_from_hint(KEEPER, 8, 0, 0, 0);
        let config = yield_router::new_config_for_testing(100, 10_000_000, false, GOVERNANCE, &mut ctx);
        let funds = coin::mint_for_testing<TEST_COIN>(AMOUNT, &mut ctx);
        yield_router::split_and_forward_fee<TEST_COIN>(
            &config,
            funds,
            ADAPTER,
            0,
            &mut ctx,
        );
        yield_router::destroy_config_for_testing(config);
    }

    /// A keeper cannot consume another owner's position even when it supplies
    /// an exact-value Coin. Authorization comes from the Position owner.
    #[test]
    #[expected_failure(abort_code = day::managed_position::E_NOT_DEPOSITOR)]
    fun test_keeper_cannot_redirect_position_bound_payout() {
        let mut scn = ts::begin(OWNER);
        let (mut accounting, mut position) = position_for_owner(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, KEEPER);
        let funds = coin::mint_for_testing<TEST_COIN>(AMOUNT, ts::ctx(&mut scn));
        yield_router::settle_position_owner_exit<TEST_COIN>(
            &mut accounting,
            &mut position,
            AMOUNT as u128,
            funds,
            ts::ctx(&mut scn),
        );
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scn);
    }

    #[test]
    fun test_owner_settlement_pays_recorded_position_destination() {
        let mut scn = ts::begin(OWNER);
        let (mut accounting, mut position) = position_for_owner(ts::ctx(&mut scn));
        let funds = coin::mint_for_testing<TEST_COIN>(AMOUNT, ts::ctx(&mut scn));
        yield_router::settle_position_owner_exit<TEST_COIN>(
            &mut accounting,
            &mut position,
            AMOUNT as u128,
            funds,
            ts::ctx(&mut scn),
        );
        assert!(managed_position::position_shares(&position) == 0, 0);
        assert!(managed_position::total_assets_micros(&accounting) == 0, 1);
        ts::next_tx(&mut scn, OWNER);
        let paid = ts::take_from_sender<coin::Coin<TEST_COIN>>(&scn);
        assert!(coin::value(&paid) == AMOUNT, 2);
        coin::burn_for_testing(paid);
        managed_position::destroy_position_for_testing(position);
        managed_position::destroy_accounting_for_testing(accounting);
        ts::end(scn);
    }
}
