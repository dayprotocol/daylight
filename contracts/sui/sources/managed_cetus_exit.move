// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY-961 exact top-30d Cetus USDC/SUI managed position.
///
/// The universal exit never closes the Cetus Position NFT and never attempts
/// to instantiate a reward type from runtime TypeName metadata. Unknown future
/// reward claims therefore travel with the NFT to the immutable DAY owner.
module day::managed_cetus_exit {
    use cetusclmm::config::GlobalConfig;
    use cetusclmm::pool::{Self, Pool};
    use cetusclmm::position::{Self as cetus_position, Position as CetusPosition};
    use day::adapter_registry::{Self, AdapterRegistryV2, RegistryAdminCap};
    use day::day::ProtocolConfig;
    use day::guardrails_v2::GuardrailsV2;
    use day::leader_policy::LeaderPolicy;
    use day::managed_position::{Self, OpportunityAccounting, Position};
    use day::strategy_registry::{AdminCap as StrategyAdminCap, StrategyRegistry};
    use std::ascii;
    use std::type_name::{Self, TypeName};
    use sui::balance;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::sui::SUI;

    const TOP_30D_STRATEGY: vector<u8> = b"day-autopilot-top-30d-monthly";
    const TOP_30D_OPPORTUNITY: vector<u8> = b"dayope3465f1716";
    const TOP_30D_ADAPTER_ID: vector<u8> = b"cetus-usdc-sui-5bps";
    const TREASURY: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;
    const TOP_30D_POOL: address =
        @0x51e883ba7c0b566a26cbc8a94cd33eb0abd418a77cc1e60ad22fd9b1f29cd2ab;
    const CETUS_GLOBAL_CONFIG: address =
        @0xdaa46292632c3c4d8f31f23ea0f9b36a28ff3677e9684980e4438403a67a3d8f;
    const USDC_ORIGINAL_TYPE: vector<u8> =
        b"dba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";
    const FEE_RATE: u64 = 500;
    const TICK_SPACING: u32 = 10;
    // Reviewed one-sided-USDC range used by the measured Cetus proof. Crossing
    // the range can return SUI, which is why every exit is multi-asset.
    const TICK_LOWER: u32 = 72_070;
    const TICK_UPPER: u32 = 72_570;

    const E_WRONG_POOL: u64 = 1;
    const E_WRONG_FEE_RATE: u64 = 2;
    const E_WRONG_TICK_SPACING: u64 = 3;
    const E_POOL_PAUSED: u64 = 4;
    const E_WRONG_ASSET: u64 = 5;
    const E_WRONG_OPPORTUNITY: u64 = 6;
    const E_WRONG_STRATEGY: u64 = 7;
    const E_WRONG_ACCOUNTING: u64 = 8;
    const E_WRONG_POSITION: u64 = 9;
    const E_NOT_ONE_SIDED_USDC: u64 = 10;
    const E_ZERO_LIQUIDITY: u64 = 11;
    const E_MINIMUM_RETURN: u64 = 12;
    const E_WRONG_CETUS_POSITION: u64 = 13;
    const E_WRONG_CONFIG: u64 = 14;

    /// Unforgeable reviewed adapter identity bound in AdapterRegistryV2.
    public struct CetusTop30Adapter has drop {}

    /// Owner-held DAY/Cetus binding. The venue NFT remains linear inside this
    /// object until normal liquidation or the pool-independent emergency exit.
    public struct ManagedCetusClaim<phantom Principal, Residual: key + store> has key {
        id: UID,
        accounting_id: ID,
        day_position_id: ID,
        day_position_shares: u128,
        opportunity_id: vector<u8>,
        strategy_id: vector<u8>,
        pool_id: ID,
        cost_basis_micros: u128,
        adapter_nonce: u64,
        tick_lower: u32,
        tick_upper: u32,
        measured_liquidity: u128,
        cetus_position_id: ID,
        residual: Residual,
    }

    public struct ManagedCetusClaimCreated has copy, drop {
        claim_id: ID,
        accounting_id: ID,
        day_position_id: ID,
        day_position_shares: u128,
        pool_id: ID,
        cetus_position_id: ID,
        cost_basis_micros: u128,
        adapter_nonce: u64,
        measured_liquidity: u128,
        owner: address,
    }

    public struct OwnerInKindExitRecorded has copy, drop {
        accounting_id: ID,
        day_position_id: ID,
        claim_id: ID,
        pool_id: ID,
        cetus_position_id: ID,
        cost_basis_micros: u128,
        primary_type: TypeName,
        primary_amount: u64,
        secondary_type: TypeName,
        secondary_amount: u64,
        residual_type: TypeName,
        payout_destination: address,
        residual_nft_transferred: bool,
        residual_may_hold_rewards_or_principal: bool,
        emergency: bool,
        deployment_adapter_nonce: u64,
        terminal_adapter_nonce: u64,
    }

    /// Register the only byte id this package accepts for the reviewed top-30d
    /// witness. The generic registry mutator remains useful for other adapters;
    /// this wrapper removes caller-selected identity from this money path.
    public fun register_top30_adapter(
        admin_cap: &RegistryAdminCap,
        adapters: &mut AdapterRegistryV2,
    ) {
        adapter_registry::register_authenticated(
            admin_cap,
            adapters,
            TOP_30D_ADAPTER_ID,
            b"sui",
            b"DAY top-30d Cetus USDC/SUI 5bps",
        )
    }

    /// Create the sole accounting shape accepted by this adapter. FeeConfig v2
    /// has managed performance fees off (0/0); nonzero destinations are still
    /// pinned to treasury because the generic accounting schema requires them.
    public fun create_top30_accounting<Principal>(
        protocol_config: &ProtocolConfig,
        strategy_registry: &StrategyRegistry,
        admin_cap: &StrategyAdminCap,
        adapters: &AdapterRegistryV2,
        guardrails: &GuardrailsV2,
        ctx: &mut TxContext,
    ): ID {
        assert_usdc<Principal>();
        managed_position::create_managed_accounting<CetusTop30Adapter, Principal>(
            protocol_config,
            strategy_registry,
            admin_cap,
            adapters,
            guardrails,
            TOP_30D_STRATEGY,
            TOP_30D_OPPORTUNITY,
            b"sui",
            vector[],
            TOP_30D_ADAPTER_ID,
            0,
            0,
            TREASURY,
            TREASURY,
            TREASURY,
            ctx,
        )
    }

    /// Exact pool-pinned managed deposit. The same Coin measured by DAY is
    /// consumed by Cetus add-liquidity; no caller supplies an amount, pool,
    /// opportunity, destination, NAV, price, profit, or loss.
    public fun deposit_top30_usdc<Principal>(
        accounting: &mut OpportunityAccounting,
        protocol_config: &ProtocolConfig,
        strategy_registry: &StrategyRegistry,
        guardrails: &GuardrailsV2,
        adapters: &AdapterRegistryV2,
        policy: &LeaderPolicy,
        cetus_config: &GlobalConfig,
        cetus_pool: &mut Pool<Principal, SUI>,
        clock: &Clock,
        allocation_bps: u64,
        principal: Coin<Principal>,
        ctx: &mut TxContext,
    ): (ID, ID) {
        assert_usdc<Principal>();
        managed_position::assert_exact_adapter_binding<CetusTop30Adapter, Principal>(
            accounting,
            TOP_30D_ADAPTER_ID,
        );
        assert_config(cetus_config);
        assert_pool(cetus_pool);
        let cost_basis = coin::value(&principal);
        let shares_before = managed_position::total_shares(accounting);
        let (day_position_id, in_flight) = managed_position::record_managed_local_deposit(
            accounting,
            protocol_config,
            strategy_registry,
            guardrails,
            adapters,
            policy,
            allocation_bps,
            principal,
            ctx,
        );
        let day_position_shares = managed_position::total_shares(accounting) - shares_before;
        let witness = CetusTop30Adapter {};
        let receipt = managed_position::attest_adapter_deployment(
            accounting,
            protocol_config,
            strategy_registry,
            guardrails,
            adapters,
            &witness,
            allocation_bps,
            in_flight,
        );
        let in_flight = managed_position::record_measured_deployment(accounting, receipt);

        let mut venue_position = pool::open_position(
            cetus_config,
            cetus_pool,
            TICK_LOWER,
            TICK_UPPER,
            ctx,
        );
        let add_receipt = pool::add_liquidity_fix_coin(
            cetus_config,
            cetus_pool,
            &mut venue_position,
            cost_basis,
            true,
            clock,
        );
        let (required_usdc, required_sui) = pool::add_liquidity_pay_amount(&add_receipt);
        assert!(required_usdc == cost_basis && required_sui == 0, E_NOT_ONE_SIDED_USDC);
        pool::repay_add_liquidity(
            cetus_config,
            cetus_pool,
            coin::into_balance(in_flight),
            balance::zero<SUI>(),
            add_receipt,
        );
        let measured_liquidity = cetus_position::liquidity(&venue_position);
        assert!(measured_liquidity > 0, E_ZERO_LIQUIDITY);
        let claim = bind_claim_internal<Principal, CetusPosition>(
            accounting,
            day_position_id,
            day_position_shares,
            cost_basis as u128,
            TICK_LOWER,
            TICK_UPPER,
            measured_liquidity,
            object::id(&venue_position),
            venue_position,
            ctx,
        );
        let claim_id = object::id(&claim);
        transfer::transfer(claim, tx_context::sender(ctx));
        (day_position_id, claim_id)
    }

    /// Normal owner exit. It removes all measured liquidity and collects only
    /// the two statically known pool assets. Reward claims of any current or
    /// future type remain on the residual NFT transferred to the DAY owner.
    public fun normal_full_exit<Principal>(
        accounting: &mut OpportunityAccounting,
        day_position: &mut Position,
        claim: ManagedCetusClaim<Principal, CetusPosition>,
        cetus_config: &GlobalConfig,
        cetus_pool: &mut Pool<Principal, SUI>,
        clock: &Clock,
        min_principal: u64,
        min_sui: u64,
        ctx: &mut TxContext,
    ) {
        assert_usdc<Principal>();
        assert_config(cetus_config);
        assert_pool(cetus_pool);
        assert_claim(&claim, accounting, day_position);
        assert!(cetus_position::pool_id(&claim.residual) == object::id(cetus_pool), E_WRONG_POOL);
        assert!(cetus_position::liquidity(&claim.residual) == claim.measured_liquidity, E_WRONG_CETUS_POSITION);
        let ManagedCetusClaim {
            id,
            accounting_id: _,
            day_position_id: _,
            day_position_shares: _,
            opportunity_id: _,
            strategy_id: _,
            pool_id: _,
            cost_basis_micros,
            adapter_nonce,
            tick_lower: _,
            tick_upper: _,
            measured_liquidity,
            cetus_position_id,
            residual: mut venue_position,
        } = claim;
        let claim_id = object::uid_to_inner(&id);
        let (mut principal_balance, mut sui_balance) = pool::remove_liquidity(
            cetus_config,
            cetus_pool,
            &mut venue_position,
            measured_liquidity,
            clock,
        );
        let (principal_fees, sui_fees) = pool::collect_fee(
            cetus_config,
            cetus_pool,
            &venue_position,
            false,
        );
        balance::join(&mut principal_balance, principal_fees);
        balance::join(&mut sui_balance, sui_fees);
        let principal_amount = balance::value(&principal_balance);
        let sui_amount = balance::value(&sui_balance);
        assert!(principal_amount >= min_principal && sui_amount >= min_sui, E_MINIMUM_RETURN);
        object::delete(id);
        settle_with_assets<Principal, SUI, CetusPosition>(
            accounting,
            day_position,
            claim_id,
            cetus_position_id,
            cost_basis_micros,
            adapter_nonce,
            coin::from_balance(principal_balance, ctx),
            coin::from_balance(sui_balance, ctx),
            venue_position,
            true,
            false,
            ctx,
        )
    }

    /// Pool-independent universal escape. No Cetus object/function, registry,
    /// policy, leader, lifecycle, reward vault, clock, price, or recipient is
    /// accepted. The still-funded NFT itself returns to the recorded DAY owner.
    public fun emergency_exit<Principal>(
        accounting: &mut OpportunityAccounting,
        day_position: &mut Position,
        claim: ManagedCetusClaim<Principal, CetusPosition>,
        ctx: &mut TxContext,
    ) {
        assert_usdc<Principal>();
        assert_claim(&claim, accounting, day_position);
        let ManagedCetusClaim {
            id,
            accounting_id: _,
            day_position_id: _,
            day_position_shares: _,
            opportunity_id: _,
            strategy_id: _,
            pool_id: _,
            cost_basis_micros,
            adapter_nonce,
            tick_lower: _,
            tick_upper: _,
            measured_liquidity: _,
            cetus_position_id,
            residual,
        } = claim;
        let claim_id = object::uid_to_inner(&id);
        object::delete(id);
        settle_residual_only<Principal, CetusPosition>(
            accounting,
            day_position,
            claim_id,
            cetus_position_id,
            cost_basis_micros,
            adapter_nonce,
            residual,
            ctx,
        )
    }

    fun assert_pool<Principal>(cetus_pool: &Pool<Principal, SUI>) {
        assert!(object::id(cetus_pool) == object::id_from_address(TOP_30D_POOL), E_WRONG_POOL);
        assert!(pool::fee_rate(cetus_pool) == FEE_RATE, E_WRONG_FEE_RATE);
        assert!(pool::tick_spacing(cetus_pool) == TICK_SPACING, E_WRONG_TICK_SPACING);
        assert!(!pool::is_pause(cetus_pool), E_POOL_PAUSED);
    }

    fun assert_config(cetus_config: &GlobalConfig) {
        assert!(object::id(cetus_config) == object::id_from_address(CETUS_GLOBAL_CONFIG), E_WRONG_CONFIG);
    }

    fun assert_usdc<Principal>() {
        let name = ascii::into_bytes(type_name::into_string(
            type_name::with_original_ids<Principal>(),
        ));
        assert!(name == USDC_ORIGINAL_TYPE, E_WRONG_ASSET);
    }

    fun bind_claim_internal<Principal, Residual: key + store>(
        accounting: &OpportunityAccounting,
        day_position_id: ID,
        day_position_shares: u128,
        cost_basis_micros: u128,
        tick_lower: u32,
        tick_upper: u32,
        measured_liquidity: u128,
        cetus_position_id: ID,
        residual: Residual,
        ctx: &mut TxContext,
    ): ManagedCetusClaim<Principal, Residual> {
        assert!(managed_position::accounting_opportunity_id(accounting) == TOP_30D_OPPORTUNITY, E_WRONG_OPPORTUNITY);
        assert!(managed_position::accounting_strategy_id(accounting) == option::some(TOP_30D_STRATEGY), E_WRONG_STRATEGY);
        assert!(managed_position::deployed_assets_micros(accounting) >= cost_basis_micros, E_WRONG_ACCOUNTING);
        let claim = ManagedCetusClaim {
            id: object::new(ctx),
            accounting_id: managed_position::accounting_id(accounting),
            day_position_id,
            day_position_shares,
            opportunity_id: TOP_30D_OPPORTUNITY,
            strategy_id: TOP_30D_STRATEGY,
            pool_id: object::id_from_address(TOP_30D_POOL),
            cost_basis_micros,
            adapter_nonce: managed_position::adapter_nonce_for_package(accounting),
            tick_lower,
            tick_upper,
            measured_liquidity,
            cetus_position_id,
            residual,
        };
        event::emit(ManagedCetusClaimCreated {
            claim_id: object::id(&claim),
            accounting_id: claim.accounting_id,
            day_position_id,
            day_position_shares,
            pool_id: claim.pool_id,
            cetus_position_id,
            cost_basis_micros,
            adapter_nonce: claim.adapter_nonce,
            measured_liquidity,
            owner: tx_context::sender(ctx),
        });
        claim
    }

    fun assert_claim<Principal, Residual: key + store>(
        claim: &ManagedCetusClaim<Principal, Residual>,
        accounting: &OpportunityAccounting,
        day_position: &Position,
    ) {
        assert!(claim.accounting_id == managed_position::accounting_id(accounting), E_WRONG_ACCOUNTING);
        assert!(claim.day_position_id == object::id(day_position), E_WRONG_POSITION);
        assert!(claim.day_position_shares == managed_position::position_shares(day_position), E_WRONG_POSITION);
        assert!(managed_position::leg_accounting_id(day_position) == claim.accounting_id, E_WRONG_ACCOUNTING);
        assert!(claim.opportunity_id == TOP_30D_OPPORTUNITY, E_WRONG_OPPORTUNITY);
        assert!(claim.strategy_id == TOP_30D_STRATEGY, E_WRONG_STRATEGY);
        assert!(claim.pool_id == object::id_from_address(TOP_30D_POOL), E_WRONG_POOL);
        assert!(claim.cetus_position_id == object::id(&claim.residual), E_WRONG_CETUS_POSITION);
        assert!(claim.tick_lower == TICK_LOWER && claim.tick_upper == TICK_UPPER, E_WRONG_TICK_SPACING);
    }

    fun settle_with_assets<Principal, Secondary, Residual: key + store>(
        accounting: &mut OpportunityAccounting,
        day_position: &mut Position,
        claim_id: ID,
        cetus_position_id: ID,
        cost_basis_micros: u128,
        adapter_nonce: u64,
        primary: Coin<Principal>,
        secondary: Coin<Secondary>,
        residual: Residual,
        residual_may_hold_rewards_or_principal: bool,
        emergency: bool,
        ctx: &TxContext,
    ) {
        let primary_amount = coin::value(&primary);
        let secondary_amount = coin::value(&secondary);
        let witness = CetusTop30Adapter {};
        let payout = managed_position::authorize_full_owner_in_kind_exit<CetusTop30Adapter, Principal>(
            accounting,
            day_position,
            &witness,
            cost_basis_micros,
            ctx,
        );
        let (
            day_position_id,
            accounting_id,
            destination,
            _shares,
            removed_basis,
            terminal_adapter_nonce,
        ) = managed_position::consume_in_kind_owner_payout<Principal>(payout);
        event::emit(OwnerInKindExitRecorded {
            accounting_id,
            day_position_id,
            claim_id,
            pool_id: object::id_from_address(TOP_30D_POOL),
            cetus_position_id,
            cost_basis_micros: removed_basis,
            primary_type: type_name::with_original_ids<Principal>(),
            primary_amount,
            secondary_type: type_name::with_original_ids<Secondary>(),
            secondary_amount,
            residual_type: type_name::with_original_ids<Residual>(),
            payout_destination: destination,
            residual_nft_transferred: true,
            residual_may_hold_rewards_or_principal,
            emergency,
            deployment_adapter_nonce: adapter_nonce,
            terminal_adapter_nonce,
        });
        transfer::public_transfer(primary, destination);
        transfer::public_transfer(secondary, destination);
        transfer::public_transfer(residual, destination);
    }

    fun settle_residual_only<Principal, Residual: key + store>(
        accounting: &mut OpportunityAccounting,
        day_position: &mut Position,
        claim_id: ID,
        cetus_position_id: ID,
        cost_basis_micros: u128,
        adapter_nonce: u64,
        residual: Residual,
        ctx: &TxContext,
    ) {
        let witness = CetusTop30Adapter {};
        let payout = managed_position::authorize_full_owner_in_kind_exit<CetusTop30Adapter, Principal>(
            accounting,
            day_position,
            &witness,
            cost_basis_micros,
            ctx,
        );
        let (
            day_position_id,
            accounting_id,
            destination,
            _shares,
            removed_basis,
            terminal_adapter_nonce,
        ) = managed_position::consume_in_kind_owner_payout<Principal>(payout);
        event::emit(OwnerInKindExitRecorded {
            accounting_id,
            day_position_id,
            claim_id,
            pool_id: object::id_from_address(TOP_30D_POOL),
            cetus_position_id,
            cost_basis_micros: removed_basis,
            primary_type: type_name::with_original_ids<Principal>(),
            primary_amount: 0,
            secondary_type: type_name::with_original_ids<SUI>(),
            secondary_amount: 0,
            residual_type: type_name::with_original_ids<Residual>(),
            payout_destination: destination,
            residual_nft_transferred: true,
            residual_may_hold_rewards_or_principal: true,
            emergency: true,
            deployment_adapter_nonce: adapter_nonce,
            terminal_adapter_nonce,
        });
        transfer::public_transfer(residual, destination);
    }

    #[test_only]
    public fun witness_for_testing(): CetusTop30Adapter { CetusTop30Adapter {} }

    #[test_only]
    public fun bind_claim_for_testing<Principal, Residual: key + store>(
        accounting: &OpportunityAccounting,
        day_position: &Position,
        cost_basis_micros: u128,
        residual: Residual,
        ctx: &mut TxContext,
    ): ManagedCetusClaim<Principal, Residual> {
        assert!(managed_position::position_value_micros(accounting, day_position)
            == cost_basis_micros, E_WRONG_ACCOUNTING);
        bind_claim_internal(
            accounting,
            object::id(day_position),
            managed_position::position_shares(day_position),
            cost_basis_micros,
            TICK_LOWER,
            TICK_UPPER,
            1,
            object::id(&residual),
            residual,
            ctx,
        )
    }

    #[test_only]
    public fun normal_exit_for_testing<Principal, Secondary, Residual: key + store>(
        accounting: &mut OpportunityAccounting,
        day_position: &mut Position,
        claim: ManagedCetusClaim<Principal, Residual>,
        primary: Coin<Principal>,
        secondary: Coin<Secondary>,
        ctx: &TxContext,
    ) {
        assert_claim(&claim, accounting, day_position);
        let ManagedCetusClaim {
            id,
            accounting_id: _, day_position_id: _, day_position_shares: _, opportunity_id: _, strategy_id: _, pool_id: _,
            cost_basis_micros, adapter_nonce, tick_lower: _, tick_upper: _, measured_liquidity: _,
            cetus_position_id, residual,
        } = claim;
        let claim_id = object::uid_to_inner(&id);
        object::delete(id);
        settle_with_assets(
            accounting, day_position, claim_id, cetus_position_id, cost_basis_micros,
            adapter_nonce, primary, secondary, residual, true, false, ctx,
        )
    }

    #[test_only]
    public fun emergency_exit_for_testing<Principal, Residual: key + store>(
        accounting: &mut OpportunityAccounting,
        day_position: &mut Position,
        claim: ManagedCetusClaim<Principal, Residual>,
        ctx: &TxContext,
    ) {
        assert_claim(&claim, accounting, day_position);
        let ManagedCetusClaim {
            id,
            accounting_id: _, day_position_id: _, day_position_shares: _, opportunity_id: _, strategy_id: _, pool_id: _,
            cost_basis_micros, adapter_nonce, tick_lower: _, tick_upper: _, measured_liquidity: _,
            cetus_position_id, residual,
        } = claim;
        let claim_id = object::uid_to_inner(&id);
        object::delete(id);
        settle_residual_only<Principal, Residual>(
            accounting, day_position, claim_id, cetus_position_id,
            cost_basis_micros, adapter_nonce, residual, ctx,
        )
    }
}
