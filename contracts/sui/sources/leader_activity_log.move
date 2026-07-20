// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-850 authenticated managed-strategy activity log.
///
/// The Sui hub is the only place where leader identity is proven. This module
/// therefore records an ORDERED intent only from the no-abilities
/// `AuthorizedHubCommand` produced after the package's policy checks. The
/// intent id is derived from that command and the actor is derived from the
/// transaction context; neither is accepted as an argument.
///
/// The LayerZero OApp owns EXECUTED/FAILED outcome state. It joins its
/// authenticated outcome to this event with the exact same 32-byte intent id.
/// This module deliberately exposes no outcome event emitter.
module day::leader_activity_log {
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::hub_protocol::{Self, AuthorizedHubCommand};
    use sui::bcs;
    use sui::clock::{Self, Clock};
    use sui::event;

    const STATE_ORDERED: u8 = 1;
    const STATE_EXECUTED: u8 = 2;
    const STATE_FAILED: u8 = 3;

    const HASH_LEN: u64 = 32;
    const E_INVALID_GUARDRAILS_HASH: u64 = 1;
    const E_INVALID_INTENT: u64 = 2;
    const E_NOT_TERMINAL_STATE: u64 = 3;
    const E_NOT_GUARDRAILS_LEADER: u64 = 4;
    const E_GUARDRAILS_ID_MISMATCH: u64 = 5;

    /// Authenticated hub-side record that a leader ordered a reallocation.
    /// It does not assert that a spoke executed the order.
    public struct ReallocateOrderedV1 has copy, drop {
        state: u8,
        intent_id: vector<u8>,
        verified_leader: address,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        route_commitment: vector<u8>,
        reallocation_state_id: vector<u8>,
        allocation_bps: u64,
        source_opportunity_id: vector<u8>,
        destination_opportunity_id: vector<u8>,
        source_chain_id: vector<u8>,
        destination_chain_id: vector<u8>,
        source_native_asset: vector<u8>,
        destination_native_asset: vector<u8>,
        issued_at_ms: u64,
        expires_at_ms: u64,
        recorded_at_ms: u64,
    }

    /// Record an authenticated ORDERED intent while borrowing the no-abilities
    /// command. `leader_authority` is the sole intended caller: it must retain
    /// and return that same hot potato to the OApp consumer after this call.
    ///
    /// Every emitted command fact is read from the typed command retained in
    /// the no-abilities authorization. This deliberately accepts no route,
    /// strategy, allocation, endpoint, chain, asset, timestamp, or intent
    /// parameter that an external caller could substitute.
    public(package) fun record_ordered(
        command: &AuthorizedHubCommand,
        guardrails: &GuardrailsV2,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let recorded_at_ms = clock::timestamp_ms(clock);
        let intent_id = hub_protocol::authorized_intent_id(command);
        assert!(vector::length(&intent_id) == HASH_LEN, E_INVALID_INTENT);
        let (
            strategy_id,
            committed_guardrails_hash,
            committed_guardrails_id,
            route_commitment,
            reallocation_state_id,
            allocation_bps,
            source_opportunity_id,
            destination_opportunity_id,
            source_chain_id,
            destination_chain_id,
            source_native_asset,
            destination_native_asset,
            issued_at_ms,
            expires_at_ms,
        ) = hub_protocol::authorized_reallocate_audit_v1(command);
        let guardrails_hash = guardrails_v2::guardrails_hash(guardrails);
        assert!(vector::length(&guardrails_hash) == HASH_LEN, E_INVALID_GUARDRAILS_HASH);
        assert!(guardrails_v2::verify_hash(guardrails), E_INVALID_GUARDRAILS_HASH);
        assert!(committed_guardrails_hash == guardrails_hash, E_INVALID_GUARDRAILS_HASH);
        assert!(
            committed_guardrails_id == bcs::to_bytes(&guardrails_v2::id(guardrails)),
            E_GUARDRAILS_ID_MISMATCH,
        );

        let verified_leader = tx_context::sender(ctx);
        assert!(guardrails_v2::strategy_lead(guardrails) == verified_leader, E_NOT_GUARDRAILS_LEADER);

        event::emit(ReallocateOrderedV1 {
            state: STATE_ORDERED,
            intent_id,
            verified_leader,
            strategy_id,
            guardrails_id: guardrails_v2::id(guardrails),
            guardrails_hash,
            route_commitment,
            reallocation_state_id,
            allocation_bps,
            source_opportunity_id,
            destination_opportunity_id,
            source_chain_id,
            destination_chain_id,
            source_native_asset,
            destination_native_asset,
            issued_at_ms,
            expires_at_ms,
            recorded_at_ms,
        });
    }

    /// Stable state codes shared with the separately published OApp outcome
    /// schema. Only ORDERED is emitted by this package.
    public fun ordered_state(): u8 { STATE_ORDERED }
    public fun executed_state(): u8 { STATE_EXECUTED }
    public fun failed_state(): u8 { STATE_FAILED }

    /// Fail closed if an OApp outcome is not one of the two terminal states.
    /// This function does not emit an outcome or authenticate transport.
    public fun assert_terminal_outcome_state(state: u8) {
        assert!(state == STATE_EXECUTED || state == STATE_FAILED, E_NOT_TERMINAL_STATE);
    }

    #[test_only]
    public fun assert_last_ordered_event_for_testing(
        expected_intent_id: vector<u8>,
        expected_leader: address,
        expected_strategy_id: vector<u8>,
        expected_guardrails_id: ID,
        expected_guardrails_hash: vector<u8>,
        expected_route_commitment: vector<u8>,
        expected_reallocation_state_id: vector<u8>,
        expected_allocation_bps: u64,
        expected_source_opportunity_id: vector<u8>,
        expected_destination_opportunity_id: vector<u8>,
        expected_source_chain_id: vector<u8>,
        expected_destination_chain_id: vector<u8>,
        expected_source_native_asset: vector<u8>,
        expected_destination_native_asset: vector<u8>,
        expected_issued_at_ms: u64,
        expected_expires_at_ms: u64,
        expected_recorded_at_ms: u64,
    ) {
        let events = event::events_by_type<ReallocateOrderedV1>();
        let last = &events[vector::length(&events) - 1];
        assert!(last.state == STATE_ORDERED, 100);
        assert!(last.intent_id == expected_intent_id, 101);
        assert!(last.verified_leader == expected_leader, 102);
        assert!(last.strategy_id == expected_strategy_id, 103);
        assert!(last.guardrails_id == expected_guardrails_id, 104);
        assert!(last.guardrails_hash == expected_guardrails_hash, 105);
        assert!(last.route_commitment == expected_route_commitment, 106);
        assert!(last.reallocation_state_id == expected_reallocation_state_id, 107);
        assert!(last.allocation_bps == expected_allocation_bps, 108);
        assert!(last.source_opportunity_id == expected_source_opportunity_id, 109);
        assert!(last.destination_opportunity_id == expected_destination_opportunity_id, 110);
        assert!(last.source_chain_id == expected_source_chain_id, 111);
        assert!(last.destination_chain_id == expected_destination_chain_id, 112);
        assert!(last.source_native_asset == expected_source_native_asset, 113);
        assert!(last.destination_native_asset == expected_destination_native_asset, 114);
        assert!(last.issued_at_ms == expected_issued_at_ms, 115);
        assert!(last.expires_at_ms == expected_expires_at_ms, 116);
        assert!(last.recorded_at_ms == expected_recorded_at_ms, 117);
    }
}
