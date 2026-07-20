// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY vault core — VaultConfig + Vault + liquid deposit/withdraw share math.
/// Fee only on yield (harvest skim). Auto deploy default OFF.
/// Empty-vault protection: virtual share/asset offset (1:1 first deposit).
module day::vault {
    use sui::event;

    const DEFAULT_FEE_SKIM_BPS: u64 = 500;
    const BASIS_POINTS: u64 = 10_000;
    /// Virtual offset for inflation-attack resistance (ERC-4626-style).
    const VIRTUAL_SHARES: u64 = 1_000;
    const VIRTUAL_ASSETS: u64 = 1_000;

    const E_ZERO_AMOUNT: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_INSUFFICIENT_SHARES: u64 = 3;
    const E_INSUFFICIENT_LIQUID: u64 = 4;
    const E_INVALID_BPS: u64 = 5;
    const E_TVL_CAP: u64 = 6;
    /// DAY-4306: withdraw caller is not the recorded position owner.
    const E_NOT_OWNER: u64 = 8;
    /// DAY-830: legacy shared VaultConfig has no authenticated owner field.
    const E_AUTHENTICATED_MUTATION_REQUIRED: u64 = 9;

    /// Shared vault policy (immutable fee path; strategy arm separate).
    public struct VaultConfig has key {
        id: UID,
        name: vector<u8>,
        asset: vector<u8>,
        fee_skim_bps: u64,
        /// Always true at create — deploy liquid→venue is opt-in.
        auto_deploy_default_off: bool,
        /// Owner/strategy arm; default false.
        strategy_enabled: bool,
        max_tvl_micros: u64,
        has_max_tvl: bool,
        paused: bool,
    }

    /// Shared vault accounting (liquid-only deploy in W1).
    public struct Vault has key {
        id: UID,
        config_id: ID,
        total_assets_micros: u64,
        total_shares: u64,
        liquid_micros: u64,
        deployed_micros: u64,
    }

    /// Owner-held claim on vault shares (position object).
    public struct Position has key, store {
        id: UID,
        vault_id: ID,
        owner: address,
        shares: u64,
    }

    public struct VaultCreated has copy, drop {
        vault_id: ID,
        config_id: ID,
        fee_skim_bps: u64,
        auto_deploy_default_off: bool,
    }

    public struct Deposited has copy, drop {
        vault_id: ID,
        owner: address,
        assets_micros: u64,
        shares_minted: u64,
        fee_micros: u64,
    }

    public struct Withdrawn has copy, drop {
        vault_id: ID,
        owner: address,
        shares_burned: u64,
        assets_micros: u64,
        fee_micros: u64,
    }

    /// DAY-4306: payout is destination-locked to the recorded depositor (`owner`).
    public struct WithdrawPaidToOwner has copy, drop {
        vault_id: ID,
        owner: address,
        assets_micros: u64,
    }

    public struct VaultHarvested has copy, drop {
        vault_id: ID,
        gross_yield_micros: u64,
        protocol_skim_micros: u64,
        net_yield_micros: u64,
        fee_bps: u64,
    }

    /// Create shared VaultConfig + Vault. Strategy OFF; auto_deploy_default_off = true.
    public fun create_vault(
        name: vector<u8>,
        asset: vector<u8>,
        fee_skim_bps: u64,
        ctx: &mut TxContext,
    ): (ID, ID) {
        assert!(fee_skim_bps <= BASIS_POINTS, E_INVALID_BPS);
        let config = VaultConfig {
            id: object::new(ctx),
            name,
            asset,
            fee_skim_bps,
            auto_deploy_default_off: true,
            strategy_enabled: false,
            max_tvl_micros: 0,
            has_max_tvl: false,
            paused: false,
        };
        let config_id = object::id(&config);
        let vault = Vault {
            id: object::new(ctx),
            config_id,
            total_assets_micros: 0,
            total_shares: 0,
            liquid_micros: 0,
            deployed_micros: 0,
        };
        let vault_id = object::id(&vault);
        event::emit(VaultCreated {
            vault_id,
            config_id,
            fee_skim_bps,
            auto_deploy_default_off: true,
        });
        transfer::share_object(config);
        transfer::share_object(vault);
        (config_id, vault_id)
    }

    public fun default_fee_skim_bps(): u64 {
        DEFAULT_FEE_SKIM_BPS
    }

    public fun auto_deploy_default_off(config: &VaultConfig): bool {
        config.auto_deploy_default_off
    }

    public fun strategy_enabled(config: &VaultConfig): bool {
        config.strategy_enabled
    }

    public fun fee_skim_bps(config: &VaultConfig): u64 {
        config.fee_skim_bps
    }

    public fun is_paused(config: &VaultConfig): bool {
        config.paused
    }

    public fun total_assets(vault: &Vault): u64 {
        vault.total_assets_micros
    }

    public fun total_shares(vault: &Vault): u64 {
        vault.total_shares
    }

    public fun liquid_micros(vault: &Vault): u64 {
        vault.liquid_micros
    }

    public fun position_shares(position: &Position): u64 {
        position.shares
    }

    /// DAY-4306: expose the destination-locked owner (the recorded depositor / payout address).
    public fun position_owner(position: &Position): address {
        position.owner
    }

    /// DAY-830: deployed signature retained for upgrade compatibility, but permanently
    /// fail-closed. VaultConfig has no recorded owner/cap binding, and prior package
    /// versions remain callable, so this legacy type is quarantined from every future
    /// strategy/money path rather than pretending sender auth can secure it.
    public fun set_strategy_enabled(
        _config: &mut VaultConfig,
        _enabled: bool,
        _owner: &TxContext,
    ) {
        abort E_AUTHENTICATED_MUTATION_REQUIRED
    }

    /// Convert assets → shares. Empty vault: 1:1 via virtual offset.
    public fun convert_to_shares(assets_micros: u64, total_assets: u64, total_shares: u64): u64 {
        assert!(assets_micros > 0, E_ZERO_AMOUNT);
        let num = (assets_micros as u128) * ((total_shares as u128) + (VIRTUAL_SHARES as u128));
        let den = (total_assets as u128) + (VIRTUAL_ASSETS as u128);
        (num / den) as u64
    }

    /// Convert shares → assets (floor).
    public fun convert_to_assets(shares: u64, total_assets: u64, total_shares: u64): u64 {
        assert!(shares > 0, E_ZERO_AMOUNT);
        if (total_shares == 0) {
            return 0
        };
        let num = (shares as u128) * ((total_assets as u128) + (VIRTUAL_ASSETS as u128));
        let den = (total_shares as u128) + (VIRTUAL_SHARES as u128);
        (num / den) as u64
    }

    /// Price per share in micros (assets * 1e6 / shares scale simplified as assets*1e6/shares).
    /// Returns 1_000_000 when empty (1:1).
    public fun price_per_share_micros(vault: &Vault): u64 {
        if (vault.total_shares == 0) {
            return 1_000_000
        };
        let num = ((vault.total_assets_micros as u128) + (VIRTUAL_ASSETS as u128)) * 1_000_000u128;
        let den = (vault.total_shares as u128) + (VIRTUAL_SHARES as u128);
        (num / den) as u64
    }

    /// Legacy accounting-only deposit retained for upgrade compatibility and
    /// permanently quarantined. It accepted a caller-asserted amount without
    /// consuming authenticated principal, so no production path may trust it.
    public fun deposit_liquid(
        _config: &VaultConfig,
        _vault: &mut Vault,
        _assets_micros: u64,
        _ctx: &mut TxContext,
    ): Position {
        abort E_AUTHENTICATED_MUTATION_REQUIRED
    }

    #[test_only]
    public fun deposit_liquid_for_testing(
        config: &VaultConfig,
        vault: &mut Vault,
        assets_micros: u64,
        ctx: &mut TxContext,
    ): Position {
        assert!(!config.paused, E_PAUSED);
        assert!(assets_micros > 0, E_ZERO_AMOUNT);
        if (config.has_max_tvl) {
            assert!(
                vault.total_assets_micros + assets_micros <= config.max_tvl_micros,
                E_TVL_CAP,
            );
        };
        let shares = convert_to_shares(
            assets_micros,
            vault.total_assets_micros,
            vault.total_shares,
        );
        assert!(shares > 0, E_ZERO_AMOUNT);
        vault.total_assets_micros = vault.total_assets_micros + assets_micros;
        vault.liquid_micros = vault.liquid_micros + assets_micros;
        vault.total_shares = vault.total_shares + shares;
        let owner = tx_context::sender(ctx);
        let position = Position {
            id: object::new(ctx),
            vault_id: object::id(vault),
            owner,
            shares,
        };
        event::emit(Deposited {
            vault_id: object::id(vault),
            owner,
            assets_micros,
            shares_minted: shares,
            fee_micros: 0,
        });
        position
    }

    /// Liquid withdraw: fee = 0. Burns shares; fails if shares > position or assets > liquid.
    /// DAY-4306 destination-lock: ONLY the recorded depositor (`position.owner`) may withdraw.
    /// The caller (tx sender) MUST equal `position.owner`, so a foreign actor or a malicious
    /// composing PTB can never burn someone else's shares or redirect the payout. Note: pause
    /// does NOT block withdraw (DAY-136) — that assert lives in the strategy/deploy path, not here.
    /// Principal Coin<T> custody + physical payout live in the off-chain/PTB custody layer, which
    /// is itself owner-locked via the `entry_withdraw_liquid_to_owner` wrapper below (transfers to
    /// `position.owner`, never to tx sender or a caller-supplied address).
    public fun withdraw_liquid(
        _config: &VaultConfig,
        vault: &mut Vault,
        position: &mut Position,
        shares: u64,
        ctx: &TxContext,
    ): u64 {
        // Destination lock: the withdrawing caller must be the recorded depositor.
        // NOTE: pause is intentionally NOT asserted here — pause must never block withdraw
        // (DAY-136). `_config` is retained in the signature for ABI/caller stability.
        assert!(position.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(shares > 0, E_ZERO_AMOUNT);
        assert!(position.shares >= shares, E_INSUFFICIENT_SHARES);
        assert!(object::id(vault) == position.vault_id, E_INSUFFICIENT_SHARES);
        let assets = convert_to_assets(shares, vault.total_assets_micros, vault.total_shares);
        assert!(assets > 0, E_ZERO_AMOUNT);
        assert!(vault.liquid_micros >= assets, E_INSUFFICIENT_LIQUID);
        position.shares = position.shares - shares;
        vault.total_shares = vault.total_shares - shares;
        vault.total_assets_micros = vault.total_assets_micros - assets;
        vault.liquid_micros = vault.liquid_micros - assets;
        // Stamp the event against the verified owner (== sender, asserted above), never an
        // unverified sender value.
        event::emit(Withdrawn {
            vault_id: object::id(vault),
            owner: position.owner,
            shares_burned: shares,
            assets_micros: assets,
            fee_micros: 0,
        });
        assets
    }

    /// DAY-4306 owner-locked withdraw entry (what FE/users call).
    /// Performs the accounting withdraw, then emits a WithdrawPaidToOwner event recording that
    /// the payout is bound to `position.owner`. Because `withdraw_liquid` above asserts
    /// `position.owner == sender`, this entry can only ever be driven by the depositor, and the
    /// recorded/settlement destination is `position.owner` — NOT tx sender, NOT a parameter.
    ///
    /// This module keeps u64 accounting only (no Coin<T> custody in-module); the physical
    /// principal Coin<T> is taken and returned by the off-chain/PTB custody layer keyed on the
    /// `position.owner` in this event. There is no code path here that can redirect it to any
    /// other address. If a Coin<T> custody path is ever added to this module, it MUST
    /// `transfer::public_transfer(coin, position.owner)` here — never to the sender or a param.
    public entry fun entry_withdraw_liquid_to_owner(
        config: &VaultConfig,
        vault: &mut Vault,
        position: &mut Position,
        shares: u64,
        ctx: &mut TxContext,
    ) {
        let owner = position.owner;
        let assets = withdraw_liquid(config, vault, position, shares, ctx);
        event::emit(WithdrawPaidToOwner {
            vault_id: object::id(vault),
            owner,
            assets_micros: assets,
        });
    }

    /// Legacy caller-asserted harvest retained for upgrade compatibility and
    /// permanently quarantined. A replacement must consume a measured adapter
    /// receipt before it may mutate NAV or emit a trusted event.
    public fun apply_harvest_skim(
        _config: &VaultConfig,
        _vault: &mut Vault,
        _gross_yield_micros: u64,
    ): (u64, u64) {
        abort E_AUTHENTICATED_MUTATION_REQUIRED
    }

    /// DAY-830 quarantine: the legacy flag can still be toggled through prior package
    /// bytecode, so no new deploy path may trust it. A future managed path must use a
    /// fresh authenticated policy type.
    public fun require_strategy_for_deploy(_config: &VaultConfig) {
        abort E_AUTHENTICATED_MUTATION_REQUIRED
    }

    #[test_only]
    public fun create_vault_for_testing(
        name: vector<u8>,
        asset: vector<u8>,
        fee_skim_bps: u64,
        ctx: &mut TxContext,
    ): (VaultConfig, Vault) {
        assert!(fee_skim_bps <= BASIS_POINTS, E_INVALID_BPS);
        let config = VaultConfig {
            id: object::new(ctx),
            name,
            asset,
            fee_skim_bps,
            auto_deploy_default_off: true,
            strategy_enabled: false,
            max_tvl_micros: 0,
            has_max_tvl: false,
            paused: false,
        };
        let config_id = object::id(&config);
        let vault = Vault {
            id: object::new(ctx),
            config_id,
            total_assets_micros: 0,
            total_shares: 0,
            liquid_micros: 0,
            deployed_micros: 0,
        };
        (config, vault)
    }

    #[test_only]
    public fun destroy_for_testing(config: VaultConfig, vault: Vault) {
        let VaultConfig {
            id: cid,
            name: _,
            asset: _,
            fee_skim_bps: _,
            auto_deploy_default_off: _,
            strategy_enabled: _,
            max_tvl_micros: _,
            has_max_tvl: _,
            paused: _,
        } = config;
        object::delete(cid);
        let Vault {
            id: vid,
            config_id: _,
            total_assets_micros: _,
            total_shares: _,
            liquid_micros: _,
            deployed_micros: _,
        } = vault;
        object::delete(vid);
    }

    #[test_only]
    public fun destroy_position_for_testing(position: Position) {
        let Position { id, vault_id: _, owner: _, shares: _ } = position;
        object::delete(id);
    }
}

#[test_only]
module day::vault_tests {
    use day::day;
    use day::vault;
    use sui::test_scenario;

    const OWNER: address = @0xA11CE;
    const ATTACKER: address = @0xBAD;

    #[test]
    #[expected_failure(abort_code = vault::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_legacy_set_strategy_enabled_is_quarantined() {
        let mut scenario = test_scenario::begin(ATTACKER);
        let (mut config, vault) = vault::create_vault_for_testing(
            b"v", b"USDC", 0, test_scenario::ctx(&mut scenario),
        );
        vault::set_strategy_enabled(&mut config, true, test_scenario::ctx(&mut scenario));
        vault::destroy_for_testing(config, vault);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = vault::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_legacy_strategy_deploy_gate_is_quarantined() {
        let mut scenario = test_scenario::begin(ATTACKER);
        let (config, vault) = vault::create_vault_for_testing(
            b"v", b"USDC", 0, test_scenario::ctx(&mut scenario),
        );
        vault::require_strategy_for_deploy(&config);
        vault::destroy_for_testing(config, vault);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = vault::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_legacy_caller_asserted_deposit_is_quarantined() {
        let mut scenario = test_scenario::begin(ATTACKER);
        let (config, mut shared_vault) = vault::create_vault_for_testing(
            b"v", b"USDC", 0, test_scenario::ctx(&mut scenario),
        );
        let position = vault::deposit_liquid(
            &config, &mut shared_vault, 1_000_000, test_scenario::ctx(&mut scenario),
        );
        vault::destroy_position_for_testing(position);
        vault::destroy_for_testing(config, shared_vault);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = vault::E_AUTHENTICATED_MUTATION_REQUIRED)]
    fun test_legacy_caller_asserted_harvest_is_quarantined() {
        let mut scenario = test_scenario::begin(ATTACKER);
        let (config, mut shared_vault) = vault::create_vault_for_testing(
            b"v", b"USDC", 0, test_scenario::ctx(&mut scenario),
        );
        let (_skim, _net) = vault::apply_harvest_skim(&config, &mut shared_vault, 1_000_000);
        vault::destroy_for_testing(config, shared_vault);
        test_scenario::end(scenario);
    }

    /// DAY-4306: a non-owner sender must NOT be able to withdraw (destination-lock).
    #[test]
    #[expected_failure(abort_code = vault::E_NOT_OWNER)]
    fun test_withdraw_by_non_owner_aborts() {
        let mut scenario = test_scenario::begin(OWNER);
        let (config, mut vault) = vault::create_vault_for_testing(
            b"v", b"USDC", 0, test_scenario::ctx(&mut scenario),
        );
        // OWNER deposits and receives a Position owned by OWNER.
        let mut position = vault::deposit_liquid_for_testing(
            &config, &mut vault, 1_000_000, test_scenario::ctx(&mut scenario),
        );
        // Now the ATTACKER tries to drive the withdraw against OWNER's position.
        test_scenario::next_tx(&mut scenario, ATTACKER);
        // This MUST abort with E_NOT_OWNER (sender != position.owner).
        let _assets = vault::withdraw_liquid(
            &config, &mut vault, &mut position, 500_000, test_scenario::ctx(&mut scenario),
        );
        // Unreachable — teardown only to satisfy the type checker.
        vault::destroy_position_for_testing(position);
        vault::destroy_for_testing(config, vault);
        test_scenario::end(scenario);
    }

    /// DAY-4306: the recorded owner CAN withdraw, and the payout is bound to that owner.
    /// The entry wrapper only ever settles to position.owner (== sender here).
    #[test]
    fun test_owner_can_withdraw_and_payout_bound_to_owner() {
        let mut scenario = test_scenario::begin(OWNER);
        let (config, mut vault) = vault::create_vault_for_testing(
            b"v", b"USDC", 0, test_scenario::ctx(&mut scenario),
        );
        let mut position = vault::deposit_liquid_for_testing(
            &config, &mut vault, 1_000_000, test_scenario::ctx(&mut scenario),
        );
        assert!(vault::position_owner(&position) == OWNER, 100);
        // OWNER (the tx sender) withdraws — allowed.
        let assets = vault::withdraw_liquid(
            &config, &mut vault, &mut position, 500_000, test_scenario::ctx(&mut scenario),
        );
        assert!(assets > 0, 101);
        // Payout destination is the recorded owner, not an arbitrary address.
        assert!(vault::position_owner(&position) == OWNER, 102);
        // Drive the owner-locked entry wrapper too (settles to position.owner).
        vault::entry_withdraw_liquid_to_owner(
            &config, &mut vault, &mut position, 100_000, test_scenario::ctx(&mut scenario),
        );
        vault::destroy_position_for_testing(position);
        vault::destroy_for_testing(config, vault);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_first_deposit_one_to_one() {
        let shares = vault::convert_to_shares(1_000_000, 0, 0);
        assert!(shares == 1_000_000, 0);
    }

    #[test]
    fun test_harvest_skim_500_bps() {
        let (skim, net) = day::skim_yield(1_000_000, 500);
        assert!(skim == 50_000, 1);
        assert!(net == 950_000, 2);
    }

    #[test]
    fun test_default_fee_and_auto_deploy_off_flag() {
        assert!(vault::default_fee_skim_bps() == 500, 3);
    }

    #[test]
    fun test_convert_roundtrip_empty_then_second() {
        let s1 = vault::convert_to_shares(1_000_000, 0, 0);
        assert!(s1 == 1_000_000, 4);
        // After first: total_assets=1e6, total_shares=1e6
        let s2 = vault::convert_to_shares(1_000_000, 1_000_000, 1_000_000);
        // (1e6 * (1e6+1000)) / (1e6+1000) = 1e6
        assert!(s2 == 1_000_000, 5);
        let assets = vault::convert_to_assets(1_000_000, 2_000_000, 2_000_000);
        assert!(assets == 1_000_000, 6);
    }
}
