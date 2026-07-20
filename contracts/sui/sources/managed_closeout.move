// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-859/860 managed leg fee reconciliation and reallocation receipts.
///
/// Production mutations consume nonce-bound, source-typed adapter receipts from
/// `managed_position`; raw Coins and caller-asserted profit/loss are never enough.
module day::managed_closeout {
    use day::managed_position::{
        Self, AdapterCloseoutReturnReceipt, AdapterReturnReceipt, ForceExitAdapterReceipt,
        OpportunityAccounting,
    };
    use day::managed_reallocation::{Self, ReallocationReturnProceeds};
    use std::type_name;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::dynamic_object_field;
    use sui::event;

    const BASIS_POINTS: u64 = 10_000;
    const HASH_LEN: u64 = 32;
    const ROUTE_COMMITMENT_LEN: u64 = 32;
    const PPS_SCALE: u128 = 1_000_000;
    const VIRTUAL_SHARES: u128 = 1_000;
    const VIRTUAL_ASSETS: u128 = 1_000;
    const MAX_COIN_VALUE: u128 = 18_446_744_073_709_551_615;
    const MAX_U64: u64 = 18_446_744_073_709_551_615;
    /// Immutable delay before a funded frozen-exit claim becomes
    /// permissionlessly crankable. The published package-only constructor
    /// retains its deadline argument for compatibility, but accepts only this
    /// package-derived value so a sibling module cannot freeze owner funds for
    /// an arbitrary interval.
    const FROZEN_EXIT_SETTLEMENT_DELAY_MS: u64 = 300_000;

    const E_INVALID_POLICY: u64 = 1;
    const E_INVALID_COMMITMENT: u64 = 2;
    const E_INVALID_DEADLINE: u64 = 3;
    const E_RECEIPT_CLOSED: u64 = 4;
    const E_RECEIPT_OVER_SETTLED: u64 = 5;
    const E_WRONG_RECEIPT_LEG: u64 = 6;
    const E_SELF_SETTLE_NOT_READY: u64 = 7;
    const E_WRONG_ASSET: u64 = 8;
    const E_ZERO_AMOUNT: u64 = 9;
    const E_AMOUNT_TOO_LARGE: u64 = 10;
    const E_ASSET_UNDERFLOW: u64 = 11;
    const E_WRONG_EXIT_POT: u64 = 12;
    const E_EXIT_POT_ALREADY_FUNDED: u64 = 13;
    const E_EXIT_CLAIM_NOT_FOUND: u64 = 14;
    const E_UNFUNDED_CLAIM: u64 = 15;
    const E_CONSENT_UNDERFUNDED: u64 = 16;
    const E_CONSENT_REQUIRED: u64 = 17;
    /// Positive force-exit adapter gain is fail-closed until the authenticated
    /// fee waterfall is composed into this path (cannot exit free on gain).
    const E_FORCE_EXIT_GAIN_REQUIRES_RECONCILIATION: u64 = 18;
    /// Fixed settlement delay for consented force-exit pots (package-only).
    const FORCE_EXIT_SETTLEMENT_DELAY_MS: u64 = 300_000;

    public struct FeeAssessment has copy, drop {
        gross_assets_micros: u128,
        profit_above_high_water_micros: u128,
        lead_fee_pool_micros: u128,
        /// Net amount paid to Lead after DAY's share of the Lead fee pool.
        lead_fee_micros: u128,
        day_fee_micros: u128,
        net_assets_micros: u128,
        previous_high_water_pps: u128,
        new_high_water_pps: u128,
    }

    /// Unforgeable linear proof produced only by reviewed package adapter code
    /// from the Coin<T> actually withdrawn in this PTB.
    #[test_only]
    public struct MeasuredSettlement<phantom T> {
        receipt_id: ID,
        route_commitment: vector<u8>,
        proceeds: Coin<T>,
    }

    /// A package adapter may issue this only after the route has conclusively
    /// returned. `none` represents an authenticated zero return; any loss is
    /// derived from the receipt residual, never supplied by a caller.
    #[test_only]
    public struct FinalMeasuredSettlement<phantom T> {
        receipt_id: ID,
        route_commitment: vector<u8>,
        proceeds: Option<Coin<T>>,
    }

    /// Test-only executable model for the still-quarantined reallocation
    /// design. One shareholder ledger owns both opportunity lots; in-transit
    /// basis remains in total assets until an authenticated final close.
    #[test_only]
    public struct ReallocationLedger has drop {
        ledger_id: ID,
        accounting_asset: type_name::TypeName,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        source_opportunity_id: vector<u8>,
        destination_opportunity_id: vector<u8>,
        source_deployed_micros: u128,
        destination_deployed_micros: u128,
        in_transit_micros: u128,
        total_assets_micros: u128,
        total_shares: u128,
        high_water_pps: u128,
        adapter_destination: address,
    }

    /// Shared reserved pot. It persists across transactions, freezes
    /// exactly one measured exit PPS when funded, and retains owner-bound
    /// claims until any caller cranks them after the self-settle deadline.
    public struct FrozenExitPot<phantom T> has key, store {
        id: UID,
        ledger_id: ID,
        accounting_asset: type_name::TypeName,
        exit_pps: u128,
        total_reserved_shares: u128,
        remaining_reserved_shares: u128,
        total_reserved_assets_micros: u128,
        remaining_reserved_assets_micros: u128,
        measured_total_micros: u128,
        /// Claims are dynamic object fields keyed by claim id. This counter is
        /// bounded metadata; no transaction scans or removes from a vector.
        active_claims: u64,
        self_settle_deadline_ms: u64,
        funded: bool,
        proceeds: Balance<T>,
    }

    /// Wrapped, non-droppable claim state. The payout destination is copied
    /// from the recorded position owner, never from the crank caller.
    public struct FrozenExitClaim has key, store {
        id: UID,
        ledger_id: ID,
        accounting_asset: type_name::TypeName,
        payout_destination: address,
        position_id: ID,
        shares: u128,
        /// Half-open interval in the reservation-order share space. The exact
        /// payout is floor(end * measured / total) - floor(start * measured /
        /// total), so every micro is assigned exactly once and crank order is
        /// irrelevant.
        share_start: u128,
        share_end: u128,
        reserved_assets_micros: u128,
    }

    /// Metadata-only shared receipt. Frozen source assets are in transit, never
    /// held by this object. `remaining_assets_micros` is monotonic to zero.
    #[test_only]
    public struct ExitReceipt has key {
        id: UID,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        /// Reallocation is deliberately constrained to one shareholder ledger.
        /// A second accounting object would transfer value without transferring
        /// its Positions/shares.
        accounting_id: ID,
        accounting_asset: type_name::TypeName,
        source_opportunity_id: vector<u8>,
        destination_opportunity_id: vector<u8>,
        route_commitment: vector<u8>,
        frozen_price_pps: u128,
        frozen_assets_micros: u128,
        remaining_assets_micros: u128,
        realized_loss_micros: u128,
        self_settle_deadline_ms: u64,
        closed: bool,
    }

    public struct AdapterReconciled has copy, drop {
        leg_accounting_id: ID,
        measured_gross_assets_micros: u128,
        previous_deployed_assets_micros: u128,
        derived_profit_above_high_water_micros: u128,
        lead_fee_pool_micros: u128,
        lead_fee_micros: u128,
        day_fee_micros: u128,
        net_assets_micros: u128,
        high_water_pps: u128,
    }

    /// Full adapter reconciliation from a nonce/source-bound linear receipt.
    /// The Lead fee pool is `profit * lead_fee_bps`; DAY receives its configured
    /// share of that pool and Lead receives the remainder. `none` is an
    /// authenticated total loss. A conclusive return never blocks an owner exit:
    /// if ledger-wide profit implies a fee larger than this final returned Coin,
    /// only the Coin-supported fee is collected and the remainder is forgiven.
    public(package) fun reconcile_full_adapter_return<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
        ctx: &mut TxContext,
    ): (Option<Coin<T>>, FeeAssessment) {
        let accounting_id = managed_position::accounting_id(accounting);
        let proceeds = managed_position::consume_adapter_full_return(
            accounting,
            accounting_id,
            receipt,
        );
        reconcile_measured_return(accounting, proceeds, ctx)
    }

    /// Crystallize all accrued managed profit from the conclusive authenticated
    /// destination return, then settle one owner's pro-rata net claim to the
    /// destination recorded in Position. Partial chunks cannot construct
    /// ReallocationReturnProceeds and therefore cannot enter this fee path. A
    /// raw Coin, caller profit, caller amount, or payout address is insufficient.
    public(package) fun crystallize_and_settle_reallocation_exit<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut managed_position::Position,
        shares: u128,
        authenticated: ReallocationReturnProceeds<T>,
        ctx: &mut TxContext,
    ): FeeAssessment {
        let (mut proceeds, assessment) = crystallize_authenticated_reallocation_return(
            accounting,
            authenticated,
            ctx,
        );
        let exit_assets = if (shares == managed_position::total_shares(accounting)) {
            managed_position::total_assets_micros(accounting)
        } else {
            managed_position::convert_to_assets(
                shares,
                managed_position::total_assets_micros(accounting),
                managed_position::total_shares(accounting),
            )
        };
        assert!(exit_assets <= (coin::value(&proceeds) as u128), E_ASSET_UNDERFLOW);
        assert!(exit_assets <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);
        let owner_proceeds = coin::split(&mut proceeds, exit_assets as u64, ctx);
        managed_position::settle_owner_exit(
            accounting, position, shares, owner_proceeds, ctx,
        );
        // Any authenticated return not used by this owner remains bound to the
        // accounting's adapter destination and its matching liquid ledger.
        transfer::public_transfer(
            proceeds,
            managed_position::adapter_destination_for_package(accounting),
        );
        assessment
    }

    /// Crystallize the conclusive authenticated return before a managed
    /// subscription can enter the leg. Partial chunks are not fee-bearing. The
    /// remaining principal is returned only to the pinned adapter destination;
    /// neither profit nor a destination is caller input.
    public(package) fun crystallize_reallocation_fees<T>(
        accounting: &mut OpportunityAccounting,
        authenticated: ReallocationReturnProceeds<T>,
        ctx: &mut TxContext,
    ): FeeAssessment {
        let (proceeds, assessment) = crystallize_authenticated_reallocation_return(
            accounting,
            authenticated,
            ctx,
        );
        transfer::public_transfer(
            proceeds,
            managed_position::adapter_destination_for_package(accounting),
        );
        assessment
    }

    fun crystallize_authenticated_reallocation_return<T>(
        accounting: &mut OpportunityAccounting,
        authenticated: ReallocationReturnProceeds<T>,
        ctx: &mut TxContext,
    ): (Coin<T>, FeeAssessment) {
        let (source_accounting_id, _state_id, proceeds) =
            managed_reallocation::consume_return_proceeds(authenticated);
        assert!(source_accounting_id == managed_position::accounting_id(accounting), E_WRONG_EXIT_POT);
        assert!(option::is_some(&proceeds), E_ZERO_AMOUNT);
        let mut proceeds = option::destroy_some(proceeds);
        let gross_proceeds = coin::value(&proceeds) as u128;
        let gross_total = managed_position::total_assets_micros(accounting);
        let feeable_profit = profit_above_fee_basis(
            gross_total,
            managed_position::fee_basis_assets_micros_for_package(accounting),
        );
        let (
            lead_fee_bps,
            day_share_bps,
            lead_destination,
            day_destination,
        ) = managed_position::fee_policy_for_package(accounting);
        let derived_lead_fee_pool = mul_bps_floor(feeable_profit, lead_fee_bps);
        // Same exit-safe rule as reconcile_measured_return: fee may only split
        // value carried by this authenticated return. Ledger-wide profit can
        // exceed a partial reallocation return; aborting freezes the path.
        // Cap collection and forgive the unsupported remainder.
        let lead_fee_pool = if (derived_lead_fee_pool > gross_proceeds) {
            gross_proceeds
        } else {
            derived_lead_fee_pool
        };
        let day_fee = mul_bps_floor(lead_fee_pool, day_share_bps);
        let lead_fee = lead_fee_pool - day_fee;
        assert!(lead_fee <= MAX_COIN_VALUE && day_fee <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);
        let previous_high_water = managed_position::high_water_pps(accounting);

        if (lead_fee > 0) {
            transfer::public_transfer(
                coin::split(&mut proceeds, lead_fee as u64, ctx),
                lead_destination,
            );
        };
        if (day_fee > 0) {
            transfer::public_transfer(
                coin::split(&mut proceeds, day_fee as u64, ctx),
                day_destination,
            );
        };
        managed_position::apply_fee_crystallization(accounting, lead_fee_pool);
        let assessment = FeeAssessment {
            gross_assets_micros: gross_proceeds,
            profit_above_high_water_micros: feeable_profit,
            lead_fee_pool_micros: lead_fee_pool,
            lead_fee_micros: lead_fee,
            day_fee_micros: day_fee,
            net_assets_micros: gross_proceeds - lead_fee_pool,
            previous_high_water_pps: previous_high_water,
            new_high_water_pps: managed_position::high_water_pps(accounting),
        };
        (proceeds, assessment)
    }

    fun reconcile_measured_return<T>(
        accounting: &mut OpportunityAccounting,
        mut proceeds: Option<Coin<T>>,
        ctx: &mut TxContext,
    ): (Option<Coin<T>>, FeeAssessment) {
        assert!(managed_position::accounting_asset(accounting)
            == type_name::with_original_ids<T>(), E_WRONG_ASSET);
        let previous_deployed = managed_position::deployed_assets_micros(accounting);
        assert!(previous_deployed > 0, E_ZERO_AMOUNT);
        let measured_gross = if (option::is_some(&proceeds)) {
            coin::value(option::borrow(&proceeds)) as u128
        } else {
            0
        };
        let previous_high_water = managed_position::high_water_pps(accounting);
        let gross_total = managed_position::liquid_assets_micros(accounting) + measured_gross;
        let feeable_profit = profit_above_fee_basis(
            gross_total,
            managed_position::fee_basis_assets_micros_for_package(accounting),
        );
        let (
            lead_fee_bps,
            day_share_bps,
            lead_destination,
            day_destination,
        ) = managed_position::fee_policy_for_package(accounting);
        let derived_lead_fee_pool = mul_bps_floor(feeable_profit, lead_fee_bps);
        // The fee waterfall may only split value carried by this authenticated
        // conclusive return. Ledger-wide profit can already sit in liquid value
        // returned by another spoke while this final adapter proves a zero or
        // smaller return. Aborting in that state permanently prevents the
        // deployed leg from closing. Taking more than this Coin carries is also
        // impossible without banking principal elsewhere. Cap the collected
        // fee and close the epoch; any unsupported remainder is deliberately
        // forgiven so fee collection can never become an R3 exit dependency.
        let lead_fee_pool = if (derived_lead_fee_pool > measured_gross) {
            measured_gross
        } else {
            derived_lead_fee_pool
        };
        let day_fee = mul_bps_floor(lead_fee_pool, day_share_bps);
        let lead_fee = lead_fee_pool - day_fee;
        let total_fees = lead_fee_pool;
        assert!(lead_fee <= MAX_COIN_VALUE && day_fee <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);

        if (lead_fee > 0) {
            transfer::public_transfer(
                coin::split(option::borrow_mut(&mut proceeds), lead_fee as u64, ctx),
                lead_destination,
            );
        };
        if (day_fee > 0) {
            transfer::public_transfer(
                coin::split(option::borrow_mut(&mut proceeds), day_fee as u64, ctx),
                day_destination,
            );
        };

        let net_return = measured_gross - total_fees;
        let net_total = managed_position::liquid_assets_micros(accounting) + net_return;
        let net_pps = price_per_share_ceil(
            net_total,
            managed_position::total_shares(accounting),
        );
        let new_high_water = if (net_pps > previous_high_water) {
            net_pps
        } else {
            previous_high_water
        };
        managed_position::apply_full_reconciliation(
            accounting, net_return, new_high_water,
        );

        let assessment = FeeAssessment {
            gross_assets_micros: measured_gross,
            profit_above_high_water_micros: feeable_profit,
            lead_fee_pool_micros: lead_fee_pool,
            lead_fee_micros: lead_fee,
            day_fee_micros: day_fee,
            net_assets_micros: net_return,
            previous_high_water_pps: previous_high_water,
            new_high_water_pps: new_high_water,
        };
        event::emit(AdapterReconciled {
            leg_accounting_id: managed_position::accounting_id(accounting),
            measured_gross_assets_micros: measured_gross,
            previous_deployed_assets_micros: previous_deployed,
            derived_profit_above_high_water_micros: feeable_profit,
            lead_fee_pool_micros: lead_fee_pool,
            lead_fee_micros: lead_fee,
            day_fee_micros: day_fee,
            net_assets_micros: net_return,
            high_water_pps: new_high_water,
        });
        (proceeds, assessment)
    }

    #[test_only]
    public fun reconcile_full_adapter_return_for_testing<AdapterWitness: drop, T>(
        accounting: &mut OpportunityAccounting,
        _full_exit_witness: AdapterWitness,
        proceeds: Coin<T>,
        ctx: &mut TxContext,
    ): (Coin<T>, FeeAssessment) {
        let (proceeds, assessment) = reconcile_measured_return(
            accounting,
            option::some(proceeds),
            ctx,
        );
        (option::destroy_some(proceeds), assessment)
    }

    /// DAY-849 authenticates leader + Guardrails before this package-only hook.
    #[test_only]
    public fun start_reallocation_for_testing(
        ledger: &mut ReallocationLedger,
        destination_opportunity_id: vector<u8>,
        route_commitment: vector<u8>,
        allocation_bps: u64,
        self_settle_deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let receipt = new_receipt(
            ledger,
            destination_opportunity_id,
            route_commitment,
            allocation_bps,
            self_settle_deadline_ms,
            clock::timestamp_ms(clock),
            ctx,
        );
        let id = object::id(&receipt);
        transfer::share_object(receipt);
        id
    }

    #[test_only]
    fun new_receipt(
        ledger: &mut ReallocationLedger,
        destination_opportunity_id: vector<u8>,
        route_commitment: vector<u8>,
        allocation_bps: u64,
        self_settle_deadline_ms: u64,
        now_ms: u64,
        ctx: &mut TxContext,
    ): ExitReceipt {
        assert!(!vector::is_empty(&ledger.strategy_id), E_INVALID_POLICY);
        assert!(vector::length(&ledger.guardrails_hash) == HASH_LEN, E_INVALID_POLICY);
        assert!(!vector::is_empty(&destination_opportunity_id), E_INVALID_POLICY);
        assert!(
            destination_opportunity_id != ledger.source_opportunity_id,
            E_WRONG_RECEIPT_LEG,
        );
        assert!(destination_opportunity_id == ledger.destination_opportunity_id, E_WRONG_RECEIPT_LEG);
        assert!(vector::length(&route_commitment) == ROUTE_COMMITMENT_LEN, E_INVALID_COMMITMENT);
        assert!(allocation_bps > 0 && allocation_bps <= BASIS_POINTS, E_INVALID_POLICY);
        assert!(self_settle_deadline_ms > now_ms, E_INVALID_DEADLINE);
        let frozen_price_pps = price_per_share_floor(
            ledger.total_assets_micros,
            ledger.total_shares,
        );
        let frozen_assets = mul_bps_floor(ledger.source_deployed_micros, allocation_bps);
        assert!(frozen_assets > 0, E_ZERO_AMOUNT);
        ledger.source_deployed_micros = ledger.source_deployed_micros - frozen_assets;
        ledger.in_transit_micros = ledger.in_transit_micros + frozen_assets;
        assert_ledger_invariant(ledger);
        ExitReceipt {
            id: object::new(ctx),
            strategy_id: ledger.strategy_id,
            guardrails_id: ledger.guardrails_id,
            guardrails_hash: ledger.guardrails_hash,
            accounting_id: ledger.ledger_id,
            accounting_asset: ledger.accounting_asset,
            source_opportunity_id: ledger.source_opportunity_id,
            destination_opportunity_id,
            route_commitment,
            frozen_price_pps,
            frozen_assets_micros: frozen_assets,
            remaining_assets_micros: frozen_assets,
            realized_loss_micros: 0,
            self_settle_deadline_ms,
            closed: false,
        }
    }

    #[test_only]
    public fun measure_reallocation_settlement_for_testing<AdapterWitness: drop, T>(
        receipt: &ExitReceipt,
        _route_witness: AdapterWitness,
        proceeds: Coin<T>,
    ): MeasuredSettlement<T> {
        assert!(!receipt.closed, E_RECEIPT_CLOSED);
        MeasuredSettlement {
            receipt_id: object::id(receipt),
            route_commitment: receipt.route_commitment,
            proceeds,
        }
    }

    #[test_only]
    public fun measure_final_reallocation_settlement_for_testing<AdapterWitness: drop, T>(
        receipt: &ExitReceipt,
        _final_route_witness: AdapterWitness,
        proceeds: Option<Coin<T>>,
    ): FinalMeasuredSettlement<T> {
        assert!(!receipt.closed, E_RECEIPT_CLOSED);
        FinalMeasuredSettlement {
            receipt_id: object::id(receipt),
            route_commitment: receipt.route_commitment,
            proceeds,
        }
    }

    #[test_only]
    public fun settle_reallocation_chunk_for_testing<T>(
        receipt: &mut ExitReceipt,
        ledger: &mut ReallocationLedger,
        settlement: MeasuredSettlement<T>,
        clock: &Clock,
    ) {
        assert!(!receipt.closed, E_RECEIPT_CLOSED);
        assert!(clock::timestamp_ms(clock) <= receipt.self_settle_deadline_ms, E_INVALID_DEADLINE);
        assert_receipt_ledger<T>(receipt, ledger);
        let MeasuredSettlement { receipt_id, route_commitment, proceeds } = settlement;
        assert!(receipt_id == object::id(receipt), E_WRONG_RECEIPT_LEG);
        assert!(route_commitment == receipt.route_commitment, E_INVALID_COMMITMENT);
        settle_to_ledger(receipt, ledger, proceeds);
    }

    #[test_only]
    public fun self_settle_reallocation_remainder_for_testing<T>(
        receipt: &mut ExitReceipt,
        ledger: &mut ReallocationLedger,
        settlement: MeasuredSettlement<T>,
        clock: &Clock,
    ) {
        assert!(!receipt.closed, E_RECEIPT_CLOSED);
        assert!(clock::timestamp_ms(clock) > receipt.self_settle_deadline_ms, E_SELF_SETTLE_NOT_READY);
        assert_receipt_ledger<T>(receipt, ledger);
        let MeasuredSettlement { receipt_id, route_commitment, proceeds } = settlement;
        assert!(receipt_id == object::id(receipt), E_WRONG_RECEIPT_LEG);
        assert!(route_commitment == receipt.route_commitment, E_INVALID_COMMITMENT);
        settle_to_ledger(receipt, ledger, proceeds);
    }

    /// Consume the adapter's final-route witness. The measured Coin is credited;
    /// any remaining frozen basis is a derived write-down. No donation is needed
    /// to close a genuine shortfall and no caller supplies the loss amount.
    #[test_only]
    public fun finalize_reallocation_for_testing<T>(
        receipt: &mut ExitReceipt,
        ledger: &mut ReallocationLedger,
        settlement: FinalMeasuredSettlement<T>,
    ) {
        assert!(!receipt.closed, E_RECEIPT_CLOSED);
        assert_receipt_ledger<T>(receipt, ledger);
        let FinalMeasuredSettlement { receipt_id, route_commitment, proceeds } = settlement;
        assert!(receipt_id == object::id(receipt), E_WRONG_RECEIPT_LEG);
        assert!(route_commitment == receipt.route_commitment, E_INVALID_COMMITMENT);
        if (option::is_some(&proceeds)) {
            let proceeds = option::destroy_some(proceeds);
            settle_final_to_ledger(receipt, ledger, proceeds);
        } else {
            option::destroy_none(proceeds);
        };
        if (receipt.remaining_assets_micros > 0) {
            let loss = receipt.remaining_assets_micros;
            assert!(ledger.in_transit_micros >= loss, E_ASSET_UNDERFLOW);
            ledger.in_transit_micros = ledger.in_transit_micros - loss;
            ledger.total_assets_micros = ledger.total_assets_micros - loss;
            receipt.realized_loss_micros = receipt.realized_loss_micros + loss;
            receipt.remaining_assets_micros = 0;
        };
        receipt.closed = true;
        assert_ledger_invariant(ledger);
    }

    #[test_only]
    fun settle_final_to_ledger<T>(
        receipt: &mut ExitReceipt,
        ledger: &mut ReallocationLedger,
        proceeds: Coin<T>,
    ) {
        let amount = coin::value(&proceeds) as u128;
        assert!(amount > 0, E_ZERO_AMOUNT);
        let basis_returned = if (amount > receipt.remaining_assets_micros) {
            receipt.remaining_assets_micros
        } else {
            amount
        };
        let measured_gain = amount - basis_returned;
        if (basis_returned > 0) {
            ledger.in_transit_micros = ledger.in_transit_micros - basis_returned;
            ledger.destination_deployed_micros = ledger.destination_deployed_micros + basis_returned;
            receipt.remaining_assets_micros = receipt.remaining_assets_micros - basis_returned;
        };
        if (measured_gain > 0) {
            ledger.destination_deployed_micros = ledger.destination_deployed_micros + measured_gain;
            ledger.total_assets_micros = ledger.total_assets_micros + measured_gain;
        };
        transfer::public_transfer(
            proceeds,
            ledger.adapter_destination,
        );
        assert_ledger_invariant(ledger);
    }

    #[test_only]
    fun assert_receipt_ledger<T>(
        receipt: &ExitReceipt,
        ledger: &ReallocationLedger,
    ) {
        assert!(ledger.ledger_id == receipt.accounting_id, E_WRONG_RECEIPT_LEG);
        assert!(ledger.strategy_id == receipt.strategy_id, E_INVALID_POLICY);
        assert!(ledger.accounting_asset == receipt.accounting_asset, E_WRONG_ASSET);
        assert!(receipt.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ASSET);
    }

    #[test_only]
    fun settle_to_ledger<T>(
        receipt: &mut ExitReceipt,
        ledger: &mut ReallocationLedger,
        proceeds: Coin<T>,
    ) {
        let amount = coin::value(&proceeds) as u128;
        assert!(amount > 0 && amount <= receipt.remaining_assets_micros, E_RECEIPT_OVER_SETTLED);
        receipt.remaining_assets_micros = receipt.remaining_assets_micros - amount;
        assert!(ledger.in_transit_micros >= amount, E_ASSET_UNDERFLOW);
        ledger.in_transit_micros = ledger.in_transit_micros - amount;
        ledger.destination_deployed_micros = ledger.destination_deployed_micros + amount;
        if (receipt.remaining_assets_micros == 0) receipt.closed = true;
        transfer::public_transfer(
            proceeds,
            ledger.adapter_destination,
        );
        assert_ledger_invariant(ledger);
    }

    #[test_only]
    fun assert_ledger_invariant(ledger: &ReallocationLedger) {
        assert!(
            ledger.total_assets_micros
                == ledger.source_deployed_micros
                    + ledger.destination_deployed_micros
                    + ledger.in_transit_micros,
            E_ASSET_UNDERFLOW,
        );
    }

    /// Test compatibility for the superseded asynchronous batch model. The
    /// production path is `prepare_frozen_exit_pot` followed in the same PTB by
    /// `reserve_and_fund_frozen_exit_pot`; no production share burn can precede
    /// authenticated funding.
    #[test_only]
    public(package) fun open_frozen_exit_pot<T>(
        accounting: &OpportunityAccounting,
        self_settle_deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let pot = new_frozen_exit_pot<T>(
            managed_position::accounting_id(accounting),
            managed_position::accounting_asset(accounting),
            self_settle_deadline_ms,
            clock::timestamp_ms(clock),
            ctx,
        );
        let id = object::id(&pot);
        transfer::share_object(pot);
        id
    }

    /// Compatibility shell for the superseded settlement-priced path. It stays
    /// in the compatible ABI but cannot create a closeout without the
    /// Position-bound consent snapshot required by DAY-859.
    public(package) fun prepare_frozen_exit_pot<T>(
        _accounting: &OpportunityAccounting,
        self_settle_deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): FrozenExitPot<T> {
        let now_ms = clock::timestamp_ms(clock);
        assert_package_frozen_exit_deadline(now_ms, self_settle_deadline_ms);
        abort E_CONSENT_REQUIRED
    }

    /// Fixed-delay pot for a consented Exit Mode crank. Separate from the owner
    /// closeout helper so a caller cannot choose a force-exit deadline.
    public(package) fun prepare_consented_force_exit_pot<T>(
        accounting: &OpportunityAccounting,
        clock: &Clock,
        ctx: &mut TxContext,
    ): FrozenExitPot<T> {
        let now_ms = clock::timestamp_ms(clock);
        new_frozen_exit_pot<T>(
            managed_position::accounting_id(accounting),
            managed_position::accounting_asset(accounting),
            now_ms + FORCE_EXIT_SETTLEMENT_DELAY_MS,
            now_ms,
            ctx,
        )
    }

    public(package) fun force_exit_pot_binding<T>(
        pot: &FrozenExitPot<T>,
    ): (ID, u64) {
        (object::id(pot), pot.self_settle_deadline_ms)
    }

    /// Consume the force-specific adapter receipt, reserve all shares of the
    /// exact consented Position, and share one funded fixed-delay payout pot.
    /// Positive adapter gain fails closed until the authenticated fee waterfall
    /// is composed; it can never be paid fee-free through this plumbing path.
    /// Claim payout_destination is only the destination returned from the
    /// receipt consumer (position.payout_destination) — never the crank sender.
    public(package) fun reserve_and_fund_consented_force_exit_pot<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        mut pot: FrozenExitPot<T>,
        position: &mut managed_position::Position,
        receipt: ForceExitAdapterReceipt<AdapterWitness, T>,
        ctx: &mut TxContext,
    ): (ID, ID) {
        assert!(pot.ledger_id == managed_position::accounting_id(accounting), E_WRONG_EXIT_POT);
        assert!(pot.accounting_asset == managed_position::accounting_asset(accounting), E_WRONG_ASSET);
        assert!(!pot.funded && pot.active_claims == 0, E_EXIT_POT_ALREADY_FUNDED);
        let (
            payout_destination,
            shares,
            reserved_assets_micros,
            proceeds,
        ) = managed_position::consume_and_reserve_consented_force_exit(
            accounting,
            position,
            object::id(&pot),
            pot.self_settle_deadline_ms,
            receipt,
        );
        let amount = if (option::is_some(&proceeds)) {
            coin::value(option::borrow(&proceeds)) as u128
        } else {
            0
        };
        assert!(amount <= reserved_assets_micros, E_FORCE_EXIT_GAIN_REQUIRES_RECONCILIATION);
        let claim = FrozenExitClaim {
            id: object::new(ctx),
            ledger_id: pot.ledger_id,
            accounting_asset: pot.accounting_asset,
            payout_destination,
            position_id: object::id(position),
            shares,
            share_start: 0,
            share_end: shares,
            reserved_assets_micros,
        };
        let claim_id = object::id(&claim);
        dynamic_object_field::add(&mut pot.id, claim_id, claim);
        pot.total_reserved_shares = shares;
        pot.remaining_reserved_shares = shares;
        pot.total_reserved_assets_micros = reserved_assets_micros;
        pot.remaining_reserved_assets_micros = reserved_assets_micros;
        pot.measured_total_micros = amount;
        pot.exit_pps = if (shares == 0) {
            0
        } else {
            (((amount as u256) * (PPS_SCALE as u256)) / (shares as u256)) as u128
        };
        pot.active_claims = 1;
        pot.funded = true;
        if (option::is_some(&proceeds)) {
            balance::join(
                &mut pot.proceeds,
                coin::into_balance(option::destroy_some(proceeds)),
            );
        } else {
            option::destroy_none(proceeds);
        };
        let pot_id = object::id(&pot);
        transfer::share_object(pot);
        (pot_id, claim_id)
    }

    /// Additive delayed-closeout path. It freezes the owner's exact claim at
    /// consent time under the Position, then shares only the empty pot. A later
    /// adapter return must consume that provenance-bound consent rather than
    /// re-reading the mutable accounting PPS.
    ///
    /// DAY-911: package-visible core. Production PTBs must call the additive
    /// `public` wrappers below — sibling package modules may still call this
    /// directly. Existing signature retained (compatible upgrade).
    public(package) fun prepare_frozen_exit_pot_with_consent<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut managed_position::Position,
        shares: u128,
        self_settle_deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let now_ms = clock::timestamp_ms(clock);
        assert_package_frozen_exit_deadline(now_ms, self_settle_deadline_ms);
        let pot = new_frozen_exit_pot<T>(
            managed_position::accounting_id(accounting),
            managed_position::accounting_asset(accounting),
            self_settle_deadline_ms,
            now_ms,
            ctx,
        );
        let pot_id = object::id(&pot);
        managed_position::reserve_deployed_exit_for_frozen_consent<T>(
            accounting,
            position,
            pot_id,
            shares,
            self_settle_deadline_ms,
            ctx,
        );
        transfer::share_object(pot);
        pot_id
    }

    /// DAY-911 additive production surface: owner-callable consent prepare.
    /// New `public fun` (not a signature change of a published public) — safe
    /// under compatible upgrade; does not touch the abort-17 legacy shells.
    public fun owner_prepare_frozen_exit_with_consent<T>(
        accounting: &mut OpportunityAccounting,
        position: &mut managed_position::Position,
        shares: u128,
        self_settle_deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        prepare_frozen_exit_pot_with_consent<T>(
            accounting,
            position,
            shares,
            self_settle_deadline_ms,
            clock,
            ctx,
        )
    }

    /// Fund a delayed frozen exit from a nonce/source-bound adapter return.
    ///
    /// Owner claim amount:
    /// - if `gross >= frozen_assets`: the consent-time frozen claim (DAY-859);
    /// - if `gross < frozen_assets`: the authenticated gross only (DAY-911 #3 —
    ///   real adapter loss; do not abort-then-cancel restore a phantom basis).
    ///
    /// Nested lead/DAY fee waterfall runs on feeable profit above the consent
    /// fee basis, capped to the surplus after the owner claim so fees never
    /// steal the frozen principal slice when funds are sufficient, and never
    /// invent coins on a loss.
    public(package) fun fund_frozen_exit_pot_from_consent<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        pot: &mut FrozenExitPot<T>,
        position: &mut managed_position::Position,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
        ctx: &mut TxContext,
    ): ID {
        assert!(pot.ledger_id == managed_position::accounting_id(accounting), E_WRONG_EXIT_POT);
        assert!(pot.accounting_asset == managed_position::accounting_asset(accounting), E_WRONG_ASSET);
        assert!(!pot.funded && pot.active_claims == 0, E_EXIT_POT_ALREADY_FUNDED);
        let (
            shares,
            frozen_assets_micros,
            frozen_pps,
            reserved_fee_basis_micros,
            payout_destination,
        ) = managed_position::consume_frozen_exit_consent<T>(
            accounting,
            position,
            object::id(pot),
        );
        let proceeds_opt = managed_position::consume_adapter_full_return(
            accounting,
            object::id(pot),
            receipt,
        );
        // Authenticated zero return is a real total loss, not a missing receipt.
        // Option::None → zero Coin; cancel is only for returns that never arrive.
        let mut proceeds = if (option::is_some(&proceeds_opt)) {
            option::destroy_some(proceeds_opt)
        } else {
            option::destroy_none(proceeds_opt);
            coin::zero<T>(ctx)
        };
        let gross_amount = coin::value(&proceeds) as u128;
        assert!(frozen_assets_micros <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);
        assert!(gross_amount <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);

        // Owner claim: freeze protects against favorable reprice for others;
        // it does not invent coins when the adapter realizes a loss.
        let owner_claim_micros = if (gross_amount >= frozen_assets_micros) {
            frozen_assets_micros
        } else {
            gross_amount
        };

        // Feeable profit vs consent-time fee basis (same nested waterfall as the
        // pre-#822 atomic fund path). Cap the lead pool to surplus after the
        // owner claim so fees never underfund the frozen principal slice.
        let feeable_profit = if (gross_amount > reserved_fee_basis_micros) {
            gross_amount - reserved_fee_basis_micros
        } else {
            0
        };
        let (
            lead_fee_bps,
            day_share_bps,
            lead_destination,
            day_destination,
        ) = managed_position::fee_policy_for_package(accounting);
        let derived_lead_fee_pool = mul_bps_floor(feeable_profit, lead_fee_bps);
        let surplus_after_owner = gross_amount - owner_claim_micros;
        let lead_fee_pool = if (derived_lead_fee_pool > surplus_after_owner) {
            surplus_after_owner
        } else {
            derived_lead_fee_pool
        };
        let day_fee = mul_bps_floor(lead_fee_pool, day_share_bps);
        let lead_fee = lead_fee_pool - day_fee;
        assert!(lead_fee <= MAX_COIN_VALUE && day_fee <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);
        if (lead_fee > 0) {
            transfer::public_transfer(
                coin::split(&mut proceeds, lead_fee as u64, ctx),
                lead_destination,
            );
        };
        if (day_fee > 0) {
            transfer::public_transfer(
                coin::split(&mut proceeds, day_fee as u64, ctx),
                day_destination,
            );
        };

        let payout_coin = if (owner_claim_micros > 0) {
            coin::split(&mut proceeds, owner_claim_micros as u64, ctx)
        } else {
            coin::zero<T>(ctx)
        };
        let dust = coin::value(&proceeds) as u128;
        if (dust > 0) {
            managed_position::credit_remaining_leg_dust(accounting, dust);
            transfer::public_transfer(
                proceeds,
                managed_position::adapter_destination_for_package(accounting),
            );
        } else {
            coin::destroy_zero(proceeds);
        };

        let claim = FrozenExitClaim {
            id: object::new(ctx),
            ledger_id: pot.ledger_id,
            accounting_asset: pot.accounting_asset,
            payout_destination,
            position_id: object::id(position),
            shares,
            share_start: 0,
            share_end: shares,
            reserved_assets_micros: owner_claim_micros,
        };
        let claim_id = object::id(&claim);
        dynamic_object_field::add(&mut pot.id, claim_id, claim);
        pot.total_reserved_shares = shares;
        pot.remaining_reserved_shares = shares;
        pot.total_reserved_assets_micros = owner_claim_micros;
        pot.remaining_reserved_assets_micros = owner_claim_micros;
        pot.measured_total_micros = owner_claim_micros;
        // Consent PPS is retained for audit even when a loss reduced the paid
        // claim; settle pays reserved_assets_micros, not exit_pps * shares.
        pot.exit_pps = frozen_pps;
        pot.active_claims = 1;
        pot.funded = true;
        balance::join(&mut pot.proceeds, coin::into_balance(payout_coin));
        claim_id
    }

    /// DAY-911 additive production surface: fund from a package-attested
    /// adapter return receipt. Receipt construction remains package-gated;
    /// this public wrapper makes the fund step PTB-callable once a same-package
    /// adapter (or router) has minted the hot-potato receipt.
    public fun owner_fund_frozen_exit_from_consent<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        pot: &mut FrozenExitPot<T>,
        position: &mut managed_position::Position,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
        ctx: &mut TxContext,
    ): ID {
        fund_frozen_exit_pot_from_consent<AdapterWitness, T>(
            accounting,
            pot,
            position,
            receipt,
            ctx,
        )
    }

    /// Owner-only R3 recovery for a delayed adapter return that never arrives.
    /// It restores the exact consent-time reservation; the stale pot remains
    /// unfunded and can no longer consume a Position consent.
    ///
    /// DAY-911 #3: cancel is ONLY for non-arrival. Authenticated underfund /
    /// loss MUST go through `fund_frozen_exit_pot_from_consent` (pays the
    /// measured gross, no phantom restore). Cancel after a real on-chain loss
    /// would re-credit assets that do not exist — that path is intentionally
    /// not used for underfunded receipts anymore.
    public(package) fun cancel_frozen_exit_pot_consent<T>(
        accounting: &mut OpportunityAccounting,
        pot: &FrozenExitPot<T>,
        position: &mut managed_position::Position,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(!pot.funded, E_EXIT_POT_ALREADY_FUNDED);
        managed_position::cancel_frozen_exit_consent<T>(
            accounting,
            position,
            object::id(pot),
            clock::timestamp_ms(clock),
            ctx,
        );
    }

    /// DAY-911 additive production surface: owner cancel after deadline.
    public fun owner_cancel_frozen_exit_consent<T>(
        accounting: &mut OpportunityAccounting,
        pot: &FrozenExitPot<T>,
        position: &mut managed_position::Position,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        cancel_frozen_exit_pot_consent<T>(accounting, pot, position, clock, ctx)
    }

    /// Legacy settlement-priced path retained only for compatible ABI.
    public(package) fun reserve_and_fund_frozen_exit_pot<AdapterWitness, T>(
        _accounting: &mut OpportunityAccounting,
        _pot: FrozenExitPot<T>,
        _position: &mut managed_position::Position,
        _shares: u128,
        _receipt: AdapterCloseoutReturnReceipt<AdapterWitness, T>,
        _ctx: &mut TxContext,
    ): (ID, ID) {
        abort E_CONSENT_REQUIRED
    }

    fun new_frozen_exit_pot<T>(
        ledger_id: ID,
        accounting_asset: type_name::TypeName,
        self_settle_deadline_ms: u64,
        now_ms: u64,
        ctx: &mut TxContext,
    ): FrozenExitPot<T> {
        assert!(self_settle_deadline_ms > now_ms, E_INVALID_DEADLINE);
        assert!(accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ASSET);
        FrozenExitPot {
            id: object::new(ctx),
            ledger_id,
            accounting_asset,
            exit_pps: 0,
            total_reserved_shares: 0,
            remaining_reserved_shares: 0,
            total_reserved_assets_micros: 0,
            remaining_reserved_assets_micros: 0,
            measured_total_micros: 0,
            active_claims: 0,
            self_settle_deadline_ms,
            funded: false,
            proceeds: balance::zero<T>(),
        }
    }

    /// Preserve the v4 package-only ABI without preserving caller discretion.
    /// The overflow guard also makes the expected abort stable instead of
    /// relying on arithmetic overflow behavior at the u64 boundary.
    fun assert_package_frozen_exit_deadline(
        now_ms: u64,
        self_settle_deadline_ms: u64,
    ) {
        assert!(now_ms <= MAX_U64 - FROZEN_EXIT_SETTLEMENT_DELAY_MS, E_INVALID_DEADLINE);
        assert!(
            self_settle_deadline_ms == now_ms + FROZEN_EXIT_SETTLEMENT_DELAY_MS,
            E_INVALID_DEADLINE,
        );
    }

    /// Owner-pull reservation. The mutable Position proves ownership at the VM
    /// boundary, and the recorded payout destination is copied into the claim.
    #[test_only]
    public(package) fun reserve_frozen_exit_claim<T>(
        accounting: &mut OpportunityAccounting,
        pot: &mut FrozenExitPot<T>,
        position: &mut managed_position::Position,
        shares: u128,
        ctx: &mut TxContext,
    ): ID {
        assert!(pot.ledger_id == managed_position::accounting_id(accounting), E_WRONG_EXIT_POT);
        assert!(pot.accounting_asset == managed_position::accounting_asset(accounting), E_WRONG_ASSET);
        assert!(!pot.funded, E_EXIT_POT_ALREADY_FUNDED);
        let reserved_assets_micros = managed_position::reserve_deployed_exit_for_closeout<T>(
            accounting,
            position,
            shares,
            ctx,
        );
        let share_start = pot.total_reserved_shares;
        let share_end = share_start + shares;
        let claim = FrozenExitClaim {
            id: object::new(ctx),
            ledger_id: pot.ledger_id,
            accounting_asset: pot.accounting_asset,
            payout_destination: managed_position::recorded_payout_destination(position),
            position_id: object::id(position),
            shares,
            share_start,
            share_end,
            reserved_assets_micros,
        };
        let claim_id = object::id(&claim);
        dynamic_object_field::add(&mut pot.id, claim_id, claim);
        pot.active_claims = pot.active_claims + 1;
        pot.total_reserved_shares = pot.total_reserved_shares + shares;
        pot.remaining_reserved_shares = pot.remaining_reserved_shares + shares;
        pot.total_reserved_assets_micros = pot.total_reserved_assets_micros + reserved_assets_micros;
        pot.remaining_reserved_assets_micros = pot.remaining_reserved_assets_micros + reserved_assets_micros;
        claim_id
    }

    /// Freeze one measured PPS from a source/nonce/pot-bound adapter receipt.
    /// Zero return and positive gain are both valid. Floor dust is credited at
    /// funding time to remaining-leg accounting, never based on crank order.
    #[test_only]
    public(package) fun fund_frozen_exit_pot<AdapterWitness, T>(
        accounting: &mut OpportunityAccounting,
        pot: &mut FrozenExitPot<T>,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
        ctx: &mut TxContext,
    ) {
        assert!(pot.ledger_id == managed_position::accounting_id(accounting), E_WRONG_EXIT_POT);
        assert!(!pot.funded, E_EXIT_POT_ALREADY_FUNDED);
        assert!(pot.total_reserved_shares > 0, E_ZERO_AMOUNT);
        let mut proceeds = managed_position::consume_adapter_full_return(
            accounting,
            object::id(pot),
            receipt,
        );
        let amount = if (option::is_some(&proceeds)) {
            coin::value(option::borrow(&proceeds)) as u128
        } else {
            0
        };
        initialize_claim_payouts(pot, amount);
        if (option::is_some(&proceeds)) {
            balance::join(
                &mut pot.proceeds,
                coin::into_balance(option::destroy_some(proceeds)),
            );
        } else {
            option::destroy_none(proceeds);
        };
        pot.funded = true;
    }

    fun initialize_claim_payouts<T>(pot: &mut FrozenExitPot<T>, amount: u128) {
        pot.exit_pps = (((amount as u256) * (PPS_SCALE as u256))
            / (pot.total_reserved_shares as u256)) as u128;
        pot.measured_total_micros = amount;
    }

    /// Permissionless crank after the immutable deadline. Payout goes only to
    /// the destination copied from the Position at reservation.
    public fun settle_frozen_exit_claim<T>(
        pot: &mut FrozenExitPot<T>,
        claim_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u128 {
        assert!(pot.funded, E_UNFUNDED_CLAIM);
        assert!(clock::timestamp_ms(clock) > pot.self_settle_deadline_ms, E_SELF_SETTLE_NOT_READY);
        assert!(dynamic_object_field::exists_(&pot.id, claim_id), E_EXIT_CLAIM_NOT_FOUND);
        let claim = dynamic_object_field::remove<ID, FrozenExitClaim>(&mut pot.id, claim_id);
        assert!(claim.ledger_id == pot.ledger_id, E_WRONG_EXIT_POT);
        assert!(claim.accounting_asset == pot.accounting_asset, E_WRONG_ASSET);
        let payout = interval_payout(
            claim.share_start,
            claim.share_end,
            pot.total_reserved_shares,
            pot.measured_total_micros,
        );
        assert!(payout <= MAX_COIN_VALUE, E_AMOUNT_TOO_LARGE);
        assert!(payout <= (balance::value(&pot.proceeds) as u128), E_ASSET_UNDERFLOW);
        pot.remaining_reserved_shares = pot.remaining_reserved_shares - claim.shares;
        pot.remaining_reserved_assets_micros =
            pot.remaining_reserved_assets_micros - claim.reserved_assets_micros;
        pot.active_claims = pot.active_claims - 1;
        let FrozenExitClaim {
            id,
            ledger_id: _,
            accounting_asset: _,
            payout_destination,
            position_id: _,
            shares: _,
            share_start: _,
            share_end: _,
            reserved_assets_micros: _,
        } = claim;
        object::delete(id);
        transfer::public_transfer(
            coin::take(&mut pot.proceeds, payout as u64, ctx),
            payout_destination,
        );
        payout
    }

    #[test_only]
    public fun new_frozen_exit_pot_for_testing<T>(
        ledger: &ReallocationLedger,
        self_settle_deadline_ms: u64,
        now_ms: u64,
        ctx: &mut TxContext,
    ): FrozenExitPot<T> {
        new_frozen_exit_pot<T>(
            ledger.ledger_id,
            ledger.accounting_asset,
            self_settle_deadline_ms,
            now_ms,
            ctx,
        )
    }

    #[test_only]
    public fun share_frozen_exit_pot_for_testing<T>(pot: FrozenExitPot<T>) {
        transfer::share_object(pot);
    }

    #[test_only]
    public fun reserve_frozen_exit_claim_for_testing<T>(
        ledger: &mut ReallocationLedger,
        pot: &mut FrozenExitPot<T>,
        position: &managed_position::Position,
        shares: u128,
        ctx: &mut TxContext,
    ): ID {
        assert!(pot.ledger_id == ledger.ledger_id, E_WRONG_EXIT_POT);
        assert!(pot.accounting_asset == ledger.accounting_asset, E_WRONG_ASSET);
        assert!(pot.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ASSET);
        assert!(!pot.funded, E_EXIT_POT_ALREADY_FUNDED);
        assert!(managed_position::leg_accounting_id(position) == ledger.ledger_id, E_WRONG_EXIT_POT);
        assert!(managed_position::position_shares(position) >= shares, E_ZERO_AMOUNT);
        assert!(shares > 0 && ledger.total_shares >= shares, E_ZERO_AMOUNT);
        let reserved_assets_micros = managed_position::convert_to_assets(
            shares,
            ledger.total_assets_micros,
            ledger.total_shares,
        );
        assert!(ledger.source_deployed_micros >= reserved_assets_micros, E_ASSET_UNDERFLOW);
        ledger.source_deployed_micros = ledger.source_deployed_micros - reserved_assets_micros;
        ledger.total_assets_micros = ledger.total_assets_micros - reserved_assets_micros;
        ledger.total_shares = ledger.total_shares - shares;
        pot.total_reserved_shares = pot.total_reserved_shares + shares;
        pot.remaining_reserved_shares = pot.remaining_reserved_shares + shares;
        pot.total_reserved_assets_micros =
            pot.total_reserved_assets_micros + reserved_assets_micros;
        pot.remaining_reserved_assets_micros =
            pot.remaining_reserved_assets_micros + reserved_assets_micros;
        assert_ledger_invariant(ledger);
        let share_start = pot.total_reserved_shares - shares;
        let share_end = pot.total_reserved_shares;
        let claim = FrozenExitClaim {
            id: object::new(ctx),
            ledger_id: ledger.ledger_id,
            accounting_asset: ledger.accounting_asset,
            payout_destination: managed_position::recorded_payout_destination(position),
            position_id: object::id(position),
            shares,
            share_start,
            share_end,
            reserved_assets_micros,
        };
        let claim_id = object::id(&claim);
        dynamic_object_field::add(&mut pot.id, claim_id, claim);
        pot.active_claims = pot.active_claims + 1;
        claim_id
    }

    #[test_only]
    public fun fund_frozen_exit_pot_for_testing<T>(
        pot: &mut FrozenExitPot<T>,
        ledger: &mut ReallocationLedger,
        mut proceeds: Coin<T>,
        ctx: &mut TxContext,
    ) {
        assert!(!pot.funded, E_EXIT_POT_ALREADY_FUNDED);
        assert!(pot.total_reserved_shares > 0, E_ZERO_AMOUNT);
        let amount = coin::value(&proceeds) as u128;
        initialize_claim_payouts(pot, amount);
        pot.funded = true;
        balance::join(&mut pot.proceeds, coin::into_balance(proceeds));
    }

    #[test_only]
    public fun settle_frozen_exit_claim_for_testing<T>(
        pot: &mut FrozenExitPot<T>,
        ledger: &mut ReallocationLedger,
        claim_id: ID,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u128 {
        assert!(pot.funded, E_INVALID_POLICY);
        assert!(clock::timestamp_ms(clock) > pot.self_settle_deadline_ms, E_SELF_SETTLE_NOT_READY);
        assert!(pot.ledger_id == ledger.ledger_id, E_WRONG_EXIT_POT);
        assert!(pot.accounting_asset == ledger.accounting_asset, E_WRONG_ASSET);
        settle_frozen_exit_claim(pot, claim_id, clock, ctx)
    }

    #[test_only]
    public fun frozen_exit_pot_pps<T>(pot: &FrozenExitPot<T>): u128 {
        pot.exit_pps
    }

    #[test_only]
    public fun frozen_exit_claim_assets<T>(
        pot: &FrozenExitPot<T>,
        claim_id: ID,
    ): u128 {
        assert!(dynamic_object_field::exists_(&pot.id, claim_id), E_EXIT_CLAIM_NOT_FOUND);
        dynamic_object_field::borrow<ID, FrozenExitClaim>(&pot.id, claim_id).reserved_assets_micros
    }

    #[test_only]
    public fun destroy_frozen_exit_pot_for_testing<T>(pot: FrozenExitPot<T>) {
        let FrozenExitPot {
            id,
            ledger_id: _,
            accounting_asset: _,
            exit_pps: _,
            total_reserved_shares: _,
            remaining_reserved_shares,
            total_reserved_assets_micros: _,
            remaining_reserved_assets_micros,
            measured_total_micros: _,
            active_claims,
            self_settle_deadline_ms: _,
            funded: _,
            proceeds,
        } = pot;
        assert!(remaining_reserved_shares == 0, E_WRONG_EXIT_POT);
        assert!(remaining_reserved_assets_micros == 0, E_WRONG_EXIT_POT);
        assert!(active_claims == 0, E_WRONG_EXIT_POT);
        balance::destroy_zero(proceeds);
        object::delete(id);
    }

    fun interval_payout(
        share_start: u128,
        share_end: u128,
        total_shares: u128,
        measured_total: u128,
    ): u128 {
        let start_assets = (((share_start as u256) * (measured_total as u256))
            / (total_shares as u256)) as u128;
        let end_assets = (((share_end as u256) * (measured_total as u256))
            / (total_shares as u256)) as u128;
        end_assets - start_assets
    }

    fun assets_at_exit_pps(shares: u128, exit_pps: u128): u128 {
        (((shares as u256) * (exit_pps as u256)) / (PPS_SCALE as u256)) as u128
    }

    fun mul_bps_floor(amount: u128, bps: u64): u128 {
        (((amount as u256) * (bps as u256)) / (BASIS_POINTS as u256)) as u128
    }

    fun div_ceil(numerator: u256, denominator: u256): u256 {
        if (numerator == 0) return 0;
        ((numerator - 1) / denominator) + 1
    }

    fun profit_above_fee_basis(
        gross_total_assets: u128,
        fee_basis_assets: u128,
    ): u128 {
        if (gross_total_assets > fee_basis_assets) {
            gross_total_assets - fee_basis_assets
        } else {
            0
        }
    }

    fun price_per_share_ceil(total_assets: u128, total_shares: u128): u128 {
        if (total_shares == 0) return PPS_SCALE;
        div_ceil(
            ((total_assets as u256) + (VIRTUAL_ASSETS as u256)) * (PPS_SCALE as u256),
            (total_shares as u256) + (VIRTUAL_SHARES as u256),
        ) as u128
    }

    fun price_per_share_floor(total_assets: u128, total_shares: u128): u128 {
        if (total_shares == 0) return PPS_SCALE;
        ((((total_assets as u256) + (VIRTUAL_ASSETS as u256)) * (PPS_SCALE as u256))
            / ((total_shares as u256) + (VIRTUAL_SHARES as u256))) as u128
    }

    public fun fee_profit_micros(assessment: &FeeAssessment): u128 {
        assessment.profit_above_high_water_micros
    }
    public fun fee_lead_pool_micros(assessment: &FeeAssessment): u128 {
        assessment.lead_fee_pool_micros
    }
    public fun fee_lead_micros(assessment: &FeeAssessment): u128 { assessment.lead_fee_micros }
    public fun fee_day_micros(assessment: &FeeAssessment): u128 { assessment.day_fee_micros }
    public fun fee_net_micros(assessment: &FeeAssessment): u128 { assessment.net_assets_micros }
    #[test_only]
    public fun receipt_remaining_micros(receipt: &ExitReceipt): u128 {
        receipt.remaining_assets_micros
    }
    #[test_only]
    public fun receipt_frozen_assets_micros(receipt: &ExitReceipt): u128 {
        receipt.frozen_assets_micros
    }
    #[test_only]
    public fun receipt_frozen_price_pps(receipt: &ExitReceipt): u128 { receipt.frozen_price_pps }
    #[test_only]
    public fun receipt_realized_loss_micros(receipt: &ExitReceipt): u128 {
        receipt.realized_loss_micros
    }
    #[test_only]
    public fun receipt_closed(receipt: &ExitReceipt): bool { receipt.closed }
    #[test_only]
    public fun receipt_route_commitment(receipt: &ExitReceipt): vector<u8> {
        receipt.route_commitment
    }

    #[test_only]
    public fun new_receipt_for_testing(
        ledger: &mut ReallocationLedger,
        destination_opportunity_id: vector<u8>,
        route_commitment: vector<u8>,
        allocation_bps: u64,
        self_settle_deadline_ms: u64,
        now_ms: u64,
        ctx: &mut TxContext,
    ): ExitReceipt {
        new_receipt(
            ledger, destination_opportunity_id, route_commitment, allocation_bps,
            self_settle_deadline_ms, now_ms, ctx,
        )
    }

    #[test_only]
    public fun new_reallocation_ledger_for_testing<T>(
        ledger_id: ID,
        source_opportunity_id: vector<u8>,
        destination_opportunity_id: vector<u8>,
        total_assets_micros: u128,
        total_shares: u128,
        adapter_destination: address,
    ): ReallocationLedger {
        assert!(total_assets_micros > 0 && total_shares > 0, E_ZERO_AMOUNT);
        ReallocationLedger {
            ledger_id,
            accounting_asset: type_name::with_original_ids<T>(),
            strategy_id: b"day-managed-top-one",
            guardrails_id: object::id_from_address(@0x6A4D),
            guardrails_hash: x"1111111111111111111111111111111111111111111111111111111111111111",
            source_opportunity_id,
            destination_opportunity_id,
            source_deployed_micros: total_assets_micros,
            destination_deployed_micros: 0,
            in_transit_micros: 0,
            total_assets_micros,
            total_shares,
            high_water_pps: price_per_share_ceil(total_assets_micros, total_shares),
            adapter_destination,
        }
    }

    #[test_only]
    public fun ledger_total_assets_micros(ledger: &ReallocationLedger): u128 {
        ledger.total_assets_micros
    }

    #[test_only]
    public fun ledger_in_transit_micros(ledger: &ReallocationLedger): u128 {
        ledger.in_transit_micros
    }

    #[test_only]
    public fun ledger_price_per_share_micros(ledger: &ReallocationLedger): u128 {
        price_per_share_ceil(ledger.total_assets_micros, ledger.total_shares)
    }

    #[test_only]
    public fun ledger_position_value_micros(
        ledger: &ReallocationLedger,
        shares: u128,
    ): u128 {
        managed_position::convert_to_assets(
            shares,
            ledger.total_assets_micros,
            ledger.total_shares,
        )
    }

    #[test_only]
    public fun ledger_allocation_lot_for_testing(
        ledger: &ReallocationLedger,
        opportunity_id: vector<u8>,
    ): (u128, u128) {
        if (opportunity_id == ledger.source_opportunity_id) {
            (ledger.source_deployed_micros, ledger.in_transit_micros)
        } else if (opportunity_id == ledger.destination_opportunity_id) {
            (ledger.destination_deployed_micros, 0)
        } else {
            (0, 0)
        }
    }

    #[test_only]
    public fun destroy_receipt_for_testing(receipt: ExitReceipt) {
        let ExitReceipt {
            id,
            strategy_id: _,
            guardrails_id: _,
            guardrails_hash: _,
            accounting_id: _,
            accounting_asset: _,
            source_opportunity_id: _,
            destination_opportunity_id: _,
            route_commitment: _,
            frozen_price_pps: _,
            frozen_assets_micros: _,
            remaining_assets_micros: _,
            realized_loss_micros: _,
            self_settle_deadline_ms: _,
            closed: _,
        } = receipt;
        object::delete(id);
    }
}
