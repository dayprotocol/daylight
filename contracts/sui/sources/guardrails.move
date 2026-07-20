// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY Guardrails — immutable, on-chain Scope for a managed Strategy (DAY-569).
///
/// Product language: "Scope" = the Guardrails. A Guardrails set fixes, at
/// creation time and forever:
///   - guardrails_hash   = sha2_256(canonical_json(guardrails))  (32 bytes)
///   - asset_allowlist   (deposit assets, e.g. b"USDC")
///   - opportunity_allowlist (Yield Opportunity ids, e.g. b"suilend")
///   - max_allocation_bps (per-Opportunity share of AUM, 1..10000)
///
/// The canonical JSON preimage that produced the hash is stored on-chain so
/// anyone can recompute sha2_256(preimage) == guardrails_hash and read the
/// human-readable Scope directly from the object (the trust surface the FE
/// links to). This module NEVER holds principal and NEVER lets an agent widen
/// scope: the object is `freeze`d after creation, so no field can be mutated,
/// and every AgentCap is bound to exactly one guardrails_hash.
///
/// Enforcement: `assert_allocation_allowed` / `allocation_allowed` reject any
/// reallocation whose Opportunity is not in the allowlist or whose bps exceeds
/// `max_allocation_bps`. This is the ON-CHAIN source of truth for Scope.
///
/// DAY-569 cap unification: this module no longer defines its own AgentCap.
/// The single keeper capability is `day::agent_cap::AgentCap` (DAY-566 —
/// revocable, grantee-enforced, fund-bound). That cap is bound to a frozen
/// `Guardrails` object id + hash at grant, and its guarded reallocate path
/// (`day::agent_cap::authorize_reallocate_guarded`) calls
/// `assert_allocation_allowed` on THIS frozen object. So the allowlist the
/// keeper is checked against is the immutable on-chain Guardrails, not a
/// mutable off-chain copy — a wider Scope is a different frozen object with a
/// different hash and therefore requires a different (owner-minted) cap.
module day::guardrails {
    use std::hash;
    use sui::event;

    // ---- Constants ----------------------------------------------------------

    const BASIS_POINTS: u64 = 10_000;
    /// sha2-256 digest length in bytes.
    const HASH_LEN: u64 = 32;

    // ---- Error codes --------------------------------------------------------

    /// EHashMismatch — provided guardrails_hash != sha2_256(preimage).
    const E_HASH_MISMATCH: u64 = 1;
    /// EEmptyAssetAllowlist — asset allowlist must be non-empty.
    const E_EMPTY_ASSET_ALLOWLIST: u64 = 2;
    /// EEmptyOpportunityAllowlist — opportunity allowlist must be non-empty.
    const E_EMPTY_OPPORTUNITY_ALLOWLIST: u64 = 3;
    /// EInvalidBps — max_allocation_bps must be 1..10000.
    const E_INVALID_BPS: u64 = 4;
    /// EOpportunityNotAllowed — reallocation target not in allowlist.
    const E_OPPORTUNITY_NOT_ALLOWED: u64 = 5;
    /// EAllocationExceeded — bps > max_allocation_bps.
    const E_ALLOCATION_EXCEEDED: u64 = 6;
    /// EAssetNotAllowed — asset not in allowlist.
    const E_ASSET_NOT_ALLOWED: u64 = 7;
    /// EBadHashLen — guardrails_hash is not 32 bytes.
    const E_BAD_HASH_LEN: u64 = 8;

    // ---- Objects ------------------------------------------------------------

    /// Immutable Scope. Created then `transfer::freeze_object`d — no field is
    /// ever mutable, so the guardrails can never be widened after deposit.
    public struct Guardrails has key, store {
        id: UID,
        /// sha2_256(canonical_json(guardrails)) — 32 bytes. The trust anchor.
        guardrails_hash: vector<u8>,
        /// Exact canonical JSON preimage. sha2_256(preimage) == guardrails_hash.
        canonical_preimage: vector<u8>,
        /// Deposit assets allowed (uppercase symbol bytes, e.g. b"USDC").
        asset_allowlist: vector<vector<u8>>,
        /// Yield Opportunity ids allowed (lowercase slug bytes, e.g. b"suilend").
        opportunity_allowlist: vector<vector<u8>>,
        /// Max share of AUM into any single Opportunity (1..10000 bps).
        max_allocation_bps: u64,
        /// Creator (Strategy Lead) — recorded, not a mutation authority.
        strategy_lead: address,
    }

    // ---- Events -------------------------------------------------------------

    public struct GuardrailsCreated has copy, drop {
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        max_allocation_bps: u64,
        asset_count: u64,
        opportunity_count: u64,
        strategy_lead: address,
    }

    // ---- Create + freeze ----------------------------------------------------

    /// Build a Guardrails object, verifying the committed hash against the
    /// on-chain sha2_256 of the canonical preimage, then FREEZE it so it can
    /// never be mutated. Returns the frozen object's id for cap binding.
    ///
    /// `expected_hash` is what the runtime (guardrails.mjs) computed off-chain;
    /// we recompute on-chain and assert equality — a single source of truth.
    public fun create_and_freeze(
        expected_hash: vector<u8>,
        canonical_preimage: vector<u8>,
        asset_allowlist: vector<vector<u8>>,
        opportunity_allowlist: vector<vector<u8>>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): ID {
        assert!(vector::length(&expected_hash) == HASH_LEN, E_BAD_HASH_LEN);
        assert!(!vector::is_empty(&asset_allowlist), E_EMPTY_ASSET_ALLOWLIST);
        assert!(!vector::is_empty(&opportunity_allowlist), E_EMPTY_OPPORTUNITY_ALLOWLIST);
        assert!(max_allocation_bps >= 1 && max_allocation_bps <= BASIS_POINTS, E_INVALID_BPS);

        // Recompute the hash on-chain from the canonical preimage. This binds
        // the stored, human-readable Scope to the 32-byte trust anchor.
        let computed = hash::sha2_256(canonical_preimage);
        assert!(computed == expected_hash, E_HASH_MISMATCH);

        let g = Guardrails {
            id: object::new(ctx),
            guardrails_hash: expected_hash,
            canonical_preimage,
            asset_allowlist,
            opportunity_allowlist,
            max_allocation_bps,
            strategy_lead: tx_context::sender(ctx),
        };
        let gid = object::id(&g);
        event::emit(GuardrailsCreated {
            guardrails_id: gid,
            guardrails_hash: g.guardrails_hash,
            max_allocation_bps: g.max_allocation_bps,
            asset_count: vector::length(&g.asset_allowlist),
            opportunity_count: vector::length(&g.opportunity_allowlist),
            strategy_lead: g.strategy_lead,
        });
        // Immutable forever: no setter exists AND the object is frozen.
        transfer::freeze_object(g);
        gid
    }

    // ---- Verify -------------------------------------------------------------

    /// Independently recompute sha2_256(preimage) and compare to the committed
    /// hash. Anyone (indexer / FE verify link) can call this read-only.
    public fun verify_hash(g: &Guardrails): bool {
        hash::sha2_256(g.canonical_preimage) == g.guardrails_hash
    }

    /// Verify a caller-supplied hash matches the on-chain committed hash.
    public fun matches_hash(g: &Guardrails, candidate: vector<u8>): bool {
        candidate == g.guardrails_hash
    }

    // ---- Enforcement --------------------------------------------------------

    fun contains_bytes(haystack: &vector<vector<u8>>, needle: &vector<u8>): bool {
        let n = vector::length(haystack);
        let mut i = 0;
        while (i < n) {
            if (vector::borrow(haystack, i) == needle) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Non-aborting predicate: is this reallocation within Scope?
    public fun allocation_allowed(
        g: &Guardrails,
        opportunity_id: vector<u8>,
        allocation_bps: u64,
    ): bool {
        if (!contains_bytes(&g.opportunity_allowlist, &opportunity_id)) {
            return false
        };
        if (allocation_bps == 0 || allocation_bps > g.max_allocation_bps) {
            return false
        };
        true
    }

    /// Fail-closed enforcement for a reallocation: aborts out-of-scope moves.
    /// This is the on-chain gate DAY must clear before any managed reallocation.
    public fun assert_allocation_allowed(
        g: &Guardrails,
        opportunity_id: vector<u8>,
        allocation_bps: u64,
    ) {
        assert!(
            contains_bytes(&g.opportunity_allowlist, &opportunity_id),
            E_OPPORTUNITY_NOT_ALLOWED,
        );
        assert!(allocation_bps >= 1 && allocation_bps <= g.max_allocation_bps, E_ALLOCATION_EXCEEDED);
    }

    /// Fail-closed enforcement including the deposit asset.
    public fun assert_allocation_with_asset(
        g: &Guardrails,
        opportunity_id: vector<u8>,
        asset: vector<u8>,
        allocation_bps: u64,
    ) {
        assert!(
            contains_bytes(&g.asset_allowlist, &asset),
            E_ASSET_NOT_ALLOWED,
        );
        assert_allocation_allowed(g, opportunity_id, allocation_bps);
    }

    /// Non-aborting membership check for a deposit asset.
    public fun asset_allowed(g: &Guardrails, asset: vector<u8>): bool {
        contains_bytes(&g.asset_allowlist, &asset)
    }

    // ---- Read accessors -----------------------------------------------------

    /// Object id of this (frozen) Guardrails — the anchor an AgentCap binds to.
    public fun id(g: &Guardrails): ID { object::id(g) }

    public fun guardrails_hash(g: &Guardrails): vector<u8> { g.guardrails_hash }

    public fun canonical_preimage(g: &Guardrails): vector<u8> { g.canonical_preimage }

    public fun max_allocation_bps(g: &Guardrails): u64 { g.max_allocation_bps }

    public fun asset_allowlist(g: &Guardrails): vector<vector<u8>> { g.asset_allowlist }

    public fun opportunity_allowlist(g: &Guardrails): vector<vector<u8>> {
        g.opportunity_allowlist
    }

    public fun strategy_lead(g: &Guardrails): address { g.strategy_lead }

    // ---- Test helpers -------------------------------------------------------

    #[test_only]
    public fun new_for_testing(
        expected_hash: vector<u8>,
        canonical_preimage: vector<u8>,
        asset_allowlist: vector<vector<u8>>,
        opportunity_allowlist: vector<vector<u8>>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): Guardrails {
        let computed = hash::sha2_256(canonical_preimage);
        assert!(computed == expected_hash, E_HASH_MISMATCH);
        Guardrails {
            id: object::new(ctx),
            guardrails_hash: expected_hash,
            canonical_preimage,
            asset_allowlist,
            opportunity_allowlist,
            max_allocation_bps,
            strategy_lead: tx_context::sender(ctx),
        }
    }

    #[test_only]
    public fun destroy_for_testing(g: Guardrails) {
        let Guardrails {
            id,
            guardrails_hash: _,
            canonical_preimage: _,
            asset_allowlist: _,
            opportunity_allowlist: _,
            max_allocation_bps: _,
            strategy_lead: _,
        } = g;
        object::delete(id);
    }

    /// Create + freeze a Guardrails and return its id (test convenience so the
    /// agent_cap guarded-path tests can bind a cap to a real frozen object).
    #[test_only]
    public fun create_and_freeze_for_testing(
        expected_hash: vector<u8>,
        canonical_preimage: vector<u8>,
        asset_allowlist: vector<vector<u8>>,
        opportunity_allowlist: vector<vector<u8>>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): ID {
        create_and_freeze(
            expected_hash,
            canonical_preimage,
            asset_allowlist,
            opportunity_allowlist,
            max_allocation_bps,
            ctx,
        )
    }
}
