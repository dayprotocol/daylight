// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// Production DAY-862 reallocation accounting.
///
/// Only package policy code can start a move. Settlement consumes the exact
/// source accounting's adapter receipt, which binds source type, asset type,
/// nonce, purpose object and measured Coin/none. No amount, profit or loss is
/// accepted from a caller.
module day::managed_reallocation {
    use day::guardrails_v2::NativeAssetBinding;
    use day::managed_position::{Self, AdapterReturnReceipt, OpportunityAccounting};
    use std::hash;
    use std::type_name::{Self, TypeName};
    use sui::coin::{Self, Coin};

    const ROUTE_COMMITMENT_LEN: u64 = 32;
    const E_INVALID_ROUTE: u64 = 1;
    const E_WRONG_ENDPOINT: u64 = 2;
    const E_WRONG_ASSET: u64 = 3;
    const E_WRONG_POLICY: u64 = 4;
    const E_CLOSED: u64 = 5;
    const E_ZERO_RETURN: u64 = 6;
    const E_FINAL_REQUIRED: u64 = 7;

    /// Linear proof that live accounting was reserved for one reallocation.
    ///
    /// This type deliberately lives beside `start_reallocation`: private fields
    /// make that function the only constructor, so no sibling DAY module can
    /// manufacture provenance without first mutating the source accounting.
    public struct ReallocationReservation<phantom T> {
        state_id: ID,
        source_accounting_id: ID,
        destination_accounting_id: ID,
        source_opportunity_id: vector<u8>,
        destination_opportunity_id: vector<u8>,
        strategy_id: vector<u8>,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        canonical_route: vector<u8>,
        route_commitment: vector<u8>,
        source_native_asset_binding: NativeAssetBinding,
        destination_native_asset_binding: NativeAssetBinding,
        allocation_bps: u64,
    }

    /// Shared metadata only. Coins transit directly to the destination adapter.
    public struct ReallocationState<phantom T> has key {
        id: UID,
        source_accounting_id: ID,
        destination_accounting_id: ID,
        source_opportunity_id: vector<u8>,
        destination_opportunity_id: vector<u8>,
        accounting_asset: TypeName,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        route_commitment: vector<u8>,
        frozen_basis_micros: u128,
        remaining_basis_micros: u128,
        destination_deployed_micros: u128,
        measured_return_micros: u128,
        destination_reconciled_micros: u128,
        realized_gain_micros: u128,
        realized_loss_micros: u128,
        closed: bool,
        destination_return_closed: bool,
    }

    /// Authenticated destination-spoke proceeds. The Coin cannot be detached
    /// from its parent accounting/state binding by an external caller.
    public struct ReallocationReturnProceeds<phantom T> {
        source_accounting_id: ID,
        state_id: ID,
        proceeds: Option<Coin<T>>,
    }

    /// DAY-849 calls this only after leader, lifecycle, Guardrails and complete
    /// route validation. Basis is derived from deployed accounting and bps.
    public(package) fun start_reallocation<T>(
        source: &mut OpportunityAccounting,
        destination: &OpportunityAccounting,
        canonical_route: vector<u8>,
        allocation_bps: u64,
        ctx: &mut TxContext,
    ): ReallocationReservation<T> {
        assert!(!vector::is_empty(&canonical_route), E_INVALID_ROUTE);
        let route_commitment = hash::sha2_256(copy canonical_route);
        assert!(vector::length(&route_commitment) == ROUTE_COMMITMENT_LEN, E_INVALID_ROUTE);
        let source_id = managed_position::accounting_id(source);
        let destination_id = managed_position::accounting_id(destination);
        assert!(source_id != destination_id, E_WRONG_ENDPOINT);
        let source_opportunity_id = managed_position::accounting_opportunity_id(source);
        let destination_opportunity_id = managed_position::accounting_opportunity_id(destination);
        assert!(source_opportunity_id != destination_opportunity_id, E_WRONG_ENDPOINT);
        let accounting_asset = type_name::with_original_ids<T>();
        assert!(managed_position::accounting_asset(source) == accounting_asset, E_WRONG_ASSET);
        assert!(managed_position::accounting_asset(destination) == accounting_asset, E_WRONG_ASSET);
        // The source accounting is the single parent share ledger. A destination
        // endpoint with independent holders would create an economic windfall.
        assert!(managed_position::total_assets_micros(destination) == 0, E_WRONG_ENDPOINT);
        assert!(managed_position::total_shares(destination) == 0, E_WRONG_ENDPOINT);
        let source_guardrails = managed_position::accounting_guardrails_id(source);
        let destination_guardrails = managed_position::accounting_guardrails_id(destination);
        let source_strategy = managed_position::accounting_strategy_id(source);
        let destination_strategy = managed_position::accounting_strategy_id(destination);
        assert!(option::is_some(&source_strategy), E_WRONG_POLICY);
        assert!(option::is_some(&destination_strategy), E_WRONG_POLICY);
        let strategy_id = *option::borrow(&source_strategy);
        assert!(strategy_id == *option::borrow(&destination_strategy), E_WRONG_POLICY);
        assert!(option::is_some(&source_guardrails), E_WRONG_POLICY);
        assert!(option::is_some(&destination_guardrails), E_WRONG_POLICY);
        let guardrails_id = *option::borrow(&source_guardrails);
        assert!(guardrails_id == *option::borrow(&destination_guardrails), E_WRONG_POLICY);
        let source_hash = managed_position::accounting_guardrails_hash(source);
        let destination_hash = managed_position::accounting_guardrails_hash(destination);
        assert!(option::is_some(&source_hash), E_WRONG_POLICY);
        assert!(option::is_some(&destination_hash), E_WRONG_POLICY);
        let guardrails_hash = *option::borrow(&source_hash);
        assert!(guardrails_hash == *option::borrow(&destination_hash), E_WRONG_POLICY);
        // These exact values come only from immutable accounting state. No
        // caller-supplied chain/token descriptor crosses into the reservation.
        let source_native_asset_binding =
            managed_position::accounting_native_asset_binding(source);
        let destination_native_asset_binding =
            managed_position::accounting_native_asset_binding(destination);
        let basis = managed_position::begin_measured_reallocation(source, allocation_bps);
        let state = ReallocationState<T> {
            id: object::new(ctx),
            source_accounting_id: source_id,
            destination_accounting_id: destination_id,
            source_opportunity_id: copy source_opportunity_id,
            destination_opportunity_id: copy destination_opportunity_id,
            accounting_asset,
            guardrails_id,
            guardrails_hash,
            route_commitment: copy route_commitment,
            frozen_basis_micros: basis,
            remaining_basis_micros: basis,
            destination_deployed_micros: 0,
            measured_return_micros: 0,
            destination_reconciled_micros: 0,
            realized_gain_micros: 0,
            realized_loss_micros: 0,
            closed: false,
            destination_return_closed: false,
        };
        let state_id = object::id(&state);
        transfer::share_object(state);
        ReallocationReservation<T> {
            state_id,
            source_accounting_id: source_id,
            destination_accounting_id: destination_id,
            source_opportunity_id,
            destination_opportunity_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            canonical_route,
            route_commitment,
            source_native_asset_binding,
            destination_native_asset_binding,
            allocation_bps,
        }
    }

    /// Sole accessor for the accounting provenance proof. Consumption is
    /// linear; the hub cannot retain or duplicate a reservation.
    public(package) fun consume_reallocation_reservation<T>(
        reservation: ReallocationReservation<T>,
    ): (
        ID, ID, ID, vector<u8>, vector<u8>, vector<u8>, ID, vector<u8>,
        vector<u8>, vector<u8>, NativeAssetBinding, NativeAssetBinding, u64,
    ) {
        let ReallocationReservation {
            state_id,
            source_accounting_id,
            destination_accounting_id,
            source_opportunity_id,
            destination_opportunity_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            canonical_route,
            route_commitment,
            source_native_asset_binding,
            destination_native_asset_binding,
            allocation_bps,
        } = reservation;
        (
            state_id,
            source_accounting_id,
            destination_accounting_id,
            source_opportunity_id,
            destination_opportunity_id,
            strategy_id,
            guardrails_id,
            guardrails_hash,
            canonical_route,
            route_commitment,
            source_native_asset_binding,
            destination_native_asset_binding,
            allocation_bps,
        )
    }

    /// Consume one authenticated positive partial return. A conclusive zero or
    /// shortfall must use `finalize_reallocation`.
    public(package) fun settle_reallocation_chunk<AdapterWitness, T>(
        state: &mut ReallocationState<T>,
        source: &mut OpportunityAccounting,
        destination: &mut OpportunityAccounting,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
    ) {
        assert_bound(state, source, destination);
        let proceeds = managed_position::consume_adapter_full_return(
            source,
            object::id(state),
            receipt,
        );
        assert!(option::is_some(&proceeds), E_ZERO_RETURN);
        let proceeds = option::destroy_some(proceeds);
        let amount = coin::value(&proceeds) as u128;
        assert!(amount > 0, E_ZERO_RETURN);
        let basis = if (amount < state.remaining_basis_micros) {
            amount
        } else {
            state.remaining_basis_micros
        };
        apply_measured(state, source, destination, basis, amount, proceeds);
        assert!(state.remaining_basis_micros > 0, E_FINAL_REQUIRED);
    }

    /// Consume the conclusive adapter return. `none` is an authenticated total
    /// loss; a short Coin derives loss and an excess Coin derives gain.
    public(package) fun finalize_reallocation<AdapterWitness, T>(
        state: &mut ReallocationState<T>,
        source: &mut OpportunityAccounting,
        destination: &mut OpportunityAccounting,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
    ) {
        assert_bound(state, source, destination);
        let proceeds = managed_position::consume_adapter_full_return(
            source,
            object::id(state),
            receipt,
        );
        let amount = if (option::is_some(&proceeds)) {
            coin::value(option::borrow(&proceeds)) as u128
        } else {
            0
        };
        let basis = state.remaining_basis_micros;
        let loss = if (basis > amount) basis - amount else 0;
        if (option::is_some(&proceeds)) {
            apply_measured(
                state,
                source,
                destination,
                basis,
                amount,
                option::destroy_some(proceeds),
            );
        } else {
            option::destroy_none(proceeds);
            managed_position::apply_measured_reallocation(source, basis, 0);
            state.remaining_basis_micros = 0;
        };
        state.realized_loss_micros = state.realized_loss_micros + loss;
        state.closed = true;
    }

    /// Destination-spoke partial returns are deliberately unsupported. Without
    /// contract custody, a partial Coin cannot be retained until the conclusive
    /// outcome is known; forwarding it could leave the final Coin too small to
    /// pay a legitimately derived aggregate fee. Abort before consuming the
    /// receipt or mutating accounting so the adapter can submit one conclusive
    /// receipt instead. No caller can crystallize a provisional gain.
    public(package) fun settle_destination_return_chunk<AdapterWitness, T>(
        _state: &mut ReallocationState<T>,
        _source: &mut OpportunityAccounting,
        _destination: &mut OpportunityAccounting,
        _receipt: AdapterReturnReceipt<AdapterWitness, T>,
    ) {
        abort E_FINAL_REQUIRED
    }

    /// Conclusively reconcile the destination spoke. `none` is an authenticated
    /// total loss; a short Coin derives loss and an excess Coin derives gain.
    /// This is the sole constructor of linear ReallocationReturnProceeds, so
    /// fee derivation and payment can happen only after the destination leg is
    /// conclusively closed. The returned Coin must be consumed by package code.
    public(package) fun finalize_destination_return<AdapterWitness, T>(
        state: &mut ReallocationState<T>,
        source: &mut OpportunityAccounting,
        destination: &mut OpportunityAccounting,
        receipt: AdapterReturnReceipt<AdapterWitness, T>,
    ): ReallocationReturnProceeds<T> {
        assert_destination_return_bound(state, source, destination);
        let proceeds = managed_position::consume_adapter_full_return(
            destination,
            object::id(state),
            receipt,
        );
        let amount = if (option::is_some(&proceeds)) {
            coin::value(option::borrow(&proceeds)) as u128
        } else {
            0
        };
        let basis = state.destination_deployed_micros;
        apply_destination_return(state, source, basis, amount);
        state.destination_return_closed = true;
        ReallocationReturnProceeds<T> {
            source_accounting_id: state.source_accounting_id,
            state_id: object::id(state),
            proceeds,
        }
    }

    public(package) fun consume_return_proceeds<T>(
        authenticated: ReallocationReturnProceeds<T>,
    ): (ID, ID, Option<Coin<T>>) {
        let ReallocationReturnProceeds {
            source_accounting_id,
            state_id,
            proceeds,
        } = authenticated;
        (source_accounting_id, state_id, proceeds)
    }

    fun apply_destination_return<T>(
        state: &mut ReallocationState<T>,
        source: &mut OpportunityAccounting,
        basis: u128,
        amount: u128,
    ) {
        managed_position::apply_measured_spoke_return(source, basis, amount);
        state.destination_deployed_micros = state.destination_deployed_micros - basis;
        state.destination_reconciled_micros = state.destination_reconciled_micros + amount;
        if (amount > basis) {
            state.realized_gain_micros = state.realized_gain_micros + (amount - basis);
        } else if (basis > amount) {
            state.realized_loss_micros = state.realized_loss_micros + (basis - amount);
        };
    }

    fun apply_measured<T>(
        state: &mut ReallocationState<T>,
        source: &mut OpportunityAccounting,
        destination: &mut OpportunityAccounting,
        basis: u128,
        amount: u128,
        proceeds: Coin<T>,
    ) {
        managed_position::apply_measured_reallocation(source, basis, amount);
        state.destination_deployed_micros = state.destination_deployed_micros + amount;
        state.remaining_basis_micros = state.remaining_basis_micros - basis;
        state.measured_return_micros = state.measured_return_micros + amount;
        if (amount > basis) {
            state.realized_gain_micros = state.realized_gain_micros + (amount - basis);
        };
        transfer::public_transfer(
            proceeds,
            managed_position::adapter_destination_for_package(destination),
        );
    }

    fun assert_bound<T>(
        state: &ReallocationState<T>,
        source: &OpportunityAccounting,
        destination: &OpportunityAccounting,
    ) {
        assert!(!state.closed, E_CLOSED);
        assert!(state.source_accounting_id == managed_position::accounting_id(source), E_WRONG_ENDPOINT);
        assert!(state.destination_accounting_id == managed_position::accounting_id(destination), E_WRONG_ENDPOINT);
        assert!(state.source_opportunity_id == managed_position::accounting_opportunity_id(source), E_WRONG_ENDPOINT);
        assert!(state.destination_opportunity_id == managed_position::accounting_opportunity_id(destination), E_WRONG_ENDPOINT);
        assert!(state.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ASSET);
        assert!(managed_position::accounting_asset(source) == state.accounting_asset, E_WRONG_ASSET);
        assert!(managed_position::accounting_asset(destination) == state.accounting_asset, E_WRONG_ASSET);
        assert!(managed_position::total_assets_micros(destination) == 0, E_WRONG_ENDPOINT);
        assert!(managed_position::total_shares(destination) == 0, E_WRONG_ENDPOINT);
        let source_guardrails = managed_position::accounting_guardrails_id(source);
        let destination_guardrails = managed_position::accounting_guardrails_id(destination);
        assert!(option::is_some(&source_guardrails), E_WRONG_POLICY);
        assert!(option::is_some(&destination_guardrails), E_WRONG_POLICY);
        assert!(*option::borrow(&source_guardrails) == state.guardrails_id, E_WRONG_POLICY);
        assert!(*option::borrow(&destination_guardrails) == state.guardrails_id, E_WRONG_POLICY);
        let source_hash = managed_position::accounting_guardrails_hash(source);
        let destination_hash = managed_position::accounting_guardrails_hash(destination);
        assert!(option::is_some(&source_hash), E_WRONG_POLICY);
        assert!(option::is_some(&destination_hash), E_WRONG_POLICY);
        assert!(*option::borrow(&source_hash) == state.guardrails_hash, E_WRONG_POLICY);
        assert!(*option::borrow(&destination_hash) == state.guardrails_hash, E_WRONG_POLICY);
        assert!(vector::length(&state.route_commitment) == ROUTE_COMMITMENT_LEN, E_INVALID_ROUTE);
    }

    fun assert_destination_return_bound<T>(
        state: &ReallocationState<T>,
        source: &OpportunityAccounting,
        destination: &OpportunityAccounting,
    ) {
        assert!(state.closed, E_FINAL_REQUIRED);
        assert!(!state.destination_return_closed, E_CLOSED);
        assert!(state.destination_deployed_micros > 0, E_CLOSED);
        assert!(state.source_accounting_id == managed_position::accounting_id(source), E_WRONG_ENDPOINT);
        assert!(state.destination_accounting_id == managed_position::accounting_id(destination), E_WRONG_ENDPOINT);
        assert!(state.source_opportunity_id == managed_position::accounting_opportunity_id(source), E_WRONG_ENDPOINT);
        assert!(state.destination_opportunity_id == managed_position::accounting_opportunity_id(destination), E_WRONG_ENDPOINT);
        assert!(state.accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ASSET);
        assert!(managed_position::accounting_asset(source) == state.accounting_asset, E_WRONG_ASSET);
        assert!(managed_position::accounting_asset(destination) == state.accounting_asset, E_WRONG_ASSET);
        assert!(managed_position::total_assets_micros(destination) == 0, E_WRONG_ENDPOINT);
        assert!(managed_position::total_shares(destination) == 0, E_WRONG_ENDPOINT);
        let source_guardrails = managed_position::accounting_guardrails_id(source);
        let destination_guardrails = managed_position::accounting_guardrails_id(destination);
        assert!(option::is_some(&source_guardrails), E_WRONG_POLICY);
        assert!(option::is_some(&destination_guardrails), E_WRONG_POLICY);
        assert!(*option::borrow(&source_guardrails) == state.guardrails_id, E_WRONG_POLICY);
        assert!(*option::borrow(&destination_guardrails) == state.guardrails_id, E_WRONG_POLICY);
        let source_hash = managed_position::accounting_guardrails_hash(source);
        let destination_hash = managed_position::accounting_guardrails_hash(destination);
        assert!(option::is_some(&source_hash), E_WRONG_POLICY);
        assert!(option::is_some(&destination_hash), E_WRONG_POLICY);
        assert!(*option::borrow(&source_hash) == state.guardrails_hash, E_WRONG_POLICY);
        assert!(*option::borrow(&destination_hash) == state.guardrails_hash, E_WRONG_POLICY);
        assert!(vector::length(&state.route_commitment) == ROUTE_COMMITMENT_LEN, E_INVALID_ROUTE);
    }

    public fun route_commitment<T>(state: &ReallocationState<T>): vector<u8> {
        state.route_commitment
    }
    public fun remaining_basis_micros<T>(state: &ReallocationState<T>): u128 {
        state.remaining_basis_micros
    }
    public fun realized_gain_micros<T>(state: &ReallocationState<T>): u128 {
        state.realized_gain_micros
    }
    public fun realized_loss_micros<T>(state: &ReallocationState<T>): u128 {
        state.realized_loss_micros
    }
    public fun destination_deployed_micros<T>(state: &ReallocationState<T>): u128 {
        state.destination_deployed_micros
    }
    public fun destination_reconciled_micros<T>(state: &ReallocationState<T>): u128 {
        state.destination_reconciled_micros
    }
    public fun destination_return_closed<T>(state: &ReallocationState<T>): bool {
        state.destination_return_closed
    }
    public fun closed<T>(state: &ReallocationState<T>): bool { state.closed }

    #[test_only]
    public fun destroy_for_testing<T>(state: ReallocationState<T>) {
        let ReallocationState {
            id,
            source_accounting_id: _, destination_accounting_id: _,
            source_opportunity_id: _, destination_opportunity_id: _,
            accounting_asset: _, guardrails_id: _, guardrails_hash: _,
            route_commitment: _, frozen_basis_micros: _, remaining_basis_micros: _,
            destination_deployed_micros: _,
            measured_return_micros: _, destination_reconciled_micros: _,
            realized_gain_micros: _, realized_loss_micros: _,
            closed: _, destination_return_closed: _,
        } = state;
        object::delete(id);
    }
}
