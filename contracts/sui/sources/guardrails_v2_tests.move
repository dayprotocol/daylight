// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-847 GuardrailsV2 typed, frozen Tier-1 policy tests.
#[test_only]
module day::guardrails_v2_tests {
    use day::guardrails_v2;
    use sui::sui::SUI;
    use sui::test_scenario as ts;

    #[test]
    fun test_native_asset_binding_fixed_bcs_and_sha256_vectors() {
        let sui = guardrails_v2::sui_asset_binding<SUI>();
        let sol = guardrails_v2::solana_asset_binding(
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        let evm = guardrails_v2::evm_asset_binding(
            b"base",
            x"0202020202020202020202020202020202020202",
        );
        let sui_bytes = guardrails_v2::native_asset_canonical_v1_bytes(&sui);
        let sol_bytes = guardrails_v2::native_asset_canonical_v1_bytes(&sol);
        let evm_bytes = guardrails_v2::native_asset_canonical_v1_bytes(&evm);
        assert!(sui_bytes == x"010103737569014a303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030323a3a7375693a3a53554900", 200);
        assert!(std::hash::sha2_256(sui_bytes)
            == x"fff76697ea511559c84a5e87ef3a74139f28359e43b98ebe1c5fb069bfbcd327", 201);
        assert!(sol_bytes == x"010206736f6c616e6100200101010101010101010101010101010101010101010101010101010101010101", 202);
        assert!(std::hash::sha2_256(sol_bytes)
            == x"d687970ff6667866dee7cdb0de81043db340d974550994b214df9994a65c31ed", 203);
        assert!(evm_bytes == x"0103046261736500140202020202020202020202020202020202020202", 204);
        assert!(std::hash::sha2_256(evm_bytes)
            == x"ce0458c07e95e3e353b99a6067ea8ea29dcd54fd8c0b560452baddc35edf4898", 205);
    }

    const LEAD: address = @0xA11CE;

    /// Distinct native types intentionally share a display-style suffix. GuardrailsV2
    /// authorizes the full original-package TypeName, never a caller-supplied symbol.
    public struct RealUsdc has drop {}
    public struct AlternateUsdc has drop {}
    public struct SpoofUsdc has drop {}

    fun complete_builder(ctx: &mut TxContext): guardrails_v2::GuardrailsV2Builder {
        let mut builder = guardrails_v2::new_builder(ctx);
        guardrails_v2::add_allowed_asset<RealUsdc>(&mut builder, ctx);
        guardrails_v2::add_allowed_asset<AlternateUsdc>(&mut builder, ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop0000000001", ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop0000000002", ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"sui", ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"solana", ctx);
        guardrails_v2::set_max_allocation_bps(&mut builder, 2500, ctx);
        builder
    }

    #[test]
    fun test_creation_hash_and_preimage_parity() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let expected_preimage = guardrails_v2::preview_preimage(&builder);
        let expected_hash = guardrails_v2::preview_hash(&builder);
        let g = guardrails_v2::finalize_for_testing(builder, expected_hash, &mut ctx);

        assert!(guardrails_v2::verify_hash(&g), 0);
        assert!(guardrails_v2::canonical_preimage(&g) == expected_preimage, 1);
        assert!(guardrails_v2::guardrails_hash(&g) == expected_hash, 2);
        assert!(guardrails_v2::matches_hash(&g, expected_hash), 3);
        assert!(guardrails_v2::schema_version(&g) == 2, 4);
        assert!(guardrails_v2::asset_type_count(&g) == 2, 5);
        assert!(guardrails_v2::opportunity_count(&g) == 2, 6);
        assert!(guardrails_v2::chain_count(&g) == 2, 7);
        assert!(guardrails_v2::max_allocation_bps(&g) == 2500, 8);
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_HASH_MISMATCH)]
    fun test_creation_rejects_wrong_hash() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let wrong = x"0000000000000000000000000000000000000000000000000000000000000000";
        let g = guardrails_v2::finalize_for_testing(builder, wrong, &mut ctx);
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_EMPTY_ASSET_ALLOWLIST)]
    fun test_creation_rejects_empty_policy() {
        let mut ctx = tx_context::dummy();
        let builder = guardrails_v2::new_builder(&mut ctx);
        let hash = guardrails_v2::preview_hash(&builder);
        let g = guardrails_v2::finalize_for_testing(builder, hash, &mut ctx);
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_OPPORTUNITY_ID)]
    fun test_rejects_protocol_slug_as_opportunity_id() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"suilend", &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_OPPORTUNITY_ID)]
    fun test_rejects_dashed_opportunity_id() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop0000-00000", &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_OPPORTUNITY_ID)]
    fun test_rejects_uppercase_opportunity_id() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop000000000A", &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_OPPORTUNITY_ID)]
    fun test_rejects_wrong_length_opportunity_id() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop000000001", &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_OPPORTUNITY_ID)]
    fun test_rejects_nonhex_opportunity_id() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_opportunity(&mut builder, b"dayop000000000g", &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_CHAIN_ID)]
    fun test_rejects_noncanonical_chain_id() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_chain(&mut builder, b"SUI", &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INVALID_ASSET_TYPE)]
    fun test_rejects_primitive_asset_type() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_asset<u64>(&mut builder, &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_DUPLICATE_ALLOWED_VALUE)]
    fun test_rejects_duplicate_allowed_value() {
        let mut ctx = tx_context::dummy();
        let mut builder = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_asset<RealUsdc>(&mut builder, &ctx);
        guardrails_v2::add_allowed_asset<RealUsdc>(&mut builder, &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_NOT_STRATEGY_LEAD)]
    fun test_non_lead_cannot_mutate_builder() {
        let mut lead_ctx = tx_context::new_from_hint(LEAD, 1, 0, 0, 0);
        let mut builder = guardrails_v2::new_builder(&mut lead_ctx);
        // TxContext test natives hold the active sender globally, so construct the
        // attacker's context only after the builder has captured LEAD.
        let attacker_ctx = tx_context::new_from_hint(@0xBAD, 2, 0, 0, 0);
        guardrails_v2::add_allowed_asset<RealUsdc>(&mut builder, &attacker_ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }

    #[test]
    fun test_canonical_preimage_is_independent_of_allowlist_insertion_order() {
        let mut ctx = tx_context::dummy();
        let forward = complete_builder(&mut ctx);

        let mut reverse = guardrails_v2::new_builder(&mut ctx);
        guardrails_v2::add_allowed_asset<AlternateUsdc>(&mut reverse, &ctx);
        guardrails_v2::add_allowed_asset<RealUsdc>(&mut reverse, &ctx);
        guardrails_v2::add_allowed_opportunity(&mut reverse, b"dayop0000000002", &ctx);
        guardrails_v2::add_allowed_opportunity(&mut reverse, b"dayop0000000001", &ctx);
        guardrails_v2::add_allowed_chain(&mut reverse, b"solana", &ctx);
        guardrails_v2::add_allowed_chain(&mut reverse, b"sui", &ctx);
        guardrails_v2::set_max_allocation_bps(&mut reverse, 2500, &ctx);

        let expected_preimage = guardrails_v2::preview_preimage(&forward);
        let expected_hash = guardrails_v2::preview_hash(&forward);
        assert!(expected_preimage == guardrails_v2::preview_preimage(&reverse), 0);
        assert!(expected_hash == guardrails_v2::preview_hash(&reverse), 1);

        let forward_g = guardrails_v2::finalize_for_testing(forward, expected_hash, &mut ctx);
        let reverse_g = guardrails_v2::finalize_for_testing(reverse, expected_hash, &mut ctx);
        assert!(
            guardrails_v2::canonical_preimage(&forward_g)
                == guardrails_v2::canonical_preimage(&reverse_g),
            2,
        );
        assert!(guardrails_v2::guardrails_hash(&forward_g) == guardrails_v2::guardrails_hash(&reverse_g), 3);
        guardrails_v2::destroy_for_testing(forward_g);
        guardrails_v2::destroy_for_testing(reverse_g);
    }

    #[test]
    fun test_supported_predicates_are_and_across_dimensions_or_within_sets() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let hash = guardrails_v2::preview_hash(&builder);
        let g = guardrails_v2::finalize_for_testing(builder, hash, &mut ctx);

        // Multiple values in one allowlist are alternatives, not impossible repeated ANDs.
        assert!(guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000001", b"sui", 2500), 0);
        assert!(guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000002", b"solana", 1), 1);
        assert!(guardrails_v2::allocation_allowed<AlternateUsdc>(&g, b"dayop0000000001", b"sui", 100), 2);

        // A failure in any independent dimension narrows the result to false.
        assert!(!guardrails_v2::allocation_allowed<SpoofUsdc>(&g, b"dayop0000000001", b"sui", 100), 3);
        assert!(!guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000003", b"sui", 100), 4);
        assert!(!guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000001", b"SUI", 100), 5);
        assert!(!guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000001", b"sui", 0), 6);
        assert!(!guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000001", b"sui", 2501), 7);
        guardrails_v2::assert_allocation_allowed<RealUsdc>(&g, b"dayop0000000002", b"solana", 2500);
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_ASSET_NOT_ALLOWED)]
    fun test_native_type_identity_resists_symbol_spoofing() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let hash = guardrails_v2::preview_hash(&builder);
        let g = guardrails_v2::finalize_for_testing(builder, hash, &mut ctx);
        guardrails_v2::assert_allocation_allowed<SpoofUsdc>(&g, b"dayop0000000001", b"sui", 100);
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_UNKNOWN_PREDICATE)]
    fun test_creation_rejects_unknown_predicate_tag() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let g = guardrails_v2::finalize_with_tags_for_testing(
            builder,
            vector[1, 2, 3, 255],
            &mut ctx,
        );
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_INCOMPLETE_PREDICATES)]
    fun test_creation_rejects_incomplete_predicates() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let g = guardrails_v2::finalize_with_tags_for_testing(builder, vector[1, 2, 3], &mut ctx);
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_DUPLICATE_PREDICATE)]
    fun test_creation_rejects_duplicate_predicate_tag() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let g = guardrails_v2::finalize_with_tags_for_testing(
            builder,
            vector[1, 2, 3, 3],
            &mut ctx,
        );
        guardrails_v2::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_UNKNOWN_PREDICATE)]
    fun test_evaluator_fails_closed_on_unknown_predicate_tag() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let g = guardrails_v2::forge_with_tags_for_testing(
            builder,
            vector[1, 2, 3, 255],
            &mut ctx,
        );
        let _ = guardrails_v2::allocation_allowed<RealUsdc>(&g, b"dayop0000000001", b"sui", 100);
        guardrails_v2::destroy_for_testing(g);
    }

    /// The published object is only retrievable through the immutable scenario API.
    /// GuardrailsV2 exposes no setter and the consumed builder cannot mutate it later.
    #[test]
    fun test_finalize_and_freeze_is_immutable_and_verifiable() {
        let mut scenario = ts::begin(LEAD);
        {
            let ctx = ts::ctx(&mut scenario);
            let builder = complete_builder(ctx);
            let expected_hash = guardrails_v2::preview_hash(&builder);
            let gid = guardrails_v2::finalize_and_freeze(builder, expected_hash, ctx);
            ts::next_tx(&mut scenario, LEAD);
            let g = ts::take_immutable_by_id<guardrails_v2::GuardrailsV2>(&scenario, gid);
            assert!(guardrails_v2::verify_hash(&g), 0);
            assert!(guardrails_v2::allocation_allowed<RealUsdc>(
                &g,
                b"dayop0000000001",
                b"sui",
                2500,
            ), 1);
            ts::return_immutable(g);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_native_asset_binding_is_canonical_chain_and_original_id_bound() {
        let sui = guardrails_v2::sui_asset_binding<RealUsdc>();
        let sol = guardrails_v2::solana_asset_binding(
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        let evm = guardrails_v2::evm_asset_binding(
            b"base",
            x"0202020202020202020202020202020202020202",
        );
        guardrails_v2::assert_native_asset_binding(&sui);
        guardrails_v2::assert_native_asset_binding(&sol);
        guardrails_v2::assert_native_asset_binding(&evm);
        assert!(guardrails_v2::native_asset_chain_id(&sui) == b"sui", 10);
        assert!(guardrails_v2::native_asset_chain_id(&sol) == b"solana", 11);
        assert!(guardrails_v2::native_asset_chain_id(&evm) == b"base", 12);
        let sui_bytes = guardrails_v2::native_asset_canonical_v1_bytes(&sui);
        assert!(sui_bytes != guardrails_v2::native_asset_canonical_v1_bytes(&sol), 13);
        assert!(sui_bytes != guardrails_v2::native_asset_canonical_v1_bytes(&evm), 14);
        assert!(!guardrails_v2::same_native_asset_binding(&sui, &sol), 15);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_UNKNOWN_ASSET_KIND)]
    fun test_native_asset_binding_unknown_tag_fails_closed() {
        let forged = guardrails_v2::forge_native_asset_binding_for_testing(
            1, 255, b"sui", option::none(), b"USDC",
        );
        let _ = guardrails_v2::native_asset_canonical_v1_bytes(&forged);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_MALFORMED_NATIVE_ASSET)]
    fun test_sui_symbol_bytes_are_not_a_type_name() {
        let forged = guardrails_v2::forge_native_asset_binding_for_testing(
            1, 1, b"sui", option::none(), b"USDC",
        );
        let _ = guardrails_v2::native_asset_chain_id(&forged);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_UNSUPPORTED_BINDING_SCHEMA)]
    fun test_native_asset_binding_unknown_schema_fails_closed() {
        let forged = guardrails_v2::forge_native_asset_binding_for_testing(
            2,
            1,
            b"sui",
            option::some(std::type_name::with_original_ids<RealUsdc>()),
            vector[],
        );
        let _ = guardrails_v2::native_asset_chain_id(&forged);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_MALFORMED_NATIVE_ASSET)]
    fun test_remote_binding_rejects_ambiguous_original_id_marker() {
        let forged = guardrails_v2::forge_native_asset_binding_for_testing(
            1,
            2,
            b"solana",
            option::some(std::type_name::with_original_ids<RealUsdc>()),
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        let _ = guardrails_v2::native_asset_canonical_v1_bytes(&forged);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_MALFORMED_NATIVE_ASSET)]
    fun test_solana_symbol_bytes_cannot_be_a_mint() {
        let _ = guardrails_v2::solana_asset_binding(b"USDC");
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_MALFORMED_NATIVE_ASSET)]
    fun test_zero_evm_token_is_not_a_native_identity() {
        let _ = guardrails_v2::evm_asset_binding(
            b"base",
            x"0000000000000000000000000000000000000000",
        );
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_REMOTE_ASSET_NOT_CONFIGURED)]
    fun test_v2_remote_asset_policy_is_explicitly_fail_closed() {
        let mut ctx = tx_context::dummy();
        let builder = complete_builder(&mut ctx);
        let hash = guardrails_v2::preview_hash(&builder);
        let guardrails = guardrails_v2::finalize_for_testing(builder, hash, &mut ctx);
        let _ = guardrails_v2::native_asset_binding_from_policy(
            &guardrails,
            b"solana",
            x"0101010101010101010101010101010101010101010101010101010101010101",
        );
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    fun test_remote_binding_is_only_returned_by_exact_frozen_policy_lookup() {
        let mut ctx = tx_context::dummy();
        let mut builder = complete_builder(&mut ctx);
        let mint = x"0101010101010101010101010101010101010101010101010101010101010101";
        guardrails_v2::add_allowed_solana_asset(&mut builder, mint, &ctx);
        let hash = guardrails_v2::preview_hash(&builder);
        let guardrails = guardrails_v2::finalize_for_testing(builder, hash, &mut ctx);
        let binding = guardrails_v2::native_asset_binding_from_policy(
            &guardrails, b"solana", mint,
        );
        assert!(guardrails_v2::native_asset_chain_id(&binding) == b"solana", 16);
        assert!(guardrails_v2::native_asset_canonical_v1_bytes(&binding)
            == guardrails_v2::native_asset_canonical_v1_bytes(
                &guardrails_v2::solana_asset_binding(mint),
            ), 17);
        guardrails_v2::destroy_for_testing(guardrails);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails_v2::E_DUPLICATE_ALLOWED_VALUE)]
    fun test_remote_binding_registry_rejects_duplicate_identity() {
        let mut ctx = tx_context::dummy();
        let mut builder = complete_builder(&mut ctx);
        let mint = x"0101010101010101010101010101010101010101010101010101010101010101";
        guardrails_v2::add_allowed_solana_asset(&mut builder, mint, &ctx);
        guardrails_v2::add_allowed_solana_asset(&mut builder, mint, &ctx);
        guardrails_v2::destroy_builder_for_testing(builder);
    }
}
