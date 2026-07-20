// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-876 LayerZero V2 transport boundary for the Sui policy plane.
///
/// This is intentionally a fresh package, not a module added to the deployed
/// DAY package. LayerZero package CallCaps require a one-time witness, while
/// Sui package upgrades never run module initializers. Publishing this package
/// creates the OApp and seals both LayerZero capabilities inside `HubOApp`;
/// neither capability is transferred to the publisher or another address.
///
/// Outbound raw messaging is package-only. A public `vector<u8>` send surface
/// would let any caller make the authenticated DAY peer emit forged commands.
/// The eventual public path must consume a non-forgeable hot potato issued by
/// the DAY hub after leader authentication and per-leg guardrail checks.
module day_hub_oapp::hub_oapp;

use day::{
    day::ProtocolConfig,
    hub_protocol::{Self as hub_protocol, AuthorizedHubCommand, HubState},
    strategy_registry::{AdminCap as DayAdminCap, StrategyRegistry},
};
use std::hash;
use call::{
    call::{Call, Void},
    call_cap::CallCap,
};
use endpoint_v2::{
    endpoint_send::SendParam,
    endpoint_v2::{Self, EndpointV2},
    lz_receive::LzReceiveParam,
    messaging_channel::MessagingChannel,
    messaging_receipt::MessagingReceipt,
};
use oapp::{
    oapp::{Self, AdminCap, OApp},
    oapp_info_v1,
};
use sui::{
    bcs,
    clock::Clock,
    coin::Coin,
    event,
    package::{Self as sui_package, UpgradeCap},
    sui::SUI,
    table::{Self, Table},
};
use utils::{bytes32::{Self, Bytes32}, package as lz_package};
use zro::zro::ZRO;

// ---- Canonical LayerZero deployment pins ---------------------------------

const SUI_EID: u32 = 30_378;
const BASE_EID: u32 = 30_184;
const ARBITRUM_EID: u32 = 30_110;
const SOLANA_EID: u32 = 30_168;
// DAY-903: six-chain EVM expansion; eids verified against live LayerZero
// v2 metadata on 2026-07-17.
const ETHEREUM_EID: u32 = 30_101;
const BSC_EID: u32 = 30_102;
const POLYGON_EID: u32 = 30_109;
const MONAD_EID: u32 = 30_390;
const PLASMA_EID: u32 = 30_383;
const ROBINHOOD_EID: u32 = 30_416;
const ENDPOINT_V2_OBJECT: address =
    @0xd45b6890fa030bcb43347c0c69a9e5a1a288d1ca7b86b428014752b472f6bf91;
const DEPLOYER_EOA: address =
    @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;

// ---- Application wire protocol ------------------------------------------

const REALLOCATE_MSG_TYPE: u16 = 1;

const INTENT_DOMAIN: vector<u8> = b"DAY_INTENT";
const OUTCOME_DOMAIN: vector<u8> = b"DAY_OUTCOME";
const OUTCOME_VERSION: u8 = 1;
const OUTCOME_ACTION_EXECUTION: u8 = 1;
const OUTCOME_EXECUTED: u8 = 1;
const OUTCOME_FAILED: u8 = 2;
const HASH_LEN: u64 = 32;
const INTENT_RETENTION_MS: u64 = 2_592_000_000;
#[test_only]
const TEST_PEER: vector<u8> =
    x"5555555555555555555555555555555555555555555555555555555555555555";

// ---- Errors --------------------------------------------------------------

const E_ALREADY_REGISTERED: u64 = 1;
const E_NOT_REGISTERED: u64 = 2;
const E_WRONG_ENDPOINT: u64 = 3;
const E_WRONG_LOCAL_EID: u64 = 4;
const E_WRONG_OAPP: u64 = 5;
const E_WRONG_CHANNEL: u64 = 6;
const E_GOVERNANCE_UNRESOLVED: u64 = 7;
const E_WRONG_GOVERNANCE: u64 = 8;
const E_INVALID_GOVERNANCE: u64 = 9;
const E_WRONG_UPGRADE_CAP: u64 = 10;
const E_UNSUPPORTED_REMOTE: u64 = 11;
const E_ZERO_PEER: u64 = 12;
const E_INVALID_MESSAGE: u64 = 13;
const E_UNKNOWN_ACTION: u64 = 14;
const E_REPLAY: u64 = 15;
const E_REPLAY_OR_GAP: u64 = 16;
const E_EXPIRED: u64 = 17;
const E_VALUE_NOT_ALLOWED: u64 = 18;
const E_INTENT_EXISTS: u64 = 21;
const E_UNKNOWN_INTENT: u64 = 22;
const E_OUTCOME_ALREADY_RECORDED: u64 = 23;
const E_COMMAND_HASH_MISMATCH: u64 = 24;
const E_INVALID_OUTCOME: u64 = 25;
const E_INTENT_NOT_PRUNABLE: u64 = 26;
const E_INVALID_OAPP_INFO: u64 = 27;
const E_INVALID_OPTIONS: u64 = 28;
const E_INTENT_NOT_EXPIRED: u64 = 29;
const E_PEER_MISMATCH: u64 = 30;

// ---- State and capabilities ---------------------------------------------

/// One-time witness used by LayerZero to derive this package's peer identity.
public struct HUB_OAPP has drop {}

/// Wrapper governance capability. It never contains or exposes LayerZero's
/// AdminCap; it only authorizes this module to borrow the sealed AdminCap.
public struct GovernanceCap has key {
    id: UID,
    hub_id: ID,
}

public struct RemoteSequence has drop, store {
    eid: u32,
    peer: Bytes32,
    next_nonce: u64,
}

/// Immutable outbound commitment recorded before the official Endpoint call.
/// The key is `intent_id`; the exact command hash and destination EID are
/// derived from the consumed DAY authorization, never supplied by the caller.
public struct OutboundIntent has drop, store {
    dst_eid: u32,
    peer: Bytes32,
    command_hash: vector<u8>,
    expires_at_ms: u64,
    outcome_recorded: bool,
    /// True only after the pinned peer's exact authenticated return message
    /// has consumed its LayerZero nonce. A permissionless local timeout may
    /// provisionally record FAILED, but cannot stand in for transport
    /// acknowledgement or make the following nonce unreachable.
    outcome_received: bool,
    outcome: u8,
}

/// One-shot transport proof joining DAY's no-abilities authorization to the
/// exact official LayerZero Call created from it. This type has no abilities,
/// so the PTB cannot commit after reserving a DAY sequence unless it completes
/// and confirms this exact send. Callers never regain a separable command or
/// a droppable raw-payload result after entering the OApp boundary.
public struct PendingAuthorizedHubSend {
    authorized: AuthorizedHubCommand,
    call: Call<SendParam, MessagingReceipt>,
}

public struct IntentPreimageV1 has drop {
    domain: vector<u8>,
    dst_eid: u32,
    command_hash: vector<u8>,
}

/// Shared transport state. `call_cap` and `admin_cap` have no public borrower,
/// extractor, transfer, or destroy surface.
public struct HubOApp has key {
    id: UID,
    oapp_object: address,
    call_cap: CallCap,
    admin_cap: AdminCap,
    expected_endpoint: address,
    endpoint_object: Option<address>,
    messaging_channel: Option<address>,
    governance_cap: Option<ID>,
    outbound_intents: Table<vector<u8>, OutboundIntent>,
    consumed_guids: Table<vector<u8>, bool>,
    return_sequences: vector<RemoteSequence>,
}

public struct ExecutionOutcomeRecorded has copy, drop {
    src_eid: u32,
    source_peer: vector<u8>,
    layerzero_nonce: u64,
    guid: vector<u8>,
    intent_id: vector<u8>,
    command_hash: vector<u8>,
    outcome: u8,
}

public struct HubCommandCommitted has copy, drop {
    dst_eid: u32,
    peer: vector<u8>,
    intent_id: vector<u8>,
    command_hash: vector<u8>,
    expires_at_ms: u64,
}

public struct HubIntentPruned has copy, drop {
    intent_id: vector<u8>,
}

public struct HubIntentExpired has copy, drop {
    dst_eid: u32,
    peer: vector<u8>,
    intent_id: vector<u8>,
    command_hash: vector<u8>,
    expires_at_ms: u64,
    recorded_at_ms: u64,
    outcome: u8,
}

public struct ExecutionOutcomeWire has drop {
    domain: vector<u8>,
    version: u8,
    action: u8,
    intent_id: vector<u8>,
    command_hash: vector<u8>,
    outcome: u8,
}

fun init(otw: HUB_OAPP, ctx: &mut TxContext) {
    let (call_cap, admin_cap, oapp_object) = oapp::new(&otw, ctx);
    transfer::share_object(HubOApp {
        id: object::new(ctx),
        oapp_object,
        call_cap,
        admin_cap,
        expected_endpoint: ENDPOINT_V2_OBJECT,
        endpoint_object: option::none(),
        messaging_channel: option::none(),
        governance_cap: option::none(),
        outbound_intents: table::new(ctx),
        consumed_guids: table::new(ctx),
        return_sequences: vector[],
    });
}

// ---- Explicit, one-shot governance bootstrap -----------------------------

/// Create the wrapper governance cap only after a recipient has been named.
/// The known deployer/treasury EOA and the transaction sender are rejected.
/// This function is not called by package initialization and no recipient is
/// selected in source, deployment scripts, or tests.
public fun bootstrap_governance(
    hub: &mut HubOApp,
    upgrade_cap: &UpgradeCap,
    governance: address,
    ctx: &mut TxContext,
) {
    assert!(hub.governance_cap.is_none(), E_WRONG_GOVERNANCE);
    assert!(
        governance != @0x0 &&
            governance != DEPLOYER_EOA &&
            governance != ctx.sender(),
        E_INVALID_GOVERNANCE,
    );
    assert!(
        sui_package::upgrade_package(upgrade_cap).to_address() ==
            lz_package::package_of_type<HUB_OAPP>(),
        E_WRONG_UPGRADE_CAP,
    );

    let cap = GovernanceCap { id: object::new(ctx), hub_id: object::id(hub) };
    hub.governance_cap = option::some(object::id(&cap));
    transfer::transfer(cap, governance);
}

// ---- Endpoint registration and peer configuration ------------------------

public fun register_oapp(
    hub: &mut HubOApp,
    oapp: &OApp,
    governance: &GovernanceCap,
    endpoint: &mut EndpointV2,
    next_nonce_info: vector<u8>,
    lz_receive_info: vector<u8>,
    extra_info: vector<u8>,
    ctx: &mut TxContext,
) {
    assert_governance(hub, governance);
    assert!(!hub.is_registered(), E_ALREADY_REGISTERED);
    assert_endpoint(hub, endpoint);
    assert_oapp(hub, oapp);

    assert!(
        !next_nonce_info.is_empty() && !lz_receive_info.is_empty(),
        E_INVALID_OAPP_INFO,
    );
    let oapp_info = oapp_info_v1::create(
        hub.oapp_object,
        next_nonce_info,
        lz_receive_info,
        extra_info,
    );
    let channel = endpoint.register_oapp(
        &hub.call_cap,
        oapp_info.encode(),
        ctx,
    );
    hub.endpoint_object = option::some(object::id_address(endpoint));
    hub.messaging_channel = option::some(channel);
}

/// Replace executor metadata without changing the registered package identity,
/// channel, peers, or either sealed LayerZero capability. The exact OApp object
/// is always derived from `HubOApp`; callers cannot substitute one in metadata.
public fun update_oapp_info(
    hub: &HubOApp,
    oapp: &OApp,
    governance: &GovernanceCap,
    endpoint: &mut EndpointV2,
    next_nonce_info: vector<u8>,
    lz_receive_info: vector<u8>,
    extra_info: vector<u8>,
) {
    assert_governance(hub, governance);
    assert!(hub.is_registered(), E_NOT_REGISTERED);
    assert_endpoint(hub, endpoint);
    assert_oapp(hub, oapp);
    assert!(
        !next_nonce_info.is_empty() && !lz_receive_info.is_empty(),
        E_INVALID_OAPP_INFO,
    );
    let oapp_info = oapp_info_v1::create(
        hub.oapp_object,
        next_nonce_info,
        lz_receive_info,
        extra_info,
    );
    endpoint.set_oapp_info(
        &hub.call_cap,
        hub.call_cap.id(),
        oapp_info.encode(),
    );
}

public fun configure_peer(
    hub: &HubOApp,
    oapp: &mut OApp,
    governance: &GovernanceCap,
    endpoint: &EndpointV2,
    channel: &mut MessagingChannel,
    remote_eid: u32,
    peer: Bytes32,
    ctx: &mut TxContext,
) {
    assert_governance(hub, governance);
    assert_ready(hub, oapp, endpoint, channel);
    assert!(is_supported_remote(remote_eid), E_UNSUPPORTED_REMOTE);
    assert!(!bytes32::is_zero(&peer), E_ZERO_PEER);
    oapp.set_peer(&hub.admin_cap, endpoint, channel, remote_eid, peer, ctx);
}

/// Bind mandatory destination execution options for the official OApp send
/// flow. Empty options are rejected so a route cannot be configured to emit
/// messages without an execution budget.
public fun configure_enforced_options(
    hub: &HubOApp,
    oapp: &mut OApp,
    governance: &GovernanceCap,
    remote_eid: u32,
    msg_type: u16,
    options: vector<u8>,
) {
    assert_governance(hub, governance);
    assert_oapp(hub, oapp);
    assert!(is_supported_remote(remote_eid), E_UNSUPPORTED_REMOTE);
    assert!(msg_type == REALLOCATE_MSG_TYPE, E_INVALID_OPTIONS);
    assert!(!options.is_empty(), E_INVALID_OPTIONS);
    oapp.set_enforced_options(&hub.admin_cap, remote_eid, msg_type, options);
}

/// Bind DAY's canonical HubState to this OTW-created OApp without accepting a
/// caller-authored CallCap address. The immutable identity is derived from the
/// sealed CallCap held by the exact `HubOApp` object after Endpoint
/// registration. Registry governance is still enforced by DAY; this wrapper
/// removes the typo/rogue-address footgun from the production bootstrap PTB.
public fun bind_canonical_day_hub_transport(
    hub: &HubOApp,
    governance: &GovernanceCap,
    config: &ProtocolConfig,
    day_hub: &mut HubState,
    registry: &StrategyRegistry,
    day_admin: &DayAdminCap,
    ctx: &TxContext,
) {
    assert!(hub.is_registered(), E_NOT_REGISTERED);
    assert_governance(hub, governance);
    hub_protocol::bind_layerzero_oapp_call_cap(
        config,
        day_hub,
        registry,
        day_admin,
        &hub.call_cap,
        ctx,
    )
}

// ---- Outbound LayerZero call path -----------------------------------------

/// Begin an outbound LayerZero send by borrowing the linear authorization
/// issued by DAY's policy hub. The caller supplies no destination or message;
/// both are committed after registry, leader, accounting reservation, and
/// typed per-leg guardrail checks. The token must be consumed by the completed
/// official Call finalizer in the same PTB or the transaction cannot finish.
public fun send_authorized_hub_command(
    hub: &mut HubOApp,
    oapp: &mut OApp,
    endpoint: &EndpointV2,
    channel: &MessagingChannel,
    authorized: AuthorizedHubCommand,
    native_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): PendingAuthorizedHubSend {
    // Borrow only long enough to build the official send. Ownership of the
    // linear DAY authorization moves into the returned pending-send proof.
    let (dst_eid, message) = hub_protocol::authorized_transport_message(&authorized);
    let call = send_hub_command(
        hub,
        oapp,
        endpoint,
        channel,
        dst_eid,
        message,
        native_fee,
        clock,
        ctx,
    );
    PendingAuthorizedHubSend { authorized, call }
}

/// Produce the official LayerZero Call hot potato after validating the DAY hub
/// wire header. It remains package-only so no public caller can substitute raw
/// bytes for DAY's `AuthorizedHubCommand`.
public(package) fun send_hub_command(
    hub: &mut HubOApp,
    oapp: &mut OApp,
    endpoint: &EndpointV2,
    channel: &MessagingChannel,
    dst_eid: u32,
    message: vector<u8>,
    native_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): Call<SendParam, MessagingReceipt> {
    assert_ready(hub, oapp, endpoint, channel);
    let expires_at_ms = assert_hub_message(dst_eid, &message);
    assert!(clock.timestamp_ms() <= expires_at_ms, E_EXPIRED);
    assert!(oapp.has_peer(dst_eid), E_UNSUPPORTED_REMOTE);
    let peer = oapp.get_peer(dst_eid);
    // Resolve the exact reallocation execution options before recording the
    // intent. A configured peer without a type-1 execution budget is not a
    // sendable route and must leave no committed outbound state behind.
    let options = reallocate_options(oapp, dst_eid);
    let command_hash = hash::sha2_256(copy message);
    let intent_id = intent_id(dst_eid, copy command_hash);
    assert!(!hub.outbound_intents.contains(copy intent_id), E_INTENT_EXISTS);
    hub.outbound_intents.add(copy intent_id, OutboundIntent {
        dst_eid,
        peer,
        command_hash: copy command_hash,
        expires_at_ms,
        outcome_recorded: false,
        outcome_received: false,
        outcome: 0,
    });
    event::emit(HubCommandCommitted {
        dst_eid,
        peer: peer.to_bytes(),
        intent_id,
        command_hash,
        expires_at_ms,
    });
    oapp.lz_send(
        &hub.call_cap,
        dst_eid,
        message,
        options,
        native_fee,
        option::none<Coin<ZRO>>(),
        option::some(ctx.sender()),
        ctx,
    )
}

fun reallocate_options(oapp: &OApp, dst_eid: u32): vector<u8> {
    let options = oapp.combine_options(
        dst_eid,
        REALLOCATE_MSG_TYPE,
        vector[],
    );
    assert!(!options.is_empty(), E_INVALID_OPTIONS);
    options
}

/// Complete the sequential LayerZero send after the Endpoint and message
/// library have executed the returned Call. The OApp's sealed CallCap and
/// `sending_call` id reject any unrelated or replayed Call.
public fun confirm_authorized_hub_command(
    hub: &HubOApp,
    oapp: &mut OApp,
    pending: PendingAuthorizedHubSend,
): (SendParam, MessagingReceipt) {
    assert_oapp(hub, oapp);
    let PendingAuthorizedHubSend { authorized, call } = pending;
    // DAY verifies the completed official Call while it is still bound to the
    // OApp's sealed CallCap. The verifier consumes the authorization token;
    // any failure in `confirm_lz_send` rolls the whole PTB back atomically.
    hub_protocol::consume_after_completed_layerzero_call(authorized, &call);
    oapp.confirm_lz_send(&hub.call_cap, call)
}

/// Permissionless storage cleanup after the audit retention window. The
/// immutable command/outcome events remain in chain history; live state keeps
/// each intent for at least 30 days after its committed expiry.
public fun prune_expired_intent(
    hub: &mut HubOApp,
    intent_id: vector<u8>,
    clock: &Clock,
) {
    assert!(hub.outbound_intents.contains(copy intent_id), E_UNKNOWN_INTENT);
    let intent = hub.outbound_intents.borrow(copy intent_id);
    let expires_at_ms = intent.expires_at_ms;
    // Never delete the command/hash binding while its ordered LayerZero
    // outcome can still arrive. Without this record an exact late nonce could
    // no longer authenticate its intent and would deadlock every later nonce.
    assert!(intent.outcome_received, E_INTENT_NOT_PRUNABLE);
    let now_ms = clock.timestamp_ms();
    assert!(
        now_ms > expires_at_ms && now_ms - expires_at_ms > INTENT_RETENTION_MS,
        E_INTENT_NOT_PRUNABLE,
    );
    let _intent = hub.outbound_intents.remove(copy intent_id);
    event::emit(HubIntentPruned { intent_id });
}

/// Deterministically close an unreturned intent as FAILED once its committed
/// expiry has passed. The caller supplies only the table key; destination,
/// command hash, expiry, and outcome are read from authenticated OApp state.
/// A later exact authenticated spoke message remains authoritative: it must
/// consume the return nonce and may replace this provisional timeout status.
/// Otherwise one late result would permanently deadlock every later nonce.
public fun mark_expired_intent_failed(
    hub: &mut HubOApp,
    intent_id: vector<u8>,
    clock: &Clock,
) {
    assert!(hub.outbound_intents.contains(copy intent_id), E_UNKNOWN_INTENT);
    let intent = hub.outbound_intents.borrow(copy intent_id);
    assert!(!intent.outcome_recorded, E_OUTCOME_ALREADY_RECORDED);
    let now_ms = clock.timestamp_ms();
    assert!(now_ms > intent.expires_at_ms, E_INTENT_NOT_EXPIRED);
    let dst_eid = intent.dst_eid;
    let peer = intent.peer.to_bytes();
    let command_hash = copy intent.command_hash;
    let expires_at_ms = intent.expires_at_ms;

    let intent = hub.outbound_intents.borrow_mut(copy intent_id);
    intent.outcome_recorded = true;
    intent.outcome = OUTCOME_FAILED;
    event::emit(HubIntentExpired {
        dst_eid,
        peer,
        intent_id,
        command_hash,
        expires_at_ms,
        recorded_at_ms: now_ms,
        outcome: OUTCOME_FAILED,
    });
}

// ---- Permissionless authenticated receive path ---------------------------

/// Receive an execution outcome from a configured spoke peer. LayerZero's
/// OApp validates the Endpoint CallCap and pinned peer before this module
/// parses application bytes. The payload has no EID, payout destination, or
/// amount/delta fields: it can only reconcile an existing locally committed
/// intent by its exact command hash.
public fun lz_receive_execution_outcome(
    hub: &mut HubOApp,
    oapp: &OApp,
    call: Call<LzReceiveParam, Void>,
    clock: &Clock,
) {
    assert!(hub.is_registered(), E_NOT_REGISTERED);
    assert_oapp(hub, oapp);
    let param = oapp.lz_receive(&hub.call_cap, call);
    assert!(param.value().is_none(), E_VALUE_NOT_ALLOWED);

    let src_eid = param.src_eid();
    assert!(is_supported_remote(src_eid), E_UNSUPPORTED_REMOTE);
    let source_peer = param.sender();
    let layerzero_nonce = param.nonce();
    let guid = param.guid().to_bytes();
    apply_authenticated_outcome(
        hub,
        src_eid,
        source_peer,
        layerzero_nonce,
        copy guid,
        *param.message(),
        clock.timestamp_ms(),
    );
    let (_, _, _, _, _, _, _, value) = param.destroy();
    value.destroy_none();
}

// ---- Codec ---------------------------------------------------------------

/// Canonical BCS encoder for spoke conformance fixtures. Encoding grants no
/// authority; only a configured peer delivered through the official Endpoint
/// can reach `lz_receive_execution_outcome`.
public fun encode_execution_outcome(
    intent_id: vector<u8>,
    command_hash: vector<u8>,
    outcome: u8,
): vector<u8> {
    assert!(intent_id.length() == HASH_LEN, E_INVALID_MESSAGE);
    assert!(command_hash.length() == HASH_LEN, E_INVALID_MESSAGE);
    assert!(outcome == OUTCOME_EXECUTED || outcome == OUTCOME_FAILED, E_INVALID_OUTCOME);
    bcs::to_bytes(&ExecutionOutcomeWire {
        domain: OUTCOME_DOMAIN,
        version: OUTCOME_VERSION,
        action: OUTCOME_ACTION_EXECUTION,
        intent_id,
        command_hash,
        outcome,
    })
}

fun decode_execution_outcome(
    message: vector<u8>,
): (vector<u8>, vector<u8>, u8) {
    let mut wire = bcs::new(message);
    assert!(wire.peel_vec_u8() == OUTCOME_DOMAIN, E_INVALID_MESSAGE);
    assert!(wire.peel_u8() == OUTCOME_VERSION, E_INVALID_MESSAGE);
    assert!(wire.peel_u8() == OUTCOME_ACTION_EXECUTION, E_UNKNOWN_ACTION);
    let outcome_intent_id = wire.peel_vec_u8();
    let command_hash = wire.peel_vec_u8();
    let outcome = wire.peel_u8();
    assert!(wire.into_remainder_bytes().is_empty(), E_INVALID_MESSAGE);
    assert!(outcome_intent_id.length() == HASH_LEN, E_INVALID_MESSAGE);
    assert!(command_hash.length() == HASH_LEN, E_INVALID_MESSAGE);
    assert!(outcome == OUTCOME_EXECUTED || outcome == OUTCOME_FAILED, E_INVALID_OUTCOME);
    (outcome_intent_id, command_hash, outcome)
}

fun apply_authenticated_outcome(
    hub: &mut HubOApp,
    src_eid: u32,
    source_peer: Bytes32,
    layerzero_nonce: u64,
    guid: vector<u8>,
    message: vector<u8>,
    now_ms: u64,
) {
    assert!(is_supported_remote(src_eid), E_UNSUPPORTED_REMOTE);
    assert!(guid.length() == HASH_LEN, E_INVALID_MESSAGE);
    assert!(!hub.consumed_guids.contains(copy guid), E_REPLAY);
    let (outcome_intent_id, command_hash, outcome) =
        decode_execution_outcome(message);
    assert!(hub.outbound_intents.contains(copy outcome_intent_id), E_UNKNOWN_INTENT);
    let intent = hub.outbound_intents.borrow(copy outcome_intent_id);
    assert!(intent.dst_eid == src_eid, E_INVALID_MESSAGE);
    assert!(intent.peer == source_peer, E_PEER_MISMATCH);
    assert!(intent.command_hash == command_hash, E_COMMAND_HASH_MISMATCH);
    let outcome_recorded = intent.outcome_recorded;
    let outcome_received = intent.outcome_received;
    let recorded_outcome = intent.outcome;
    let expires_at_ms = intent.expires_at_ms;
    // An authenticated transport outcome is accepted exactly once even when
    // it arrives after the command deadline. Expiry prevents new execution;
    // it must not falsify a pinned peer's already-executed result or strand
    // the ordered return channel. The only replaceable local state is the
    // provisional FAILED status written by mark_expired_intent_failed.
    assert!(!outcome_received, E_OUTCOME_ALREADY_RECORDED);
    if (outcome_recorded) {
        assert!(recorded_outcome == OUTCOME_FAILED && now_ms > expires_at_ms, E_OUTCOME_ALREADY_RECORDED);
    };
    consume_return_nonce(hub, src_eid, source_peer, layerzero_nonce);

    let intent = hub.outbound_intents.borrow_mut(copy outcome_intent_id);
    intent.outcome_recorded = true;
    intent.outcome_received = true;
    intent.outcome = outcome;
    hub.consumed_guids.add(copy guid, true);
    event::emit(ExecutionOutcomeRecorded {
        src_eid,
        source_peer: source_peer.to_bytes(),
        layerzero_nonce,
        guid,
        intent_id: outcome_intent_id,
        command_hash,
        outcome,
    });
}

fun intent_id(dst_eid: u32, command_hash: vector<u8>): vector<u8> {
    hash::sha2_256(bcs::to_bytes(&IntentPreimageV1 {
        domain: INTENT_DOMAIN,
        dst_eid,
        command_hash,
    }))
}

fun assert_hub_message(dst_eid: u32, message: &vector<u8>): u64 {
    assert!(is_supported_remote(dst_eid), E_UNSUPPORTED_REMOTE);
    hub_protocol::assert_managed_reallocate_v1_message(dst_eid, message)
}

// ---- Predicates and views ------------------------------------------------

fun assert_governance(hub: &HubOApp, governance: &GovernanceCap) {
    assert!(hub.governance_cap.is_some(), E_GOVERNANCE_UNRESOLVED);
    assert!(governance.hub_id == object::id(hub), E_WRONG_GOVERNANCE);
    assert!(object::id(governance) == *hub.governance_cap.borrow(), E_WRONG_GOVERNANCE);
}

fun assert_endpoint(hub: &HubOApp, endpoint: &EndpointV2) {
    assert!(object::id_address(endpoint) == hub.expected_endpoint, E_WRONG_ENDPOINT);
    assert!(endpoint.eid() == SUI_EID, E_WRONG_LOCAL_EID);
}

fun assert_oapp(hub: &HubOApp, oapp: &OApp) {
    assert!(object::id_address(oapp) == hub.oapp_object, E_WRONG_OAPP);
    assert!(oapp.oapp_cap_id() == hub.call_cap.id(), E_WRONG_OAPP);
    assert!(oapp.admin_cap() == object::id_address(&hub.admin_cap), E_WRONG_OAPP);
}

fun assert_ready(
    hub: &HubOApp,
    oapp: &OApp,
    endpoint: &EndpointV2,
    channel: &MessagingChannel,
) {
    assert!(hub.is_registered(), E_NOT_REGISTERED);
    assert_endpoint(hub, endpoint);
    assert_oapp(hub, oapp);
    assert!(object::id_address(channel) == *hub.messaging_channel.borrow(), E_WRONG_CHANNEL);
    assert!(endpoint_v2::get_oapp(channel) == hub.call_cap.id(), E_WRONG_CHANNEL);
}

fun consume_return_nonce(
    hub: &mut HubOApp,
    eid: u32,
    peer: Bytes32,
    nonce: u64,
) {
    let mut i = 0;
    while (i < hub.return_sequences.length()) {
        let sequence = hub.return_sequences.borrow_mut(i);
        if (sequence.eid == eid && sequence.peer == peer) {
            // EndpointV2 may deliver a higher nonce after all preceding
            // payloads have merely been verified, and its admin can skip a
            // nonce. Neither condition proves DAY application ordering. DAY
            // therefore accepts only the exact next outcome from this peer.
            assert!(nonce == sequence.next_nonce, E_REPLAY_OR_GAP);
            sequence.next_nonce = sequence.next_nonce + 1;
            return
        };
        i = i + 1;
    };
    // LayerZero EndpointV2 inbound channel nonces are 1-based.
    assert!(nonce == 1, E_REPLAY_OR_GAP);
    hub.return_sequences.push_back(RemoteSequence { eid, peer, next_nonce: 2 });
}

public fun is_supported_remote(eid: u32): bool {
    // A supported EID is not enough to send or receive: the governance-bound
    // OApp must also pin an exact nonzero Bytes32 peer for that EID.
    // DAY-903: six-chain EVM expansion.
    eid == BASE_EID || eid == ARBITRUM_EID || eid == SOLANA_EID || eid == ETHEREUM_EID
        || eid == BSC_EID || eid == POLYGON_EID || eid == MONAD_EID || eid == PLASMA_EID
        || eid == ROBINHOOD_EID
}

public fun is_registered(hub: &HubOApp): bool {
    hub.endpoint_object.is_some() && hub.messaging_channel.is_some()
}

public fun endpoint_object(hub: &HubOApp): Option<address> { hub.endpoint_object }
public fun messaging_channel(hub: &HubOApp): Option<address> { hub.messaging_channel }
public fun governance_cap_id(hub: &HubOApp): Option<ID> { hub.governance_cap }
public fun oapp_object(hub: &HubOApp): address { hub.oapp_object }
public fun oapp_package_id(hub: &HubOApp): address { hub.call_cap.id() }
public fun sui_eid(): u32 { SUI_EID }
public fun endpoint_v2_object(): address { ENDPOINT_V2_OBJECT }

// ---- Test helpers --------------------------------------------------------

#[test_only]
public fun new_for_testing(
    call_cap: CallCap,
    admin_cap: AdminCap,
    oapp_object: address,
    expected_endpoint: address,
    ctx: &mut TxContext,
): HubOApp {
    HubOApp {
        id: object::new(ctx),
        oapp_object,
        call_cap,
        admin_cap,
        expected_endpoint,
        endpoint_object: option::none(),
        messaging_channel: option::none(),
        governance_cap: option::none(),
        outbound_intents: table::new(ctx),
        consumed_guids: table::new(ctx),
        return_sequences: vector[],
    }
}

#[test_only]
public fun create_governance_for_testing(
    hub: &mut HubOApp,
    ctx: &mut TxContext,
): GovernanceCap {
    let cap = GovernanceCap { id: object::new(ctx), hub_id: object::id(hub) };
    hub.governance_cap = option::some(object::id(&cap));
    cap
}

#[test_only]
public fun share_for_testing(hub: HubOApp) {
    transfer::share_object(hub)
}

#[test_only]
public fun destroy_for_testing(hub: HubOApp): (CallCap, AdminCap) {
    let HubOApp {
        id,
        oapp_object: _,
        call_cap,
        admin_cap,
        expected_endpoint: _,
        endpoint_object: _,
        messaging_channel: _,
        governance_cap: _,
        outbound_intents,
        consumed_guids,
        return_sequences: _,
    } = hub;
    outbound_intents.drop();
    consumed_guids.drop();
    id.delete();
    (call_cap, admin_cap)
}

#[test_only]
public fun destroy_governance_for_testing(cap: GovernanceCap) {
    let GovernanceCap { id, hub_id: _ } = cap;
    id.delete();
}

#[test_only]
public fun transfer_governance_for_testing(cap: GovernanceCap, recipient: address) {
    transfer::transfer(cap, recipient)
}

#[test_only]
public fun assert_governance_for_testing(
    hub: &HubOApp,
    governance: &GovernanceCap,
) {
    assert_governance(hub, governance)
}

#[test_only]
public fun assert_reallocate_options_for_testing(oapp: &OApp, dst_eid: u32) {
    let _ = reallocate_options(oapp, dst_eid);
}

#[test_only]
public fun assert_hub_message_for_testing(dst_eid: u32, message: vector<u8>) {
    let _ = assert_hub_message(dst_eid, &message);
}

#[test_only]
public fun record_intent_for_testing(
    hub: &mut HubOApp,
    dst_eid: u32,
    command_hash: vector<u8>,
    expires_at_ms: u64,
): vector<u8> {
    record_intent_for_peer_testing(
        hub,
        dst_eid,
        bytes32::from_bytes(TEST_PEER),
        command_hash,
        expires_at_ms,
    )
}

#[test_only]
public fun record_intent_for_peer_testing(
    hub: &mut HubOApp,
    dst_eid: u32,
    peer: Bytes32,
    command_hash: vector<u8>,
    expires_at_ms: u64,
): vector<u8> {
    assert!(command_hash.length() == HASH_LEN, E_INVALID_MESSAGE);
    let id = intent_id(dst_eid, copy command_hash);
    assert!(!hub.outbound_intents.contains(copy id), E_INTENT_EXISTS);
    hub.outbound_intents.add(copy id, OutboundIntent {
        dst_eid,
        peer,
        command_hash,
        expires_at_ms,
        outcome_recorded: false,
        outcome_received: false,
        outcome: 0,
    });
    id
}

#[test_only]
public fun apply_authenticated_outcome_for_testing(
    hub: &mut HubOApp,
    src_eid: u32,
    layerzero_nonce: u64,
    guid: vector<u8>,
    message: vector<u8>,
    now_ms: u64,
) {
    apply_authenticated_outcome_for_peer_testing(
        hub,
        src_eid,
        bytes32::from_bytes(TEST_PEER),
        layerzero_nonce,
        guid,
        message,
        now_ms,
    )
}

#[test_only]
public fun apply_authenticated_outcome_for_peer_testing(
    hub: &mut HubOApp,
    src_eid: u32,
    source_peer: Bytes32,
    layerzero_nonce: u64,
    guid: vector<u8>,
    message: vector<u8>,
    now_ms: u64,
) {
    apply_authenticated_outcome(
        hub,
        src_eid,
        source_peer,
        layerzero_nonce,
        guid,
        message,
        now_ms,
    )
}

#[test_only]
public fun outcome_for_testing(hub: &HubOApp, id: vector<u8>): (bool, u8) {
    let intent = hub.outbound_intents.borrow(id);
    (intent.outcome_recorded, intent.outcome)
}

#[test_only]
public fun has_intent_for_testing(hub: &HubOApp, id: vector<u8>): bool {
    hub.outbound_intents.contains(id)
}
