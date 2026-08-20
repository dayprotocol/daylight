// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
//! DAY-962 — Solidity ABI codecs for Mayan/MCTP peer wire model (docs/66).
//!
//! Pure encode/hash helpers for `Route` / `DepositIntent` / `WithdrawalRequest` /
//! `WithdrawalContext` / `ReturnIntent` that must be byte-for-byte compatible
//! with `DayRouterExecutor.sol` and `IDayWithdrawalTransport.sol`.
//!
//! Uses Solidity ABI **static** encoding (no dynamic head/tail): every field is
//! a fixed-width word or nested static struct. Nested structs are inlined in
//! declaration order. `keccak256` is Solana's program-compatible hasher so
//! on-chain and unit tests share one path.
//!
//! This module never moves tokens, never promotes a pair, and never invents
//! peer readiness. It freezes the wire surface for reverse-attestation wiring.

use solana_program::keccak;

/// Solidity `keccak256("DAY_PROTOCOL_WORMHOLE_WITHDRAWAL_V1")` domain separator.
/// Computed once at first use via the same hasher the EVM side uses.
pub fn wormhole_withdrawal_domain_separator() -> [u8; 32] {
    keccak::hash(b"DAY_PROTOCOL_WORMHOLE_WITHDRAWAL_V1").to_bytes()
}

/// EVM-compatible route (docs/66 `RouteV1` / Solidity `Route`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RouteV1 {
    pub day_chain_id: u32,
    pub mctp_domain: u32,
    pub owner: [u8; 32],
    pub token: [u8; 32],
    pub bridge_token: [u8; 32],
    pub executor: [u8; 32],
}

impl RouteV1 {
    /// ABI word count (6 static fields).
    pub const ABI_WORDS: usize = 6;
    pub const ABI_LEN: usize = Self::ABI_WORDS * 32;

    pub fn abi_encode(&self) -> [u8; Self::ABI_LEN] {
        let mut out = [0u8; Self::ABI_LEN];
        write_u32_word(&mut out, 0, self.day_chain_id);
        write_u32_word(&mut out, 1, self.mctp_domain);
        write_bytes32(&mut out, 2, &self.owner);
        write_bytes32(&mut out, 3, &self.token);
        write_bytes32(&mut out, 4, &self.bridge_token);
        write_bytes32(&mut out, 5, &self.executor);
        out
    }

    pub fn abi_decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::ABI_LEN {
            return None;
        }
        Some(Self {
            day_chain_id: read_u32_word(bytes, 0)?,
            mctp_domain: read_u32_word(bytes, 1)?,
            owner: read_bytes32(bytes, 2)?,
            token: read_bytes32(bytes, 3)?,
            bridge_token: read_bytes32(bytes, 4)?,
            executor: read_bytes32(bytes, 5)?,
        })
    }
}

/// Deposit intent (docs/66 / Solidity `DepositIntent`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DepositIntentV1 {
    pub day_tx_id: [u8; 32],
    /// EVM controller (20 bytes); left-padded to word when encoded.
    pub controller: [u8; 20],
    pub source: RouteV1,
    pub destination: RouteV1,
    pub opportunity_id: [u8; 32],
    pub adapter_id: [u8; 32],
    pub source_amount: [u8; 32], // uint256 BE
    pub source_bridge_amount: [u8; 32],
    pub min_destination_amount: [u8; 32],
    pub min_bridge_return_amount: [u8; 32],
    pub min_return_amount: [u8; 32],
    pub deadline: u64,
    pub adapter_data_hash: [u8; 32],
}

impl DepositIntentV1 {
    /// 1 + 1 + 6 + 6 + 1 + 1 + 5 + 1 + 1 = 23 words.
    pub const ABI_WORDS: usize = 23;
    pub const ABI_LEN: usize = Self::ABI_WORDS * 32;

    pub fn abi_encode(&self) -> Vec<u8> {
        let mut out = vec![0u8; Self::ABI_LEN];
        write_bytes32_slice(&mut out, 0, &self.day_tx_id);
        write_address_word(&mut out, 1, &self.controller);
        out[2 * 32..2 * 32 + RouteV1::ABI_LEN].copy_from_slice(&self.source.abi_encode());
        out[8 * 32..8 * 32 + RouteV1::ABI_LEN].copy_from_slice(&self.destination.abi_encode());
        write_bytes32_slice(&mut out, 14, &self.opportunity_id);
        write_bytes32_slice(&mut out, 15, &self.adapter_id);
        write_bytes32_slice(&mut out, 16, &self.source_amount);
        write_bytes32_slice(&mut out, 17, &self.source_bridge_amount);
        write_bytes32_slice(&mut out, 18, &self.min_destination_amount);
        write_bytes32_slice(&mut out, 19, &self.min_bridge_return_amount);
        write_bytes32_slice(&mut out, 20, &self.min_return_amount);
        write_u64_word_slice(&mut out, 21, self.deadline);
        write_bytes32_slice(&mut out, 22, &self.adapter_data_hash);
        out
    }

    pub fn commitment_hash(&self) -> [u8; 32] {
        keccak::hash(&self.abi_encode()).to_bytes()
    }

    /// Decode a static Solidity ABI DepositIntent body (exact `ABI_LEN` bytes).
    /// Rejects non-canonical u32/u64 padding and wrong length. Used by Path-B
    /// residual preflight so a malformed compose cannot look like progress.
    pub fn abi_decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::ABI_LEN {
            return None;
        }
        let source = RouteV1::abi_decode(&bytes[2 * 32..2 * 32 + RouteV1::ABI_LEN])?;
        let destination = RouteV1::abi_decode(&bytes[8 * 32..8 * 32 + RouteV1::ABI_LEN])?;
        Some(Self {
            day_tx_id: read_bytes32(bytes, 0)?,
            controller: read_address_word(bytes, 1)?,
            source,
            destination,
            opportunity_id: read_bytes32(bytes, 14)?,
            adapter_id: read_bytes32(bytes, 15)?,
            source_amount: read_bytes32(bytes, 16)?,
            source_bridge_amount: read_bytes32(bytes, 17)?,
            min_destination_amount: read_bytes32(bytes, 18)?,
            min_bridge_return_amount: read_bytes32(bytes, 19)?,
            min_return_amount: read_bytes32(bytes, 20)?,
            deadline: read_u64_word(bytes, 21)?,
            adapter_data_hash: read_bytes32(bytes, 22)?,
        })
    }
}

/// Source-signed withdrawal request (Solidity `WithdrawalRequest`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WithdrawalRequestV1 {
    pub day_tx_id: [u8; 32],
    pub controller: [u8; 20],
    pub source: RouteV1,
    pub destination: RouteV1,
    pub opportunity_id: [u8; 32],
    pub adapter_id: [u8; 32],
    pub position_amount: [u8; 32],
    pub min_bridge_return_amount: [u8; 32],
    pub min_return_amount: [u8; 32],
    pub deadline: u64,
    pub redeem_fee: u64,
    pub adapter_data_hash: [u8; 32],
    pub full_refund: bool,
}

impl WithdrawalRequestV1 {
    /// 1+1+6+6+1+1+3+1+1+1+1 = 23 words (matches DepositIntent field count shape).
    pub const ABI_WORDS: usize = 23;
    pub const ABI_LEN: usize = Self::ABI_WORDS * 32;

    pub fn abi_encode(&self) -> Vec<u8> {
        let mut out = vec![0u8; Self::ABI_LEN];
        write_bytes32_slice(&mut out, 0, &self.day_tx_id);
        write_address_word(&mut out, 1, &self.controller);
        out[2 * 32..2 * 32 + RouteV1::ABI_LEN].copy_from_slice(&self.source.abi_encode());
        out[8 * 32..8 * 32 + RouteV1::ABI_LEN].copy_from_slice(&self.destination.abi_encode());
        write_bytes32_slice(&mut out, 14, &self.opportunity_id);
        write_bytes32_slice(&mut out, 15, &self.adapter_id);
        write_bytes32_slice(&mut out, 16, &self.position_amount);
        write_bytes32_slice(&mut out, 17, &self.min_bridge_return_amount);
        write_bytes32_slice(&mut out, 18, &self.min_return_amount);
        write_u64_word_slice(&mut out, 19, self.deadline);
        write_u64_word_slice(&mut out, 20, self.redeem_fee);
        write_bytes32_slice(&mut out, 21, &self.adapter_data_hash);
        write_bool_word_slice(&mut out, 22, self.full_refund);
        out
    }

    /// `request_id = keccak256(abi.encode(WithdrawalRequestV1, uint256(nonce)))`.
    /// Matches EVM DayRouterExecutor typed-tuple encoding (docs/66).
    pub fn request_id(&self, nonce: u64) -> [u8; 32] {
        let mut buf = self.abi_encode();
        let mut nonce_word = [0u8; 32];
        // uint256 big-endian of nonce (fits in last 8 bytes)
        nonce_word[24..32].copy_from_slice(&nonce.to_be_bytes());
        buf.extend_from_slice(&nonce_word);
        keccak::hash(&buf).to_bytes()
    }

    /// Decode static Solidity ABI WithdrawalRequest body (exact `ABI_LEN` bytes).
    /// Used by Path-B reverse-attestation residual preflight (docs/66 §6).
    pub fn abi_decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::ABI_LEN {
            return None;
        }
        let source = RouteV1::abi_decode(&bytes[2 * 32..2 * 32 + RouteV1::ABI_LEN])?;
        let destination = RouteV1::abi_decode(&bytes[8 * 32..8 * 32 + RouteV1::ABI_LEN])?;
        Some(Self {
            day_tx_id: read_bytes32(bytes, 0)?,
            controller: read_address_word(bytes, 1)?,
            source,
            destination,
            opportunity_id: read_bytes32(bytes, 14)?,
            adapter_id: read_bytes32(bytes, 15)?,
            position_amount: read_bytes32(bytes, 16)?,
            min_bridge_return_amount: read_bytes32(bytes, 17)?,
            min_return_amount: read_bytes32(bytes, 18)?,
            deadline: read_u64_word(bytes, 19)?,
            redeem_fee: read_u64_word(bytes, 20)?,
            adapter_data_hash: read_bytes32(bytes, 21)?,
            full_refund: read_bool_word(bytes, 22)?,
        })
    }
}

/// Authenticated withdrawal context carried in Wormhole VAA (Solidity `WithdrawalContext`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WithdrawalContextV1 {
    pub request_id: [u8; 32],
    pub day_tx_id: [u8; 32],
    pub controller: [u8; 20],
    pub source_chain_id: u32,
    pub source_executor: [u8; 32],
    pub source_route_hash: [u8; 32],
    pub origin_owner: [u8; 32],
    pub origin_token: [u8; 32],
    pub origin_bridge_token: [u8; 32],
    pub destination_chain_id: u32,
    pub destination_executor: [u8; 32],
    pub destination_route_hash: [u8; 32],
    pub opportunity_id: [u8; 32],
    pub adapter_id: [u8; 32],
    pub position_amount: [u8; 32],
    pub min_bridge_return_amount: [u8; 32],
    pub min_return_amount: [u8; 32],
    pub deadline: u64,
    pub redeem_fee: u64,
    pub adapter_data_hash: [u8; 32],
    pub full_refund: bool,
}

impl WithdrawalContextV1 {
    /// Static field word count (no nested Route).
    pub const ABI_WORDS: usize = 21;
    pub const ABI_LEN: usize = Self::ABI_WORDS * 32;

    pub fn abi_encode(&self) -> Vec<u8> {
        let mut out = vec![0u8; Self::ABI_LEN];
        write_bytes32_slice(&mut out, 0, &self.request_id);
        write_bytes32_slice(&mut out, 1, &self.day_tx_id);
        write_address_word(&mut out, 2, &self.controller);
        write_u32_word_slice(&mut out, 3, self.source_chain_id);
        write_bytes32_slice(&mut out, 4, &self.source_executor);
        write_bytes32_slice(&mut out, 5, &self.source_route_hash);
        write_bytes32_slice(&mut out, 6, &self.origin_owner);
        write_bytes32_slice(&mut out, 7, &self.origin_token);
        write_bytes32_slice(&mut out, 8, &self.origin_bridge_token);
        write_u32_word_slice(&mut out, 9, self.destination_chain_id);
        write_bytes32_slice(&mut out, 10, &self.destination_executor);
        write_bytes32_slice(&mut out, 11, &self.destination_route_hash);
        write_bytes32_slice(&mut out, 12, &self.opportunity_id);
        write_bytes32_slice(&mut out, 13, &self.adapter_id);
        write_bytes32_slice(&mut out, 14, &self.position_amount);
        write_bytes32_slice(&mut out, 15, &self.min_bridge_return_amount);
        write_bytes32_slice(&mut out, 16, &self.min_return_amount);
        write_u64_word_slice(&mut out, 17, self.deadline);
        write_u64_word_slice(&mut out, 18, self.redeem_fee);
        write_bytes32_slice(&mut out, 19, &self.adapter_data_hash);
        write_bool_word_slice(&mut out, 20, self.full_refund);
        out
    }

    /// Wormhole payload:
    /// `abi.encode(domain, uint8(1), uint8(1), WithdrawalContextV1)`.
    pub fn wormhole_payload_encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(32 * 3 + Self::ABI_LEN);
        out.extend_from_slice(&wormhole_withdrawal_domain_separator());
        let mut version_word = [0u8; 32];
        version_word[31] = 1;
        out.extend_from_slice(&version_word);
        let mut action_word = [0u8; 32];
        action_word[31] = 1;
        out.extend_from_slice(&action_word);
        out.extend_from_slice(&self.abi_encode());
        out
    }

    pub fn payload_hash(&self) -> [u8; 32] {
        keccak::hash(&self.wormhole_payload_encode()).to_bytes()
    }
}

/// Return intent for final owner redemption (Solidity `ReturnIntent`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReturnIntentV1 {
    pub day_tx_id: [u8; 32],
    pub request_id: [u8; 32],
    pub withdrawal_id: [u8; 32],
    pub controller: [u8; 20],
    pub source: RouteV1,
    pub destination: RouteV1,
    pub opportunity_id: [u8; 32],
    pub adapter_id: [u8; 32],
    pub amount: [u8; 32],
    pub min_bridge_return_amount: [u8; 32],
    pub min_amount: [u8; 32],
    pub deadline: u64,
}

impl ReturnIntentV1 {
    /// 1+1+1+1+6+6+1+1+3+1 = 22 words.
    pub const ABI_WORDS: usize = 22;
    pub const ABI_LEN: usize = Self::ABI_WORDS * 32;

    pub fn abi_encode(&self) -> Vec<u8> {
        let mut out = vec![0u8; Self::ABI_LEN];
        write_bytes32_slice(&mut out, 0, &self.day_tx_id);
        write_bytes32_slice(&mut out, 1, &self.request_id);
        write_bytes32_slice(&mut out, 2, &self.withdrawal_id);
        write_address_word(&mut out, 3, &self.controller);
        out[4 * 32..4 * 32 + RouteV1::ABI_LEN].copy_from_slice(&self.source.abi_encode());
        out[10 * 32..10 * 32 + RouteV1::ABI_LEN].copy_from_slice(&self.destination.abi_encode());
        write_bytes32_slice(&mut out, 16, &self.opportunity_id);
        write_bytes32_slice(&mut out, 17, &self.adapter_id);
        write_bytes32_slice(&mut out, 18, &self.amount);
        write_bytes32_slice(&mut out, 19, &self.min_bridge_return_amount);
        write_bytes32_slice(&mut out, 20, &self.min_amount);
        write_u64_word_slice(&mut out, 21, self.deadline);
        out
    }

    pub fn commitment_hash(&self) -> [u8; 32] {
        keccak::hash(&self.abi_encode()).to_bytes()
    }

    /// Decode static Solidity ABI ReturnIntent body (exact `ABI_LEN` bytes).
    /// Used by Path-B return-bridge residual preflight (docs/66 §8–§9).
    pub fn abi_decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() != Self::ABI_LEN {
            return None;
        }
        let source = RouteV1::abi_decode(&bytes[4 * 32..4 * 32 + RouteV1::ABI_LEN])?;
        let destination = RouteV1::abi_decode(&bytes[10 * 32..10 * 32 + RouteV1::ABI_LEN])?;
        Some(Self {
            day_tx_id: read_bytes32(bytes, 0)?,
            request_id: read_bytes32(bytes, 1)?,
            withdrawal_id: read_bytes32(bytes, 2)?,
            controller: read_address_word(bytes, 3)?,
            source,
            destination,
            opportunity_id: read_bytes32(bytes, 16)?,
            adapter_id: read_bytes32(bytes, 17)?,
            amount: read_bytes32(bytes, 18)?,
            min_bridge_return_amount: read_bytes32(bytes, 19)?,
            min_amount: read_bytes32(bytes, 20)?,
            deadline: read_u64_word(bytes, 21)?,
        })
    }
}

/// Encode a u64 amount into a uint256 big-endian word (upper 24 bytes zero).
pub fn u64_as_uint256(v: u64) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[24..32].copy_from_slice(&v.to_be_bytes());
    out
}

/// Left-pad a 20-byte EVM address into a 32-byte owner/executor word.
pub fn left_pad_address20(addr: &[u8; 20]) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[12..32].copy_from_slice(addr);
    out
}

// ── word helpers ────────────────────────────────────────────────────────────

fn write_u32_word(buf: &mut [u8; RouteV1::ABI_LEN], word: usize, v: u32) {
    let start = word * 32 + 28;
    buf[start..start + 4].copy_from_slice(&v.to_be_bytes());
}

fn write_u32_word_slice(buf: &mut [u8], word: usize, v: u32) {
    let start = word * 32 + 28;
    buf[start..start + 4].copy_from_slice(&v.to_be_bytes());
}

fn write_u64_word_slice(buf: &mut [u8], word: usize, v: u64) {
    let start = word * 32 + 24;
    buf[start..start + 8].copy_from_slice(&v.to_be_bytes());
}

fn write_bool_word_slice(buf: &mut [u8], word: usize, v: bool) {
    buf[word * 32 + 31] = if v { 1 } else { 0 };
}

fn write_bytes32(buf: &mut [u8; RouteV1::ABI_LEN], word: usize, v: &[u8; 32]) {
    let start = word * 32;
    buf[start..start + 32].copy_from_slice(v);
}

fn write_bytes32_slice(buf: &mut [u8], word: usize, v: &[u8; 32]) {
    let start = word * 32;
    buf[start..start + 32].copy_from_slice(v);
}

fn write_address_word(buf: &mut [u8], word: usize, addr: &[u8; 20]) {
    let start = word * 32 + 12;
    buf[start..start + 20].copy_from_slice(addr);
}

fn read_u32_word(buf: &[u8], word: usize) -> Option<u32> {
    let start = word * 32;
    // upper 28 bytes must be zero for canonical encode
    if buf[start..start + 28].iter().any(|b| *b != 0) {
        return None;
    }
    let mut be = [0u8; 4];
    be.copy_from_slice(&buf[start + 28..start + 32]);
    Some(u32::from_be_bytes(be))
}

fn read_bytes32(buf: &[u8], word: usize) -> Option<[u8; 32]> {
    let start = word * 32;
    let mut out = [0u8; 32];
    out.copy_from_slice(&buf[start..start + 32]);
    Some(out)
}

fn read_u64_word(buf: &[u8], word: usize) -> Option<u64> {
    let start = word * 32;
    if buf[start..start + 24].iter().any(|b| *b != 0) {
        return None;
    }
    let mut be = [0u8; 8];
    be.copy_from_slice(&buf[start + 24..start + 32]);
    Some(u64::from_be_bytes(be))
}

fn read_address_word(buf: &[u8], word: usize) -> Option<[u8; 20]> {
    let start = word * 32;
    // left-pad zeros (12 bytes) then 20-byte address
    if buf[start..start + 12].iter().any(|b| *b != 0) {
        return None;
    }
    let mut out = [0u8; 20];
    out.copy_from_slice(&buf[start + 12..start + 32]);
    Some(out)
}

fn read_bool_word(buf: &[u8], word: usize) -> Option<bool> {
    let start = word * 32;
    if buf[start..start + 31].iter().any(|b| *b != 0) {
        return None;
    }
    match buf[start + 31] {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_route() -> RouteV1 {
        RouteV1 {
            day_chain_id: 501,
            mctp_domain: 5,
            owner: [0x11; 32],
            token: [0x22; 32],
            bridge_token: [0x33; 32],
            executor: [0x44; 32],
        }
    }

    #[test]
    fn route_round_trip_and_length() {
        let r = sample_route();
        let enc = r.abi_encode();
        assert_eq!(enc.len(), 192);
        // day_chain_id 501 at end of first word
        assert_eq!(&enc[28..32], &501u32.to_be_bytes());
        // mctp_domain 5
        assert_eq!(&enc[60..64], &5u32.to_be_bytes());
        let back = RouteV1::abi_decode(&enc).unwrap();
        assert_eq!(back, r);
    }

    #[test]
    fn route_rejects_noncanonical_u32_padding() {
        let mut enc = sample_route().abi_encode();
        enc[0] = 1; // pollute padding
        assert!(RouteV1::abi_decode(&enc).is_none());
    }

    #[test]
    fn deposit_intent_length_and_hash_stable() {
        let intent = DepositIntentV1 {
            day_tx_id: [0xaa; 32],
            controller: [0xbb; 20],
            source: sample_route(),
            destination: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: [0x55; 32],
                token: [0x66; 32],
                bridge_token: [0x77; 32],
                executor: [0x88; 32],
            },
            opportunity_id: [0x01; 32],
            adapter_id: [0x02; 32],
            source_amount: u64_as_uint256(1_000_000),
            source_bridge_amount: u64_as_uint256(999_000),
            min_destination_amount: u64_as_uint256(900_000),
            min_bridge_return_amount: u64_as_uint256(890_000),
            min_return_amount: u64_as_uint256(880_000),
            deadline: 1_700_000_000,
            adapter_data_hash: [0x03; 32],
        };
        let enc = intent.abi_encode();
        assert_eq!(enc.len(), DepositIntentV1::ABI_LEN);
        // controller address right-aligned in word 1
        assert_eq!(&enc[32 + 12..64], &[0xbb; 20]);
        let h1 = intent.commitment_hash();
        let h2 = intent.commitment_hash();
        assert_eq!(h1, h2);
        assert_ne!(h1, [0u8; 32]);
        let back = DepositIntentV1::abi_decode(&enc).expect("round-trip decode");
        assert_eq!(back.day_tx_id, intent.day_tx_id);
        assert_eq!(back.controller, intent.controller);
        assert_eq!(back.source, intent.source);
        assert_eq!(back.destination, intent.destination);
        assert_eq!(back.deadline, intent.deadline);
        assert_eq!(back.source_amount, intent.source_amount);
        assert!(DepositIntentV1::abi_decode(&enc[..enc.len() - 1]).is_none());
    }

    #[test]
    fn request_id_changes_with_nonce_and_is_deterministic() {
        let req = WithdrawalRequestV1 {
            day_tx_id: [0x10; 32],
            controller: [0x20; 20],
            source: sample_route(),
            destination: sample_route(),
            opportunity_id: [0x30; 32],
            adapter_id: [0x40; 32],
            position_amount: u64_as_uint256(5_000_000),
            min_bridge_return_amount: u64_as_uint256(4_500_000),
            min_return_amount: u64_as_uint256(4_400_000),
            deadline: 1_800_000_000,
            redeem_fee: 100,
            adapter_data_hash: [0x50; 32],
            full_refund: false,
        };
        let id0 = req.request_id(0);
        let id1 = req.request_id(1);
        assert_ne!(id0, id1);
        assert_eq!(id0, req.request_id(0));
        let enc = req.abi_encode();
        assert_eq!(enc.len(), WithdrawalRequestV1::ABI_LEN);
        let back = WithdrawalRequestV1::abi_decode(&enc).expect("withdrawal round-trip");
        assert_eq!(back.day_tx_id, req.day_tx_id);
        assert_eq!(back.controller, req.controller);
        assert_eq!(back.redeem_fee, 100);
        assert_eq!(back.full_refund, false);
        assert_eq!(back.position_amount, req.position_amount);
        assert!(WithdrawalRequestV1::abi_decode(&enc[..enc.len() - 1]).is_none());
    }

    #[test]
    fn wormhole_payload_has_domain_version_action_prefix() {
        let ctx = WithdrawalContextV1 {
            request_id: [0x01; 32],
            day_tx_id: [0x02; 32],
            controller: [0x03; 20],
            source_chain_id: 501,
            source_executor: [0x04; 32],
            source_route_hash: [0x05; 32],
            origin_owner: [0x06; 32],
            origin_token: [0x07; 32],
            origin_bridge_token: [0x08; 32],
            destination_chain_id: 8453,
            destination_executor: [0x09; 32],
            destination_route_hash: [0x0a; 32],
            opportunity_id: [0x0b; 32],
            adapter_id: [0x0c; 32],
            position_amount: u64_as_uint256(1),
            min_bridge_return_amount: u64_as_uint256(1),
            min_return_amount: u64_as_uint256(1),
            deadline: 99,
            redeem_fee: 0,
            adapter_data_hash: [0x0d; 32],
            full_refund: true,
        };
        let payload = ctx.wormhole_payload_encode();
        assert_eq!(
            &payload[0..32],
            &wormhole_withdrawal_domain_separator()
        );
        assert_eq!(payload[63], 1); // version
        assert_eq!(payload[95], 1); // action
        assert_eq!(payload.len(), 32 * 3 + WithdrawalContextV1::ABI_LEN);
        assert_eq!(ctx.payload_hash(), keccak::hash(&payload).to_bytes());
    }

    #[test]
    fn return_intent_length() {
        let ri = ReturnIntentV1 {
            day_tx_id: [1; 32],
            request_id: [2; 32],
            withdrawal_id: [3; 32],
            controller: [4; 20],
            source: sample_route(),
            destination: sample_route(),
            opportunity_id: [5; 32],
            adapter_id: [6; 32],
            amount: u64_as_uint256(10),
            min_bridge_return_amount: u64_as_uint256(9),
            min_amount: u64_as_uint256(8),
            deadline: 42,
        };
        let enc = ri.abi_encode();
        assert_eq!(enc.len(), ReturnIntentV1::ABI_LEN);
        assert_ne!(ri.commitment_hash(), [0u8; 32]);
        let back = ReturnIntentV1::abi_decode(&enc).expect("return intent round-trip");
        assert_eq!(back.day_tx_id, ri.day_tx_id);
        assert_eq!(back.request_id, ri.request_id);
        assert_eq!(back.withdrawal_id, ri.withdrawal_id);
        assert_eq!(back.deadline, 42);
        assert_eq!(back.amount, ri.amount);
        assert!(ReturnIntentV1::abi_decode(&enc[..enc.len() - 1]).is_none());
    }

    #[test]
    fn left_pad_and_uint256_helpers() {
        let addr = [0xab; 20];
        let padded = left_pad_address20(&addr);
        assert_eq!(&padded[0..12], &[0u8; 12]);
        assert_eq!(&padded[12..], &addr);
        let u = u64_as_uint256(0x1122334455667788);
        assert_eq!(&u[0..24], &[0u8; 24]);
        assert_eq!(&u[24..], &0x1122334455667788u64.to_be_bytes());
    }
}
