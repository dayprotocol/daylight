// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-849 consented Exit Mode plumbing (package-only force-exit crank).
///
/// One primitive covers force_sell and force_withdraw-everyone: the leader
/// chooses WHEN (enter Exit Mode), never WHERE. Payout destination is always
/// read from the Position record at settlement — never from the caller, never
/// from the receipt, never from a message field.
///
/// This module composes:
///   1. canonical entered-policy proof (`authorize_entered_exit_mode`)
///   2. a fixed-delay payout pot (package deadline only)
///   3. a no-abilities position ticket + source-typed adapter receipt
///   4. atomic share-burn + pot fund to the recorded owner
///
/// All entry points are `public(package)`. A reviewed production adapter must
/// wrap these constructors; until then the path remains fail-closed and no
/// public goNoGo surface changes. There is deliberately no public money path
/// and no on-chain broadcast enablement in this module.
module day::managed_force_exit {
    use day::guardrails_v2::GuardrailsV2;
    use day::leader_policy::{Self, ExitModeLatch, LeaderPolicy};
    use day::managed_closeout::{Self, FrozenExitPot};
    use day::managed_position::{
        Self, ConsentedForceExitTicket, ForceExitAdapterReceipt,
        OpportunityAccounting, Position,
    };
    use day::strategy_registry::StrategyRegistry;
    use sui::clock::{Self, Clock};
    use sui::coin::Coin;

    /// Policy-only preparation. There is deliberately no sender, payout,
    /// shares, amount, profit, or deadline argument.
    public(package) fun prepare_consented_force_exit<T>(
        registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        policy: &LeaderPolicy,
        latch: &ExitModeLatch,
        accounting: &OpportunityAccounting,
        position: &Position,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (ConsentedForceExitTicket<T>, FrozenExitPot<T>) {
        let authorization = leader_policy::authorize_entered_exit_mode(
            registry,
            guardrails,
            policy,
            latch,
        );
        let pot = managed_closeout::prepare_consented_force_exit_pot<T>(
            accounting,
            clock,
            ctx,
        );
        let (pot_id, settle_after_ms) = managed_closeout::force_exit_pot_binding(&pot);
        let ticket = managed_position::authorize_consented_force_exit<T>(
            accounting,
            position,
            authorization,
            pot_id,
            settle_after_ms,
            clock::timestamp_ms(clock),
        );
        (ticket, pot)
    }

    /// Future reviewed adapter boundary. The adapter supplies only its package
    /// witness and measured Coin/none; all authorization and accounting facts
    /// are inherited from the no-abilities ticket.
    public(package) fun attest_adapter_return<AdapterWitness: drop, T>(
        accounting: &OpportunityAccounting,
        position: &Position,
        ticket: ConsentedForceExitTicket<T>,
        adapter_witness: &AdapterWitness,
        proceeds: Option<Coin<T>>,
    ): ForceExitAdapterReceipt<AdapterWitness, T> {
        managed_position::attest_force_exit_adapter_return(
            accounting,
            position,
            ticket,
            adapter_witness,
            proceeds,
        )
    }

    /// Atomic reservation + funding. The receipt is the sole sender-bypass;
    /// owner-local exit remains independently sender-authenticated. Payout is
    /// locked to the recorded Position destination inside consume/fund.
    public(package) fun fund_consented_force_exit<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        pot: FrozenExitPot<T>,
        position: &mut Position,
        receipt: ForceExitAdapterReceipt<AdapterWitness, T>,
        ctx: &mut TxContext,
    ): (ID, ID) {
        managed_closeout::reserve_and_fund_consented_force_exit_pot(
            accounting,
            pot,
            position,
            receipt,
            ctx,
        )
    }
}
