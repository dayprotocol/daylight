// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-848 canonical hub-and-spoke command protocol.
///
/// Sui is the only policy plane. The sole production HubState constructor is
/// a one-shot bootstrap bound to DAY's canonical ProtocolConfig,
/// StrategyRegistry, existing AdminCap, and governance sender. A live command
/// path must also perform DAY-847's typed per-leg checks, then hand the bytes
/// produced here to the LayerZero OApp.
/// Mayan remains an asset rail and is not a command authority.
///
/// A receiving spoke authenticates LayerZero transport metadata against its
/// pinned DAY hub peer. Leader identity is checked once on Sui and is never
/// serialized into a command or independently configured on a spoke.
module day::hub_protocol {
    use day::day::{Self, ProtocolConfig};
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::leader_policy::{Self, ReallocationPolicyWitness};
    use day::managed_reallocation::{Self, ReallocationReservation};
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use call::{
        call::{Self as lz_call, Call},
        call_cap::{Self as call_cap, CallCap},
    };
    use endpoint_v2::{
        endpoint_send::{Self as endpoint_send, SendParam},
        endpoint_v2::EndpointV2,
        messaging_fee,
        messaging_receipt::{Self as messaging_receipt, MessagingReceipt},
        utils as endpoint_utils,
    };
    use std::hash;
    use sui::bcs;
    use sui::clock::{Self, Clock};
    use sui::event;
    use utils::{bytes32, package as lz_package};

    // ---- Wire protocol -----------------------------------------------------

    const DOMAIN: vector<u8> = b"DAY_HUB";
    const INTENT_DOMAIN: vector<u8> = b"DAY_INTENT";
    const VERSION: u8 = 1;
    const ACTION_REALLOCATE: u8 = 1;
    const ACTION_EXIT_MODE: u8 = 2;

    /// LayerZero endpoint id assigned to Sui mainnet.
    const SUI_LAYERZERO_EID: u32 = 30_378;
    const BASE_LAYERZERO_EID: u32 = 30_184;
    const ARBITRUM_LAYERZERO_EID: u32 = 30_110;
    const SOLANA_LAYERZERO_EID: u32 = 30_168;
    // DAY-903: six-chain EVM expansion; eids verified against live LayerZero
    // v2 metadata on 2026-07-17.
    const ETHEREUM_LAYERZERO_EID: u32 = 30_101;
    const BSC_LAYERZERO_EID: u32 = 30_102;
    const POLYGON_LAYERZERO_EID: u32 = 30_109;
    const MONAD_LAYERZERO_EID: u32 = 30_390;
    const PLASMA_LAYERZERO_EID: u32 = 30_383;
    const ROBINHOOD_LAYERZERO_EID: u32 = 30_416;
    const PEER_LEN: u64 = 32;
    const HASH_LEN: u64 = 32;
    const BASIS_POINTS: u64 = 10_000;
    const MAX_U64: u64 = 18_446_744_073_709_551_615;

    // ---- Errors ------------------------------------------------------------

    const E_INVALID_SPOKE: u64 = 1;
    const E_INVALID_EXPIRY: u64 = 2;
    const E_EMPTY_STRATEGY: u64 = 3;
    const E_INVALID_GUARDRAILS_HASH: u64 = 4;
    const E_EMPTY_OPPORTUNITY: u64 = 5;
    const E_SAME_OPPORTUNITY: u64 = 6;
    const E_INVALID_BPS: u64 = 7;
    const E_SEQUENCE_EXHAUSTED: u64 = 8;
    const E_INVALID_PROVENANCE: u64 = 9;
    const E_WRONG_SPOKE: u64 = 10;
    const E_WRONG_DOMAIN: u64 = 11;
    const E_UNSUPPORTED_VERSION: u64 = 12;
    const E_UNKNOWN_ACTION: u64 = 13;
    const E_REPLAY_OR_GAP: u64 = 14;
    const E_EXPIRED: u64 = 15;
    const E_UNSUPPORTED_DESTINATION_CHAIN: u64 = 16;
    const E_NOT_STRATEGY_LEADER: u64 = 17;
    const E_GUARDRAILS_MISMATCH: u64 = 18;
    const E_EMPTY_CHAIN: u64 = 19;
    const E_EMPTY_ASSET_TYPE: u64 = 20;
    const E_REGISTRY_NOT_BOOTSTRAPPED: u64 = 21;
    const E_WRONG_ADMIN_CAP: u64 = 22;
    const E_NOT_GOVERNANCE: u64 = 23;
    const E_OAPP_ALREADY_BOUND: u64 = 24;
    const E_OAPP_NOT_BOUND: u64 = 25;
    const E_WRONG_OAPP_CALL: u64 = 26;
    const E_INCOMPLETE_OAPP_CALL: u64 = 27;
    const E_INVALID_OAPP_RECEIPT: u64 = 28;
    const E_INVALID_OAPP_FEE: u64 = 29;
    const E_POLICY_PROVENANCE_MISMATCH: u64 = 30;
    const E_INTENT_NOT_EXPIRED: u64 = 31;
    /// ABI-preserving quarantine for the two legacy public expiry consumers.
    /// Sui compatible upgrades cannot remove their v4 public signatures, but
    /// the v5 transport path must not advance a nonce outside authenticated
    /// OApp completion.
    const E_LEGACY_SKIP_QUARANTINED: u64 = 32;

    // ---- Hub-owned sequencing ---------------------------------------------

    /// One ordered sequence per spoke. Per-spoke counters avoid gaps when one
    /// Sui hub fans commands out to several LayerZero endpoints.
    public struct SpokeSequence has drop, store {
        spoke_eid: u32,
        next_sequence: u64,
    }

    /// Module-owned policy-plane state. It contains metadata only: no Coin,
    /// Balance, owner address, leader key, or asset.
    ///
    /// The production constructor is `bootstrap_hub_state`, which creates one
    /// shared instance and permanently anchors it under ProtocolConfig.
    public struct HubState has key {
        id: UID,
        sequences: vector<SpokeSequence>,
        /// One-shot binding to the fresh DAY OApp's sealed LayerZero CallCap.
        /// It is set by the existing registry governance after OApp publish;
        /// no leader or transaction caller can choose a transport identity.
        oapp_call_cap_id: Option<address>,
    }

    public struct HubStateBootstrapped has copy, drop {
        hub_id: ID,
        registry_id: ID,
    }

    public struct HubOAppBound has copy, drop {
        hub_id: ID,
        oapp_call_cap_id: address,
    }

    // ---- Canonical commands ------------------------------------------------

    /// Reallocate between two policy-approved opportunities. `spoke_eid` is
    /// transport routing metadata; neither command type contains a recipient
    /// or an exit-token selector.
    public struct ReallocateCommand has copy, drop, store {
        domain: vector<u8>,
        version: u8,
        action: u8,
        spoke_eid: u32,
        sequence: u64,
        issued_at_ms: u64,
        expires_at_ms: u64,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
        source_chain_id: vector<u8>,
        destination_chain_id: vector<u8>,
        from_asset_type: vector<u8>,
        to_asset_type: vector<u8>,
        from_opportunity_id: vector<u8>,
        to_opportunity_id: vector<u8>,
        allocation_bps: u64,
    }

    /// Final managed-reallocation wire schema. Unlike the legacy codec above,
    /// every chain/native identity is derived from the exact frozen bindings
    /// and `route_commitment` covers the accounting module's atomic,
    /// Guardrails-bound serialization of every ordered route leg.
    public struct ManagedReallocateCommandV1 has copy, drop, store {
        domain: vector<u8>,
        version: u8,
        action: u8,
        spoke_eid: u32,
        sequence: u64,
        issued_at_ms: u64,
        expires_at_ms: u64,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
        /// Exact immutable Guardrails object id committed alongside its hash.
        guardrails_id: vector<u8>,
        source_chain_id: vector<u8>,
        destination_chain_id: vector<u8>,
        source_native_asset: vector<u8>,
        destination_native_asset: vector<u8>,
        from_opportunity_id: vector<u8>,
        to_opportunity_id: vector<u8>,
        allocation_bps: u64,
        route_commitment: vector<u8>,
        /// Exact shared ReallocationState reserved before command minting.
        reallocation_state_id: vector<u8>,
    }

    /// One-way Exit Mode signal. Settlement remains pull-based: each position
    /// uses its recorded origin and owner. The command carries no recipient,
    /// token, amount, or per-chain leader identity.
    public struct ExitModeCommand has copy, drop, store {
        domain: vector<u8>,
        version: u8,
        action: u8,
        spoke_eid: u32,
        sequence: u64,
        issued_at_ms: u64,
        expires_at_ms: u64,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
    }

    /// A policy-authorized command that may be consumed by the LayerZero
    /// transport adapter. It intentionally has no abilities: callers cannot
    /// copy, drop, persist, or synthesize an authorization token. The only
    /// constructor is `authorize_validated_reallocation`, after canonical
    /// object binding and the complete atomic route proof have been checked.
    public struct AuthorizedHubCommand {
        dst_eid: u32,
        payload: vector<u8>,
        /// Exact typed command from which `payload` was serialized. Retaining
        /// it prevents audit consumers from re-supplying or decoding fields.
        /// The outer type has no abilities, so this value cannot be copied,
        /// dropped, or stored independently of the live authorization token.
        reallocate: ManagedReallocateCommandV1,
        /// Immutable OApp transport identity copied from canonical HubState.
        /// The final consumer requires a completed official Call from exactly
        /// this sealed CallCap, so a rogue OApp cannot burn a DAY sequence.
        oapp_call_cap_id: address,
    }

    /// Frozen parity preimage for the fresh LayerZero OApp. BCS commits field
    /// order and types; the OApp records this exact hash before sending and
    /// requires the same value in its authenticated execution outcome.
    public struct IntentPreimageV1 has drop {
        domain: vector<u8>,
        dst_eid: u32,
        command_hash: vector<u8>,
    }

    // ---- Executable spoke-verification reference --------------------------

    /// Reference state for Solana/EVM spoke ports. Ordered delivery accepts
    /// exactly the next sequence; a duplicate and a gap both fail closed.
    /// No production constructor exists in this Sui package.
    public struct SpokeInbox has drop, store {
        local_eid: u32,
        pinned_day_hub_peer: vector<u8>,
        next_sequence: u64,
    }

    // ---- Production bootstrap ---------------------------------------------

    /// Create the only production HubState. Authority is inherited from the
    /// already-bootstrapped canonical StrategyRegistry: the supplied registry,
    /// its bound AdminCap, and the transaction sender must match every field
    /// stored under ProtocolConfig. No new capability or EOA allowlist exists.
    public entry fun bootstrap_hub_state(
        config: &mut ProtocolConfig,
        registry: &StrategyRegistry,
        cap: &AdminCap,
        ctx: &mut TxContext,
    ) {
        assert!(day::strategy_registry_bootstrapped(config), E_REGISTRY_NOT_BOOTSTRAPPED);

        let registry_id = strategy_registry::id(registry);
        let registry_admin_cap_id = strategy_registry::admin_cap_id(registry);
        let governance = strategy_registry::governance(registry);
        day::assert_canonical_strategy_registry_binding(
            config,
            registry_id,
            registry_admin_cap_id,
            governance,
        );
        assert!(object::id(cap) == registry_admin_cap_id, E_WRONG_ADMIN_CAP);
        assert!(tx_context::sender(ctx) == governance, E_NOT_GOVERNANCE);

        let hub = HubState {
            id: object::new(ctx),
            sequences: vector[],
            oapp_call_cap_id: option::none(),
        };
        let hub_id = object::id(&hub);
        day::anchor_hub_state(config, hub_id, registry_id);
        event::emit(HubStateBootstrapped { hub_id, registry_id });
        transfer::share_object(hub);
    }

    /// Bind the canonical hub once to the fresh DAY OApp's sealed LayerZero
    /// CallCap. This is deliberately a post-publish governance transaction:
    /// the CallCap does not exist until the OApp's OTW initializer runs. The
    /// boundary accepts the official typed capability itself, never a caller-
    /// authored address; the OApp wrapper borrows its sealed capability only
    /// after proving the matching OApp GovernanceCap.
    ///
    /// The existing StrategyRegistry AdminCap and governance address are the
    /// only authority; no new capability or deployer allowlist is introduced.
    /// The binding is immutable after first set so an admin cannot redirect
    /// already-governed leaders to a rogue OApp later.
    public entry fun bind_layerzero_oapp_call_cap(
        config: &ProtocolConfig,
        hub: &mut HubState,
        registry: &StrategyRegistry,
        cap: &AdminCap,
        oapp_call_cap: &CallCap,
        ctx: &TxContext,
    ) {
        assert_canonical_hub_and_registry(config, hub, registry);
        assert!(object::id(cap) == strategy_registry::admin_cap_id(registry), E_WRONG_ADMIN_CAP);
        assert!(tx_context::sender(ctx) == strategy_registry::governance(registry), E_NOT_GOVERNANCE);
        assert!(call_cap::is_package(oapp_call_cap), E_WRONG_OAPP_CALL);
        let oapp_call_cap_id = oapp_call_cap.id();
        assert!(oapp_call_cap_id != @0x0, E_WRONG_OAPP_CALL);
        assert!(hub.oapp_call_cap_id.is_none(), E_OAPP_ALREADY_BOUND);
        hub.oapp_call_cap_id = option::some(oapp_call_cap_id);
        event::emit(HubOAppBound { hub_id: object::id(hub), oapp_call_cap_id });
    }

    /// Authorization-ready fail-closed object binding. The final policy path
    /// must call this before reserving a sequence or minting an opaque command.
    /// It verifies both the registry's complete ProtocolConfig anchor and the
    /// supplied HubState/registry pair in the immutable HubState anchor.
    public(package) fun assert_canonical_hub_and_registry(
        config: &ProtocolConfig,
        hub: &HubState,
        registry: &StrategyRegistry,
    ) {
        let registry_id = strategy_registry::id(registry);
        day::assert_canonical_strategy_registry_binding(
            config,
            registry_id,
            strategy_registry::admin_cap_id(registry),
            strategy_registry::governance(registry),
        );
        day::assert_canonical_hub_state_binding(config, object::id(hub), registry_id);
    }

    // ---- Hub preparation (package-only) -----------------------------------

    /// Package-only wire preparation. The eventual caller must first prove the
    /// sender is DAY-845's immutable leader and validate every leg through
    /// DAY-847. Keeping this package-only prevents a transaction from treating
    /// serialization itself as authorization.
    public(package) fun prepare_reallocate(
        hub: &mut HubState,
        spoke_eid: u32,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
        source_chain_id: vector<u8>,
        destination_chain_id: vector<u8>,
        from_asset_type: vector<u8>,
        to_asset_type: vector<u8>,
        from_opportunity_id: vector<u8>,
        to_opportunity_id: vector<u8>,
        allocation_bps: u64,
        expires_at_ms: u64,
        clock: &Clock,
    ): ReallocateCommand {
        let issued_at_ms = clock::timestamp_ms(clock);
        validate_common(
            spoke_eid,
            &strategy_id,
            &guardrails_hash,
            issued_at_ms,
            expires_at_ms,
        );
        assert!(!vector::is_empty(&from_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&to_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&source_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&destination_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&from_asset_type), E_EMPTY_ASSET_TYPE);
        assert!(!vector::is_empty(&to_asset_type), E_EMPTY_ASSET_TYPE);
        assert!(layerzero_eid_for_chain(copy destination_chain_id) == spoke_eid, E_WRONG_SPOKE);
        assert!(from_opportunity_id != to_opportunity_id, E_SAME_OPPORTUNITY);
        assert!(allocation_bps >= 1 && allocation_bps <= BASIS_POINTS, E_INVALID_BPS);

        ReallocateCommand {
            domain: DOMAIN,
            version: VERSION,
            action: ACTION_REALLOCATE,
            spoke_eid,
            sequence: reserve_sequence(hub, spoke_eid),
            issued_at_ms,
            expires_at_ms,
            strategy_id,
            guardrails_hash,
            source_chain_id,
            destination_chain_id,
            from_asset_type,
            to_asset_type,
            from_opportunity_id,
            to_opportunity_id,
            allocation_bps,
        }
    }

    /// Package-only Exit Mode wire preparation. This creates a signal only; it
    /// cannot touch an owned position or move principal.
    public(package) fun prepare_exit_mode(
        hub: &mut HubState,
        spoke_eid: u32,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
        expires_at_ms: u64,
        clock: &Clock,
    ): ExitModeCommand {
        let issued_at_ms = clock::timestamp_ms(clock);
        validate_common(
            spoke_eid,
            &strategy_id,
            &guardrails_hash,
            issued_at_ms,
            expires_at_ms,
        );

        ExitModeCommand {
            domain: DOMAIN,
            version: VERSION,
            action: ACTION_EXIT_MODE,
            spoke_eid,
            sequence: reserve_sequence(hub, spoke_eid),
            issued_at_ms,
            expires_at_ms,
            strategy_id,
            guardrails_hash,
        }
    }

    // ---- Policy authorization --------------------------------------------

    /// Final package-only authorizer for a complete managed reallocation.
    ///
    /// Canonical object identity is checked before registry/Guardrails policy
    /// or sequence state is touched. The no-abilities reservation is minted by
    /// accounting only after the complete route is validated and real source
    /// basis is reserved. Consuming it is the only way endpoint ids, route
    /// commitment, allocation, exact native-asset bindings and
    /// ReallocationState identity cross into the command. No caller-provided
    /// chain, endpoint id, native-asset bytes, route hash, state id, intent id,
    /// or raw payload crosses this boundary.
    ///
    /// Strategy and Guardrails identities are carried only by the accounting
    /// reservation and checked again against the immutable registry record.
    /// No legacy package mint or compatibility wrapper exists.
    public(package) fun authorize_validated_reallocation<T>(
        config: &ProtocolConfig,
        hub: &mut HubState,
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy_witness: ReallocationPolicyWitness,
        reservation: ReallocationReservation<T>,
        expires_at_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ): AuthorizedHubCommand {
        // This must remain the first executable statement. In particular, an
        // unanchored/wrong hub cannot probe policy or consume a sequence.
        assert_canonical_hub_and_registry(config, hub, registry);

        let (
            _policy_id,
            _latch_id,
            policy_registry_id,
            policy_strategy_id,
            policy_guardrails_id,
            policy_guardrails_hash,
            verified_leader,
            policy_source_accounting_id,
            policy_source_opportunity_id,
            policy_destination_accounting_id,
            policy_destination_opportunity_id,
            policy_allocation_bps,
        ) = leader_policy::consume_reallocation_witness(policy_witness);
        let (
            reallocation_state_id,
            source_accounting_id,
            destination_accounting_id,
            source_opportunity_id,
            destination_opportunity_id,
            strategy_id,
            guardrails_id,
            reserved_guardrails_hash,
            canonical_route,
            route_commitment,
            source_asset,
            destination_asset,
            allocation_bps,
        ) = managed_reallocation::consume_reallocation_reservation(reservation);

        assert!(policy_registry_id == strategy_registry::id(registry), E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_strategy_id == strategy_id, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_guardrails_id == guardrails_id, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_guardrails_hash == reserved_guardrails_hash, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_source_accounting_id == source_accounting_id, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_destination_accounting_id == destination_accounting_id, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_source_opportunity_id == source_opportunity_id, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_destination_opportunity_id == destination_opportunity_id, E_POLICY_PROVENANCE_MISMATCH);
        assert!(policy_allocation_bps == allocation_bps, E_POLICY_PROVENANCE_MISMATCH);
        // Accounting is the sole route/asset provenance source. Recompute the
        // commitment before any sequence mutation so even an internally
        // inconsistent reservation fails closed rather than producing a wire
        // message whose endpoint assets disagree with its signed route.
        assert!(!vector::is_empty(&canonical_route), E_POLICY_PROVENANCE_MISMATCH);
        assert!(hash::sha2_256(canonical_route) == route_commitment, E_POLICY_PROVENANCE_MISMATCH);
        strategy_registry::assert_accepts_reallocation(registry, copy strategy_id);
        let record = strategy_registry::record(registry, copy strategy_id);
        let sender = tx_context::sender(ctx);
        assert!(verified_leader == sender, E_NOT_STRATEGY_LEADER);
        assert!(strategy_registry::leader(record) == sender, E_NOT_STRATEGY_LEADER);
        assert!(
            strategy_registry::guardrails_id(record) == guardrails_v2::id(guardrails),
            E_GUARDRAILS_MISMATCH,
        );
        let registered_hash = strategy_registry::guardrails_hash(record);
        assert!(
            registered_hash == guardrails_v2::guardrails_hash(guardrails),
            E_GUARDRAILS_MISMATCH,
        );
        assert!(guardrails_v2::verify_hash(guardrails), E_GUARDRAILS_MISMATCH);
        assert!(guardrails_v2::strategy_lead(guardrails) == sender, E_NOT_STRATEGY_LEADER);
        assert!(guardrails_id == guardrails_v2::id(guardrails), E_GUARDRAILS_MISMATCH);
        assert!(reserved_guardrails_hash == registered_hash, E_GUARDRAILS_MISMATCH);
        assert!(hub.oapp_call_cap_id.is_some(), E_OAPP_NOT_BOUND);
        let oapp_call_cap_id = *hub.oapp_call_cap_id.borrow();

        let reallocation_state_id = bcs::to_bytes(&reallocation_state_id);
        let guardrails_id = bcs::to_bytes(&guardrails_id);
        let source_chain_id = guardrails_v2::native_asset_chain_id(&source_asset);
        let destination_chain_id = guardrails_v2::native_asset_chain_id(&destination_asset);
        let source_native_asset = guardrails_v2::native_asset_canonical_v1_bytes(&source_asset);
        let destination_native_asset =
            guardrails_v2::native_asset_canonical_v1_bytes(&destination_asset);
        let dst_eid = layerzero_eid_for_chain(copy destination_chain_id);

        let command = prepare_validated_reallocation(
            hub,
            dst_eid,
            strategy_id,
            registered_hash,
            guardrails_id,
            source_chain_id,
            destination_chain_id,
            source_native_asset,
            destination_native_asset,
            source_opportunity_id,
            destination_opportunity_id,
            allocation_bps,
            route_commitment,
            reallocation_state_id,
            expires_at_ms,
            clock,
        );
        AuthorizedHubCommand {
            dst_eid,
            payload: managed_reallocate_v1_bytes(&command),
            reallocate: command,
            oapp_call_cap_id,
        }
    }

    fun prepare_validated_reallocation(
        hub: &mut HubState,
        spoke_eid: u32,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
        guardrails_id: vector<u8>,
        source_chain_id: vector<u8>,
        destination_chain_id: vector<u8>,
        source_native_asset: vector<u8>,
        destination_native_asset: vector<u8>,
        from_opportunity_id: vector<u8>,
        to_opportunity_id: vector<u8>,
        allocation_bps: u64,
        route_commitment: vector<u8>,
        reallocation_state_id: vector<u8>,
        expires_at_ms: u64,
        clock: &Clock,
    ): ManagedReallocateCommandV1 {
        let issued_at_ms = clock::timestamp_ms(clock);
        validate_common(
            spoke_eid,
            &strategy_id,
            &guardrails_hash,
            issued_at_ms,
            expires_at_ms,
        );
        assert!(!vector::is_empty(&from_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&to_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(from_opportunity_id != to_opportunity_id, E_SAME_OPPORTUNITY);
        assert!(!vector::is_empty(&source_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&destination_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&source_native_asset), E_EMPTY_ASSET_TYPE);
        assert!(!vector::is_empty(&destination_native_asset), E_EMPTY_ASSET_TYPE);
        assert!(vector::length(&guardrails_id) == HASH_LEN, E_GUARDRAILS_MISMATCH);
        assert!(vector::length(&route_commitment) == HASH_LEN, E_INVALID_GUARDRAILS_HASH);
        assert!(vector::length(&reallocation_state_id) == HASH_LEN, E_INVALID_PROVENANCE);
        assert!(layerzero_eid_for_chain(copy destination_chain_id) == spoke_eid, E_WRONG_SPOKE);
        assert!(allocation_bps >= 1 && allocation_bps <= BASIS_POINTS, E_INVALID_BPS);

        ManagedReallocateCommandV1 {
            domain: DOMAIN,
            version: VERSION,
            action: ACTION_REALLOCATE,
            spoke_eid,
            sequence: reserve_sequence(hub, spoke_eid),
            issued_at_ms,
            expires_at_ms,
            strategy_id,
            guardrails_hash,
            guardrails_id,
            source_chain_id,
            destination_chain_id,
            source_native_asset,
            destination_native_asset,
            from_opportunity_id,
            to_opportunity_id,
            allocation_bps,
            route_commitment,
            reallocation_state_id,
        }
    }

    fun validate_common(
        spoke_eid: u32,
        strategy_id: &vector<u8>,
        guardrails_hash: &vector<u8>,
        issued_at_ms: u64,
        expires_at_ms: u64,
    ) {
        assert!(spoke_eid != 0 && spoke_eid != SUI_LAYERZERO_EID, E_INVALID_SPOKE);
        assert!(!vector::is_empty(strategy_id), E_EMPTY_STRATEGY);
        assert!(vector::length(guardrails_hash) == HASH_LEN, E_INVALID_GUARDRAILS_HASH);
        assert!(expires_at_ms > issued_at_ms, E_INVALID_EXPIRY);
    }

    fun reserve_sequence(hub: &mut HubState, spoke_eid: u32): u64 {
        let count = vector::length(&hub.sequences);
        let mut i = 0;
        while (i < count) {
            let route = vector::borrow_mut(&mut hub.sequences, i);
            if (route.spoke_eid == spoke_eid) {
                let sequence = route.next_sequence;
                assert!(sequence < MAX_U64, E_SEQUENCE_EXHAUSTED);
                route.next_sequence = sequence + 1;
                return sequence
            };
            i = i + 1;
        };
        vector::push_back(
            &mut hub.sequences,
            SpokeSequence { spoke_eid, next_sequence: 1 },
        );
        0
    }

    // ---- Spoke verification -----------------------------------------------

    /// Verify LayerZero-supplied source metadata against a spoke's immutable
    /// peer pin. The peer is a 32-byte LayerZero OApp identity, never a
    /// permissionlessly minted Wormhole emitter-cap object id.
    public fun provenance_matches(
        actual_source_eid: u32,
        actual_source_peer: vector<u8>,
        pinned_day_hub_peer: vector<u8>,
    ): bool {
        vector::length(&actual_source_peer) == PEER_LEN &&
            vector::length(&pinned_day_hub_peer) == PEER_LEN &&
            actual_source_eid == SUI_LAYERZERO_EID &&
            actual_source_peer == pinned_day_hub_peer
    }

    /// Executable fail-closed reference for a receiving spoke. Ports must call
    /// this logic only after the canonical LayerZero endpoint supplies source
    /// metadata; direct user input is not provenance.
    public fun verify_reallocate_and_consume(
        inbox: &mut SpokeInbox,
        actual_source_eid: u32,
        actual_source_peer: vector<u8>,
        command: &ReallocateCommand,
        now_ms: u64,
    ) {
        assert_provenance(inbox, actual_source_eid, actual_source_peer);
        assert_wire_header(
            inbox,
            command.domain,
            command.version,
            command.action,
            ACTION_REALLOCATE,
            command.spoke_eid,
            command.sequence,
            command.issued_at_ms,
            command.expires_at_ms,
            now_ms,
        );
        assert_reallocate_body(command);
        inbox.next_sequence = inbox.next_sequence + 1;
    }

    /// Legacy v4 ABI retained solely for compatible upgrades. It is
    /// intentionally quarantined: the final transport path consumes an
    /// authenticated OApp completion, never caller-supplied expiry metadata.
    ///
    /// Do not restore the former nonce-advancing behavior. Keeping this
    /// signature fail-closed prevents an arbitrary caller from skipping the
    /// canonical LayerZero completion path while preserving the deployed ABI.
    public fun skip_expired_reallocate_and_consume(
        _inbox: &mut SpokeInbox,
        _actual_source_eid: u32,
        _actual_source_peer: vector<u8>,
        _command: &ReallocateCommand,
        _now_ms: u64,
    ) {
        abort E_LEGACY_SKIP_QUARANTINED
    }

    fun assert_reallocate_body(command: &ReallocateCommand) {
        assert!(!vector::is_empty(&command.strategy_id), E_EMPTY_STRATEGY);
        assert!(vector::length(&command.guardrails_hash) == HASH_LEN, E_INVALID_GUARDRAILS_HASH);
        assert!(!vector::is_empty(&command.from_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&command.to_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&command.source_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&command.destination_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&command.from_asset_type), E_EMPTY_ASSET_TYPE);
        assert!(!vector::is_empty(&command.to_asset_type), E_EMPTY_ASSET_TYPE);
        assert!(
            layerzero_eid_for_chain(command.destination_chain_id) == command.spoke_eid,
            E_WRONG_SPOKE,
        );
        assert!(command.from_opportunity_id != command.to_opportunity_id, E_SAME_OPPORTUNITY);
        assert!(command.allocation_bps >= 1 && command.allocation_bps <= BASIS_POINTS, E_INVALID_BPS);
    }

    public fun verify_exit_mode_and_consume(
        inbox: &mut SpokeInbox,
        actual_source_eid: u32,
        actual_source_peer: vector<u8>,
        command: &ExitModeCommand,
        now_ms: u64,
    ) {
        assert_provenance(inbox, actual_source_eid, actual_source_peer);
        assert_wire_header(
            inbox,
            command.domain,
            command.version,
            command.action,
            ACTION_EXIT_MODE,
            command.spoke_eid,
            command.sequence,
            command.issued_at_ms,
            command.expires_at_ms,
            now_ms,
        );
        assert_exit_body(command);
        inbox.next_sequence = inbox.next_sequence + 1;
    }

    /// Legacy v4 ABI retained solely for compatible upgrades. See
    /// `skip_expired_reallocate_and_consume`; exit-mode expiry consumption is
    /// likewise quarantined until the authenticated OApp completion path is
    /// available.
    public fun skip_expired_exit_mode_and_consume(
        _inbox: &mut SpokeInbox,
        _actual_source_eid: u32,
        _actual_source_peer: vector<u8>,
        _command: &ExitModeCommand,
        _now_ms: u64,
    ) {
        abort E_LEGACY_SKIP_QUARANTINED
    }

    fun assert_exit_body(command: &ExitModeCommand) {
        assert!(!vector::is_empty(&command.strategy_id), E_EMPTY_STRATEGY);
        assert!(vector::length(&command.guardrails_hash) == HASH_LEN, E_INVALID_GUARDRAILS_HASH);
    }

    fun assert_provenance(
        inbox: &SpokeInbox,
        actual_source_eid: u32,
        actual_source_peer: vector<u8>,
    ) {
        assert!(
            provenance_matches(
                actual_source_eid,
                actual_source_peer,
                inbox.pinned_day_hub_peer,
            ),
            E_INVALID_PROVENANCE,
        );
    }

    fun assert_wire_header(
        inbox: &SpokeInbox,
        domain: vector<u8>,
        version: u8,
        action: u8,
        expected_action: u8,
        spoke_eid: u32,
        sequence: u64,
        issued_at_ms: u64,
        expires_at_ms: u64,
        now_ms: u64,
    ) {
        assert!(domain == DOMAIN, E_WRONG_DOMAIN);
        assert!(version == VERSION, E_UNSUPPORTED_VERSION);
        assert!(action == expected_action, E_UNKNOWN_ACTION);
        assert!(spoke_eid == inbox.local_eid, E_WRONG_SPOKE);
        assert!(sequence == inbox.next_sequence, E_REPLAY_OR_GAP);
        assert!(expires_at_ms > issued_at_ms, E_INVALID_EXPIRY);
        assert!(issued_at_ms <= now_ms, E_INVALID_EXPIRY);
        assert!(now_ms <= expires_at_ms, E_EXPIRED);
        assert!(inbox.next_sequence < MAX_U64, E_SEQUENCE_EXHAUSTED);
    }

    fun assert_expired_wire_header(
        inbox: &SpokeInbox,
        domain: vector<u8>,
        version: u8,
        action: u8,
        expected_action: u8,
        spoke_eid: u32,
        sequence: u64,
        issued_at_ms: u64,
        expires_at_ms: u64,
        now_ms: u64,
    ) {
        assert!(domain == DOMAIN, E_WRONG_DOMAIN);
        assert!(version == VERSION, E_UNSUPPORTED_VERSION);
        assert!(action == expected_action, E_UNKNOWN_ACTION);
        assert!(spoke_eid == inbox.local_eid, E_WRONG_SPOKE);
        assert!(sequence == inbox.next_sequence, E_REPLAY_OR_GAP);
        assert!(expires_at_ms > issued_at_ms, E_INVALID_EXPIRY);
        assert!(issued_at_ms <= now_ms, E_INVALID_EXPIRY);
        assert!(now_ms > expires_at_ms, E_INTENT_NOT_EXPIRED);
        assert!(inbox.next_sequence < MAX_U64, E_SEQUENCE_EXHAUSTED);
    }

    // ---- Read / encoding API ----------------------------------------------

    public fun sui_layerzero_eid(): u32 { SUI_LAYERZERO_EID }

    /// Exact canonical chain-id to LayerZero endpoint mapping. Unknown or
    /// differently-cased identifiers abort rather than selecting a fallback.
    public fun layerzero_eid_for_chain(chain_id: vector<u8>): u32 {
        if (chain_id == b"base") {
            BASE_LAYERZERO_EID
        } else if (chain_id == b"arbitrum") {
            ARBITRUM_LAYERZERO_EID
        } else if (chain_id == b"solana") {
            SOLANA_LAYERZERO_EID
        // DAY-903: six-chain EVM expansion.
        } else if (chain_id == b"ethereum") {
            ETHEREUM_LAYERZERO_EID
        } else if (chain_id == b"bsc") {
            BSC_LAYERZERO_EID
        } else if (chain_id == b"polygon") {
            POLYGON_LAYERZERO_EID
        } else if (chain_id == b"monad") {
            MONAD_LAYERZERO_EID
        } else if (chain_id == b"plasma") {
            PLASMA_LAYERZERO_EID
        } else if (chain_id == b"robinhood") {
            ROBINHOOD_LAYERZERO_EID
        } else {
            abort E_UNSUPPORTED_DESTINATION_CHAIN
        }
    }

    /// Parse and validate the sole managed-reallocation wire schema used by
    /// DAY and the fresh LayerZero OApp. Keeping the decoder beside the
    /// encoder prevents the transport package from drifting to a shorter or
    /// reordered field list while still accepting a signed command.
    public fun assert_managed_reallocate_v1_message(
        dst_eid: u32,
        message: &vector<u8>,
    ): u64 {
        let mut wire = bcs::new(*message);
        assert!(wire.peel_vec_u8() == DOMAIN, E_WRONG_DOMAIN);
        assert!(wire.peel_u8() == VERSION, E_UNSUPPORTED_VERSION);
        assert!(wire.peel_u8() == ACTION_REALLOCATE, E_UNKNOWN_ACTION);
        assert!(wire.peel_u32() == dst_eid, E_WRONG_SPOKE);
        let _sequence = wire.peel_u64();
        let issued_at_ms = wire.peel_u64();
        let expires_at_ms = wire.peel_u64();
        let strategy_id = wire.peel_vec_u8();
        let guardrails_hash = wire.peel_vec_u8();
        let guardrails_id = wire.peel_vec_u8();
        let source_chain_id = wire.peel_vec_u8();
        let destination_chain_id = wire.peel_vec_u8();
        let source_native_asset = wire.peel_vec_u8();
        let destination_native_asset = wire.peel_vec_u8();
        let from_opportunity_id = wire.peel_vec_u8();
        let to_opportunity_id = wire.peel_vec_u8();
        let allocation_bps = wire.peel_u64();
        let route_commitment = wire.peel_vec_u8();
        let reallocation_state_id = wire.peel_vec_u8();

        assert!(!vector::is_empty(&strategy_id), E_EMPTY_STRATEGY);
        assert!(vector::length(&guardrails_hash) == HASH_LEN, E_INVALID_GUARDRAILS_HASH);
        assert!(vector::length(&guardrails_id) == HASH_LEN, E_GUARDRAILS_MISMATCH);
        assert!(!vector::is_empty(&source_chain_id), E_EMPTY_CHAIN);
        assert!(!vector::is_empty(&destination_chain_id), E_EMPTY_CHAIN);
        assert!(layerzero_eid_for_chain(destination_chain_id) == dst_eid, E_WRONG_SPOKE);
        assert!(!vector::is_empty(&source_native_asset), E_EMPTY_ASSET_TYPE);
        assert!(!vector::is_empty(&destination_native_asset), E_EMPTY_ASSET_TYPE);
        assert!(!vector::is_empty(&from_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&to_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(from_opportunity_id != to_opportunity_id, E_SAME_OPPORTUNITY);
        assert!(allocation_bps >= 1 && allocation_bps <= BASIS_POINTS, E_INVALID_BPS);
        assert!(vector::length(&route_commitment) == HASH_LEN, E_INVALID_PROVENANCE);
        assert!(vector::length(&reallocation_state_id) == HASH_LEN, E_INVALID_PROVENANCE);
        assert!(vector::is_empty(&wire.into_remainder_bytes()), E_INVALID_PROVENANCE);
        assert!(expires_at_ms > issued_at_ms, E_INVALID_EXPIRY);
        expires_at_ms
    }

    /// Borrow the committed transport fields without consuming the linear
    /// authorization. Returning raw bytes cannot commit a DAY sequence: the
    /// transaction still holds a no-abilities token and must complete the
    /// official LayerZero Call below or abort.
    public fun authorized_transport_message(
        command: &AuthorizedHubCommand,
    ): (u32, vector<u8>) {
        (command.dst_eid, copy command.payload)
    }

    /// Consume authorization only after the exact official LayerZero Call has
    /// completed from the immutable OApp CallCap bound in canonical HubState.
    /// A caller-created SendParam, unrelated receipt, rogue OApp, active Call,
    /// destination substitution, or payload substitution all fail closed.
    public fun consume_after_completed_layerzero_call(
        command: AuthorizedHubCommand,
        completed_call: &Call<SendParam, MessagingReceipt>,
    ) {
        assert!(lz_call::caller(completed_call) == command.oapp_call_cap_id, E_WRONG_OAPP_CALL);
        assert!(
            lz_call::callee(completed_call) == lz_package::original_package_of_type<EndpointV2>(),
            E_WRONG_OAPP_CALL,
        );
        assert!(lz_call::is_completed(lz_call::status(completed_call)), E_INCOMPLETE_OAPP_CALL);
        assert!(lz_call::result(completed_call).is_some(), E_INCOMPLETE_OAPP_CALL);
        let send = lz_call::param(completed_call);
        assert!(endpoint_send::dst_eid(send) == command.dst_eid, E_WRONG_SPOKE);
        assert!(*endpoint_send::message(send) == command.payload, E_INVALID_PROVENANCE);

        // A completed Call alone is not sufficient: bind the non-forgeable
        // Endpoint receipt back to this exact OApp sender, destination and
        // receiver. This prevents an unrelated successful Endpoint call from
        // being paired with a DAY command merely because its payload matched.
        let receipt = lz_call::result(completed_call).borrow();
        let nonce = messaging_receipt::nonce(receipt);
        assert!(nonce > 0, E_INVALID_OAPP_RECEIPT);
        let expected_guid = endpoint_utils::compute_guid(
            nonce,
            SUI_LAYERZERO_EID,
            bytes32::from_address(command.oapp_call_cap_id),
            command.dst_eid,
            endpoint_send::receiver(send),
        );
        assert!(messaging_receipt::guid(receipt) == expected_guid, E_INVALID_OAPP_RECEIPT);

        // The receipt is produced only by the official Endpoint package. Its
        // stable fee fields are nevertheless checked for internal coherence:
        // a native-only send cannot claim a ZRO payment. A zero native fee is
        // valid for a configured free path, so it must not be rejected.
        let fee = messaging_receipt::messaging_fee(receipt);
        let _native_fee = messaging_fee::native_fee(fee);
        let zro_fee = messaging_fee::zro_fee(fee);
        if (!endpoint_send::pay_in_zro(send)) {
            assert!(zro_fee == 0, E_INVALID_OAPP_FEE);
        };
        let AuthorizedHubCommand {
            dst_eid: _,
            payload: _,
            reallocate: _,
            oapp_call_cap_id: _,
        } = command;
    }

    /// Return the exact committed fields required by the authenticated
    /// ORDERED event. Every value comes from the typed command retained inside
    /// the no-abilities authorization token; callers cannot substitute audit
    /// facts or decode an arbitrary payload.
    public(package) fun authorized_reallocate_audit_v1(
        command: &AuthorizedHubCommand,
    ): (
        vector<u8>,
        vector<u8>,
        vector<u8>,
        vector<u8>,
        vector<u8>,
        u64,
        vector<u8>,
        vector<u8>,
        vector<u8>,
        vector<u8>,
        vector<u8>,
        vector<u8>,
        u64,
        u64,
    ) {
        let audit = &command.reallocate;
        (
            copy audit.strategy_id,
            copy audit.guardrails_hash,
            copy audit.guardrails_id,
            copy audit.route_commitment,
            copy audit.reallocation_state_id,
            audit.allocation_bps,
            copy audit.from_opportunity_id,
            copy audit.to_opportunity_id,
            copy audit.source_chain_id,
            copy audit.destination_chain_id,
            copy audit.source_native_asset,
            copy audit.destination_native_asset,
            audit.issued_at_ms,
            audit.expires_at_ms,
        )
    }

    /// Derive the exact 32-byte identity that the LayerZero OApp commits and
    /// later requires from an authenticated spoke outcome. No caller may
    /// supply an intent id, endpoint, or raw payload to this accessor.
    public(package) fun authorized_intent_id(
        command: &AuthorizedHubCommand,
    ): vector<u8> {
        let command_hash = hash::sha2_256(copy command.payload);
        hash::sha2_256(bcs::to_bytes(&IntentPreimageV1 {
            domain: INTENT_DOMAIN,
            dst_eid: command.dst_eid,
            command_hash,
        }))
    }

    public fun reallocate_bytes(command: &ReallocateCommand): vector<u8> {
        bcs::to_bytes(command)
    }

    public fun managed_reallocate_v1_bytes(command: &ManagedReallocateCommandV1): vector<u8> {
        bcs::to_bytes(command)
    }

    public fun exit_mode_bytes(command: &ExitModeCommand): vector<u8> {
        bcs::to_bytes(command)
    }

    public fun reallocate_hash(command: &ReallocateCommand): vector<u8> {
        hash::sha2_256(reallocate_bytes(command))
    }

    public fun exit_mode_hash(command: &ExitModeCommand): vector<u8> {
        hash::sha2_256(exit_mode_bytes(command))
    }

    public fun reallocate_sequence(command: &ReallocateCommand): u64 { command.sequence }
    public fun exit_mode_sequence(command: &ExitModeCommand): u64 { command.sequence }
    public fun reallocate_spoke_eid(command: &ReallocateCommand): u32 { command.spoke_eid }
    public fun exit_mode_spoke_eid(command: &ExitModeCommand): u32 { command.spoke_eid }
    public fun inbox_next_sequence(inbox: &SpokeInbox): u64 { inbox.next_sequence }

    // ---- Test-only construction / mutation --------------------------------

    #[test_only]
    public fun new_hub_for_testing(ctx: &mut TxContext): HubState {
        HubState {
            id: object::new(ctx),
            sequences: vector[],
            oapp_call_cap_id: option::none(),
        }
    }

    /// Canonical full-schema fixture encoder for dependent OApp tests. This
    /// cannot authorize a send: the production send path still requires the
    /// no-abilities `AuthorizedHubCommand` minted by the package authorizer.
    #[test_only]
    public fun managed_reallocate_v1_bytes_for_testing(
        spoke_eid: u32,
        action: u8,
        sequence: u64,
        issued_at_ms: u64,
        expires_at_ms: u64,
        strategy_id: vector<u8>,
        guardrails_hash: vector<u8>,
        guardrails_id: vector<u8>,
        source_chain_id: vector<u8>,
        destination_chain_id: vector<u8>,
        source_native_asset: vector<u8>,
        destination_native_asset: vector<u8>,
        from_opportunity_id: vector<u8>,
        to_opportunity_id: vector<u8>,
        allocation_bps: u64,
        route_commitment: vector<u8>,
        reallocation_state_id: vector<u8>,
    ): vector<u8> {
        managed_reallocate_v1_bytes(&ManagedReallocateCommandV1 {
            domain: DOMAIN,
            version: VERSION,
            action,
            spoke_eid,
            sequence,
            issued_at_ms,
            expires_at_ms,
            strategy_id,
            guardrails_hash,
            guardrails_id,
            source_chain_id,
            destination_chain_id,
            source_native_asset,
            destination_native_asset,
            from_opportunity_id,
            to_opportunity_id,
            allocation_bps,
            route_commitment,
            reallocation_state_id,
        })
    }

    #[test_only]
    public fun destroy_hub_for_testing(hub: HubState) {
        let HubState { id, sequences: _, oapp_call_cap_id: _ } = hub;
        object::delete(id);
    }

    #[test_only]
    public fun bind_oapp_call_cap_for_testing(hub: &mut HubState, call_cap_id: address) {
        assert!(call_cap_id != @0x0, E_WRONG_OAPP_CALL);
        assert!(hub.oapp_call_cap_id.is_none(), E_OAPP_ALREADY_BOUND);
        hub.oapp_call_cap_id = option::some(call_cap_id);
    }

    #[test_only]
    public fun destroy_authorized_for_testing(command: AuthorizedHubCommand) {
        let AuthorizedHubCommand {
            dst_eid: _,
            payload: _,
            reallocate: _,
            oapp_call_cap_id: _,
        } = command;
    }

    #[test_only]
    public fun new_inbox_for_testing(local_eid: u32, pinned_day_hub_peer: vector<u8>): SpokeInbox {
        assert!(local_eid != 0 && local_eid != SUI_LAYERZERO_EID, E_INVALID_SPOKE);
        assert!(vector::length(&pinned_day_hub_peer) == PEER_LEN, E_INVALID_PROVENANCE);
        SpokeInbox { local_eid, pinned_day_hub_peer, next_sequence: 0 }
    }

    #[test_only]
    public fun set_next_sequence_for_testing(hub: &mut HubState, spoke_eid: u32, sequence: u64) {
        let count = vector::length(&hub.sequences);
        let mut i = 0;
        while (i < count) {
            let route = vector::borrow_mut(&mut hub.sequences, i);
            if (route.spoke_eid == spoke_eid) {
                route.next_sequence = sequence;
                return
            };
            i = i + 1;
        };
        vector::push_back(&mut hub.sequences, SpokeSequence { spoke_eid, next_sequence: sequence });
    }

    #[test_only]
    public fun copy_reallocate_with_action_for_testing(
        command: &ReallocateCommand,
        action: u8,
    ): ReallocateCommand {
        let mut altered = *command;
        altered.action = action;
        altered
    }
}
