// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// DAY AdapterRegistry — allowlist of venue adapters (strategies).
/// NOT a vault product. YieldRouter consults this registry before deposit/withdraw.
/// UpgradeCap remains HELD — do not burn until explicit lock go.
module day::adapter_registry {
    use day::day::{Self as protocol, ProtocolConfig};
    use std::string::{Self, String};
    use sui::event;
    use sui::package::UpgradeCap;
    use sui::table::{Self, Table};

    /// ENotAllowlisted
    const E_NOT_ALLOWLISTED: u64 = 1;
    /// EAlreadyRegistered
    const E_ALREADY_REGISTERED: u64 = 2;
    /// EAuthenticatedMutationRequired
    const E_AUTHENTICATED_MUTATION_REQUIRED: u64 = 3;
    /// EWrongUpgradeCap
    const E_WRONG_UPGRADE_CAP: u64 = 4;
    /// EAdminCapRegistryMismatch
    const E_ADMIN_CAP_REGISTRY_MISMATCH: u64 = 6;
    /// EZeroRecipient
    const E_ZERO_RECIPIENT: u64 = 8;
    #[test_only]
    /// ERegistryCountInvariant
    const E_REGISTRY_COUNT_INVARIANT: u64 = 9;
    /// The canonical capability object that controls upgrades of this package. Its
    /// object id is stable across package upgrades. Supplying this address-owned
    /// object authenticates the bootstrap caller; this module never transfers it.
    const CANONICAL_UPGRADE_CAP: address =
        @0xfb7a7925da9332ab039cd7296828f5ebaef5ff7246f1bfa051d0a409fa15eb2d;
    const CANONICAL_PROTOCOL_CONFIG: address =
        @0xdcd2e53c6ebc03cea47bcfc656337f03bf64cf1069bb92419bb67f4969603bba;
    /// The treasury/deployer EOA may authenticate bootstrap with the UpgradeCap,
    /// but must never receive the permanent registry mutation capability.
    const DAY_AUTHORITY: address =
        @0xc7166e26852d600068350ca65b6252880a3e17b540e2080e683f796303e1d491;
    const REGISTRY_VERSION_V2: u64 = 2;
    /// EInvalidGovernanceRecipient
    const E_INVALID_GOVERNANCE_RECIPIENT: u64 = 10;
    /// EWrongProtocolConfig
    const E_WRONG_PROTOCOL_CONFIG: u64 = 11;
    /// EAlreadyBootstrapped
    const E_ALREADY_BOOTSTRAPPED: u64 = 12;
    /// EWrongAdapterChain
    const E_WRONG_ADAPTER_CHAIN: u64 = 13;

    /// Shared registry of strategy adapters (venue bindings).
    public struct AdapterRegistry has key {
        id: UID,
        /// adapter_id (e.g. b"suilend") → active
        adapters: Table<vector<u8>, AdapterMeta>,
        count: u64,
    }

    /// Fresh registry type introduced by DAY-821. Prior package bytecode only knows
    /// `AdapterRegistry` and therefore cannot take this object as an argument. The
    /// explicit version lets a future compatible upgrade retire this generation by
    /// changing the live object's version before routing through a newer type.
    public struct AdapterRegistryV2 has key {
        id: UID,
        version: u64,
        /// Immutable binding to the unique canonical ProtocolConfig whose
        /// one-shot dynamic-field anchor names this registry.
        protocol_config_id: ID,
        adapters: Table<vector<u8>, AdapterMeta>,
        count: u64,
    }

    /// Non-copyable, non-droppable, non-storable authority for one V2 registry. Because
    /// this type lacks `store`, callers cannot publicly share or transfer it; rotation
    /// must use this module's controlled transfer function.
    public struct RegistryAdminCap has key {
        id: UID,
        registry_id: ID,
    }

    public struct AdapterMeta has store, copy, drop {
        adapter_id: vector<u8>,
        chain: vector<u8>,
        active: bool,
        /// human label — UTF-8 bytes
        label: vector<u8>,
    }

    public struct AdapterRegistered has copy, drop {
        adapter_id: vector<u8>,
        chain: vector<u8>,
    }

    public struct AdapterSetActive has copy, drop {
        adapter_id: vector<u8>,
        active: bool,
    }

    public struct RegistryAdminCapCreated has copy, drop {
        registry_id: ID,
        admin_cap_id: ID,
        recipient: address,
    }

    public struct RegistryAdminCapTransferred has copy, drop {
        registry_id: ID,
        admin_cap_id: ID,
        recipient: address,
    }

    /// Create and share the registry (one-time bootstrap).
    public fun create(ctx: &mut TxContext) {
        let reg = AdapterRegistry {
            id: object::new(ctx),
            adapters: table::new(ctx),
            count: 0,
        };
        transfer::share_object(reg);
    }

    /// Create the only registry generation new DAY routes may trust. This deliberately
    /// creates a fresh object/type instead of attempting to secure the deployed legacy
    /// `AdapterRegistry`: prior Sui package versions remain callable forever and can
    /// still mutate that old type. The caller must own the canonical UpgradeCap. The
    /// V2 registry and its sole admin capability are created atomically; the cap is
    /// transferred directly to the final approved governance recipient.
    public fun bootstrap_registry_v2(
        config: &mut ProtocolConfig,
        upgrade_cap: &UpgradeCap,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(object::id_address(upgrade_cap) == CANONICAL_UPGRADE_CAP, E_WRONG_UPGRADE_CAP);
        assert!(object::id_address(config) == CANONICAL_PROTOCOL_CONFIG, E_WRONG_PROTOCOL_CONFIG);
        assert_governance_recipient(recipient);
        bootstrap_registry_v2_internal(config, recipient, ctx);
    }

    fun bootstrap_registry_v2_internal(
        config: &mut ProtocolConfig,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(!protocol::adapter_registry_v2_bootstrapped(config), E_ALREADY_BOOTSTRAPPED);
        let protocol_config_id = object::id(config);
        let reg = AdapterRegistryV2 {
            id: object::new(ctx),
            version: REGISTRY_VERSION_V2,
            protocol_config_id,
            adapters: table::new(ctx),
            count: 0,
        };
        let registry_id = object::id(&reg);
        let cap = RegistryAdminCap { id: object::new(ctx), registry_id };
        let admin_cap_id = object::id(&cap);
        protocol::anchor_adapter_registry_v2(
            config,
            registry_id,
            admin_cap_id,
            recipient,
        );
        event::emit(RegistryAdminCapCreated { registry_id, admin_cap_id, recipient });
        transfer::share_object(reg);
        transfer::transfer(cap, recipient);
    }

    /// Controlled ownership rotation. Only the current owner can supply this owned
    /// capability as an input. The cap's object id and registry binding do not change.
    public fun transfer_admin_cap(cap: RegistryAdminCap, recipient: address) {
        assert_governance_recipient(recipient);
        let registry_id = cap.registry_id;
        let admin_cap_id = object::id(&cap);
        event::emit(RegistryAdminCapTransferred { registry_id, admin_cap_id, recipient });
        transfer::transfer(cap, recipient);
    }

    /// Permanently retire this V2 generation before a future registry migration.
    /// Changing the live object's version makes every historical V2 mutator/read gate
    /// fail closed, including calls through the package version that introduced V2.
    public fun retire_v2(cap: &RegistryAdminCap, reg: &mut AdapterRegistryV2) {
        assert_admin_cap(cap, reg);
        reg.version = REGISTRY_VERSION_V2 + 1;
    }

    /// Legacy deployed signature retained for compatible upgrades. It must never
    /// mutate the shared registry again: the original function had no authority or
    /// transaction context and was callable by every address.
    ///
    /// Use `register_authenticated` instead.
    public fun register(
        _reg: &mut AdapterRegistry,
        _adapter_id: vector<u8>,
        _chain: vector<u8>,
        _label: vector<u8>,
    ) {
        abort E_AUTHENTICATED_MUTATION_REQUIRED
    }

    /// Legacy deployed signature retained for compatible upgrades. It always aborts
    /// because it has no authenticated caller context.
    ///
    /// Use `set_active_authenticated` instead.
    public fun set_active(
        _reg: &mut AdapterRegistry,
        _adapter_id: vector<u8>,
        _active: bool,
    ) {
        abort E_AUTHENTICATED_MUTATION_REQUIRED
    }

    /// Register a new adapter id. Only the active RegistryAdminCap may mutate the
    /// shared allowlist.
    public fun register_authenticated(
        cap: &RegistryAdminCap,
        reg: &mut AdapterRegistryV2,
        adapter_id: vector<u8>,
        chain: vector<u8>,
        label: vector<u8>,
    ) {
        assert_admin_cap(cap, reg);
        assert!(!table::contains(&reg.adapters, adapter_id), E_ALREADY_REGISTERED);
        table::add(&mut reg.adapters, adapter_id, AdapterMeta {
            adapter_id,
            chain,
            active: true,
            label,
        });
        reg.count = reg.count + 1;
        event::emit(AdapterRegistered { adapter_id, chain });
    }

    /// Enable or disable a registered adapter. Only the active RegistryAdminCap may
    /// change the fail-closed router gate.
    public fun set_active_authenticated(
        cap: &RegistryAdminCap,
        reg: &mut AdapterRegistryV2,
        adapter_id: vector<u8>,
        active: bool,
    ) {
        assert_admin_cap(cap, reg);
        assert!(table::contains(&reg.adapters, adapter_id), E_NOT_ALLOWLISTED);
        let m = table::borrow_mut(&mut reg.adapters, adapter_id);
        m.active = active;
        event::emit(AdapterSetActive { adapter_id, active });
    }

    /// Legacy read ABI retained for compatible upgrades only. New routing code must
    /// never accept this type because prior package versions can mutate its state.
    public fun assert_active(reg: &AdapterRegistry, adapter_id: vector<u8>) {
        assert!(table::contains(&reg.adapters, adapter_id), E_NOT_ALLOWLISTED);
        let m = table::borrow(&reg.adapters, adapter_id);
        assert!(m.active, E_NOT_ALLOWLISTED);
    }

    /// Legacy read ABI; informational only and prohibited on the money path.
    public fun is_active(reg: &AdapterRegistry, adapter_id: vector<u8>): bool {
        if (!table::contains(&reg.adapters, adapter_id)) {
            return false
        };
        table::borrow(&reg.adapters, adapter_id).active
    }

    /// Legacy read ABI; informational only and prohibited on the money path.
    public fun count(reg: &AdapterRegistry): u64 {
        reg.count
    }

    /// Fail-closed V2 allowlist check used by every new YieldRouter path.
    public fun assert_active_v2(reg: &AdapterRegistryV2, adapter_id: vector<u8>) {
        assert_canonical_v2(reg);
        assert!(table::contains(&reg.adapters, adapter_id), E_NOT_ALLOWLISTED);
        let m = table::borrow(&reg.adapters, adapter_id);
        assert!(m.active, E_NOT_ALLOWLISTED);
    }

    /// Fail closed unless the active adapter's immutable registry metadata is
    /// bound to the exact spoke chain being authorized.
    public fun assert_active_v2_on_chain(
        reg: &AdapterRegistryV2,
        adapter_id: vector<u8>,
        chain: vector<u8>,
    ) {
        assert_active_v2(reg, adapter_id);
        assert!(table::borrow(&reg.adapters, adapter_id).chain == chain, E_WRONG_ADAPTER_CHAIN);
    }

    /// Validate this registry generation without imposing active-state on
    /// recovery/return paths for already-deployed owner funds.
    public fun assert_canonical_v2(reg: &AdapterRegistryV2) {
        assert!(reg.version == REGISTRY_VERSION_V2, E_AUTHENTICATED_MUTATION_REQUIRED);
        assert!(reg.protocol_config_id == object::id_from_address(CANONICAL_PROTOCOL_CONFIG), E_WRONG_PROTOCOL_CONFIG);
    }

    public fun is_active_v2(reg: &AdapterRegistryV2, adapter_id: vector<u8>): bool {
        if (
            reg.version != REGISTRY_VERSION_V2 ||
            reg.protocol_config_id != object::id_from_address(CANONICAL_PROTOCOL_CONFIG)
        ) {
            return false
        };
        if (!table::contains(&reg.adapters, adapter_id)) {
            return false
        };
        table::borrow(&reg.adapters, adapter_id).active
    }

    public fun count_v2(reg: &AdapterRegistryV2): u64 {
        reg.count
    }

    public fun version_v2(reg: &AdapterRegistryV2): u64 {
        reg.version
    }

    /// Decode label bytes as UTF-8 string.
    public fun label_as_string(meta: &AdapterMeta): String {
        string::utf8(meta.label)
    }

    fun assert_admin_cap(cap: &RegistryAdminCap, reg: &AdapterRegistryV2) {
        assert!(reg.version == REGISTRY_VERSION_V2, E_AUTHENTICATED_MUTATION_REQUIRED);
        assert!(reg.protocol_config_id == object::id_from_address(CANONICAL_PROTOCOL_CONFIG), E_WRONG_PROTOCOL_CONFIG);
        let registry_id = object::id(reg);
        assert!(cap.registry_id == registry_id, E_ADMIN_CAP_REGISTRY_MISMATCH);
    }

    fun assert_governance_recipient(recipient: address) {
        assert!(recipient != @0x0, E_ZERO_RECIPIENT);
        assert!(recipient != DAY_AUTHORITY, E_INVALID_GOVERNANCE_RECIPIENT);
    }

    #[test_only]
    public fun bootstrap_registry_v2_for_testing(
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert_governance_recipient(recipient);
        let reg = AdapterRegistryV2 {
            id: object::new(ctx),
            version: REGISTRY_VERSION_V2,
            protocol_config_id: object::id_from_address(CANONICAL_PROTOCOL_CONFIG),
            adapters: table::new(ctx),
            count: 0,
        };
        let registry_id = object::id(&reg);
        let cap = RegistryAdminCap { id: object::new(ctx), registry_id };
        transfer::share_object(reg);
        transfer::transfer(cap, recipient);
    }

    #[test_only]
    public fun bootstrap_registry_v2_with_config_for_testing(
        config: &mut ProtocolConfig,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert_governance_recipient(recipient);
        bootstrap_registry_v2_internal(config, recipient, ctx);
    }

    #[test_only]
    public fun create_legacy_for_testing(ctx: &mut TxContext): AdapterRegistry {
        AdapterRegistry {
            id: object::new(ctx),
            adapters: table::new(ctx),
            count: 0,
        }
    }

    #[test_only]
    public fun legacy_register_for_testing(
        reg: &mut AdapterRegistry,
        adapter_id: vector<u8>,
        active: bool,
    ) {
        table::add(&mut reg.adapters, adapter_id, AdapterMeta {
            adapter_id,
            chain: b"legacy",
            active,
            label: b"Legacy",
        });
        reg.count = reg.count + 1;
    }

    #[test_only]
    public fun create_v2_for_testing(ctx: &mut TxContext): AdapterRegistryV2 {
        AdapterRegistryV2 {
            id: object::new(ctx),
            version: REGISTRY_VERSION_V2,
            protocol_config_id: object::id_from_address(CANONICAL_PROTOCOL_CONFIG),
            adapters: table::new(ctx),
            count: 0,
        }
    }

    #[test_only]
    public fun create_admin_cap_for_testing(
        reg: &AdapterRegistryV2,
        ctx: &mut TxContext,
    ): RegistryAdminCap {
        let registry_id = object::id(reg);
        RegistryAdminCap { id: object::new(ctx), registry_id }
    }

    #[test_only]
    public fun destroy_admin_cap_for_testing(cap: RegistryAdminCap) {
        let RegistryAdminCap { id, registry_id: _ } = cap;
        object::delete(id);
    }

    #[test_only]
    public fun destroy_v2_for_testing(reg: AdapterRegistryV2) {
        let AdapterRegistryV2 { id, version: _, protocol_config_id: _, adapters, count } = reg;
        assert!(count == 0, E_REGISTRY_COUNT_INVARIANT);
        table::destroy_empty(adapters);
        object::delete(id);
    }
}
