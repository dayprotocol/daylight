// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY GuardrailsV2 — frozen Tier-1 predicates for a managed Strategy (DAY-847).
/// Independent dimensions are ANDed; values within one allowlist are alternatives.
/// Unknown/incomplete descriptors fail closed. Keeper-supplied TVL/APY metrics and
/// symbol bytes are never authorization inputs.
module day::guardrails_v2 {
    use day::guardrails_v2_canonical;
    use std::bcs;
    use std::hash;
    use std::type_name::{Self, TypeName};
    use sui::event;
    use sui::vec_set::{Self, VecSet};
    // ---- Schema and bounds -------------------------------------------------
    const SCHEMA_VERSION: u64 = 2;
    const BASIS_POINTS: u64 = 10_000;
    const HASH_LEN: u64 = 32;
    const MAX_SET_SIZE: u64 = 64;
    // Predicate tags are hash-bound; unknown tags abort.
    const PREDICATE_ASSET_TYPE_ALLOWLIST: u8 = 1;
    const PREDICATE_OPPORTUNITY_ALLOWLIST: u8 = 2;
    const PREDICATE_CHAIN_ALLOWLIST: u8 = 3;
    const PREDICATE_MAX_ALLOCATION_BPS: u8 = 4;
    const SUPPORTED_PREDICATE_COUNT: u64 = 4;
    // Sui uses original TypeName; Solana/EVM use exact native bytes, never symbols.
    const ASSET_KIND_SUI_TYPE: u8 = 1;
    const ASSET_KIND_SOLANA_MINT: u8 = 2;
    const ASSET_KIND_EVM_TOKEN: u8 = 3;
    const SOLANA_MINT_LEN: u64 = 32;
    const EVM_TOKEN_LEN: u64 = 20;
    // ---- Error codes -------------------------------------------------------
    const E_HASH_MISMATCH: u64 = 1;
    const E_BAD_HASH_LEN: u64 = 2;
    const E_NOT_STRATEGY_LEAD: u64 = 3;
    const E_EMPTY_ASSET_ALLOWLIST: u64 = 4;
    const E_EMPTY_OPPORTUNITY_ALLOWLIST: u64 = 5;
    const E_EMPTY_CHAIN_ALLOWLIST: u64 = 6;
    const E_INVALID_BPS: u64 = 7;
    const E_INVALID_OPPORTUNITY_ID: u64 = 8;
    const E_INVALID_CHAIN_ID: u64 = 9;
    const E_DUPLICATE_ALLOWED_VALUE: u64 = 10;
    const E_DUPLICATE_PREDICATE: u64 = 11;
    const E_UNKNOWN_PREDICATE: u64 = 12;
    const E_INCOMPLETE_PREDICATES: u64 = 13;
    const E_ASSET_NOT_ALLOWED: u64 = 14;
    const E_OPPORTUNITY_NOT_ALLOWED: u64 = 15;
    const E_CHAIN_NOT_ALLOWED: u64 = 16;
    const E_ALLOCATION_EXCEEDED: u64 = 17;
    const E_INVALID_ASSET_TYPE: u64 = 18;
    const E_SET_TOO_LARGE: u64 = 19;
    const E_UNKNOWN_ASSET_KIND: u64 = 20;
    const E_MALFORMED_NATIVE_ASSET: u64 = 21;
    const E_REMOTE_ASSET_NOT_CONFIGURED: u64 = 22;
    const E_UNSUPPORTED_BINDING_SCHEMA: u64 = 23;
    // ---- Policy representation --------------------------------------------
    /// Auditable dispatch descriptor; one tag per independent dimension.
    public struct PredicateDescriptor has copy, drop, store {
        tag: u8,
    }
    /// Canonical identity shared across policy, commands, receipts, and events.
    public struct NativeAssetBinding has copy, drop, store {
        schema_version: u8,
        kind: u8,
        chain_id: vector<u8>,
        /// VM-produced original TypeName; callers cannot forge it from a symbol.
        original_id_type: Option<TypeName>,
        /// Exact decoded mint/address for remote identities; empty for Sui.
        native_id: vector<u8>,
    }
    /// Exact policy committed by guardrails_hash and canonical_preimage.
    public struct Tier1Policy has copy, drop, store {
        schema_version: u64,
        strategy_lead: address,
        predicates: vector<PredicateDescriptor>,
        allowed_asset_types: VecSet<TypeName>,
        /// Frozen identities; remote entries are returned only by policy lookup.
        allowed_native_assets: VecSet<NativeAssetBinding>,
        allowed_opportunity_ids: VecSet<vector<u8>>,
        allowed_chain_ids: VecSet<vector<u8>>,
        max_allocation_bps: u64,
    }
    /// Lead-authenticated builder consumed by finalize_and_freeze.
    public struct GuardrailsV2Builder has key, store {
        id: UID,
        strategy_lead: address,
        allowed_asset_types: VecSet<TypeName>,
        allowed_native_assets: VecSet<NativeAssetBinding>,
        allowed_opportunity_ids: VecSet<vector<u8>>,
        allowed_chain_ids: VecSet<vector<u8>>,
        max_allocation_bps: u64,
    }
    /// Immutable managed-Strategy policy. It holds no Balance or Coin.
    public struct GuardrailsV2 has key, store {
        id: UID,
        guardrails_hash: vector<u8>,
        canonical_preimage: vector<u8>,
        policy: Tier1Policy,
    }
    public struct GuardrailsV2Created has copy, drop {
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        strategy_lead: address,
        asset_type_count: u64,
        opportunity_count: u64,
        chain_count: u64,
        max_allocation_bps: u64,
    }

    // ---- Canonical native asset identity ---------------------------------

    /// Sui identity is generic/original-id derived; no bytes constructor exists.
    public(package) fun sui_asset_binding<Asset>(): NativeAssetBinding {
        let asset_type = type_name::with_original_ids<Asset>();
        assert!(!type_name::is_primitive(&asset_type), E_INVALID_ASSET_TYPE);
        NativeAssetBinding {
            schema_version: 1,
            kind: ASSET_KIND_SUI_TYPE,
            chain_id: b"sui",
            original_id_type: option::some(asset_type),
            native_id: vector[],
        }
    }

    /// Test-only exact decoded Solana mint constructor.
    #[test_only]
    public fun solana_asset_binding(mint: vector<u8>): NativeAssetBinding {
        checked_solana_binding(mint)
    }

    fun checked_solana_binding(mint: vector<u8>): NativeAssetBinding {
        assert!(vector::length(&mint) == SOLANA_MINT_LEN, E_MALFORMED_NATIVE_ASSET);
        assert!(!all_zero(&mint), E_MALFORMED_NATIVE_ASSET);
        NativeAssetBinding {
            schema_version: 1,
            kind: ASSET_KIND_SOLANA_MINT,
            chain_id: b"solana",
            original_id_type: option::none(),
            native_id: mint,
        }
    }

    /// Test-only exact EVM token constructor for known DAY chain ids.
    #[test_only]
    public fun evm_asset_binding(
        chain_id: vector<u8>,
        token_address: vector<u8>,
    ): NativeAssetBinding {
        checked_evm_binding(chain_id, token_address)
    }

    fun checked_evm_binding(
        chain_id: vector<u8>,
        token_address: vector<u8>,
    ): NativeAssetBinding {
        assert!(chain_id == b"base" || chain_id == b"arbitrum", E_MALFORMED_NATIVE_ASSET);
        assert!(vector::length(&token_address) == EVM_TOKEN_LEN, E_MALFORMED_NATIVE_ASSET);
        assert!(!all_zero(&token_address), E_MALFORMED_NATIVE_ASSET);
        NativeAssetBinding {
            schema_version: 1,
            kind: ASSET_KIND_EVM_TOKEN,
            chain_id,
            original_id_type: option::none(),
            native_id: token_address,
        }
    }

    /// Re-validates values decoded from BCS before authorization. Unknown tags
    /// have an explicit abort branch; there is no default-success behavior.
    public(package) fun assert_native_asset_binding(binding: &NativeAssetBinding) {
        assert!(binding.schema_version == 1, E_UNSUPPORTED_BINDING_SCHEMA);
        if (binding.kind == ASSET_KIND_SUI_TYPE) {
            assert!(binding.chain_id == b"sui", E_MALFORMED_NATIVE_ASSET);
            assert!(option::is_some(&binding.original_id_type), E_MALFORMED_NATIVE_ASSET);
            assert!(vector::is_empty(&binding.native_id), E_MALFORMED_NATIVE_ASSET);
            assert!(
                !type_name::is_primitive(option::borrow(&binding.original_id_type)),
                E_MALFORMED_NATIVE_ASSET,
            );
        } else if (binding.kind == ASSET_KIND_SOLANA_MINT) {
            assert!(binding.chain_id == b"solana", E_MALFORMED_NATIVE_ASSET);
            assert!(!option::is_some(&binding.original_id_type), E_MALFORMED_NATIVE_ASSET);
            assert!(vector::length(&binding.native_id) == SOLANA_MINT_LEN, E_MALFORMED_NATIVE_ASSET);
            assert!(!all_zero(&binding.native_id), E_MALFORMED_NATIVE_ASSET);
        } else if (binding.kind == ASSET_KIND_EVM_TOKEN) {
            assert!(
                binding.chain_id == b"base" || binding.chain_id == b"arbitrum",
                E_MALFORMED_NATIVE_ASSET,
            );
            assert!(!option::is_some(&binding.original_id_type), E_MALFORMED_NATIVE_ASSET);
            assert!(vector::length(&binding.native_id) == EVM_TOKEN_LEN, E_MALFORMED_NATIVE_ASSET);
            assert!(!all_zero(&binding.native_id), E_MALFORMED_NATIVE_ASSET);
        } else {
            abort E_UNKNOWN_ASSET_KIND
        };
    }

    public(package) fun native_asset_chain_id(binding: &NativeAssetBinding): vector<u8> {
        assert_native_asset_binding(binding);
        binding.chain_id
    }

    /// Canonical V1 commitment bytes use the frozen struct field order:
    /// schema, kind, exact chain, original-id TypeName marker, native id.
    public(package) fun native_asset_canonical_v1_bytes(
        binding: &NativeAssetBinding,
    ): vector<u8> {
        assert_native_asset_binding(binding);
        bcs::to_bytes(binding)
    }

    public(package) fun same_native_asset_binding(
        left: &NativeAssetBinding,
        right: &NativeAssetBinding,
    ): bool {
        assert_native_asset_binding(left);
        assert_native_asset_binding(right);
        left.schema_version == right.schema_version
            && left.kind == right.kind
            && left.chain_id == right.chain_id
            && left.original_id_type == right.original_id_type
            && left.native_id == right.native_id
    }

    /// V2's published predicate schema contains only Sui TypeName assets. A
    /// well-formed remote identity is auditable and hashable, but cannot become
    /// authorized by being mistaken for a Sui TypeName. Remote execution stays
    /// fail-closed until a future schema version adds a native remote allowlist.
    /// The sole production remote creation path: exact lookup from a verified,
    /// hash-bound frozen policy. Caller bytes can select an existing entry but
    /// cannot fabricate or alter a NativeAssetBinding.
    public(package) fun native_asset_binding_from_policy(
        guardrails: &GuardrailsV2,
        chain_id: vector<u8>,
        native_id: vector<u8>,
    ): NativeAssetBinding {
        assert!(verify_hash(guardrails), E_HASH_MISMATCH);
        let values = vec_set::keys(&guardrails.policy.allowed_native_assets);
        let mut i = 0;
        while (i < vector::length(values)) {
            let binding = vector::borrow(values, i);
            assert_native_asset_binding(binding);
            if (binding.chain_id == chain_id && binding.native_id == native_id) {
                assert!(binding.kind != ASSET_KIND_SUI_TYPE, E_REMOTE_ASSET_NOT_CONFIGURED);
                return *binding
            };
            i = i + 1;
        };
        abort E_REMOTE_ASSET_NOT_CONFIGURED
    }

    /// Validate one native identity and its chain against the exact frozen
    /// policy. This package-only primitive intentionally omits opportunity and
    /// allocation so route validation can apply those only to real endpoints.
    public(package) fun assert_native_asset_and_chain_allowed(
        guardrails: &GuardrailsV2,
        binding: &NativeAssetBinding,
    ) {
        assert!(verify_hash(guardrails), E_HASH_MISMATCH);
        validate_predicate_shape(&guardrails.policy.predicates);
        assert_native_asset_binding(binding);
        assert!(
            vec_set::contains(&guardrails.policy.allowed_native_assets, binding),
            E_ASSET_NOT_ALLOWED,
        );
        assert!(
            vec_set::contains(&guardrails.policy.allowed_chain_ids, &binding.chain_id),
            E_CHAIN_NOT_ALLOWED,
        );
    }

    /// Check every Tier-1 dimension against one frozen-policy binding.
    public(package) fun assert_native_allocation_allowed(
        guardrails: &GuardrailsV2,
        binding: &NativeAssetBinding,
        opportunity_id: vector<u8>,
        allocation_bps: u64,
    ) {
        assert_native_asset_and_chain_allowed(guardrails, binding);
        assert!(vec_set::contains(&guardrails.policy.allowed_opportunity_ids, &opportunity_id), E_OPPORTUNITY_NOT_ALLOWED);
        assert!(
            allocation_bps > 0 && allocation_bps <= guardrails.policy.max_allocation_bps,
            E_ALLOCATION_EXCEEDED,
        );
    }

    fun all_zero(bytes: &vector<u8>): bool {
        let mut i = 0;
        while (i < vector::length(bytes)) {
            if (*vector::borrow(bytes, i) != 0) return false;
            i = i + 1;
        };
        true
    }

    // ---- Builder -----------------------------------------------------------

    /// Begin an unpublished V2 policy. The PTB may call the generic asset setter
    /// once per allowed native type, add exact ids, preview the hash, then freeze.
    public fun new_builder(ctx: &mut TxContext): GuardrailsV2Builder {
        GuardrailsV2Builder {
            id: object::new(ctx),
            strategy_lead: tx_context::sender(ctx),
            allowed_asset_types: vec_set::empty(),
            allowed_native_assets: vec_set::empty(),
            allowed_opportunity_ids: vec_set::empty(),
            allowed_chain_ids: vec_set::empty(),
            max_allocation_bps: 0,
        }
    }

    /// Add an asset by its chain-native original-package TypeName. A token with the
    /// same display symbol but a different defining type cannot satisfy this entry.
    public fun add_allowed_asset<Asset>(builder: &mut GuardrailsV2Builder, ctx: &TxContext) {
        assert_lead(builder, ctx);
        assert!(vec_set::length(&builder.allowed_asset_types) < MAX_SET_SIZE, E_SET_TOO_LARGE);
        assert!(vec_set::length(&builder.allowed_native_assets) < MAX_SET_SIZE, E_SET_TOO_LARGE);
        let asset_type = type_name::with_original_ids<Asset>();
        assert!(!type_name::is_primitive(&asset_type), E_INVALID_ASSET_TYPE);
        assert!(
            !vec_set::contains(&builder.allowed_asset_types, &asset_type),
            E_DUPLICATE_ALLOWED_VALUE,
        );
        vec_set::insert(&mut builder.allowed_asset_types, asset_type);
        let binding = sui_asset_binding<Asset>();
        assert!(
            !vec_set::contains(&builder.allowed_native_assets, &binding),
            E_DUPLICATE_ALLOWED_VALUE,
        );
        vec_set::insert(&mut builder.allowed_native_assets, binding);
    }

    /// Register exact remote identities in the unpublished, Lead-owned policy.
    /// These setters return no binding. Executable code can obtain one only by
    /// exact lookup from the finalized hash-bound GuardrailsV2 object.
    public fun add_allowed_solana_asset(
        builder: &mut GuardrailsV2Builder,
        mint: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_lead(builder, ctx);
        insert_native_binding(builder, checked_solana_binding(mint));
    }

    public fun add_allowed_evm_asset(
        builder: &mut GuardrailsV2Builder,
        chain_id: vector<u8>,
        token_address: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_lead(builder, ctx);
        insert_native_binding(builder, checked_evm_binding(chain_id, token_address));
    }

    /// Add one DAY-800 canonical opportunity id: `dayop` plus ten lowercase hex
    /// characters. Matching is exact byte equality; protocol slugs are never ids.
    public fun add_allowed_opportunity(
        builder: &mut GuardrailsV2Builder,
        opportunity_id: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_lead(builder, ctx);
        assert!(
            guardrails_v2_canonical::is_canonical_opportunity_id(&opportunity_id),
            E_INVALID_OPPORTUNITY_ID,
        );
        assert!(vec_set::length(&builder.allowed_opportunity_ids) < MAX_SET_SIZE, E_SET_TOO_LARGE);
        assert!(
            !vec_set::contains(&builder.allowed_opportunity_ids, &opportunity_id),
            E_DUPLICATE_ALLOWED_VALUE,
        );
        vec_set::insert(&mut builder.allowed_opportunity_ids, opportunity_id);
    }

    /// Add one canonical chain id (for example b"sui" or b"solana"). Matching is
    /// exact; uppercase aliases and surrounding whitespace are invalid, not normalized.
    public fun add_allowed_chain(
        builder: &mut GuardrailsV2Builder,
        chain_id: vector<u8>,
        ctx: &TxContext,
    ) {
        assert_lead(builder, ctx);
        assert!(guardrails_v2_canonical::is_canonical_chain_id(&chain_id), E_INVALID_CHAIN_ID);
        assert!(vec_set::length(&builder.allowed_chain_ids) < MAX_SET_SIZE, E_SET_TOO_LARGE);
        assert!(
            !vec_set::contains(&builder.allowed_chain_ids, &chain_id),
            E_DUPLICATE_ALLOWED_VALUE,
        );
        vec_set::insert(&mut builder.allowed_chain_ids, chain_id);
    }

    /// Set the one max-allocation predicate. A second setter would be two predicates
    /// for the same dimension, so it is rejected rather than given ambiguous semantics.
    public fun set_max_allocation_bps(
        builder: &mut GuardrailsV2Builder,
        max_allocation_bps: u64,
        ctx: &TxContext,
    ) {
        assert_lead(builder, ctx);
        assert!(builder.max_allocation_bps == 0, E_DUPLICATE_PREDICATE);
        assert!(
            max_allocation_bps >= 1 && max_allocation_bps <= BASIS_POINTS,
            E_INVALID_BPS,
        );
        builder.max_allocation_bps = max_allocation_bps;
    }

    /// Canonical BCS preimage generated from the exact typed sets that will be stored.
    /// All sets are sorted so semantically identical policies have identical bytes.
    public fun preview_preimage(builder: &GuardrailsV2Builder): vector<u8> {
        let policy = policy_from_builder(builder);
        bcs::to_bytes(&policy)
    }

    /// sha2_256(preview_preimage). Off-chain tooling can reproduce the same BCS bytes.
    public fun preview_hash(builder: &GuardrailsV2Builder): vector<u8> {
        hash::sha2_256(preview_preimage(builder))
    }

    /// Consume the builder, verify expected_hash against the on-chain BCS policy bytes,
    /// and freeze the resulting object forever.
    public fun finalize_and_freeze(
        builder: GuardrailsV2Builder,
        expected_hash: vector<u8>,
        ctx: &mut TxContext,
    ): ID {
        let g = finalize(builder, expected_hash, ctx);
        let gid = object::id(&g);
        event::emit(GuardrailsV2Created {
            guardrails_id: gid,
            guardrails_hash: g.guardrails_hash,
            strategy_lead: g.policy.strategy_lead,
            asset_type_count: vec_set::length(&g.policy.allowed_asset_types),
            opportunity_count: vec_set::length(&g.policy.allowed_opportunity_ids),
            chain_count: vec_set::length(&g.policy.allowed_chain_ids),
            max_allocation_bps: g.policy.max_allocation_bps,
        });
        transfer::freeze_object(g);
        gid
    }

    // ---- Enforcement -------------------------------------------------------

    /// Non-aborting for valid policies. A malformed frozen policy (unknown, duplicate,
    /// or missing descriptor) aborts fail-closed before evaluating candidate inputs.
    public fun allocation_allowed<Asset>(
        g: &GuardrailsV2,
        opportunity_id: vector<u8>,
        chain_id: vector<u8>,
        allocation_bps: u64,
    ): bool {
        evaluate<Asset>(g, &opportunity_id, &chain_id, allocation_bps) == 0
    }

    /// Assert every supported predicate with AND semantics. Asset identity comes only
    /// from Asset's native TypeName; there is no caller-supplied symbol parameter.
    public fun assert_allocation_allowed<Asset>(
        g: &GuardrailsV2,
        opportunity_id: vector<u8>,
        chain_id: vector<u8>,
        allocation_bps: u64,
    ) {
        let error = evaluate<Asset>(g, &opportunity_id, &chain_id, allocation_bps);
        assert!(error == 0, error);
    }

    fun evaluate<Asset>(
        g: &GuardrailsV2,
        opportunity_id: &vector<u8>,
        chain_id: &vector<u8>,
        allocation_bps: u64,
    ): u64 {
        validate_predicate_shape(&g.policy.predicates);
        let asset_type = type_name::with_original_ids<Asset>();
        let predicates = &g.policy.predicates;
        let n = vector::length(predicates);
        let mut i = 0;
        while (i < n) {
            let tag = vector::borrow(predicates, i).tag;
            if (tag == PREDICATE_ASSET_TYPE_ALLOWLIST) {
                if (!vec_set::contains(&g.policy.allowed_asset_types, &asset_type)) {
                    return E_ASSET_NOT_ALLOWED
                }
            } else if (tag == PREDICATE_OPPORTUNITY_ALLOWLIST) {
                if (!vec_set::contains(&g.policy.allowed_opportunity_ids, opportunity_id)) {
                    return E_OPPORTUNITY_NOT_ALLOWED
                }
            } else if (tag == PREDICATE_CHAIN_ALLOWLIST) {
                if (!vec_set::contains(&g.policy.allowed_chain_ids, chain_id)) {
                    return E_CHAIN_NOT_ALLOWED
                }
            } else if (tag == PREDICATE_MAX_ALLOCATION_BPS) {
                if (allocation_bps == 0 || allocation_bps > g.policy.max_allocation_bps) {
                    return E_ALLOCATION_EXCEEDED
                }
            } else {
                // Defense in depth: validate_predicate_shape already rejects this.
                return E_UNKNOWN_PREDICATE
            };
            i = i + 1;
        };
        0
    }

    // ---- Verification and accessors ---------------------------------------

    /// Verify both halves of the commitment: stored policy -> BCS preimage -> hash.
    public fun verify_hash(g: &GuardrailsV2): bool {
        let recomputed_preimage = bcs::to_bytes(&g.policy);
        recomputed_preimage == g.canonical_preimage
            && hash::sha2_256(recomputed_preimage) == g.guardrails_hash
    }

    public fun matches_hash(g: &GuardrailsV2, candidate: vector<u8>): bool {
        candidate == g.guardrails_hash
    }

    public fun id(g: &GuardrailsV2): ID { object::id(g) }

    public fun guardrails_hash(g: &GuardrailsV2): vector<u8> { g.guardrails_hash }

    public fun canonical_preimage(g: &GuardrailsV2): vector<u8> { g.canonical_preimage }

    public fun schema_version(g: &GuardrailsV2): u64 { g.policy.schema_version }

    public fun strategy_lead(g: &GuardrailsV2): address { g.policy.strategy_lead }

    public fun max_allocation_bps(g: &GuardrailsV2): u64 { g.policy.max_allocation_bps }

    public fun asset_type_count(g: &GuardrailsV2): u64 {
        vec_set::length(&g.policy.allowed_asset_types)
    }

    public fun opportunity_count(g: &GuardrailsV2): u64 {
        vec_set::length(&g.policy.allowed_opportunity_ids)
    }

    public fun chain_count(g: &GuardrailsV2): u64 {
        vec_set::length(&g.policy.allowed_chain_ids)
    }

    // ---- Internal validation ----------------------------------------------

    fun assert_lead(builder: &GuardrailsV2Builder, ctx: &TxContext) {
        assert!(builder.strategy_lead == tx_context::sender(ctx), E_NOT_STRATEGY_LEAD);
    }

    fun insert_native_binding(
        builder: &mut GuardrailsV2Builder,
        binding: NativeAssetBinding,
    ) {
        assert_native_asset_binding(&binding);
        assert!(vec_set::length(&builder.allowed_native_assets) < MAX_SET_SIZE, E_SET_TOO_LARGE);
        assert!(
            !vec_set::contains(&builder.allowed_native_assets, &binding),
            E_DUPLICATE_ALLOWED_VALUE,
        );
        vec_set::insert(&mut builder.allowed_native_assets, binding);
    }

    fun sorted_native_bindings(
        source: &VecSet<NativeAssetBinding>,
    ): VecSet<NativeAssetBinding> {
        let mut values = vec_set::into_keys(*source);
        let n = vector::length(&values);
        let mut i = 0;
        while (i < n) {
            let mut least = i;
            let mut j = i + 1;
            while (j < n) {
                if (guardrails_v2_canonical::bytes_before(
                    &bcs::to_bytes(vector::borrow(&values, j)),
                    &bcs::to_bytes(vector::borrow(&values, least)),
                )) least = j;
                j = j + 1;
            };
            if (least != i) vector::swap(&mut values, i, least);
            i = i + 1;
        };
        vec_set::from_keys(values)
    }

    fun canonical_predicates(): vector<PredicateDescriptor> {
        vector[
            PredicateDescriptor { tag: PREDICATE_ASSET_TYPE_ALLOWLIST },
            PredicateDescriptor { tag: PREDICATE_OPPORTUNITY_ALLOWLIST },
            PredicateDescriptor { tag: PREDICATE_CHAIN_ALLOWLIST },
            PredicateDescriptor { tag: PREDICATE_MAX_ALLOCATION_BPS },
        ]
    }

    fun policy_from_builder(builder: &GuardrailsV2Builder): Tier1Policy {
        Tier1Policy {
            schema_version: SCHEMA_VERSION,
            strategy_lead: builder.strategy_lead,
            predicates: canonical_predicates(),
            allowed_asset_types: guardrails_v2_canonical::sorted_asset_types(
                &builder.allowed_asset_types,
            ),
            allowed_native_assets: sorted_native_bindings(&builder.allowed_native_assets),
            allowed_opportunity_ids: guardrails_v2_canonical::sorted_byte_values(
                &builder.allowed_opportunity_ids,
            ),
            allowed_chain_ids: guardrails_v2_canonical::sorted_byte_values(
                &builder.allowed_chain_ids,
            ),
            max_allocation_bps: builder.max_allocation_bps,
        }
    }

    fun finalize(
        builder: GuardrailsV2Builder,
        expected_hash: vector<u8>,
        ctx: &mut TxContext,
    ): GuardrailsV2 {
        assert_lead(&builder, ctx);
        assert_complete_builder(&builder);
        assert!(vector::length(&expected_hash) == HASH_LEN, E_BAD_HASH_LEN);
        let policy = policy_from_builder(&builder);
        validate_predicate_shape(&policy.predicates);
        let canonical_preimage = bcs::to_bytes(&policy);
        let computed_hash = hash::sha2_256(canonical_preimage);
        assert!(computed_hash == expected_hash, E_HASH_MISMATCH);

        let GuardrailsV2Builder {
            id: builder_id,
            strategy_lead: _,
            allowed_asset_types: _,
            allowed_native_assets: _,
            allowed_opportunity_ids: _,
            allowed_chain_ids: _,
            max_allocation_bps: _,
        } = builder;
        object::delete(builder_id);

        GuardrailsV2 {
            id: object::new(ctx),
            guardrails_hash: expected_hash,
            canonical_preimage,
            policy,
        }
    }

    fun assert_complete_builder(builder: &GuardrailsV2Builder) {
        assert!(!vec_set::is_empty(&builder.allowed_asset_types), E_EMPTY_ASSET_ALLOWLIST);
        assert!(
            !vec_set::is_empty(&builder.allowed_opportunity_ids),
            E_EMPTY_OPPORTUNITY_ALLOWLIST,
        );
        assert!(!vec_set::is_empty(&builder.allowed_chain_ids), E_EMPTY_CHAIN_ALLOWLIST);
        assert!(
            builder.max_allocation_bps >= 1 && builder.max_allocation_bps <= BASIS_POINTS,
            E_INVALID_BPS,
        );
    }

    fun validate_predicate_shape(predicates: &vector<PredicateDescriptor>) {
        assert!(vector::length(predicates) == SUPPORTED_PREDICATE_COUNT, E_INCOMPLETE_PREDICATES);
        let mut seen_asset = false;
        let mut seen_opportunity = false;
        let mut seen_chain = false;
        let mut seen_max_bps = false;
        let n = vector::length(predicates);
        let mut i = 0;
        while (i < n) {
            let tag = vector::borrow(predicates, i).tag;
            if (tag == PREDICATE_ASSET_TYPE_ALLOWLIST) {
                assert!(!seen_asset, E_DUPLICATE_PREDICATE);
                seen_asset = true;
            } else if (tag == PREDICATE_OPPORTUNITY_ALLOWLIST) {
                assert!(!seen_opportunity, E_DUPLICATE_PREDICATE);
                seen_opportunity = true;
            } else if (tag == PREDICATE_CHAIN_ALLOWLIST) {
                assert!(!seen_chain, E_DUPLICATE_PREDICATE);
                seen_chain = true;
            } else if (tag == PREDICATE_MAX_ALLOCATION_BPS) {
                assert!(!seen_max_bps, E_DUPLICATE_PREDICATE);
                seen_max_bps = true;
            } else {
                abort E_UNKNOWN_PREDICATE
            };
            i = i + 1;
        };
        assert!(seen_asset && seen_opportunity && seen_chain && seen_max_bps, E_INCOMPLETE_PREDICATES);
    }

    // ---- Test helpers ------------------------------------------------------

    #[test_only]
    public fun finalize_for_testing(
        builder: GuardrailsV2Builder,
        expected_hash: vector<u8>,
        ctx: &mut TxContext,
    ): GuardrailsV2 {
        finalize(builder, expected_hash, ctx)
    }

    #[test_only]
    public fun finalize_with_tags_for_testing(
        builder: GuardrailsV2Builder,
        tags: vector<u8>,
        ctx: &mut TxContext,
    ): GuardrailsV2 {
        assert_lead(&builder, ctx);
        assert_complete_builder(&builder);
        let predicates = descriptors_from_tags(tags);
        validate_predicate_shape(&predicates);
        finish_with_predicates_for_testing(builder, predicates, ctx)
    }

    /// Forge malformed descriptors only so enforcement's fail-closed branch is testable.
    #[test_only]
    public fun forge_with_tags_for_testing(
        builder: GuardrailsV2Builder,
        tags: vector<u8>,
        ctx: &mut TxContext,
    ): GuardrailsV2 {
        let predicates = descriptors_from_tags(tags);
        finish_with_predicates_for_testing(builder, predicates, ctx)
    }

    #[test_only]
    fun finish_with_predicates_for_testing(
        builder: GuardrailsV2Builder,
        predicates: vector<PredicateDescriptor>,
        ctx: &mut TxContext,
    ): GuardrailsV2 {
        let policy = Tier1Policy {
            schema_version: SCHEMA_VERSION,
            strategy_lead: builder.strategy_lead,
            predicates,
            allowed_asset_types: guardrails_v2_canonical::sorted_asset_types(
                &builder.allowed_asset_types,
            ),
            allowed_native_assets: sorted_native_bindings(&builder.allowed_native_assets),
            allowed_opportunity_ids: guardrails_v2_canonical::sorted_byte_values(
                &builder.allowed_opportunity_ids,
            ),
            allowed_chain_ids: guardrails_v2_canonical::sorted_byte_values(
                &builder.allowed_chain_ids,
            ),
            max_allocation_bps: builder.max_allocation_bps,
        };
        let canonical_preimage = bcs::to_bytes(&policy);
        let guardrails_hash = hash::sha2_256(canonical_preimage);
        let GuardrailsV2Builder {
            id: builder_id,
            strategy_lead: _,
            allowed_asset_types: _,
            allowed_native_assets: _,
            allowed_opportunity_ids: _,
            allowed_chain_ids: _,
            max_allocation_bps: _,
        } = builder;
        object::delete(builder_id);
        GuardrailsV2 {
            id: object::new(ctx),
            guardrails_hash,
            canonical_preimage,
            policy,
        }
    }

    #[test_only]
    fun descriptors_from_tags(tags: vector<u8>): vector<PredicateDescriptor> {
        let mut out = vector[];
        let n = vector::length(&tags);
        let mut i = 0;
        while (i < n) {
            vector::push_back(&mut out, PredicateDescriptor { tag: *vector::borrow(&tags, i) });
            i = i + 1;
        };
        out
    }

    #[test_only]
    public fun destroy_for_testing(g: GuardrailsV2) {
        let GuardrailsV2 {
            id,
            guardrails_hash: _,
            canonical_preimage: _,
            policy: _,
        } = g;
        object::delete(id);
    }

    #[test_only]
    public fun forge_native_asset_binding_for_testing(
        schema_version: u8,
        kind: u8,
        chain_id: vector<u8>,
        original_id_type: Option<TypeName>,
        native_id: vector<u8>,
    ): NativeAssetBinding {
        NativeAssetBinding {
            schema_version,
            kind,
            chain_id,
            original_id_type,
            native_id,
        }
    }

    #[test_only]
    public fun destroy_builder_for_testing(builder: GuardrailsV2Builder) {
        let GuardrailsV2Builder {
            id,
            strategy_lead: _,
            allowed_asset_types: _,
            allowed_native_assets: _,
            allowed_opportunity_ids: _,
            allowed_chain_ids: _,
            max_allocation_bps: _,
        } = builder;
        object::delete(id);
    }
}
