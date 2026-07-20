// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-849 lower-layer immutable leader policy facts.
///
/// This module deliberately sits below the public `leader_authority` leaf.
/// The linear witness is issued only after leader identity, canonical
/// policy/latch anchoring, frozen Guardrails, and the complete atomic route
/// proof are verified; the hub consumes it with accounting provenance before
/// a transport command can exist.
module day::leader_policy {
    use day::guardrails_v2::{Self, GuardrailsV2};
    use day::strategy_registry::{Self, StrategyRegistry};

    const POLICY_VERSION: u8 = 1;
    const HASH_LEN: u64 = 32;

    const E_UNSUPPORTED_POLICY: u64 = 1;
    const E_WRONG_REGISTRY: u64 = 2;
    const E_WRONG_POLICY: u64 = 3;
    const E_WRONG_GUARDRAILS: u64 = 4;
    const E_NOT_LEADER: u64 = 5;
    const E_FORCE_EXIT_NOT_CONSENTED: u64 = 6;
    const E_EXIT_MODE_ACTIVE: u64 = 7;
    /// Latch has not been entered — consented force-exit crank fail-closes.
    const E_EXIT_MODE_NOT_ACTIVE: u64 = 8;

    /// Frozen disclosure for one registered Strategy. Leader and Guardrails
    /// facts remain derived from the immutable registry record.
    public struct LeaderPolicy has key, store {
        id: UID,
        version: u8,
        registry_id: ID,
        strategy_id: vector<u8>,
        leader_may_force_exit: bool,
    }

    /// Shared one-way signal only. It contains no position, principal, payout
    /// destination, asset, amount, or transport configuration.
    public struct ExitModeLatch has key {
        id: UID,
        policy_id: ID,
        entered: bool,
        entered_at_ms: u64,
    }

    /// Linear proof of exact canonical entered Exit Mode. No copy/drop/store/key.
    /// Contains no caller, payout destination, amount, profit, or deadline fact.
    /// The leader was authenticated when the latch was entered; this recovery
    /// proof remains crankable while paused/retired and without a live leader key.
    public struct EnteredExitModeAuthorization {
        registry_id: ID,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        policy_id: ID,
        latch_id: ID,
        entered_at_ms: u64,
    }

    /// No copy/drop/store/key: a final reallocation command must consume the
    /// policy proof that was issued for this exact canonical policy/latch.
    public struct ReallocationPolicyWitness {
        policy_id: ID,
        latch_id: ID,
        registry_id: ID,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        verified_leader: address,
        source_accounting_id: ID,
        source_opportunity_id: vector<u8>,
        destination_accounting_id: ID,
        destination_opportunity_id: vector<u8>,
        allocation_bps: u64,
    }

    public(package) fun new_policy(
        registry_id: ID,
        strategy_id: vector<u8>,
        leader_may_force_exit: bool,
        ctx: &mut TxContext,
    ): LeaderPolicy {
        LeaderPolicy {
            id: object::new(ctx),
            version: POLICY_VERSION,
            registry_id,
            strategy_id,
            leader_may_force_exit,
        }
    }

    public(package) fun new_latch(policy_id: ID, ctx: &mut TxContext): ExitModeLatch {
        ExitModeLatch {
            id: object::new(ctx),
            policy_id,
            entered: false,
            entered_at_ms: 0,
        }
    }

    public(package) fun freeze_policy(policy: LeaderPolicy) {
        transfer::freeze_object(policy);
    }

    public(package) fun share_latch(latch: ExitModeLatch) {
        transfer::share_object(latch);
    }

    /// Verify the immutable policy against the canonical registry and frozen
    /// Guardrails. This is package-only so callers cannot treat a successful
    /// shape check as an authorization result.
    public(package) fun assert_policy_binding(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
    ) {
        assert!(policy.version == POLICY_VERSION, E_UNSUPPORTED_POLICY);
        assert!(policy.registry_id == strategy_registry::id(registry), E_WRONG_REGISTRY);
        let record = strategy_registry::record(registry, copy policy.strategy_id);
        assert!(strategy_registry::strategy_id(record) == policy.strategy_id, E_WRONG_POLICY);
        let guardrails_hash = strategy_registry::guardrails_hash(record);
        assert!(vector::length(&guardrails_hash) == HASH_LEN, E_WRONG_GUARDRAILS);
        assert!(strategy_registry::guardrails_id(record) == guardrails_v2::id(guardrails), E_WRONG_GUARDRAILS);
        assert!(guardrails_hash == guardrails_v2::guardrails_hash(guardrails), E_WRONG_GUARDRAILS);
        assert!(guardrails_v2::verify_hash(guardrails), E_WRONG_GUARDRAILS);
        assert!(strategy_registry::leader(record) == guardrails_v2::strategy_lead(guardrails), E_NOT_LEADER);
    }

    /// Enter the one-way latch after canonical policy binding. The public leaf
    /// emits the event; this lower module owns the private state transition.
    public(package) fun enter_latch(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &mut ExitModeLatch,
        entered_at_ms: u64,
        ctx: &TxContext,
    ) {
        assert_policy_binding(registry, guardrails, policy);
        assert!(latch.policy_id == object::id(policy), E_WRONG_POLICY);
        strategy_registry::assert_canonical_leader_policy_and_latch(
            registry,
            copy policy.strategy_id,
            object::id(policy),
            object::id(latch),
        );
        assert!(policy.leader_may_force_exit, E_FORCE_EXIT_NOT_CONSENTED);
        assert!(!latch.entered, E_EXIT_MODE_ACTIVE);
        let record = strategy_registry::record(registry, copy policy.strategy_id);
        assert!(strategy_registry::leader(record) == tx_context::sender(ctx), E_NOT_LEADER);
        latch.entered = true;
        latch.entered_at_ms = entered_at_ms;
    }

    /// Policy-only recovery proof for the consented force-exit crank. No sender
    /// or strategy lifecycle assertion is permitted here: the leader was
    /// authenticated when the one-way latch was entered, and recovery must remain
    /// permissionlessly crankable afterwards (pause/retire cannot strand exits).
    public(package) fun authorize_entered_exit_mode(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &ExitModeLatch,
    ): EnteredExitModeAuthorization {
        assert_policy_binding(registry, guardrails, policy);
        assert!(policy.leader_may_force_exit, E_FORCE_EXIT_NOT_CONSENTED);
        assert!(latch.policy_id == object::id(policy), E_WRONG_POLICY);
        strategy_registry::assert_canonical_leader_policy_and_latch(
            registry,
            copy policy.strategy_id,
            object::id(policy),
            object::id(latch),
        );
        assert!(latch.entered, E_EXIT_MODE_NOT_ACTIVE);
        EnteredExitModeAuthorization {
            registry_id: policy.registry_id,
            strategy_id: copy policy.strategy_id,
            guardrails_id: guardrails_v2::id(guardrails),
            guardrails_hash: guardrails_v2::guardrails_hash(guardrails),
            policy_id: object::id(policy),
            latch_id: object::id(latch),
            entered_at_ms: latch.entered_at_ms,
        }
    }

    /// Sole consumer of entered Exit Mode proof. Callers cannot project policy
    /// or destination facts out of the authorization.
    public(package) fun consume_entered_exit_mode_authorization(
        authorization: EnteredExitModeAuthorization,
    ): (ID, vector<u8>, ID, vector<u8>, ID, ID, u64) {
        let EnteredExitModeAuthorization {
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id,
            entered_at_ms,
        } = authorization;
        (
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            policy_id,
            latch_id,
            entered_at_ms,
        )
    }

    /// Issue the linear policy proof for one active reallocation. The route is
    /// atomically canonicalized here; no caller hash or endpoint asset crosses
    /// into the hub. Exit Mode is deliberately non-transportable: a latched
    /// policy cannot order a new reallocation.
    public(package) fun issue_reallocation_witness(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &ExitModeLatch,
        allocation_bps: u64,
        source_accounting_id: ID,
        source_opportunity_id: vector<u8>,
        destination_accounting_id: ID,
        destination_opportunity_id: vector<u8>,
        ctx: &TxContext,
    ): ReallocationPolicyWitness {
        assert_policy_binding(registry, guardrails, policy);
        assert!(latch.policy_id == object::id(policy), E_WRONG_POLICY);
        strategy_registry::assert_canonical_leader_policy_and_latch(
            registry,
            copy policy.strategy_id,
            object::id(policy),
            object::id(latch),
        );
        assert!(!latch.entered, E_EXIT_MODE_ACTIVE);
        // Reallocation has a stricter lifecycle requirement than owner exit:
        // a paused or retired strategy may not reserve accounting or issue a
        // transport command. Check it before route validation/witness minting.
        strategy_registry::assert_accepts_reallocation(registry, copy policy.strategy_id);
        let verified_leader = tx_context::sender(ctx);
        let record = strategy_registry::record(registry, copy policy.strategy_id);
        assert!(strategy_registry::leader(record) == verified_leader, E_NOT_LEADER);
        ReallocationPolicyWitness {
            policy_id: object::id(policy),
            latch_id: object::id(latch),
            registry_id: policy.registry_id,
            strategy_id: copy policy.strategy_id,
            guardrails_id: guardrails_v2::id(guardrails),
            guardrails_hash: guardrails_v2::guardrails_hash(guardrails),
            verified_leader,
            source_accounting_id,
            source_opportunity_id,
            destination_accounting_id,
            destination_opportunity_id,
            allocation_bps,
        }
    }

    /// Sole consumer; no caller may project policy, endpoints, or native asset
    /// facts out of a witness.
    public(package) fun consume_reallocation_witness(
        witness: ReallocationPolicyWitness,
    ): (
        ID, ID, ID, vector<u8>, ID, vector<u8>, address,
        ID, vector<u8>, ID, vector<u8>, u64,
    ) {
        let ReallocationPolicyWitness {
            policy_id,
            latch_id,
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            verified_leader,
            source_accounting_id,
            source_opportunity_id,
            destination_accounting_id,
            destination_opportunity_id,
            allocation_bps,
        } = witness;
        (
            policy_id,
            latch_id,
            registry_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            verified_leader,
            source_accounting_id,
            source_opportunity_id,
            destination_accounting_id,
            destination_opportunity_id,
            allocation_bps,
        )
    }

    public fun policy_id(policy: &LeaderPolicy): ID { object::id(policy) }
    public fun policy_registry_id(policy: &LeaderPolicy): ID { policy.registry_id }
    public fun policy_strategy_id(policy: &LeaderPolicy): vector<u8> { policy.strategy_id }
    public fun leader_may_force_exit(policy: &LeaderPolicy): bool { policy.leader_may_force_exit }
    public fun latch_policy_id(latch: &ExitModeLatch): ID { latch.policy_id }
    public fun exit_mode_entered(latch: &ExitModeLatch): bool { latch.entered }
    public fun exit_mode_entered_at_ms(latch: &ExitModeLatch): u64 { latch.entered_at_ms }
}
