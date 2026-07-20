// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// Immutable, ordered native-asset route bindings for managed positions.
/// Validation is independent of share/NAV accounting and fail-closes every
/// unknown, duplicate, disconnected, non-terminal, or mismatched leg.
module day::managed_route {
    use day::guardrails_v2::{Self, GuardrailsV2, NativeAssetBinding};
    use std::bcs;
    use std::type_name::{Self, TypeName};

    const LEG_KIND_SWAP: u8 = 1;
    const LEG_KIND_BRIDGE: u8 = 2;
    const LEG_KIND_DEPOSIT: u8 = 3;
    const LEG_KIND_WITHDRAW: u8 = 4;

    const E_WRONG_ORIGIN_ASSET: u64 = 6;
    const E_EMPTY_OPPORTUNITY: u64 = 8;
    const E_EMPTY_ROUTE: u64 = 11;
    const E_UNKNOWN_LEG_KIND: u64 = 12;
    const E_DUPLICATE_LEG_ID: u64 = 13;
    const E_ROUTE_NOT_DEPOSIT: u64 = 14;
    const E_ROUTE_TARGET_MISMATCH: u64 = 15;
    const E_DISCONNECTED_ROUTE: u64 = 18;
    const E_REMOTE_ASSET_IDENTITY: u64 = 25;
    const E_ROUTE_NOT_WITHDRAW: u64 = 26;
    const E_SAME_ROUTE_ENDPOINT: u64 = 27;
    const E_MISSING_ENDPOINT: u64 = 28;
    const E_AMBIGUOUS_ENDPOINT: u64 = 29;
    const E_SAME_OPPORTUNITY_ENDPOINT: u64 = 30;
    const E_ACCOUNTING_ASSET_MISMATCH: u64 = 31;

    public struct RouteLegBinding has copy, drop, store {
        leg_id: ID,
        kind: u8,
        source_asset: NativeAssetBinding,
        destination_asset: NativeAssetBinding,
        target_opportunity_id: Option<vector<u8>>,
    }

    /// Directed reallocation-only route leg. This distinct type prevents a deposit
    /// entry proof from being reinterpreted as a reallocation authorization.
    public struct ReallocationRouteLeg has copy, drop, store {
        leg_id: ID,
        kind: u8,
        source_asset: NativeAssetBinding,
        destination_asset: NativeAssetBinding,
        endpoint_opportunity_id: Option<vector<u8>>,
    }

    /// Domain-separated canonical payload returned only after the complete
    /// route passes structural and frozen-policy validation.
    public struct ReallocationRouteCanonicalV1 has drop {
        domain: vector<u8>,
        schema_version: u8,
        guardrails_id: ID,
        guardrails_hash: vector<u8>,
        allocation_bps: u64,
        ordered_legs: vector<ReallocationRouteLeg>,
    }

    public(package) fun swap_leg(
        leg_id: ID,
        input_asset: NativeAssetBinding,
        output_asset: NativeAssetBinding,
    ): RouteLegBinding {
        guardrails_v2::assert_native_asset_binding(&input_asset);
        guardrails_v2::assert_native_asset_binding(&output_asset);
        assert!(
            guardrails_v2::native_asset_chain_id(&input_asset)
                == guardrails_v2::native_asset_chain_id(&output_asset),
            E_DISCONNECTED_ROUTE,
        );
        RouteLegBinding {
            leg_id,
            kind: LEG_KIND_SWAP,
            source_asset: input_asset,
            destination_asset: output_asset,
            target_opportunity_id: option::none(),
        }
    }

    public(package) fun bridge_leg(
        leg_id: ID,
        source_asset: NativeAssetBinding,
        destination_asset: NativeAssetBinding,
    ): RouteLegBinding {
        guardrails_v2::assert_native_asset_binding(&source_asset);
        guardrails_v2::assert_native_asset_binding(&destination_asset);
        assert!(
            guardrails_v2::native_asset_chain_id(&source_asset)
                != guardrails_v2::native_asset_chain_id(&destination_asset),
            E_REMOTE_ASSET_IDENTITY,
        );
        RouteLegBinding {
            leg_id,
            kind: LEG_KIND_BRIDGE,
            source_asset,
            destination_asset,
            target_opportunity_id: option::none(),
        }
    }

    public(package) fun deposit_leg<T>(
        leg_id: ID,
        opportunity_id: vector<u8>,
    ): RouteLegBinding {
        assert!(!vector::is_empty(&opportunity_id), E_EMPTY_OPPORTUNITY);
        let asset = guardrails_v2::sui_asset_binding<T>();
        RouteLegBinding {
            leg_id,
            kind: LEG_KIND_DEPOSIT,
            source_asset: asset,
            destination_asset: asset,
            target_opportunity_id: option::some(opportunity_id),
        }
    }

    public(package) fun reallocation_withdraw_leg(
        leg_id: ID,
        asset: NativeAssetBinding,
        opportunity_id: vector<u8>,
    ): ReallocationRouteLeg {
        guardrails_v2::assert_native_asset_binding(&asset);
        assert!(!vector::is_empty(&opportunity_id), E_EMPTY_OPPORTUNITY);
        ReallocationRouteLeg {
            leg_id,
            kind: LEG_KIND_WITHDRAW,
            source_asset: asset,
            destination_asset: asset,
            endpoint_opportunity_id: option::some(opportunity_id),
        }
    }

    public(package) fun reallocation_swap_leg(
        leg_id: ID,
        input_asset: NativeAssetBinding,
        output_asset: NativeAssetBinding,
    ): ReallocationRouteLeg {
        guardrails_v2::assert_native_asset_binding(&input_asset);
        guardrails_v2::assert_native_asset_binding(&output_asset);
        assert!(
            guardrails_v2::native_asset_chain_id(&input_asset)
                == guardrails_v2::native_asset_chain_id(&output_asset),
            E_DISCONNECTED_ROUTE,
        );
        ReallocationRouteLeg {
            leg_id,
            kind: LEG_KIND_SWAP,
            source_asset: input_asset,
            destination_asset: output_asset,
            endpoint_opportunity_id: option::none(),
        }
    }

    public(package) fun reallocation_bridge_leg(
        leg_id: ID,
        source_asset: NativeAssetBinding,
        destination_asset: NativeAssetBinding,
    ): ReallocationRouteLeg {
        guardrails_v2::assert_native_asset_binding(&source_asset);
        guardrails_v2::assert_native_asset_binding(&destination_asset);
        assert!(
            guardrails_v2::native_asset_chain_id(&source_asset)
                != guardrails_v2::native_asset_chain_id(&destination_asset),
            E_REMOTE_ASSET_IDENTITY,
        );
        ReallocationRouteLeg {
            leg_id,
            kind: LEG_KIND_BRIDGE,
            source_asset,
            destination_asset,
            endpoint_opportunity_id: option::none(),
        }
    }

    public(package) fun reallocation_deposit_leg(
        leg_id: ID,
        asset: NativeAssetBinding,
        opportunity_id: vector<u8>,
    ): ReallocationRouteLeg {
        guardrails_v2::assert_native_asset_binding(&asset);
        assert!(!vector::is_empty(&opportunity_id), E_EMPTY_OPPORTUNITY);
        ReallocationRouteLeg {
            leg_id,
            kind: LEG_KIND_DEPOSIT,
            source_asset: asset,
            destination_asset: asset,
            endpoint_opportunity_id: option::some(opportunity_id),
        }
    }

    #[test_only]
    public fun remote_deposit_leg(
        leg_id: ID,
        asset: NativeAssetBinding,
        opportunity_id: vector<u8>,
    ): RouteLegBinding {
        guardrails_v2::assert_native_asset_binding(&asset);
        assert!(!vector::is_empty(&opportunity_id), E_EMPTY_OPPORTUNITY);
        RouteLegBinding {
            leg_id,
            kind: LEG_KIND_DEPOSIT,
            source_asset: asset,
            destination_asset: asset,
            target_opportunity_id: option::some(opportunity_id),
        }
    }

    #[test_only]
    public fun reallocation_leg_for_testing(
        leg_id: ID,
        kind: u8,
        source_asset: NativeAssetBinding,
        destination_asset: NativeAssetBinding,
        endpoint_opportunity_id: Option<vector<u8>>,
    ): ReallocationRouteLeg {
        ReallocationRouteLeg {
            leg_id,
            kind,
            source_asset,
            destination_asset,
            endpoint_opportunity_id,
        }
    }

    public(package) fun assert_bound_to_accounting<T>(
        route: &vector<RouteLegBinding>,
        accounting_id: ID,
        accounting_asset: TypeName,
        opportunity_id: vector<u8>,
    ) {
        let count = vector::length(route);
        assert!(count > 0, E_EMPTY_ROUTE);
        assert!(accounting_asset == type_name::with_original_ids<T>(), E_WRONG_ORIGIN_ASSET);
        let expected_asset = guardrails_v2::sui_asset_binding<T>();
        let origin = vector::borrow(route, 0);
        assert!(
            guardrails_v2::same_native_asset_binding(&origin.source_asset, &expected_asset),
            E_ROUTE_TARGET_MISMATCH,
        );
        let mut i = 0;
        while (i < count) {
            let leg = vector::borrow(route, i);
            assert!(
                leg.kind == LEG_KIND_SWAP
                    || leg.kind == LEG_KIND_BRIDGE
                    || leg.kind == LEG_KIND_DEPOSIT,
                E_UNKNOWN_LEG_KIND,
            );
            if (leg.kind == LEG_KIND_DEPOSIT) assert!(i + 1 == count, E_ROUTE_NOT_DEPOSIT);
            let mut j = i + 1;
            while (j < count) {
                assert!(leg.leg_id != vector::borrow(route, j).leg_id, E_DUPLICATE_LEG_ID);
                j = j + 1;
            };
            if (i + 1 < count) {
                let next = vector::borrow(route, i + 1);
                assert!(
                    guardrails_v2::same_native_asset_binding(
                        &leg.destination_asset,
                        &next.source_asset,
                    ),
                    E_DISCONNECTED_ROUTE,
                );
            };
            i = i + 1;
        };
        let terminal = vector::borrow(route, count - 1);
        assert!(terminal.kind == LEG_KIND_DEPOSIT, E_ROUTE_NOT_DEPOSIT);
        assert!(terminal.leg_id == accounting_id, E_ROUTE_TARGET_MISMATCH);
        assert!(
            guardrails_v2::same_native_asset_binding(&terminal.source_asset, &expected_asset)
                && guardrails_v2::same_native_asset_binding(
                    &terminal.destination_asset,
                    &expected_asset,
                ),
            E_ROUTE_TARGET_MISMATCH,
        );
        assert!(option::is_some(&terminal.target_opportunity_id), E_ROUTE_TARGET_MISMATCH);
        assert!(
            *option::borrow(&terminal.target_opportunity_id) == opportunity_id,
            E_ROUTE_TARGET_MISMATCH,
        );
    }

    /// Validate a complete managed entry route against the exact frozen policy.
    /// Every intermediate source/destination identity and chain is checked; the
    /// terminal opportunity and allocation are checked atomically with the
    /// structural accounting binding.
    public(package) fun assert_managed_entry_route_allowed<T>(
        route: &vector<RouteLegBinding>,
        guardrails: &GuardrailsV2,
        allocation_bps: u64,
        accounting_id: ID,
        accounting_asset: TypeName,
        opportunity_id: vector<u8>,
    ) {
        assert_bound_to_accounting<T>(route, accounting_id, accounting_asset, opportunity_id);
        let count = vector::length(route);
        let mut i = 0;
        while (i < count) {
            let leg = vector::borrow(route, i);
            guardrails_v2::assert_native_asset_and_chain_allowed(guardrails, &leg.source_asset);
            guardrails_v2::assert_native_asset_and_chain_allowed(guardrails, &leg.destination_asset);
            i = i + 1;
        };
        let terminal = vector::borrow(route, count - 1);
        guardrails_v2::assert_native_allocation_allowed(
            guardrails,
            &terminal.destination_asset,
            opportunity_id,
            allocation_bps,
        );
    }

    /// Validate and serialize one directed reallocation route atomically. This
    /// is deliberately separate from deposit-entry validation: the first leg is
    /// an exact source withdrawal, the last an exact destination deposit, and
    /// every intermediate native identity is committed in ordered BCS bytes.
    public(package) fun validated_reallocation_route_canonical_v1(
        route: &vector<ReallocationRouteLeg>,
        guardrails: &GuardrailsV2,
        allocation_bps: u64,
        source_accounting_id: ID,
        source_opportunity_id: vector<u8>,
        destination_accounting_id: ID,
        destination_opportunity_id: vector<u8>,
    ): (vector<u8>, NativeAssetBinding, NativeAssetBinding) {
        assert!(!vector::is_empty(&source_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(!vector::is_empty(&destination_opportunity_id), E_EMPTY_OPPORTUNITY);
        assert!(source_accounting_id != destination_accounting_id, E_SAME_ROUTE_ENDPOINT);
        assert!(source_opportunity_id != destination_opportunity_id, E_SAME_OPPORTUNITY_ENDPOINT);
        let count = vector::length(route);
        assert!(count >= 2, E_EMPTY_ROUTE);

        let first = vector::borrow(route, 0);
        assert!(first.kind == LEG_KIND_WITHDRAW, E_ROUTE_NOT_WITHDRAW);
        assert!(first.leg_id == source_accounting_id, E_ROUTE_TARGET_MISMATCH);
        assert!(option::is_some(&first.endpoint_opportunity_id), E_MISSING_ENDPOINT);
        assert!(*option::borrow(&first.endpoint_opportunity_id) == source_opportunity_id, E_ROUTE_TARGET_MISMATCH);
        assert!(
            guardrails_v2::same_native_asset_binding(
                &first.source_asset,
                &first.destination_asset,
            ),
            E_ROUTE_TARGET_MISMATCH,
        );

        let mut i = 0;
        while (i < count) {
            let leg = vector::borrow(route, i);
            guardrails_v2::assert_native_asset_binding(&leg.source_asset);
            guardrails_v2::assert_native_asset_binding(&leg.destination_asset);
            guardrails_v2::assert_native_asset_and_chain_allowed(
                guardrails,
                &leg.source_asset,
            );
            guardrails_v2::assert_native_asset_and_chain_allowed(
                guardrails,
                &leg.destination_asset,
            );
            if (i == 0) {
                assert!(leg.kind == LEG_KIND_WITHDRAW, E_ROUTE_NOT_WITHDRAW);
            } else if (i + 1 == count) {
                assert!(leg.kind == LEG_KIND_DEPOSIT, E_ROUTE_NOT_DEPOSIT);
            } else {
                assert!(leg.kind == LEG_KIND_SWAP || leg.kind == LEG_KIND_BRIDGE, E_UNKNOWN_LEG_KIND);
                assert!(!option::is_some(&leg.endpoint_opportunity_id), E_AMBIGUOUS_ENDPOINT);
                if (leg.kind == LEG_KIND_SWAP) {
                    assert!(
                        guardrails_v2::native_asset_chain_id(&leg.source_asset)
                            == guardrails_v2::native_asset_chain_id(&leg.destination_asset),
                        E_DISCONNECTED_ROUTE,
                    );
                } else {
                    assert!(
                        guardrails_v2::native_asset_chain_id(&leg.source_asset)
                            != guardrails_v2::native_asset_chain_id(&leg.destination_asset),
                        E_REMOTE_ASSET_IDENTITY,
                    );
                };
            };
            let mut j = i + 1;
            while (j < count) {
                assert!(leg.leg_id != vector::borrow(route, j).leg_id, E_DUPLICATE_LEG_ID);
                j = j + 1;
            };
            if (i + 1 < count) {
                assert!(
                    guardrails_v2::same_native_asset_binding(
                        &leg.destination_asset,
                        &vector::borrow(route, i + 1).source_asset,
                    ),
                    E_DISCONNECTED_ROUTE,
                );
            };
            i = i + 1;
        };

        let terminal = vector::borrow(route, count - 1);
        assert!(terminal.leg_id == destination_accounting_id, E_ROUTE_TARGET_MISMATCH);
        assert!(option::is_some(&terminal.endpoint_opportunity_id), E_MISSING_ENDPOINT);
        assert!(*option::borrow(&terminal.endpoint_opportunity_id) == destination_opportunity_id, E_ROUTE_TARGET_MISMATCH);
        assert!(
            guardrails_v2::same_native_asset_binding(
                &terminal.source_asset,
                &terminal.destination_asset,
            ),
            E_ROUTE_TARGET_MISMATCH,
        );
        guardrails_v2::assert_native_allocation_allowed(
            guardrails,
            &first.source_asset,
            source_opportunity_id,
            allocation_bps,
        );
        guardrails_v2::assert_native_allocation_allowed(
            guardrails,
            &terminal.destination_asset,
            destination_opportunity_id,
            allocation_bps,
        );
        let canonical_bytes = bcs::to_bytes(&ReallocationRouteCanonicalV1 {
            domain: b"DAY_REALLOCATION_ROUTE",
            schema_version: 1,
            guardrails_id: guardrails_v2::id(guardrails),
            guardrails_hash: guardrails_v2::guardrails_hash(guardrails),
            allocation_bps,
            ordered_legs: *route,
        });
        // Bindings are exposed only as part of this successful atomic proof.
        // There is no caller binding input and no partial endpoint getter.
        (canonical_bytes, first.source_asset, terminal.destination_asset)
    }

    /// The executable accounting-aware route proof. Endpoint assets are not
    /// caller-selected facts: the leaf controller borrows both immutable
    /// bindings from the real OpportunityAccounting objects and supplies them
    /// here in the same call that validates IDs, opportunities and allocation.
    public(package) fun validated_accounting_reallocation_route_canonical_v1(
        route: &vector<ReallocationRouteLeg>,
        guardrails: &GuardrailsV2,
        allocation_bps: u64,
        source_accounting_id: ID,
        source_opportunity_id: vector<u8>,
        source_accounting_binding: &NativeAssetBinding,
        destination_accounting_id: ID,
        destination_opportunity_id: vector<u8>,
        destination_accounting_binding: &NativeAssetBinding,
    ): (vector<u8>, NativeAssetBinding, NativeAssetBinding) {
        guardrails_v2::assert_native_asset_binding(source_accounting_binding);
        guardrails_v2::assert_native_asset_binding(destination_accounting_binding);
        let (bytes, source_route_binding, destination_route_binding) =
            validated_reallocation_route_canonical_v1(
                route,
                guardrails,
                allocation_bps,
                source_accounting_id,
                source_opportunity_id,
                destination_accounting_id,
                destination_opportunity_id,
            );
        assert!(
            guardrails_v2::same_native_asset_binding(
                &source_route_binding,
                source_accounting_binding,
            ),
            E_ACCOUNTING_ASSET_MISMATCH,
        );
        assert!(
            guardrails_v2::same_native_asset_binding(
                &destination_route_binding,
                destination_accounting_binding,
            ),
            E_ACCOUNTING_ASSET_MISMATCH,
        );
        (bytes, source_route_binding, destination_route_binding)
    }

    public fun source_chain(leg: &RouteLegBinding): vector<u8> {
        guardrails_v2::native_asset_chain_id(&leg.source_asset)
    }
    public fun destination_chain(leg: &RouteLegBinding): vector<u8> {
        guardrails_v2::native_asset_chain_id(&leg.destination_asset)
    }
    public fun target_opportunity(leg: &RouteLegBinding): Option<vector<u8>> {
        leg.target_opportunity_id
    }
}
