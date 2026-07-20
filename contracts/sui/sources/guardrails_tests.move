// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-569 Guardrails on-chain enforcement tests.
/// Vectors are generated from runtime/strategy/guardrails.mjs (SSOT):
///   preimage = canonical_json(validateGuardrails(defaultGuardrails({...})))
///   hash     = sha256(preimage)
/// so on-chain sha2_256 provably matches the off-chain guardrails_hash.
#[test_only]
module day::guardrails_tests {
    use day::guardrails;
    use sui::test_scenario as ts;

    const LEAD: address = @0xA11CE;

    // canonical_json preimage bytes (USDC/USDT, suilend/navi, 2500 bps)
    const PREIMAGE: vector<u8> = x"7b226167656e744d617957697468647261775072696e636970616c223a66616c73652c22616c6c6f776564436861696e73223a5b22737569225d2c226173736574416c6c6f776c697374223a5b2255534443222c2255534454225d2c22637573746f6479223a226e6f6e65222c226465706f73697461626c654c697665223a66616c73652c22686f6d65436861696e223a22737569222c226d6178416c6c6f636174696f6e427073223a323530302c226d6178416c6c6f636174696f6e4d6963726f73223a6e756c6c2c226d61785065724f70706f7274756e6974794d6963726f73223a6e756c6c2c226e616d65223a2264656661756c742d67756172647261696c73222c226e6f746573223a6e756c6c2c226f6e436861696e466163746f7279223a66616c73652c226f70706f7274756e697479416c6c6f776c697374223a5b227375696c656e64222c226e617669225d2c226f776e657245786974416c77617973223a747275652c22736368656d6156657273696f6e223a226461792d73747261746567792d67756172647261696c732e7631227d";
    // sha256(PREIMAGE)
    const HASH: vector<u8> = x"da017cf299b12df30a23b1e89f42b2edac956ae8ae44921000d49712da14169d";

    fun assets(): vector<vector<u8>> {
        vector[b"USDC", b"USDT"]
    }

    fun opps(): vector<vector<u8>> {
        vector[b"suilend", b"navi"]
    }

    #[test]
    fun test_hash_matches_offchain_ssot() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        // On-chain recompute == committed hash == off-chain guardrails_hash.
        assert!(guardrails::verify_hash(&g), 0);
        assert!(guardrails::guardrails_hash(&g) == HASH, 1);
        assert!(guardrails::matches_hash(&g, HASH), 2);
        assert!(guardrails::max_allocation_bps(&g) == 2500, 3);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_HASH_MISMATCH)]
    fun test_rejects_wrong_hash() {
        let mut ctx = tx_context::dummy();
        // A hash that does not match the preimage -> abort.
        let bad = x"0000000000000000000000000000000000000000000000000000000000000000";
        let g = guardrails::new_for_testing(bad, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_BAD_HASH_LEN)]
    fun test_rejects_bad_hash_len() {
        let mut ctx = tx_context::dummy();
        let short = x"00112233";
        let gid = guardrails::create_and_freeze(short, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        let _ = gid;
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_INVALID_BPS)]
    fun test_rejects_bps_over_10000() {
        let mut ctx = tx_context::dummy();
        // bps range is enforced on the real create path; aborts before freeze.
        let gid = guardrails::create_and_freeze(HASH, PREIMAGE, assets(), opps(), 10001, &mut ctx);
        let _ = gid;
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_EMPTY_OPPORTUNITY_ALLOWLIST)]
    fun test_rejects_empty_opportunity_allowlist() {
        let mut ctx = tx_context::dummy();
        let empty: vector<vector<u8>> = vector[];
        let gid = guardrails::create_and_freeze(HASH, PREIMAGE, assets(), empty, 2500, &mut ctx);
        let _ = gid;
    }

    #[test]
    fun test_allocation_within_scope_ok() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        assert!(guardrails::allocation_allowed(&g, b"suilend", 2500), 0);
        assert!(guardrails::allocation_allowed(&g, b"navi", 1), 1);
        assert!(!guardrails::allocation_allowed(&g, b"navi", 0), 2);
        guardrails::assert_allocation_allowed(&g, b"suilend", 2000);
        guardrails::assert_allocation_with_asset(&g, b"navi", b"USDC", 2500);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    fun test_allocation_out_of_scope_predicate_false() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        // Opportunity not in allowlist.
        assert!(!guardrails::allocation_allowed(&g, b"gmx", 100), 0);
        // Over max bps.
        assert!(!guardrails::allocation_allowed(&g, b"suilend", 2501), 1);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_OPPORTUNITY_NOT_ALLOWED)]
    fun test_reject_unlisted_opportunity() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        guardrails::assert_allocation_allowed(&g, b"gmx", 100);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_ALLOCATION_EXCEEDED)]
    fun test_reject_over_max_bps() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        guardrails::assert_allocation_allowed(&g, b"suilend", 2501);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_ALLOCATION_EXCEEDED)]
    fun test_reject_zero_bps() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        guardrails::assert_allocation_allowed(&g, b"suilend", 0);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    #[expected_failure(abort_code = day::guardrails::E_ASSET_NOT_ALLOWED)]
    fun test_reject_unlisted_asset() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        guardrails::assert_allocation_with_asset(&g, b"suilend", b"WETH", 2500);
        guardrails::destroy_for_testing(g);
    }

    #[test]
    fun test_asset_allowed_predicate() {
        let mut ctx = tx_context::dummy();
        let g = guardrails::new_for_testing(HASH, PREIMAGE, assets(), opps(), 2500, &mut ctx);
        assert!(guardrails::asset_allowed(&g, b"USDC"), 0);
        assert!(guardrails::asset_allowed(&g, b"USDT"), 1);
        assert!(!guardrails::asset_allowed(&g, b"WETH"), 2);
        guardrails::destroy_for_testing(g);
    }

    /// DAY-569 — create_and_freeze produces a genuinely IMMUTABLE object:
    /// after the tx, the Guardrails can only be taken back as an IMMUTABLE object
    /// (`ts::take_immutable`) — never `&mut` — so no field can ever be mutated.
    /// Its committed hash still recomputes on-chain (verify_hash) and the scope is
    /// readable. There is no setter anywhere in the module, so freeze = forever.
    #[test]
    fun test_create_and_freeze_is_immutable_and_verifiable() {
        let mut scenario = ts::begin(LEAD);
        {
            let ctx = ts::ctx(&mut scenario);
            let gid = guardrails::create_and_freeze_for_testing(
                HASH, PREIMAGE, assets(), opps(), 2500, ctx,
            );
            // Advance so the frozen (immutable) object is available to take.
            ts::next_tx(&mut scenario, LEAD);
            // Only takeable as IMMUTABLE — a &mut take would not type-check.
            let g = ts::take_immutable_by_id<guardrails::Guardrails>(&scenario, gid);
            assert!(guardrails::verify_hash(&g), 0);
            assert!(guardrails::guardrails_hash(&g) == HASH, 1);
            assert!(guardrails::max_allocation_bps(&g) == 2500, 2);
            assert!(guardrails::allocation_allowed(&g, b"suilend", 2500), 3);
            assert!(!guardrails::allocation_allowed(&g, b"gmx", 1), 4);
            ts::return_immutable(g);
        };
        ts::end(scenario);
    }
    // NOTE (DAY-569): AgentCap binding + guarded-reallocate enforcement tests now
    // live in day::agent_cap_tests — the cap was unified onto day::agent_cap
    // (revocable, grantee-enforced) and this module is a pure immutable Scope.
}
