// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-849 immutable leader policy and one-way Exit Mode authority.
///
/// Leadership has no recipient, token, amount, custody, or payout field. The
/// immutable StrategyRegistry proves who the leader is. A LeaderPolicy records
/// only the disclosed force-exit consent term; positions must pin this exact
/// policy object at deposit time. Exit Mode is a one-way latch. Settlement is a
/// separate permissionless pull that reads each position's recorded owner and
/// origin.
module day::leader_authority {
    use day::day::ProtocolConfig;
    use day::guardrails_v2::GuardrailsV2;
    use day::hub_protocol::{Self, AuthorizedHubCommand, HubState};
    use day::leader_activity_log;
    use day::leader_policy::{Self, ExitModeLatch, LeaderPolicy};
    use day::managed_position::{Self, OpportunityAccounting};
    use day::managed_reallocation;
    use day::managed_route::ReallocationRouteLeg;
    use day::strategy_registry::{Self, AdminCap, StrategyRegistry};
    use sui::clock::{Self, Clock};
    use sui::event;

    const E_WRONG_ADMIN_CAP: u64 = 1;
    const E_POLICY_ALREADY_EXISTS: u64 = 2;
    const E_WRONG_STRATEGY: u64 = 3;

    public struct LeaderPolicyCreated has copy, drop {
        policy_id: ID,
        latch_id: ID,
        registry_id: ID,
        strategy_id: vector<u8>,
        leader_may_force_exit: bool,
        created_at_ms: u64,
    }

    public struct ExitModeEntered has copy, drop {
        policy_id: ID,
        strategy_id: vector<u8>,
        verified_leader: address,
        entered_at_ms: u64,
    }

    /// Create the immutable disclosure and its one-way latch. The existing
    /// Registry AdminCap is the sole creation authority; this module mints no
    /// LeaderCap or additional admin capability.
    public fun create_policy_and_latch(
        registry: &mut StrategyRegistry,
        admin_cap: &AdminCap,
        strategy_id: vector<u8>,
        leader_may_force_exit: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (ID, ID) {
        assert!(object::id(admin_cap) == strategy_registry::admin_cap_id(registry), E_WRONG_ADMIN_CAP);
        assert!(
            !strategy_registry::leader_policy_anchored(registry, copy strategy_id),
            E_POLICY_ALREADY_EXISTS,
        );
        let record = strategy_registry::record(registry, copy strategy_id);
        assert!(strategy_registry::strategy_id(record) == strategy_id, E_WRONG_STRATEGY);

        let policy = leader_policy::new_policy(
            strategy_registry::id(registry),
            copy strategy_id,
            leader_may_force_exit,
            ctx,
        );
        let policy_id = object::id(&policy);
        let latch = leader_policy::new_latch(policy_id, ctx);
        let latch_id = object::id(&latch);
        let created_at_ms = clock::timestamp_ms(clock);

        strategy_registry::anchor_leader_policy(
            registry,
            admin_cap,
            copy strategy_id,
            policy_id,
            latch_id,
            ctx,
        );

        event::emit(LeaderPolicyCreated {
            policy_id,
            latch_id,
            registry_id: strategy_registry::id(registry),
            strategy_id,
            leader_may_force_exit,
            created_at_ms,
        });
        leader_policy::freeze_policy(policy);
        leader_policy::share_latch(latch);
        (policy_id, latch_id)
    }

    /// The leader chooses when to enter Exit Mode, never where funds go. This
    /// transition is valid while a Strategy is paused or retired as well as
    /// active; independent owner exit never consults this latch.
    public fun enter_exit_mode(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &mut ExitModeLatch,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let entered_at_ms = clock::timestamp_ms(clock);
        leader_policy::enter_latch(
            registry,
            guardrails,
            policy,
            latch,
            entered_at_ms,
            ctx,
        );
        event::emit(ExitModeEntered {
            policy_id: object::id(policy),
            strategy_id: leader_policy::policy_strategy_id(policy),
            verified_leader: tx_context::sender(ctx),
            entered_at_ms,
        });
    }

    /// Authorize one complete managed reallocation through the sole public
    /// orchestration path. Every command fact is derived from immutable policy,
    /// frozen Guardrails, the complete route, and live accounting; callers
    /// cannot provide a strategy, leader, endpoint, asset, route hash, state,
    /// intent, or payload assertion.
    ///
    /// The sequence reservation, accounting reservation, authenticated ORDERED
    /// event, and returned no-abilities command are all in this transaction.
    /// A failed later step rolls back the source accounting mutation and never
    /// leaves a burned sequence or fabricated audit event.
    public fun authorize_reallocation<T>(
        config: &ProtocolConfig,
        hub: &mut HubState,
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &ExitModeLatch,
        source: &mut OpportunityAccounting,
        destination: &OpportunityAccounting,
        route: &vector<ReallocationRouteLeg>,
        allocation_bps: u64,
        expires_at_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): AuthorizedHubCommand {
        // Reject noncanonical object graphs before deriving a witness or
        // reserving live source accounting. The hub repeats this internally;
        // this early guard ensures failed authorization cannot transiently
        // mutate accounting, sequence, or audit state in the public leaf.
        hub_protocol::assert_canonical_hub_and_registry(config, hub, registry);
        let source_accounting_id = managed_position::accounting_id(source);
        let source_opportunity_id = managed_position::accounting_opportunity_id(source);
        let destination_accounting_id = managed_position::accounting_id(destination);
        let destination_opportunity_id = managed_position::accounting_opportunity_id(destination);
        let (canonical_route, _source_asset, _destination_asset) =
            managed_position::validated_reallocation_route_for_accountings(
                source,
                destination,
                route,
                guardrails,
                allocation_bps,
            );

        let policy_witness = leader_policy::issue_reallocation_witness(
            registry,
            guardrails,
            policy,
            latch,
            allocation_bps,
            source_accounting_id,
            source_opportunity_id,
            destination_accounting_id,
            destination_opportunity_id,
            ctx,
        );
        let reservation = managed_reallocation::start_reallocation<T>(
            source,
            destination,
            canonical_route,
            allocation_bps,
            ctx,
        );
        let command = hub_protocol::authorize_validated_reallocation<T>(
            config,
            hub,
            registry,
            guardrails,
            policy_witness,
            reservation,
            expires_at_ms,
            clock,
            ctx,
        );
        leader_activity_log::record_ordered(&command, guardrails, clock, ctx);
        command
    }

    /// Stable public read surface; ownership of the underlying types resides
    /// in `leader_policy` so accounting can bind them without a module cycle.
    public fun policy_id(policy: &LeaderPolicy): ID { leader_policy::policy_id(policy) }
    public fun policy_registry_id(policy: &LeaderPolicy): ID { leader_policy::policy_registry_id(policy) }
    public fun policy_strategy_id(policy: &LeaderPolicy): vector<u8> { leader_policy::policy_strategy_id(policy) }
    public fun leader_may_force_exit(policy: &LeaderPolicy): bool { leader_policy::leader_may_force_exit(policy) }
    public fun latch_policy_id(latch: &ExitModeLatch): ID { leader_policy::latch_policy_id(latch) }
    public fun exit_mode_entered(latch: &ExitModeLatch): bool { leader_policy::exit_mode_entered(latch) }
    public fun exit_mode_entered_at_ms(latch: &ExitModeLatch): u64 { leader_policy::exit_mode_entered_at_ms(latch) }

    #[test_only]
    public fun assert_last_policy_created_event_for_testing(
        expected_policy_id: ID,
        expected_latch_id: ID,
        expected_registry_id: ID,
        expected_strategy_id: vector<u8>,
        expected_consent: bool,
        expected_time_ms: u64,
    ) {
        let events = event::events_by_type<LeaderPolicyCreated>();
        let last = &events[vector::length(&events) - 1];
        assert!(last.policy_id == expected_policy_id, 100);
        assert!(last.latch_id == expected_latch_id, 101);
        assert!(last.registry_id == expected_registry_id, 102);
        assert!(last.strategy_id == expected_strategy_id, 103);
        assert!(last.leader_may_force_exit == expected_consent, 104);
        assert!(last.created_at_ms == expected_time_ms, 105);
    }

    #[test_only]
    public fun assert_last_exit_mode_event_for_testing(
        expected_policy_id: ID,
        expected_strategy_id: vector<u8>,
        expected_leader: address,
        expected_time_ms: u64,
    ) {
        let events = event::events_by_type<ExitModeEntered>();
        let last = &events[vector::length(&events) - 1];
        assert!(last.policy_id == expected_policy_id, 110);
        assert!(last.strategy_id == expected_strategy_id, 111);
        assert!(last.verified_leader == expected_leader, 112);
        assert!(last.entered_at_ms == expected_time_ms, 113);
    }
}
