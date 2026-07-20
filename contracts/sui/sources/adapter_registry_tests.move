// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-821 regression proofs for the shared Sui adapter registry.
#[test_only]
module day::adapter_registry_tests {
    use day::adapter_registry::{Self, AdapterRegistry, AdapterRegistryV2, RegistryAdminCap};
    use day::day::{Self as protocol};
    use day::yield_router;
    use sui::package;
    use sui::test_scenario as ts;

    const ADMIN: address = @0xA11CE;
    const REPLACEMENT_ADMIN: address = @0xB0B;
    const ATTACKER: address = @0xBAD;
    const OWNER: address = @0x0BE4;
    const DAY_AUTHORITY: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;
    const ADAPTER: vector<u8> = b"suilend";
    fun create_registry_v2(scn: &mut ts::Scenario) {
        adapter_registry::bootstrap_registry_v2_for_testing(ADMIN, ts::ctx(scn));
        ts::next_tx(scn, ADMIN);
    }

    fun register_as_admin(scn: &mut ts::Scenario) {
        let cap = ts::take_from_sender<RegistryAdminCap>(scn);
        let mut reg = ts::take_shared<AdapterRegistryV2>(scn);
        adapter_registry::register_authenticated(&cap, &mut reg, ADAPTER, b"sui", b"Suilend");
        ts::return_to_sender(scn, cap);
        ts::return_shared(reg);
        ts::next_tx(scn, ADMIN);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_legacy_register_always_aborts() {
        let mut scn = ts::begin(ATTACKER);
        adapter_registry::create(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, ATTACKER);
        let mut reg = ts::take_shared<AdapterRegistry>(&scn);
        adapter_registry::register(&mut reg, ADAPTER, b"sui", b"Suilend");
        ts::return_shared(reg);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_legacy_set_active_always_aborts() {
        let mut scn = ts::begin(ADMIN);
        adapter_registry::create(ts::ctx(&mut scn));
        ts::next_tx(&mut scn, ADMIN);
        let mut reg = ts::take_shared<AdapterRegistry>(&scn);
        adapter_registry::set_active(&mut reg, ADAPTER, false);
        ts::return_shared(reg);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_WRONG_UPGRADE_CAP)]
    fun test_bootstrap_rejects_noncanonical_upgrade_cap() {
        let mut scn = ts::begin(ATTACKER);
        let mut config = protocol::new_config_for_testing(ts::ctx(&mut scn));
        let fake_cap = package::test_publish(object::id_from_address(@0xBAD), ts::ctx(&mut scn));
        adapter_registry::bootstrap_registry_v2(
            &mut config,
            &fake_cap,
            ATTACKER,
            ts::ctx(&mut scn),
        );
        transfer::public_transfer(fake_cap, ATTACKER);
        protocol::destroy_config_for_testing(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_INVALID_GOVERNANCE_RECIPIENT)]
    fun test_bootstrap_rejects_treasury_as_admin_recipient() {
        let mut scn = ts::begin(DAY_AUTHORITY);
        adapter_registry::bootstrap_registry_v2_for_testing(
            DAY_AUTHORITY,
            ts::ctx(&mut scn),
        );
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_ALREADY_BOOTSTRAPPED)]
    fun test_registry_v2_bootstrap_is_one_shot_per_protocol_config() {
        let mut scn = ts::begin(ADMIN);
        let mut config = protocol::new_config_for_testing(ts::ctx(&mut scn));
        adapter_registry::bootstrap_registry_v2_with_config_for_testing(
            &mut config,
            ADMIN,
            ts::ctx(&mut scn),
        );
        adapter_registry::bootstrap_registry_v2_with_config_for_testing(
            &mut config,
            ADMIN,
            ts::ctx(&mut scn),
        );
        protocol::destroy_config_for_testing(config);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = sui::test_scenario::EEmptyInventory)]
    fun test_non_owner_cannot_take_admin_cap() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);
        ts::next_tx(&mut scn, ATTACKER);
        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        ts::return_to_sender(&mut scn, cap);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_ADMIN_CAP_REGISTRY_MISMATCH)]
    fun test_foreign_cap_cannot_register() {
        let mut ctx = tx_context::dummy();
        let registry_a = adapter_registry::create_v2_for_testing(&mut ctx);
        let mut registry_b = adapter_registry::create_v2_for_testing(&mut ctx);
        let cap = adapter_registry::create_admin_cap_for_testing(&registry_a, &mut ctx);
        adapter_registry::register_authenticated(
            &cap,
            &mut registry_b,
            ADAPTER,
            b"sui",
            b"Suilend",
        );
        adapter_registry::destroy_admin_cap_for_testing(cap);
        adapter_registry::destroy_v2_for_testing(registry_a);
        adapter_registry::destroy_v2_for_testing(registry_b);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_ADMIN_CAP_REGISTRY_MISMATCH)]
    fun test_foreign_cap_cannot_set_active() {
        let mut ctx = tx_context::dummy();
        let registry_a = adapter_registry::create_v2_for_testing(&mut ctx);
        let mut registry_b = adapter_registry::create_v2_for_testing(&mut ctx);
        let cap = adapter_registry::create_admin_cap_for_testing(&registry_a, &mut ctx);
        adapter_registry::set_active_authenticated(&cap, &mut registry_b, ADAPTER, false);
        adapter_registry::destroy_admin_cap_for_testing(cap);
        adapter_registry::destroy_v2_for_testing(registry_a);
        adapter_registry::destroy_v2_for_testing(registry_b);
    }

    #[test]
    fun test_admin_cap_can_register_and_toggle() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);

        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        let mut reg = ts::take_shared<AdapterRegistryV2>(&scn);
        adapter_registry::register_authenticated(&cap, &mut reg, ADAPTER, b"sui", b"Suilend");
        assert!(adapter_registry::count_v2(&reg) == 1, 0);
        assert!(adapter_registry::is_active_v2(&reg, ADAPTER), 1);

        adapter_registry::set_active_authenticated(&cap, &mut reg, ADAPTER, false);
        assert!(!adapter_registry::is_active_v2(&reg, ADAPTER), 2);
        adapter_registry::set_active_authenticated(&cap, &mut reg, ADAPTER, true);
        assert!(adapter_registry::is_active_v2(&reg, ADAPTER), 3);

        ts::return_to_sender(&mut scn, cap);
        ts::return_shared(reg);
        ts::end(scn);
    }

    #[test]
    fun test_admin_cap_transfer_rotates_control() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);

        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        adapter_registry::transfer_admin_cap(cap, REPLACEMENT_ADMIN);
        ts::next_tx(&mut scn, ADMIN);
        assert!(!ts::has_most_recent_for_sender<RegistryAdminCap>(&scn), 0);

        ts::next_tx(&mut scn, REPLACEMENT_ADMIN);
        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        let mut reg = ts::take_shared<AdapterRegistryV2>(&scn);
        adapter_registry::register_authenticated(&cap, &mut reg, ADAPTER, b"sui", b"Suilend");
        assert!(adapter_registry::is_active_v2(&reg, ADAPTER), 1);
        ts::return_to_sender(&mut scn, cap);
        ts::return_shared(reg);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_INVALID_GOVERNANCE_RECIPIENT)]
    fun test_admin_cap_cannot_rotate_to_treasury() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);
        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        adapter_registry::transfer_admin_cap(cap, DAY_AUTHORITY);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_retired_v2_generation_rejects_historical_mutators() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);
        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        let mut reg = ts::take_shared<AdapterRegistryV2>(&scn);
        adapter_registry::retire_v2(&cap, &mut reg);
        assert!(!adapter_registry::is_active_v2(&reg, ADAPTER), 9);
        adapter_registry::register_authenticated(&cap, &mut reg, ADAPTER, b"sui", b"Suilend");
        ts::return_to_sender(&mut scn, cap);
        ts::return_shared(reg);
        ts::end(scn);
    }

    #[test]
    fun test_cap_authorized_active_adapter_still_passes_router_gate() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);
        register_as_admin(&mut scn);

        ts::next_tx(&mut scn, OWNER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let reg = ts::take_shared<AdapterRegistryV2>(&scn);
        yield_router::plan_deposit_v2(
            &router, &reg, ADAPTER, 1_000_000, OWNER, false, ts::ctx(&mut scn),
        );
        ts::return_shared(reg);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    /// A legacy registry can claim the adapter is active, but V2 routing still fails
    /// closed because the old and new shared-object types are independent inputs.
    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_NOT_ALLOWLISTED)]
    fun test_legacy_registry_state_cannot_influence_v2_routing() {
        let mut scn = ts::begin(ADMIN);
        adapter_registry::create(ts::ctx(&mut scn));
        adapter_registry::bootstrap_registry_v2_for_testing(ADMIN, ts::ctx(&mut scn));
        ts::next_tx(&mut scn, ADMIN);

        let mut legacy = ts::take_shared<AdapterRegistry>(&scn);
        adapter_registry::legacy_register_for_testing(&mut legacy, ADAPTER, true);
        assert!(adapter_registry::is_active(&legacy, ADAPTER), 10);
        ts::return_shared(legacy);

        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let reg_v2 = ts::take_shared<AdapterRegistryV2>(&scn);
        assert!(adapter_registry::count_v2(&reg_v2) == 0, 11);
        yield_router::plan_deposit_v2(
            &router, &reg_v2, ADAPTER, 1_000_000, ADMIN, false, ts::ctx(&mut scn),
        );
        ts::return_shared(reg_v2);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_NOT_ALLOWLISTED)]
    fun test_disabled_adapter_still_fails_router_closed() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);
        register_as_admin(&mut scn);

        let cap = ts::take_from_sender<RegistryAdminCap>(&scn);
        let mut reg = ts::take_shared<AdapterRegistryV2>(&scn);
        adapter_registry::set_active_authenticated(&cap, &mut reg, ADAPTER, false);
        ts::return_to_sender(&mut scn, cap);
        ts::return_shared(reg);

        ts::next_tx(&mut scn, OWNER);
        let router = yield_router::new_router_for_testing(ts::ctx(&mut scn));
        let reg = ts::take_shared<AdapterRegistryV2>(&scn);
        yield_router::plan_deposit_v2(
            &router, &reg, ADAPTER, 1_000_000, OWNER, false, ts::ctx(&mut scn),
        );
        ts::return_shared(reg);
        yield_router::destroy_for_testing(router);
        ts::end(scn);
    }

    #[test]
    #[expected_failure(abort_code = day::adapter_registry::E_WRONG_ADAPTER_CHAIN)]
    fun test_active_adapter_rejects_foreign_spoke_chain() {
        let mut scn = ts::begin(ADMIN);
        create_registry_v2(&mut scn);
        register_as_admin(&mut scn);
        let reg = ts::take_shared<AdapterRegistryV2>(&scn);
        adapter_registry::assert_active_v2_on_chain(&reg, ADAPTER, b"solana");
        ts::return_shared(reg);
        ts::end(scn);
    }
}
