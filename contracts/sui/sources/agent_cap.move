// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY Managed Autopilot AgentCap (DAY-566).
///
/// The owner signs ONCE to mint a revocable, scope-bound capability that lets
/// the DAY keeper reallocate managed-fund principal between whitelisted Yield
/// Opportunities WITHOUT an owner signature per rebalance.
///
/// Non-custodial by construction:
///   * The cap authorizes only `reallocate` between allowlisted opportunities.
///   * Every move destination is checked against the immutable `opportunity_allowlist`.
///   * There is NO function on this cap that returns a Coin or transfers value to
///     any address — the keeper can shift position between venues but can NEVER
///     withdraw to a non-owner. Owner exit stays on the owner-signed vault path.
///   * The cap carries the immutable `guardrails_hash` (sha256(canonical_json(guardrails)),
///     DAY-512 / coordinates with DAY-569). A reallocation must present the same hash,
///     so the keeper can never widen scope after the grant.
///
/// Revocable + total: `revoke` flips `active=false` and empties the allowlist.
/// Once revoked, every authorization aborts. Owner can revoke anytime; the cap
/// is a shared object owned-by-policy (owner address recorded, only owner mutates).
///
/// DAY-569 — on-chain Guardrails as the source of truth:
/// This cap can be bound to a frozen `day::guardrails::Guardrails` object at
/// grant (`grant_bound`). The guarded reallocate path
/// (`authorize_reallocate_guarded`) then checks the proposed move against the
/// IMMUTABLE on-chain Guardrails via `day::guardrails::assert_allocation_allowed`
/// — not just the cap's own inline allowlist. Because the Guardrails object is
/// frozen and the cap records its object id + hash, the keeper cannot widen
/// scope by presenting a different (wider) Guardrails: a wider Scope is a
/// different frozen object with a different id/hash and would abort here.
/// The unbound `grant` + `authorize_reallocate` path is retained unchanged for
/// backward compatibility (DAY-566 / runtime tx-builder).
module day::agent_cap {
    use sui::event;
    use std::string::{Self, String};
    use day::guardrails::{Self, Guardrails};

    // ---- Errors ----------------------------------------------------------
    /// Caller is not the recorded owner.
    const E_NOT_OWNER: u64 = 1;
    /// Capability has been revoked (or never active).
    const E_REVOKED: u64 = 2;
    /// Target opportunity is not in the immutable allowlist.
    const E_OUT_OF_SCOPE: u64 = 3;
    /// Presented guardrails_hash does not match the hash bound at grant.
    const E_HASH_MISMATCH: u64 = 4;
    /// Allowlist must be non-empty at grant.
    const E_EMPTY_ALLOWLIST: u64 = 5;
    /// guardrails_hash must be a 32-byte sha256 digest.
    const E_BAD_HASH_LEN: u64 = 6;
    /// Reallocation amount must be positive.
    const E_ZERO_AMOUNT: u64 = 7;
    /// Allocation bps exceeds the immutable per-move cap.
    const E_MAX_ALLOCATION_EXCEEDED: u64 = 8;
    /// A move from/to the same opportunity is a no-op and rejected.
    const E_SAME_OPPORTUNITY: u64 = 9;
    /// Caller is not the recorded keeper (grantee) — bearer use forbidden.
    const E_NOT_GRANTEE: u64 = 10;
    /// Presented managed-fund object does not match the fund bound at grant.
    const E_WRONG_FUND: u64 = 11;
    /// Allowlist exceeds the immutable max length (gas / self-DoS bound).
    const E_ALLOWLIST_TOO_LARGE: u64 = 12;
    /// Presented Guardrails object is not the one this cap is bound to (DAY-569).
    const E_WRONG_GUARDRAILS: u64 = 13;
    /// Cap is not bound to any on-chain Guardrails (guarded path requires binding).
    const E_NOT_GUARDRAILS_BOUND: u64 = 14;

    /// 100% in basis points.
    const BASIS_POINTS: u64 = 10_000;
    /// sha256 digest length in bytes.
    const HASH_LEN: u64 = 32;
    /// Max opportunities in one Scope allowlist (bounds contains() gas).
    const MAX_ALLOWLIST_LEN: u64 = 64;

    /// Revocable, scope-bound delegated capability for the managed keeper.
    ///
    /// Shared object: the keeper reads it to authorize a reallocate; only the
    /// recorded `owner` may revoke. The object holds NO Balance/Coin — it is a
    /// pure authorization record. Value never lives here, so it can never be
    /// drained from here.
    public struct AgentCap has key {
        id: UID,
        /// Owner who granted the cap; only this address may revoke.
        owner: address,
        /// Keeper principal authorized to reallocate. Enforced (not bearer):
        /// only this address may call authorize_reallocate.
        grantee: address,
        /// Managed-fund object this cap governs. Immutable; verified on every
        /// reallocation so a forged look-alike cap cannot poison a fund's
        /// accounting (a Reallocated event from a cap bound to a different fund
        /// id is trivially filtered off-chain, and on-chain use aborts).
        managed_fund: ID,
        /// Immutable sha256(canonical_json(guardrails)) — binds cap to one Scope.
        guardrails_hash: vector<u8>,
        /// DAY-569: object id of the frozen `day::guardrails::Guardrails` this cap
        /// is bound to, when granted via `grant_bound`. `none` for legacy unbound
        /// caps (DAY-566 `grant`). When `some`, the guarded reallocate path checks
        /// moves against that immutable on-chain Scope, not just the inline copy.
        guardrails_id: Option<ID>,
        /// Immutable allowlist of Yield Opportunity ids the keeper may move among.
        opportunity_allowlist: vector<String>,
        /// Max per-move allocation share of managed AUM (bps). Immutable.
        max_allocation_bps: u64,
        /// Revocable flag — false blocks every authorization immediately.
        active: bool,
        /// Monotonic count of authorized reallocations (audit).
        reallocations: u64,
    }

    // ---- Events ----------------------------------------------------------
    public struct AgentCapGranted has copy, drop {
        cap_id: ID,
        owner: address,
        grantee: address,
        managed_fund: ID,
        guardrails_hash: vector<u8>,
        opportunity_count: u64,
        max_allocation_bps: u64,
        /// DAY-569: object id of the frozen Guardrails this cap is bound to, or
        /// none for a legacy unbound cap.
        guardrails_id: Option<ID>,
    }

    public struct AgentCapRevoked has copy, drop {
        cap_id: ID,
        owner: address,
    }

    /// Emitted on each authorized reallocation. Note: destination is always a
    /// whitelisted opportunity, never an address — there is no withdraw event.
    public struct Reallocated has copy, drop {
        cap_id: ID,
        owner: address,
        grantee: address,
        managed_fund: ID,
        from_opportunity: String,
        to_opportunity: String,
        amount_micros: u64,
        allocation_bps: u64,
        guardrails_hash: vector<u8>,
        sequence: u64,
    }

    // ---- Grant (owner signs ONCE) ---------------------------------------
    /// Mint + share a revocable AgentCap. Owner = tx sender (never a free param,
    /// per DAY-123). Binds the immutable guardrails_hash + allowlist + max bps.
    public fun grant(
        grantee: address,
        managed_fund: ID,
        guardrails_hash: vector<u8>,
        opportunity_allowlist: vector<String>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): ID {
        grant_internal(
            grantee,
            managed_fund,
            guardrails_hash,
            option::none<ID>(),
            opportunity_allowlist,
            max_allocation_bps,
            ctx,
        )
    }

    /// DAY-569 — grant a cap BOUND to a frozen on-chain Guardrails object.
    /// The immutable `guardrails_hash`, `opportunity_allowlist`, and
    /// `max_allocation_bps` are derived FROM the frozen Guardrails, so the cap
    /// cannot disagree with the on-chain Scope, and its `guardrails_id` records
    /// which Scope it is bound to. Use `authorize_reallocate_guarded` to enforce
    /// against that same object (the on-chain source of truth). Owner = sender.
    ///
    /// `g` must be a frozen (immutable) Guardrails — the runtime creates it via
    /// `day::guardrails::create_and_freeze` before granting; passing any object
    /// that satisfies `&Guardrails` is safe because the fields are copied and the
    /// object id is recorded for the guarded-path binding check.
    public fun grant_bound(
        grantee: address,
        managed_fund: ID,
        g: &Guardrails,
        ctx: &mut TxContext,
    ): ID {
        // Derive the immutable Scope from the frozen on-chain object.
        let opportunity_allowlist = opportunity_slugs_as_strings(g);
        grant_internal(
            grantee,
            managed_fund,
            guardrails::guardrails_hash(g),
            option::some(guardrails::id(g)),
            opportunity_allowlist,
            guardrails::max_allocation_bps(g),
            ctx,
        )
    }

    /// Shared grant body — legacy (unbound) and DAY-569 (bound) both route here.
    fun grant_internal(
        grantee: address,
        managed_fund: ID,
        guardrails_hash: vector<u8>,
        guardrails_id: Option<ID>,
        opportunity_allowlist: vector<String>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): ID {
        assert!(vector::length(&guardrails_hash) == HASH_LEN, E_BAD_HASH_LEN);
        assert!(!vector::is_empty(&opportunity_allowlist), E_EMPTY_ALLOWLIST);
        assert!(vector::length(&opportunity_allowlist) <= MAX_ALLOWLIST_LEN, E_ALLOWLIST_TOO_LARGE);
        assert!(max_allocation_bps > 0 && max_allocation_bps <= BASIS_POINTS, E_MAX_ALLOCATION_EXCEEDED);
        let owner = tx_context::sender(ctx);
        let cap = AgentCap {
            id: object::new(ctx),
            owner,
            grantee,
            managed_fund,
            guardrails_hash,
            guardrails_id,
            opportunity_allowlist,
            max_allocation_bps,
            active: true,
            reallocations: 0,
        };
        let cap_id = object::id(&cap);
        event::emit(AgentCapGranted {
            cap_id,
            owner,
            grantee,
            managed_fund,
            guardrails_hash: cap.guardrails_hash,
            opportunity_count: vector::length(&cap.opportunity_allowlist),
            max_allocation_bps,
            guardrails_id: cap.guardrails_id,
        });
        transfer::share_object(cap);
        cap_id
    }

    /// Read the frozen Guardrails' opportunity allowlist as `vector<String>`
    /// (the cap stores String slugs; the Guardrails stores raw byte slugs).
    fun opportunity_slugs_as_strings(g: &Guardrails): vector<String> {
        let raw = guardrails::opportunity_allowlist(g);
        let n = vector::length(&raw);
        let mut out = vector::empty<String>();
        let mut i = 0;
        while (i < n) {
            // Guardrails slugs are validated lowercase ascii (OPP_ID_RE), so
            // utf8 is always valid here.
            vector::push_back(&mut out, string::utf8(*vector::borrow(&raw, i)));
            i = i + 1;
        };
        out
    }

    // ---- Revoke (owner, anytime) ----------------------------------------
    /// Immediate + total revoke. Only the recorded owner may revoke. Empties the
    /// allowlist and flips active=false so every future authorization aborts.
    public fun revoke(cap: &mut AgentCap, ctx: &TxContext) {
        assert!(tx_context::sender(ctx) == cap.owner, E_NOT_OWNER);
        cap.active = false;
        cap.opportunity_allowlist = vector::empty<String>();
        event::emit(AgentCapRevoked {
            cap_id: object::id(cap),
            owner: cap.owner,
        });
    }

    // ---- Authorize reallocation (keeper, no owner signature) ------------
    /// Assert a proposed reallocation is within scope, then record it. Aborts on:
    ///   * sender is not the recorded keeper/grantee (E_NOT_GRANTEE) — NOT bearer
    ///   * managed_fund does not match the fund bound at grant (E_WRONG_FUND) —
    ///     a forged look-alike cap cannot drive a real fund
    ///   * revoked cap (E_REVOKED)
    ///   * wrong guardrails_hash — attempted scope widening (E_HASH_MISMATCH)
    ///   * from/to opportunity outside the immutable allowlist (E_OUT_OF_SCOPE)
    ///   * over the immutable per-move allocation cap (E_MAX_ALLOCATION_EXCEEDED)
    ///
    /// No OWNER signature is required (that is the delegation); but the caller
    /// MUST be the recorded grantee — this is a revocable delegated keeper, not a
    /// permissionless one. This is the ONLY mutating keeper entry. It moves
    /// accounting between opportunities; it never mints, returns, or transfers a
    /// Coin. The actual venue exit/enter is composed in a PTB whose only
    /// authority is this assert; the caller binds cap→fund and treats the
    /// Reallocated event as advisory.
    public fun authorize_reallocate(
        cap: &mut AgentCap,
        managed_fund: ID,
        guardrails_hash: vector<u8>,
        from_opportunity: String,
        to_opportunity: String,
        amount_micros: u64,
        allocation_bps: u64,
        ctx: &TxContext,
    ) {
        // Delegated-but-not-bearer: only the recorded keeper may drive it.
        assert!(tx_context::sender(ctx) == cap.grantee, E_NOT_GRANTEE);
        // Cap governs exactly one fund — forged look-alike cap cannot poison it.
        assert!(managed_fund == cap.managed_fund, E_WRONG_FUND);
        assert!(cap.active, E_REVOKED);
        assert!(amount_micros > 0, E_ZERO_AMOUNT);
        assert!(guardrails_hash == cap.guardrails_hash, E_HASH_MISMATCH);
        assert!(allocation_bps > 0 && allocation_bps <= cap.max_allocation_bps, E_MAX_ALLOCATION_EXCEEDED);
        assert!(!string_eq(&from_opportunity, &to_opportunity), E_SAME_OPPORTUNITY);
        assert!(contains(&cap.opportunity_allowlist, &from_opportunity), E_OUT_OF_SCOPE);
        assert!(contains(&cap.opportunity_allowlist, &to_opportunity), E_OUT_OF_SCOPE);

        cap.reallocations = cap.reallocations + 1;
        event::emit(Reallocated {
            cap_id: object::id(cap),
            owner: cap.owner,
            grantee: cap.grantee,
            managed_fund: cap.managed_fund,
            from_opportunity,
            to_opportunity,
            amount_micros,
            allocation_bps,
            guardrails_hash: cap.guardrails_hash,
            sequence: cap.reallocations,
        });
    }

    // ---- Authorize reallocation against the IMMUTABLE on-chain Guardrails ----
    /// DAY-569 — the money-path gate that makes the frozen Guardrails object the
    /// on-chain source of truth. Same keeper/fund/revoke checks as
    /// `authorize_reallocate`, PLUS:
    ///   * the cap MUST be bound to a Guardrails (E_NOT_GUARDRAILS_BOUND)
    ///   * the presented `&Guardrails` MUST be exactly the bound object
    ///     (E_WRONG_GUARDRAILS) and carry the bound hash (E_HASH_MISMATCH)
    ///   * BOTH from/to opportunities and the allocation bps are checked against
    ///     the frozen Guardrails via `day::guardrails::assert_allocation_allowed`
    ///     — so a move outside the immutable on-chain allowlist aborts
    ///     E_OUT_OF_SCOPE even if the cap's inline copy were ever tampered.
    ///
    /// This is the entry a reallocate PTB should compose once DAY-627 lands a
    /// real on-chain deploy/reallocate money leg; today it is the authoritative
    /// authorization whose Guardrails object is the single source of truth for
    /// the allowlist. `guardrails_hash` need not be passed separately — it is
    /// read from the bound frozen object.
    ///
    /// RUNTIME ADOPTION: the autopilot tx-builder already targets
    /// `authorize_reallocate_guarded` and passes the bound Guardrails object. It
    /// fails closed when the managed-fund id, Guardrails object id, or guardrails
    /// hash is absent. This entry remains authorization-only until the separately
    /// gated on-chain money leg is wired. This correction does not address the
    /// separate router-level pause / kill-switch requirement tracked by DAY-831.
    public fun authorize_reallocate_guarded(
        cap: &mut AgentCap,
        g: &Guardrails,
        managed_fund: ID,
        from_opportunity: String,
        to_opportunity: String,
        amount_micros: u64,
        allocation_bps: u64,
        ctx: &TxContext,
    ) {
        // Delegated-but-not-bearer: only the recorded keeper may drive it.
        assert!(tx_context::sender(ctx) == cap.grantee, E_NOT_GRANTEE);
        // Cap governs exactly one fund — forged look-alike cap cannot poison it.
        assert!(managed_fund == cap.managed_fund, E_WRONG_FUND);
        assert!(cap.active, E_REVOKED);
        assert!(amount_micros > 0, E_ZERO_AMOUNT);
        assert!(allocation_bps > 0, E_ZERO_AMOUNT);

        // On-chain Guardrails binding: the presented Scope object must be the
        // exact frozen object this cap was bound to, and its committed hash must
        // match — a wider Scope is a different object/hash and aborts here.
        assert!(option::is_some(&cap.guardrails_id), E_NOT_GUARDRAILS_BOUND);
        assert!(guardrails::id(g) == *option::borrow(&cap.guardrails_id), E_WRONG_GUARDRAILS);
        assert!(guardrails::guardrails_hash(g) == cap.guardrails_hash, E_HASH_MISMATCH);

        assert!(!string_eq(&from_opportunity, &to_opportunity), E_SAME_OPPORTUNITY);

        // Fail-closed against the IMMUTABLE on-chain allowlist (both legs) + bps.
        // assert_allocation_allowed aborts E_OPPORTUNITY_NOT_ALLOWED (out of scope)
        // or E_ALLOCATION_EXCEEDED from day::guardrails.
        guardrails::assert_allocation_allowed(g, *string::as_bytes(&from_opportunity), allocation_bps);
        guardrails::assert_allocation_allowed(g, *string::as_bytes(&to_opportunity), allocation_bps);

        cap.reallocations = cap.reallocations + 1;
        event::emit(Reallocated {
            cap_id: object::id(cap),
            owner: cap.owner,
            grantee: cap.grantee,
            managed_fund: cap.managed_fund,
            from_opportunity,
            to_opportunity,
            amount_micros,
            allocation_bps,
            guardrails_hash: cap.guardrails_hash,
            sequence: cap.reallocations,
        });
    }

    // ---- Read-only views -------------------------------------------------
    public fun is_active(cap: &AgentCap): bool { cap.active }

    public fun owner(cap: &AgentCap): address { cap.owner }

    public fun grantee(cap: &AgentCap): address { cap.grantee }

    public fun managed_fund(cap: &AgentCap): ID { cap.managed_fund }

    public fun guardrails_hash(cap: &AgentCap): vector<u8> { cap.guardrails_hash }

    /// DAY-569 — object id of the bound frozen Guardrails, or none if unbound.
    public fun guardrails_id(cap: &AgentCap): Option<ID> { cap.guardrails_id }

    /// DAY-569 — whether this cap is bound to an on-chain Guardrails object.
    public fun is_guardrails_bound(cap: &AgentCap): bool { option::is_some(&cap.guardrails_id) }

    public fun max_allocation_bps(cap: &AgentCap): u64 { cap.max_allocation_bps }

    public fun reallocations(cap: &AgentCap): u64 { cap.reallocations }

    public fun allowlist_len(cap: &AgentCap): u64 {
        vector::length(&cap.opportunity_allowlist)
    }

    /// Whether an opportunity id is inside the immutable allowlist.
    public fun in_scope(cap: &AgentCap, opportunity: &String): bool {
        cap.active && contains(&cap.opportunity_allowlist, opportunity)
    }

    // ---- Internal helpers ------------------------------------------------
    fun string_eq(a: &String, b: &String): bool {
        string::as_bytes(a) == string::as_bytes(b)
    }

    fun contains(list: &vector<String>, needle: &String): bool {
        let n = vector::length(list);
        let mut i = 0;
        while (i < n) {
            if (string_eq(vector::borrow(list, i), needle)) {
                return true
            };
            i = i + 1;
        };
        false
    }

    // ---- Test-only constructors -----------------------------------------
    #[test_only]
    public fun grant_for_testing(
        owner: address,
        grantee: address,
        managed_fund: ID,
        guardrails_hash: vector<u8>,
        opportunity_allowlist: vector<String>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): AgentCap {
        AgentCap {
            id: object::new(ctx),
            owner,
            grantee,
            managed_fund,
            guardrails_hash,
            guardrails_id: option::none<ID>(),
            opportunity_allowlist,
            max_allocation_bps,
            active: true,
            reallocations: 0,
        }
    }

    /// DAY-569 — test constructor for a cap BOUND to an on-chain Guardrails id.
    #[test_only]
    public fun grant_bound_for_testing(
        owner: address,
        grantee: address,
        managed_fund: ID,
        guardrails_hash: vector<u8>,
        guardrails_id: ID,
        opportunity_allowlist: vector<String>,
        max_allocation_bps: u64,
        ctx: &mut TxContext,
    ): AgentCap {
        AgentCap {
            id: object::new(ctx),
            owner,
            grantee,
            managed_fund,
            guardrails_hash,
            guardrails_id: option::some(guardrails_id),
            opportunity_allowlist,
            max_allocation_bps,
            active: true,
            reallocations: 0,
        }
    }

    #[test_only]
    public fun destroy_for_testing(cap: AgentCap) {
        let AgentCap {
            id,
            owner: _,
            grantee: _,
            managed_fund: _,
            guardrails_hash: _,
            guardrails_id: _,
            opportunity_allowlist: _,
            max_allocation_bps: _,
            active: _,
            reallocations: _,
        } = cap;
        object::delete(id);
    }
}


#[test_only]
module day::agent_cap_tests {
    use std::string;
    use sui::test_scenario as ts;
    use day::agent_cap::{Self, AgentCap};
    use day::guardrails;

    const OWNER: address = @0xA;
    const KEEPER: address = @0xB;
    const STRANGER: address = @0xC;

    // DAY-569 — SSOT vectors (shared with day::guardrails_tests):
    //   preimage = canonical_json(defaultGuardrails({assets:[USDC,USDT],
    //              opps:[suilend,navi], maxAllocationBps:2500}))
    //   hash     = sha256(preimage)
    const G_PREIMAGE: vector<u8> = x"7b226167656e744d617957697468647261775072696e636970616c223a66616c73652c22616c6c6f776564436861696e73223a5b22737569225d2c226173736574416c6c6f776c697374223a5b2255534443222c2255534454225d2c22637573746f6479223a226e6f6e65222c226465706f73697461626c654c697665223a66616c73652c22686f6d65436861696e223a22737569222c226d6178416c6c6f636174696f6e427073223a323530302c226d6178416c6c6f636174696f6e4d6963726f73223a6e756c6c2c226d61785065724f70706f7274756e6974794d6963726f73223a6e756c6c2c226e616d65223a2264656661756c742d67756172647261696c73222c226e6f746573223a6e756c6c2c226f6e436861696e466163746f7279223a66616c73652c226f70706f7274756e697479416c6c6f776c697374223a5b227375696c656e64222c226e617669225d2c226f776e657245786974416c77617973223a747275652c22736368656d6156657273696f6e223a226461792d73747261746567792d67756172647261696c732e7631227d";
    const G_HASH: vector<u8> = x"da017cf299b12df30a23b1e89f42b2edac956ae8ae44921000d49712da14169d";
    const G_MAX_BPS: u64 = 2500;

    fun g_assets(): vector<vector<u8>> { vector[b"USDC", b"USDT"] }
    fun g_opps(): vector<vector<u8>> { vector[b"suilend", b"navi"] }

    /// A non-frozen Guardrails carrying the SSOT vectors (its object id + hash are
    /// what the guarded path binds to; freezing is an object-availability
    /// property, so a reference behaves identically for enforcement).
    fun new_guardrails(ctx: &mut TxContext): guardrails::Guardrails {
        guardrails::new_for_testing(G_HASH, G_PREIMAGE, g_assets(), g_opps(), G_MAX_BPS, ctx)
    }

    /// Cap bound to `g` (allowlist suilend/navi, max 2500 bps), keeper = KEEPER.
    fun new_bound_cap(g: &guardrails::Guardrails, ctx: &mut TxContext): AgentCap {
        let mut allow = vector::empty<string::String>();
        vector::push_back(&mut allow, string::utf8(b"suilend"));
        vector::push_back(&mut allow, string::utf8(b"navi"));
        agent_cap::grant_bound_for_testing(
            OWNER,
            KEEPER,
            fund_a(),
            G_HASH,
            guardrails::id(g),
            allow,
            G_MAX_BPS,
            ctx,
        )
    }

    /// Deterministic fund object ids for tests.
    fun fund_a(): ID { object::id_from_address(@0xF001) }
    fun fund_b(): ID { object::id_from_address(@0xF002) }

    /// Build a 32-byte fake sha256 digest for tests.
    fun fake_hash(seed: u8): vector<u8> {
        let mut v = vector::empty<u8>();
        let mut i = 0;
        while (i < 32) {
            vector::push_back(&mut v, seed);
            i = i + 1;
        };
        v
    }

    fun stable_allowlist(): vector<string::String> {
        let mut list = vector::empty<string::String>();
        vector::push_back(&mut list, string::utf8(b"suilend"));
        vector::push_back(&mut list, string::utf8(b"navi"));
        vector::push_back(&mut list, string::utf8(b"kamino"));
        list
    }

    fun new_cap(ctx: &mut TxContext): AgentCap {
        agent_cap::grant_for_testing(
            OWNER,
            KEEPER,
            fund_a(),
            fake_hash(7),
            stable_allowlist(),
            10_000,
            ctx,
        )
    }

    /// grant binds owner, grantee, fund, hash, allowlist, and starts active.
    #[test]
    fun test_grant_binds_scope() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx = ts::ctx(&mut scenario);
            let cap = new_cap(ctx);
            assert!(agent_cap::is_active(&cap), 0);
            assert!(agent_cap::owner(&cap) == OWNER, 1);
            assert!(agent_cap::grantee(&cap) == KEEPER, 2);
            assert!(agent_cap::managed_fund(&cap) == fund_a(), 2);
            assert!(agent_cap::guardrails_hash(&cap) == fake_hash(7), 3);
            assert!(agent_cap::allowlist_len(&cap) == 3, 4);
            assert!(agent_cap::max_allocation_bps(&cap) == 10_000, 5);
            assert!(agent_cap::reallocations(&cap) == 0, 6);
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// Keeper (grantee) may reallocate WITHIN the allowlist with the bound hash
    /// and correct fund — WITHOUT an owner signature.
    #[test]
    fun test_reallocate_within_scope_no_owner_sign() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx0);
            // Keeper drives the reallocation (no owner signature needed).
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_a(),
                fake_hash(7),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                5_000,
                ctx,
            );
            assert!(agent_cap::reallocations(&cap) == 1, 10);
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// A NON-grantee sender is rejected (E_NOT_GRANTEE) — delegated, not bearer.
    #[test]
    #[expected_failure(abort_code = 10, location = day::agent_cap)]
    fun test_non_grantee_cannot_reallocate() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx0);
            ts::next_tx(&mut scenario, STRANGER); // not the keeper
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_a(),
                fake_hash(7),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                5_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// A cap bound to fund_a cannot drive a reallocation for fund_b
    /// (E_WRONG_FUND) — forged / look-alike cap cannot poison a real fund.
    #[test]
    #[expected_failure(abort_code = 11, location = day::agent_cap)]
    fun test_wrong_fund_rejected() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx0); // bound to fund_a
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_b(), // wrong fund
                fake_hash(7),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                5_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// A destination outside the immutable allowlist aborts (E_OUT_OF_SCOPE).
    #[test]
    #[expected_failure(abort_code = 3, location = day::agent_cap)]
    fun test_reallocate_out_of_scope_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_a(),
                fake_hash(7),
                string::utf8(b"suilend"),
                string::utf8(b"aave"), // not in allowlist
                1_000_000,
                5_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// A different guardrails_hash (scope-widening attempt) aborts (E_HASH_MISMATCH).
    #[test]
    #[expected_failure(abort_code = 4, location = day::agent_cap)]
    fun test_reallocate_wrong_hash_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_a(),
                fake_hash(9), // wrong hash
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                5_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// After revoke, every reallocation aborts (E_REVOKED) — revocation is total.
    #[test]
    #[expected_failure(abort_code = 2, location = day::agent_cap)]
    fun test_revoke_blocks_reallocate() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx);
            agent_cap::revoke(&mut cap, ctx);
            assert!(!agent_cap::is_active(&cap), 20);
            assert!(agent_cap::allowlist_len(&cap) == 0, 21);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx2 = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_a(),
                fake_hash(7),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                5_000,
                ctx2,
            );
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// Only the recorded owner may revoke (E_NOT_OWNER for anyone else).
    #[test]
    #[expected_failure(abort_code = 1, location = day::agent_cap)]
    fun test_non_owner_cannot_revoke() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx = ts::ctx(&mut scenario);
            let cap = new_cap(ctx);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx2 = ts::ctx(&mut scenario);
            let mut cap2 = cap;
            agent_cap::revoke(&mut cap2, ctx2);
            agent_cap::destroy_for_testing(cap2);
        };
        ts::end(scenario);
    }

    /// Allocation over the immutable per-move cap aborts (E_MAX_ALLOCATION_EXCEEDED).
    #[test]
    #[expected_failure(abort_code = 8, location = day::agent_cap)]
    fun test_reallocate_over_max_bps_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            // cap max = 4000 bps
            let mut cap = agent_cap::grant_for_testing(
                OWNER,
                KEEPER,
                fund_a(),
                fake_hash(7),
                stable_allowlist(),
                4_000,
                ctx0,
            );
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate(
                &mut cap,
                fund_a(),
                fake_hash(7),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                5_000, // > 4000 cap
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    /// in_scope view: true for allowlisted while active, false after revoke.
    #[test]
    fun test_in_scope_view() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx = ts::ctx(&mut scenario);
            let mut cap = new_cap(ctx);
            assert!(agent_cap::in_scope(&cap, &string::utf8(b"navi")), 30);
            assert!(!agent_cap::in_scope(&cap, &string::utf8(b"aave")), 31);
            agent_cap::revoke(&mut cap, ctx);
            assert!(!agent_cap::in_scope(&cap, &string::utf8(b"navi")), 32);
            agent_cap::destroy_for_testing(cap);
        };
        ts::end(scenario);
    }

    // ==== DAY-569: guarded reallocate against the immutable on-chain Guardrails ====

    /// grant_bound records the Guardrails object id; is_guardrails_bound = true.
    #[test]
    fun test_grant_bound_records_guardrails_id() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx);
            let cap = new_bound_cap(&g, ctx);
            assert!(agent_cap::is_guardrails_bound(&cap), 0);
            assert!(
                agent_cap::guardrails_id(&cap) == option::some(guardrails::id(&g)),
                1,
            );
            assert!(agent_cap::guardrails_hash(&cap) == G_HASH, 2);
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }

    /// Keeper may reallocate WITHIN the on-chain Guardrails allowlist (no owner sig),
    /// enforced against the frozen Guardrails object (the source of truth).
    #[test]
    fun test_guarded_reallocate_within_onchain_scope() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_bound_cap(&g, ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g,
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                2_000, // <= 2500 on-chain max
                ctx,
            );
            assert!(agent_cap::reallocations(&cap) == 1, 10);
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }

    /// A destination OUTSIDE the immutable on-chain allowlist aborts with
    /// day::guardrails::E_OPPORTUNITY_NOT_ALLOWED — the money path is gated by the
    /// frozen Guardrails, not just the cap's inline copy (DAY-569 core assertion).
    #[test]
    #[expected_failure(abort_code = day::guardrails::E_OPPORTUNITY_NOT_ALLOWED)]
    fun test_guarded_reallocate_out_of_onchain_scope_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_bound_cap(&g, ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g,
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"gmx"), // NOT in on-chain allowlist
                1_000_000,
                2_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }

    /// Over the on-chain max_allocation_bps aborts day::guardrails::E_ALLOCATION_EXCEEDED.
    #[test]
    #[expected_failure(abort_code = day::guardrails::E_ALLOCATION_EXCEEDED)]
    fun test_guarded_reallocate_over_onchain_bps_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_bound_cap(&g, ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g,
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                2_501, // > 2500 on-chain max
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }

    /// Zero allocation bps is a no-op on the guarded money path and must abort
    /// instead of passing the max-bps check as an in-scope allocation.
    #[test]
    #[expected_failure(abort_code = day::agent_cap::E_ZERO_AMOUNT)]
    fun test_guarded_reallocate_zero_bps_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_bound_cap(&g, ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g,
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                0,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }

    /// Presenting a DIFFERENT (wider) Guardrails object than the one bound aborts
    /// E_WRONG_GUARDRAILS — the keeper cannot swap in a wider Scope.
    #[test]
    #[expected_failure(abort_code = day::agent_cap::E_WRONG_GUARDRAILS)]
    fun test_guarded_reallocate_wrong_guardrails_object_aborts() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_bound_cap(&g, ctx0); // bound to g
            // A second, distinct Guardrails object (different id, same bytes).
            let g_other = new_guardrails(ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g_other, // not the bound object
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                2_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
            guardrails::destroy_for_testing(g_other);
        };
        ts::end(scenario);
    }

    /// A legacy UNBOUND cap cannot use the guarded path (E_NOT_GUARDRAILS_BOUND).
    #[test]
    #[expected_failure(abort_code = day::agent_cap::E_NOT_GUARDRAILS_BOUND)]
    fun test_guarded_reallocate_requires_binding() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_cap(ctx0); // legacy unbound cap
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g,
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                2_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }

    /// Revocation still totally blocks the guarded path (E_REVOKED).
    #[test]
    #[expected_failure(abort_code = day::agent_cap::E_REVOKED)]
    fun test_guarded_reallocate_blocked_after_revoke() {
        let mut scenario = ts::begin(OWNER);
        {
            let ctx0 = ts::ctx(&mut scenario);
            let g = new_guardrails(ctx0);
            let mut cap = new_bound_cap(&g, ctx0);
            // Owner revokes.
            agent_cap::revoke(&mut cap, ctx0);
            ts::next_tx(&mut scenario, KEEPER);
            let ctx = ts::ctx(&mut scenario);
            agent_cap::authorize_reallocate_guarded(
                &mut cap,
                &g,
                fund_a(),
                string::utf8(b"suilend"),
                string::utf8(b"navi"),
                1_000_000,
                2_000,
                ctx,
            );
            agent_cap::destroy_for_testing(cap);
            guardrails::destroy_for_testing(g);
        };
        ts::end(scenario);
    }
}
