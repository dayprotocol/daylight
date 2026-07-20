// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
#[test_only]
module day_hub_oapp::hub_oapp_tests;

use call::{call, call_cap};
use day::hub_protocol;
use day_hub_oapp::hub_oapp::{Self, HubOApp};
use endpoint_v2::{
    endpoint_v2::{Self, AdminCap as EndpointAdminCap, EndpointV2},
    lz_receive,
    messaging_channel::MessagingChannel,
};
use oapp::{
    oapp::{Self, OApp},
    oapp_info_v1,
};
use sui::{
    bcs,
    clock,
    coin,
    sui::SUI,
    test_scenario::{Self as ts, Scenario},
};
use utils::bytes32;

const ALICE: address = @0xA11CE;
const BASE_EID: u32 = 30_184;
const ARBITRUM_EID: u32 = 30_110;
const SOLANA_EID: u32 = 30_168;
// DAY-903: six-chain EVM expansion.
const ETHEREUM_EID: u32 = 30_101;
const BSC_EID: u32 = 30_102;
const POLYGON_EID: u32 = 30_109;
const MONAD_EID: u32 = 30_390;
const PLASMA_EID: u32 = 30_383;
const ROBINHOOD_EID: u32 = 30_416;
const HASH: vector<u8> =
    x"1111111111111111111111111111111111111111111111111111111111111111";
const OTHER_HASH: vector<u8> =
    x"2222222222222222222222222222222222222222222222222222222222222222";
const GUID: vector<u8> =
    x"3333333333333333333333333333333333333333333333333333333333333333";
const OTHER_GUID: vector<u8> =
    x"4444444444444444444444444444444444444444444444444444444444444444";
const BASE_PEER: vector<u8> =
    x"5555555555555555555555555555555555555555555555555555555555555555";
const ROGUE_PEER: vector<u8> =
    x"6666666666666666666666666666666666666666666666666666666666666666";
const PEER_B: vector<u8> =
    x"7777777777777777777777777777777777777777777777777777777777777777";
const THIRD_HASH: vector<u8> =
    x"8888888888888888888888888888888888888888888888888888888888888888";
const THIRD_GUID: vector<u8> =
    x"9999999999999999999999999999999999999999999999999999999999999999";

public struct LegacyHeaderOnly has drop {
    domain: vector<u8>,
    version: u8,
    action: u8,
    spoke_eid: u32,
    sequence: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
}

public struct RawOutcomeWire has drop {
    domain: vector<u8>,
    version: u8,
    action: u8,
    intent_id: vector<u8>,
    command_hash: vector<u8>,
    outcome: u8,
}

fun managed_command(dst_eid: u32, action: u8): vector<u8> {
    managed_command_with_commitments(dst_eid, action, OTHER_HASH, OTHER_HASH, THIRD_HASH)
}

fun managed_command_with_commitments(
    dst_eid: u32,
    action: u8,
    guardrails_id: vector<u8>,
    route_commitment: vector<u8>,
    reallocation_state_id: vector<u8>,
): vector<u8> {
    hub_protocol::managed_reallocate_v1_bytes_for_testing(
        dst_eid,
        action,
        0,
        1_000,
        2_000,
        b"strategy-1",
        HASH,
        guardrails_id,
        b"sui",
        if (dst_eid == ARBITRUM_EID) b"arbitrum" else b"base",
        b"sui-native-asset",
        b"destination-native-asset",
        b"source-opportunity",
        b"destination-opportunity",
        5_000,
        route_commitment,
        reallocation_state_id,
    )
}

fun setup(): (Scenario, ID) {
    let mut scenario = ts::begin(ALICE);
    let call_cap = call_cap::new_package_cap_for_test(ts::ctx(&mut scenario));
    let admin_cap = oapp::create_admin_cap_for_test(ts::ctx(&mut scenario));
    let hub = hub_oapp::new_for_testing(
        call_cap,
        admin_cap,
        @0xC0FFEE,
        hub_oapp::endpoint_v2_object(),
        ts::ctx(&mut scenario),
    );
    let id = object::id(&hub);
    hub_oapp::share_for_testing(hub);
    (scenario, id)
}

fun cleanup(mut scenario: Scenario) {
    ts::next_tx(&mut scenario, ALICE);
    let hub = ts::take_shared<HubOApp>(&scenario);
    let (call_cap, admin_cap) = hub_oapp::destroy_for_testing(hub);
    transfer::public_transfer(call_cap, ALICE);
    transfer::public_transfer(admin_cap, ALICE);
    ts::end(scenario);
}

/// Build the same object relationship production uses: official EndpointV2,
/// official OApp, sealed package CallCap/AdminCap, registered channel, and a
/// governance-configured Base peer. IDs are returned so each test can borrow
/// the real shared objects in a later transaction.
fun setup_registered_with_options(
    configure_type1_options: bool,
): (Scenario, ID, ID, ID, ID) {
    let mut scenario = ts::begin(ALICE);
    endpoint_v2::init_for_test(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ALICE);
    let mut endpoint = ts::take_shared<EndpointV2>(&scenario);
    let endpoint_admin = ts::take_from_sender<EndpointAdminCap>(&scenario);
    endpoint.init_eid(&endpoint_admin, hub_oapp::sui_eid());

    let call_cap = call_cap::new_package_cap_for_test(ts::ctx(&mut scenario));
    let admin_cap = oapp::create_admin_cap_for_test(ts::ctx(&mut scenario));
    let oapp = oapp::create_oapp_for_test(
        &call_cap,
        &admin_cap,
        ts::ctx(&mut scenario),
    );
    let oapp_id = object::id(&oapp);
    let mut hub = hub_oapp::new_for_testing(
        call_cap,
        admin_cap,
        object::id_address(&oapp),
        object::id_address(&endpoint),
        ts::ctx(&mut scenario),
    );
    let hub_id = object::id(&hub);
    let governance = hub_oapp::create_governance_for_testing(
        &mut hub,
        ts::ctx(&mut scenario),
    );
    hub_oapp::register_oapp(
        &mut hub,
        &oapp,
        &governance,
        &mut endpoint,
        b"next_nonce_v1",
        b"lz_receive_v1",
        b"",
        ts::ctx(&mut scenario),
    );
    let channel_id = object::id_from_address(
        *hub_oapp::messaging_channel(&hub).borrow(),
    );
    let endpoint_id = object::id(&endpoint);

    hub_oapp::share_for_testing(hub);
    oapp::share_oapp_for_test(oapp);
    hub_oapp::transfer_governance_for_testing(governance, ALICE);
    ts::return_shared(endpoint);
    ts::return_to_sender(&scenario, endpoint_admin);

    ts::next_tx(&mut scenario, ALICE);
    let hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let mut oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);
    let mut channel = ts::take_shared_by_id<MessagingChannel>(&scenario, channel_id);
    let governance = ts::take_from_sender<day_hub_oapp::hub_oapp::GovernanceCap>(&scenario);
    hub_oapp::configure_peer(
        &hub,
        &mut oapp,
        &governance,
        &endpoint,
        &mut channel,
        BASE_EID,
        bytes32::from_bytes(BASE_PEER),
        ts::ctx(&mut scenario),
    );
    if (configure_type1_options) {
        hub_oapp::configure_enforced_options(
            &hub,
            &mut oapp,
            &governance,
            BASE_EID,
            1,
            x"00030100110100000000000000000000000000030d40",
        );
    };
    hub_oapp::configure_peer(
        &hub,
        &mut oapp,
        &governance,
        &endpoint,
        &mut channel,
        ARBITRUM_EID,
        bytes32::from_bytes(BASE_PEER),
        ts::ctx(&mut scenario),
    );
    if (configure_type1_options) {
        hub_oapp::configure_enforced_options(
            &hub,
            &mut oapp,
            &governance,
            ARBITRUM_EID,
            1,
            x"00030100110100000000000000000000000000030d40",
        );
    };
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::return_shared(channel);
    ts::return_to_sender(&scenario, governance);

    (scenario, hub_id, oapp_id, endpoint_id, channel_id)
}

fun setup_registered(): (Scenario, ID, ID, ID, ID) {
    setup_registered_with_options(true)
}

#[test]
fun test_registration_binds_canonical_oapp_info_and_peers() {
    let (mut scenario, hub_id, oapp_id, endpoint_id, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);

    assert!(hub_oapp::is_registered(&hub), 0);
    assert!(oapp.has_peer(BASE_EID), 1);
    assert!(oapp.has_peer(ARBITRUM_EID), 2);
    let info = oapp_info_v1::decode(endpoint.get_oapp_info(oapp.oapp_cap_id()));
    assert!(oapp_info_v1::oapp_object(&info) == object::id_address(&oapp), 3);
    assert!(*oapp_info_v1::next_nonce_info(&info) == b"next_nonce_v1", 4);
    assert!(*oapp_info_v1::lz_receive_info(&info) == b"lz_receive_v1", 5);

    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_WRONG_GOVERNANCE)]
fun test_governance_cap_is_bound_to_one_hub() {
    let mut scenario = ts::begin(ALICE);
    let call_cap_a = call_cap::new_package_cap_for_test(ts::ctx(&mut scenario));
    let admin_cap_a = oapp::create_admin_cap_for_test(ts::ctx(&mut scenario));
    let mut hub_a = hub_oapp::new_for_testing(
        call_cap_a,
        admin_cap_a,
        @0xA,
        hub_oapp::endpoint_v2_object(),
        ts::ctx(&mut scenario),
    );
    let governance_a = hub_oapp::create_governance_for_testing(
        &mut hub_a,
        ts::ctx(&mut scenario),
    );
    let call_cap_b = call_cap::new_package_cap_for_test(ts::ctx(&mut scenario));
    let admin_cap_b = oapp::create_admin_cap_for_test(ts::ctx(&mut scenario));
    let mut hub_b = hub_oapp::new_for_testing(
        call_cap_b,
        admin_cap_b,
        @0xB,
        hub_oapp::endpoint_v2_object(),
        ts::ctx(&mut scenario),
    );
    let governance_b = hub_oapp::create_governance_for_testing(
        &mut hub_b,
        ts::ctx(&mut scenario),
    );
    hub_oapp::assert_governance_for_testing(&hub_b, &governance_a);
    hub_oapp::destroy_governance_for_testing(governance_a);
    hub_oapp::destroy_governance_for_testing(governance_b);
    let (call_cap_a, admin_cap_a) = hub_oapp::destroy_for_testing(hub_a);
    let (call_cap_b, admin_cap_b) = hub_oapp::destroy_for_testing(hub_b);
    transfer::public_transfer(call_cap_a, ALICE);
    transfer::public_transfer(admin_cap_a, ALICE);
    transfer::public_transfer(call_cap_b, ALICE);
    transfer::public_transfer(admin_cap_b, ALICE);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_OAPP_INFO)]
fun test_registered_oapp_rejects_empty_executor_metadata() {
    let (mut scenario, hub_id, oapp_id, endpoint_id, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let mut endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);
    let governance = ts::take_from_sender<day_hub_oapp::hub_oapp::GovernanceCap>(&scenario);
    hub_oapp::update_oapp_info(
        &hub,
        &oapp,
        &governance,
        &mut endpoint,
        b"",
        b"lz_receive_v1",
        b"",
    );
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::return_to_sender(&scenario, governance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_OPTIONS)]
fun test_peer_options_cannot_be_empty() {
    let (mut scenario, hub_id, oapp_id, _, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let mut oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let governance = ts::take_from_sender<day_hub_oapp::hub_oapp::GovernanceCap>(&scenario);
    hub_oapp::configure_enforced_options(
        &hub,
        &mut oapp,
        &governance,
        BASE_EID,
        1,
        b"",
    );
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_to_sender(&scenario, governance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_OPTIONS)]
fun test_non_reallocate_message_type_cannot_be_configured() {
    let (mut scenario, hub_id, oapp_id, _, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let mut oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let governance = ts::take_from_sender<day_hub_oapp::hub_oapp::GovernanceCap>(&scenario);
    hub_oapp::configure_enforced_options(
        &hub,
        &mut oapp,
        &governance,
        BASE_EID,
        2,
        x"00030100110100000000000000000000000000030d40",
    );
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_to_sender(&scenario, governance);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_OPTIONS)]
fun test_configured_peer_without_type1_options_is_not_sendable() {
    let (mut scenario, _, oapp_id, _, _) = setup_registered_with_options(false);
    ts::next_tx(&mut scenario, ALICE);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    assert!(oapp.has_peer(BASE_EID), 0);
    hub_oapp::assert_reallocate_options_for_testing(&oapp, BASE_EID);
    ts::return_shared(oapp);
    ts::end(scenario);
}

#[test]
fun test_official_endpoint_call_records_executed_outcome() {
    let (mut scenario, hub_id, oapp_id, endpoint_id, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        2_000,
    );
    let param = lz_receive::create_param_for_test(
        BASE_EID,
        bytes32::from_bytes(BASE_PEER),
        1,
        bytes32::from_bytes(GUID),
        hub_oapp::encode_execution_outcome(copy intent_id, HASH, 1),
        ALICE,
        b"",
        option::none(),
    );
    let call = call::create(
        endpoint.get_call_cap_ref(),
        oapp.oapp_cap_id(),
        true,
        param,
        ts::ctx(&mut scenario),
    );
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_500);
    hub_oapp::lz_receive_execution_outcome(&mut hub, &oapp, call, &test_clock);
    let (recorded, outcome) = hub_oapp::outcome_for_testing(&hub, intent_id);
    assert!(recorded, 0);
    assert!(outcome == 1, 1);
    clock::destroy_for_testing(test_clock);

    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = oapp::EOnlyPeer)]
fun test_official_receive_rejects_rogue_peer() {
    let (mut scenario, hub_id, oapp_id, endpoint_id, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        2_000,
    );
    let param = lz_receive::create_param_for_test(
        BASE_EID,
        bytes32::from_bytes(ROGUE_PEER),
        1,
        bytes32::from_bytes(GUID),
        hub_oapp::encode_execution_outcome(intent_id, HASH, 1),
        ALICE,
        b"",
        option::none(),
    );
    let call = call::create(
        endpoint.get_call_cap_ref(),
        oapp.oapp_cap_id(),
        true,
        param,
        ts::ctx(&mut scenario),
    );
    let test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    hub_oapp::lz_receive_execution_outcome(&mut hub, &oapp, call, &test_clock);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_MESSAGE)]
fun test_official_receive_rejects_authenticated_wrong_eid() {
    let (mut scenario, hub_id, oapp_id, endpoint_id, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        2_000,
    );
    let param = lz_receive::create_param_for_test(
        ARBITRUM_EID,
        bytes32::from_bytes(BASE_PEER),
        1,
        bytes32::from_bytes(GUID),
        hub_oapp::encode_execution_outcome(intent_id, HASH, 1),
        ALICE,
        b"",
        option::none(),
    );
    let call = call::create(
        endpoint.get_call_cap_ref(),
        oapp.oapp_cap_id(),
        true,
        param,
        ts::ctx(&mut scenario),
    );
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_500);
    hub_oapp::lz_receive_execution_outcome(&mut hub, &oapp, call, &test_clock);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_VALUE_NOT_ALLOWED)]
fun test_official_receive_rejects_attached_value() {
    let (mut scenario, hub_id, oapp_id, endpoint_id, _) = setup_registered();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared_by_id<HubOApp>(&scenario, hub_id);
    let oapp = ts::take_shared_by_id<OApp>(&scenario, oapp_id);
    let endpoint = ts::take_shared_by_id<EndpointV2>(&scenario, endpoint_id);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        2_000,
    );
    let value = coin::zero<SUI>(ts::ctx(&mut scenario));
    let param = lz_receive::create_param_for_test(
        BASE_EID,
        bytes32::from_bytes(BASE_PEER),
        1,
        bytes32::from_bytes(GUID),
        hub_oapp::encode_execution_outcome(intent_id, HASH, 1),
        ALICE,
        b"",
        option::some(value),
    );
    let call = call::create(
        endpoint.get_call_cap_ref(),
        oapp.oapp_cap_id(),
        true,
        param,
        ts::ctx(&mut scenario),
    );
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_500);
    hub_oapp::lz_receive_execution_outcome(&mut hub, &oapp, call, &test_clock);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    ts::return_shared(oapp);
    ts::return_shared(endpoint);
    ts::end(scenario);
}

#[test]
fun test_supported_remotes_are_exact() {
    assert!(hub_oapp::is_supported_remote(BASE_EID), 0);
    assert!(hub_oapp::is_supported_remote(ARBITRUM_EID), 1);
    assert!(hub_oapp::is_supported_remote(SOLANA_EID), 2);
    // DAY-903: six-chain EVM expansion.
    assert!(hub_oapp::is_supported_remote(ETHEREUM_EID), 3);
    assert!(hub_oapp::is_supported_remote(BSC_EID), 4);
    assert!(hub_oapp::is_supported_remote(POLYGON_EID), 5);
    assert!(hub_oapp::is_supported_remote(MONAD_EID), 6);
    assert!(hub_oapp::is_supported_remote(PLASMA_EID), 7);
    assert!(hub_oapp::is_supported_remote(ROBINHOOD_EID), 8);
    assert!(!hub_oapp::is_supported_remote(hub_oapp::sui_eid()), 9);
    assert!(!hub_oapp::is_supported_remote(0), 10);
    // A bogus eid (tron 30_420, or anything unmapped) still fails closed.
    assert!(!hub_oapp::is_supported_remote(30_420), 11);
    assert!(!hub_oapp::is_supported_remote(99_999), 12);
}

#[test]
fun test_reallocate_header_accepts_matching_committed_destination() {
    hub_oapp::assert_hub_message_for_testing(BASE_EID, managed_command(BASE_EID, 1));
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_WRONG_SPOKE)]
fun test_header_destination_substitution_fails_closed() {
    hub_oapp::assert_hub_message_for_testing(ARBITRUM_EID, managed_command(BASE_EID, 1));
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_UNKNOWN_ACTION)]
fun test_exit_mode_is_not_transportable() {
    hub_oapp::assert_hub_message_for_testing(BASE_EID, managed_command(BASE_EID, 2));
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_UNKNOWN_ACTION)]
fun test_unknown_action_fails_closed() {
    hub_oapp::assert_hub_message_for_testing(BASE_EID, managed_command(BASE_EID, 255));
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_UNSUPPORTED_REMOTE)]
fun test_unsupported_remote_fails_before_message_send() {
    hub_oapp::assert_hub_message_for_testing(30_378, managed_command(30_378, 1));
}

#[test]
#[expected_failure]
fun test_legacy_header_only_is_not_a_managed_reallocation() {
    hub_oapp::assert_hub_message_for_testing(
        BASE_EID,
        bcs::to_bytes(&LegacyHeaderOnly {
            domain: b"DAY_HUB",
            version: 1,
            action: 1,
            spoke_eid: BASE_EID,
            sequence: 0,
            issued_at_ms: 1_000,
            expires_at_ms: 2_000,
        }),
    );
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_INVALID_PROVENANCE)]
fun test_route_commitment_is_required() {
    hub_oapp::assert_hub_message_for_testing(
        BASE_EID,
        managed_command_with_commitments(BASE_EID, 1, OTHER_HASH, b"not-32-bytes", THIRD_HASH),
    );
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_GUARDRAILS_MISMATCH)]
fun test_guardrails_id_is_required() {
    hub_oapp::assert_hub_message_for_testing(
        BASE_EID,
        managed_command_with_commitments(BASE_EID, 1, b"not-32-bytes", OTHER_HASH, THIRD_HASH),
    );
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_INVALID_PROVENANCE)]
fun test_reallocation_state_id_is_required() {
    hub_oapp::assert_hub_message_for_testing(
        BASE_EID,
        managed_command_with_commitments(BASE_EID, 1, OTHER_HASH, OTHER_HASH, b"not-32-bytes"),
    );
}

#[test]
#[expected_failure(abort_code = day::hub_protocol::E_INVALID_PROVENANCE)]
fun test_managed_reallocation_rejects_trailing_bytes() {
    let mut message = managed_command(BASE_EID, 1);
    message.push_back(0xFF);
    hub_oapp::assert_hub_message_for_testing(BASE_EID, message);
}

#[test]
fun test_authenticated_outcome_reconciles_exact_committed_command() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let message = hub_oapp::encode_execution_outcome(
        copy intent_id,
        HASH,
        1,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        message,
        1_500,
    );
    let (recorded, outcome) =
        hub_oapp::outcome_for_testing(&hub, intent_id);
    assert!(recorded, 0);
    assert!(outcome == 1, 1);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_UNKNOWN_INTENT)]
fun test_unmatched_outcome_hash_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let message = hub_oapp::encode_execution_outcome(HASH, HASH, 1);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        message,
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_COMMAND_HASH_MISMATCH)]
fun test_command_hash_substitution_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let message = hub_oapp::encode_execution_outcome(intent_id, OTHER_HASH, 1);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        message,
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_MESSAGE)]
fun test_outcome_from_wrong_eid_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let message = hub_oapp::encode_execution_outcome(intent_id, HASH, 1);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        ARBITRUM_EID,
        1,
        GUID,
        message,
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_OUTCOME_ALREADY_RECORDED)]
fun test_duplicate_outcome_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let message = hub_oapp::encode_execution_outcome(copy intent_id, HASH, 1);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        copy message,
        1_500,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        2,
        OTHER_GUID,
        message,
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_REPLAY)]
fun test_guid_replay_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let first_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let second_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, OTHER_HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(first_id, HASH, 1),
        1_500,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        2,
        GUID,
        hub_oapp::encode_execution_outcome(second_id, OTHER_HASH, 1),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_REPLAY_OR_GAP)]
fun test_lower_or_repeated_outcome_nonce_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let first_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let second_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, OTHER_HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(first_id, HASH, 1),
        1_500,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        OTHER_GUID,
        hub_oapp::encode_execution_outcome(second_id, OTHER_HASH, 1),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_REPLAY_OR_GAP)]
fun test_outcome_nonce_gap_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let first_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let second_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, OTHER_HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(first_id, HASH, 1),
        1_500,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        3,
        OTHER_GUID,
        hub_oapp::encode_execution_outcome(second_id, OTHER_HASH, 1),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
fun test_peer_rotation_starts_new_nonce_and_rotate_back_resumes_old_peer() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let peer_a = bytes32::from_bytes(BASE_PEER);
    let peer_b = bytes32::from_bytes(PEER_B);

    let a_first = hub_oapp::record_intent_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_a,
        HASH,
        2_000,
    );
    hub_oapp::apply_authenticated_outcome_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_a,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(a_first, HASH, 1),
        1_500,
    );

    let b_first = hub_oapp::record_intent_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_b,
        OTHER_HASH,
        2_000,
    );
    hub_oapp::apply_authenticated_outcome_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_b,
        1,
        OTHER_GUID,
        hub_oapp::encode_execution_outcome(b_first, OTHER_HASH, 1),
        1_500,
    );

    let a_second = hub_oapp::record_intent_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_a,
        THIRD_HASH,
        2_000,
    );
    hub_oapp::apply_authenticated_outcome_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_a,
        2,
        THIRD_GUID,
        hub_oapp::encode_execution_outcome(copy a_second, THIRD_HASH, 1),
        1_500,
    );
    let (recorded, outcome) = hub_oapp::outcome_for_testing(&hub, a_second);
    assert!(recorded, 0);
    assert!(outcome == 1, 1);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_PEER_MISMATCH)]
fun test_rotated_peer_cannot_attest_old_peer_intent() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let peer_a = bytes32::from_bytes(BASE_PEER);
    let peer_b = bytes32::from_bytes(PEER_B);
    let old_intent = hub_oapp::record_intent_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_a,
        HASH,
        2_000,
    );
    hub_oapp::apply_authenticated_outcome_for_peer_testing(
        &mut hub,
        BASE_EID,
        peer_b,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(old_intent, HASH, 1),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
fun test_old_peer_intent_expires_failed_after_rotation() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let old_intent = hub_oapp::record_intent_for_peer_testing(
        &mut hub,
        BASE_EID,
        bytes32::from_bytes(BASE_PEER),
        HASH,
        1_000,
    );
    // A newly configured peer does not gain authority over this old intent.
    let _new_peer = bytes32::from_bytes(PEER_B);
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_001);
    hub_oapp::mark_expired_intent_failed(&mut hub, copy old_intent, &test_clock);
    let (recorded, outcome) = hub_oapp::outcome_for_testing(&hub, old_intent);
    assert!(recorded, 0);
    assert!(outcome == 2, 1);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
fun test_expired_intent_can_be_pruned_after_retention() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let mut test_clock = sui::clock::create_for_testing(ts::ctx(&mut scenario));
    sui::clock::set_for_testing(&mut test_clock, 2_592_002_001);
    // Pruning is allowed only after the pinned peer's exact return message has
    // consumed this intent's ordered nonce. A local timeout alone must retain
    // the command binding needed to authenticate a late result.
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(copy intent_id, HASH, 2),
        2_592_002_001,
    );
    hub_oapp::prune_expired_intent(&mut hub, copy intent_id, &test_clock);
    assert!(!hub_oapp::has_intent_for_testing(&hub, intent_id), 0);
    sui::clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
fun test_expiry_marks_intent_failed_without_caller_authored_outcome() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        1_000,
    );
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_001);
    hub_oapp::mark_expired_intent_failed(&mut hub, copy intent_id, &test_clock);
    let (recorded, outcome) = hub_oapp::outcome_for_testing(&hub, intent_id);
    assert!(recorded, 0);
    assert!(outcome == 2, 1);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INTENT_NOT_EXPIRED)]
fun test_live_intent_cannot_be_marked_failed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        1_000,
    );
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_000);
    hub_oapp::mark_expired_intent_failed(&mut hub, intent_id, &test_clock);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_OUTCOME_ALREADY_RECORDED)]
fun test_expired_intent_cannot_be_failed_twice() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(
        &mut hub,
        BASE_EID,
        HASH,
        1_000,
    );
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_001);
    hub_oapp::mark_expired_intent_failed(&mut hub, copy intent_id, &test_clock);
    hub_oapp::mark_expired_intent_failed(&mut hub, intent_id, &test_clock);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INTENT_NOT_PRUNABLE)]
fun test_live_intent_cannot_be_pruned() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let mut test_clock = sui::clock::create_for_testing(ts::ctx(&mut scenario));
    sui::clock::set_for_testing(&mut test_clock, 1_999);
    hub_oapp::prune_expired_intent(&mut hub, intent_id, &test_clock);
    sui::clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
fun test_late_authenticated_executed_outcome_overrides_timeout_and_unblocks_next_nonce() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let first_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 1_000);
    let second_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, OTHER_HASH, 3_000);
    let mut test_clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1_001);
    hub_oapp::mark_expired_intent_failed(&mut hub, copy first_id, &test_clock);
    let (timed_out, timeout_outcome) = hub_oapp::outcome_for_testing(&hub, copy first_id);
    assert!(timed_out, 0);
    assert!(timeout_outcome == 2, 1);

    // The exact pinned peer/EID/hash result is authoritative even after the
    // local timeout. Recording EXECUTED prevents a duplicate reissue, and
    // consuming nonce 1 lets the next authenticated result advance.
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(copy first_id, HASH, 1),
        1_001,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        2,
        OTHER_GUID,
        hub_oapp::encode_execution_outcome(copy second_id, OTHER_HASH, 1),
        1_500,
    );
    let (first_recorded, first_outcome) = hub_oapp::outcome_for_testing(&hub, first_id);
    let (second_recorded, second_outcome) = hub_oapp::outcome_for_testing(&hub, second_id);
    assert!(first_recorded && first_outcome == 1, 2);
    assert!(second_recorded && second_outcome == 1, 3);
    clock::destroy_for_testing(test_clock);
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_REPLAY)]
fun test_late_authenticated_outcome_guid_replay_still_fails_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let first_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 1_000);
    let second_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, OTHER_HASH, 3_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        hub_oapp::encode_execution_outcome(first_id, HASH, 1),
        1_001,
    );
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        2,
        GUID,
        hub_oapp::encode_execution_outcome(second_id, OTHER_HASH, 1),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_OUTCOME)]
fun test_unknown_outcome_code_fails_closed() {
    let raw = RawOutcomeWire {
        domain: b"DAY_OUTCOME",
        version: 1,
        action: 1,
        intent_id: HASH,
        command_hash: HASH,
        outcome: 255,
    };
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let _ = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        bcs::to_bytes(&raw),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_MESSAGE)]
fun test_outcome_wrong_domain_fails_closed() {
    let raw = RawOutcomeWire {
        domain: b"NOT_DAY",
        version: 1,
        action: 1,
        intent_id: HASH,
        command_hash: HASH,
        outcome: 1,
    };
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let _ = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        bcs::to_bytes(&raw),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_MESSAGE)]
fun test_outcome_wrong_version_fails_closed() {
    let raw = RawOutcomeWire {
        domain: b"DAY_OUTCOME",
        version: 2,
        action: 1,
        intent_id: HASH,
        command_hash: HASH,
        outcome: 1,
    };
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let _ = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        bcs::to_bytes(&raw),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_UNKNOWN_ACTION)]
fun test_outcome_unknown_action_fails_closed() {
    let raw = RawOutcomeWire {
        domain: b"DAY_OUTCOME",
        version: 1,
        action: 255,
        intent_id: HASH,
        command_hash: HASH,
        outcome: 1,
    };
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let _ = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        bcs::to_bytes(&raw),
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_MESSAGE)]
fun test_outcome_trailing_bytes_fail_closed() {
    let (mut scenario, _) = setup();
    ts::next_tx(&mut scenario, ALICE);
    let mut hub = ts::take_shared<HubOApp>(&scenario);
    let intent_id = hub_oapp::record_intent_for_testing(&mut hub, BASE_EID, HASH, 2_000);
    let mut message = hub_oapp::encode_execution_outcome(intent_id, HASH, 1);
    message.push_back(255);
    hub_oapp::apply_authenticated_outcome_for_testing(
        &mut hub,
        BASE_EID,
        1,
        GUID,
        message,
        1_500,
    );
    ts::return_shared(hub);
    cleanup(scenario);
}

#[test]
#[expected_failure(abort_code = day_hub_oapp::hub_oapp::E_INVALID_MESSAGE)]
fun test_outcome_rejects_non_hash_intent_id() {
    let _ = hub_oapp::encode_execution_outcome(x"abcd", HASH, 1);
}
