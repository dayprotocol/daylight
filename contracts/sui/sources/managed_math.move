// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
/// Overflow-safe virtual-offset share arithmetic shared by managed ledgers.
module day::managed_math {
    const VIRTUAL_SHARES: u128 = 1_000;
    const VIRTUAL_ASSETS: u128 = 1_000;
    const PPS_SCALE: u128 = 1_000_000;
    const E_ZERO_AMOUNT: u64 = 1;
    const E_ZERO_SHARES: u64 = 2;

    public(package) fun to_shares(
        assets_micros: u128,
        total_assets_micros: u128,
        total_shares: u128,
    ): u128 {
        assert!(assets_micros > 0, E_ZERO_AMOUNT);
        let numerator = (assets_micros as u256)
            * ((total_shares as u256) + (VIRTUAL_SHARES as u256));
        let denominator = (total_assets_micros as u256) + (VIRTUAL_ASSETS as u256);
        (numerator / denominator) as u128
    }

    public(package) fun to_assets(
        shares: u128,
        total_assets_micros: u128,
        total_shares: u128,
    ): u128 {
        assert!(shares > 0, E_ZERO_SHARES);
        if (total_shares == 0) return 0;
        let numerator = (shares as u256)
            * ((total_assets_micros as u256) + (VIRTUAL_ASSETS as u256));
        let denominator = (total_shares as u256) + (VIRTUAL_SHARES as u256);
        (numerator / denominator) as u128
    }

    public(package) fun price_per_share(
        total_assets_micros: u128,
        total_shares: u128,
    ): u128 {
        if (total_shares == 0) return PPS_SCALE;
        let numerator = ((total_assets_micros as u256) + (VIRTUAL_ASSETS as u256))
            * (PPS_SCALE as u256);
        let denominator = (total_shares as u256) + (VIRTUAL_SHARES as u256);
        (numerator / denominator) as u128
    }
}
