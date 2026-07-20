// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// Canonical ordering and identifier validation shared by GuardrailsV2.
/// Keeping byte ordering here makes policy hashing reviewable independently
/// from builder authorization and predicate evaluation.
module day::guardrails_v2_canonical {
    use std::ascii;
    use std::type_name::{Self, TypeName};
    use sui::vec_set::{Self, VecSet};

    const OPPORTUNITY_ID_LEN: u64 = 15;
    const MAX_CHAIN_ID_LEN: u64 = 32;

    public(package) fun sorted_asset_types(source: &VecSet<TypeName>): VecSet<TypeName> {
        let mut values = vec_set::into_keys(*source);
        sort_type_names(&mut values);
        vec_set::from_keys(values)
    }

    public(package) fun sorted_byte_values(
        source: &VecSet<vector<u8>>,
    ): VecSet<vector<u8>> {
        let mut values = vec_set::into_keys(*source);
        sort_bytes(&mut values);
        vec_set::from_keys(values)
    }

    public(package) fun is_canonical_opportunity_id(value: &vector<u8>): bool {
        if (vector::length(value) != OPPORTUNITY_ID_LEN) return false;
        if (
            *vector::borrow(value, 0) != 100 ||
            *vector::borrow(value, 1) != 97 ||
            *vector::borrow(value, 2) != 121 ||
            *vector::borrow(value, 3) != 111 ||
            *vector::borrow(value, 4) != 112
        ) return false;
        let mut i = 5;
        while (i < OPPORTUNITY_ID_LEN) {
            if (!is_lower_hex(*vector::borrow(value, i))) return false;
            i = i + 1;
        };
        true
    }

    public(package) fun is_canonical_chain_id(value: &vector<u8>): bool {
        let n = vector::length(value);
        if (n == 0 || n > MAX_CHAIN_ID_LEN) return false;
        if (!is_lower_alpha(*vector::borrow(value, 0))) return false;
        let mut i = 1;
        while (i < n) {
            let c = *vector::borrow(value, i);
            if (!is_lower_alpha(c) && !is_digit(c) && c != 45 && c != 95) return false;
            i = i + 1;
        };
        true
    }

    fun sort_type_names(values: &mut vector<TypeName>) {
        let n = vector::length(values);
        let mut i = 0;
        while (i < n) {
            let mut least = i;
            let mut j = i + 1;
            while (j < n) {
                if (bytes_before(
                    ascii::as_bytes(type_name::as_string(vector::borrow(values, j))),
                    ascii::as_bytes(type_name::as_string(vector::borrow(values, least))),
                )) least = j;
                j = j + 1;
            };
            if (least != i) vector::swap(values, i, least);
            i = i + 1;
        }
    }

    fun sort_bytes(values: &mut vector<vector<u8>>) {
        let n = vector::length(values);
        let mut i = 0;
        while (i < n) {
            let mut least = i;
            let mut j = i + 1;
            while (j < n) {
                if (bytes_before(vector::borrow(values, j), vector::borrow(values, least))) {
                    least = j;
                };
                j = j + 1;
            };
            if (least != i) vector::swap(values, i, least);
            i = i + 1;
        }
    }

    public(package) fun bytes_before(left: &vector<u8>, right: &vector<u8>): bool {
        let left_n = vector::length(left);
        let right_n = vector::length(right);
        let common_n = if (left_n < right_n) left_n else right_n;
        let mut i = 0;
        while (i < common_n) {
            let left_byte = *vector::borrow(left, i);
            let right_byte = *vector::borrow(right, i);
            if (left_byte < right_byte) return true;
            if (left_byte > right_byte) return false;
            i = i + 1;
        };
        left_n < right_n
    }

    fun is_lower_alpha(c: u8): bool { c >= 97 && c <= 122 }
    fun is_digit(c: u8): bool { c >= 48 && c <= 57 }
    fun is_lower_hex(c: u8): bool { is_digit(c) || (c >= 97 && c <= 102) }
}
