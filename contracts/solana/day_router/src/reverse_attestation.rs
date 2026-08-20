// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
//! DAY-962 — reverse-attestation / full MCTP proof-path foundation (docs/66 §4–§9).
//!
//! Freezes Borsh param layouts, PDA seeds, and fail-closed execution gates for:
//!   - InitiateHandoffDeposit       (tag 19) — Sol-origin MCTP custom-payload start
//!   - RedeemHandoffDeposit         (tag 20) — proof-bound destination redeem
//!   - RequestRemoteWithdrawal      (tag 21) — Wormhole reverse attestation publish
//!   - ExecuteVerifiedWithdrawal    (tag 22) — consume remote withdrawal VAA + exit
//!   - BridgeWithdrawalReturn       (tag 23) — Mayan return bridge from Solana
//!   - RedeemReturnToOwner          (tag 24) — exact original-owner final redeem
//!
//! Rail-agnostic path A (tags 17/18 ReceiveAndForwardDeposit / ExitHandoffToOrigin)
//! is ALREADY live and path-A FULL RT proven (base↔solana jupiter-lend, owner-direct
//! reverse). These tags are path B: on-chain MCTP proof + Wormhole reverse
//! attestation + exact-owner redeem. Every handler returns a terminal fail-closed
//! error before any token movement or peer allocation.
//!
//! Pair GO / depositableLive remain false until measured lockstep digests +
//! bilateral peers land (DAY-980 ceremony). This module never promotes.

use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::AccountInfo, entrypoint::ProgramResult, msg, program_error::ProgramError,
    pubkey::Pubkey,
};

use crate::{
    handoff_custody_pda, handoff_position_pda, mctp_config_pda, mctp_peer_pda, DepositIntentV1,
    DayError, ReturnIntentV1, WithdrawalRequestV1, ASSOCIATED_TOKEN_PROGRAM_ID, CANONICAL_USDC_MINT,
    CCTP_DOMAIN_SOLANA, CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID, CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
    DAY_CHAIN_ID_SOLANA, MAYAN_MCTP_PROGRAM_ID, MCTP_CONFIG_VERSION_SEED, REGISTRY_V2_SEED,
    SPL_TOKEN_PROGRAM_ID, WORMHOLE_CORE_PROGRAM_ID,
};

// ── PDA seeds (versioned; never reinterpret a v1 account as v2) ─────────────

/// Source-intent receipt: Sol-origin deposit before Mayan CPI lands.
pub const SOURCE_INTENT_RECEIPT_SEED: &[u8] = b"mctp_source_intent";
/// Receive receipt: single-use proof of destination redeem (day_tx_id bound).
pub const RECEIVE_RECEIPT_SEED: &[u8] = b"mctp_receive_receipt";
/// Withdrawal request PDA: Sol-origin owner command for EVM-held position.
pub const WITHDRAWAL_REQUEST_SEED: &[u8] = b"mctp_withdrawal_req";
/// Return receipt: single-use return redeem to exact original owner.
pub const RETURN_RECEIPT_SEED: &[u8] = b"mctp_return";

/// Borsh layout version for reverse-attestation accounts (v1 frozen).
pub const REVERSE_ATTESTATION_ACCOUNT_VERSION: u8 = 1;

// Discriminators ("DAY_SINT", "DAY_RCPT", "DAY_WREQ", "DAY_RRET") as u64 LE tags.
pub const SOURCE_INTENT_RECEIPT_DISCRIMINATOR: u64 = 0x4441_595f_5349_4e54;
pub const RECEIVE_RECEIPT_DISCRIMINATOR: u64 = 0x4441_595f_5243_5054;
pub const WITHDRAWAL_REQUEST_DISCRIMINATOR: u64 = 0x4441_595f_5752_4551;
pub const RETURN_RECEIPT_DISCRIMINATOR: u64 = 0x4441_595f_5252_4554;

// ── Borsh param surfaces (frozen; handlers fail-closed before use) ──────────

/// InitiateHandoffDeposit params (docs/66 §4). ABI bytes are Solidity-encoded
/// DepositIntentV1; never trusted as value-truth without measured deltas.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct InitiateHandoffParams {
    pub deposit_intent_abi: Vec<u8>,
    pub adapter_data: Vec<u8>,
    pub mayan_quote_commitment: [u8; 32],
    pub mayan_instruction_manifest_hash: [u8; 32],
}

/// RedeemHandoffDeposit params (docs/66 §5) — proof bundle + intent.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct RedeemHandoffParams {
    pub deposit_intent_abi: Vec<u8>,
    pub adapter_data: Vec<u8>,
    pub cctp_message: Vec<u8>,
    pub cctp_attestation: Vec<u8>,
    pub wormhole_signed_vaa: Vec<u8>,
    pub mayan_redeem_manifest_hash: [u8; 32],
}

/// RequestRemoteWithdrawal params (docs/66 §6).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct RequestRemoteWithdrawalParams {
    pub withdrawal_request_abi: Vec<u8>,
}

/// ExecuteVerifiedWithdrawal params (docs/66 §7).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct ExecuteVerifiedWithdrawalParams {
    pub request_id: [u8; 32],
    pub withdrawal_request_abi: Vec<u8>,
    pub withdrawal_vaa: Vec<u8>,
    pub adapter_data: Vec<u8>,
}

/// BridgeWithdrawalReturn params (docs/66 §8).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct BridgeWithdrawalReturnParams {
    pub withdrawal_id: [u8; 32],
    pub return_intent_abi: Vec<u8>,
    pub mayan_quote_commitment: [u8; 32],
    pub mayan_instruction_manifest_hash: [u8; 32],
}

/// RedeemReturnToOwner params (docs/66 §9).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct RedeemReturnToOwnerParams {
    pub return_intent_abi: Vec<u8>,
    pub cctp_message: Vec<u8>,
    pub cctp_attestation: Vec<u8>,
    pub wormhole_signed_vaa: Vec<u8>,
    pub mayan_redeem_manifest_hash: [u8; 32],
}

// ── Account layout lengths (frozen; serialization tests lock these) ────────

/// SourceIntentReceipt fixed body (without dynamic fields).
/// disc(8) + version(1) + bump(1) + day_tx_id(32) + owner(32) + nonce(8)
/// + intent_hash(32) + peer_chain_id(4) + state(1) + pad(3) = 122
pub const SOURCE_INTENT_RECEIPT_LEN: usize = 122;

/// ReceiveReceipt: disc+ver+bump+day_tx_id+cctp_key_hash+vaa_hash+principal+state
/// 8+1+1+32+32+32+8+1+3 = 118
pub const RECEIVE_RECEIPT_LEN: usize = 118;

/// WithdrawalRequestAccount: disc+ver+bump+request_id+day_tx_id+nonce+payload_hash+state
/// 8+1+1+32+32+8+32+1+3 = 118
pub const WITHDRAWAL_REQUEST_ACCOUNT_LEN: usize = 118;

/// ReturnReceipt: disc+ver+bump+withdrawal_id+day_tx_id+owner+amount+state
/// 8+1+1+32+32+32+8+1+3 = 118
pub const RETURN_RECEIPT_LEN: usize = 118;

// ── PDA helpers ─────────────────────────────────────────────────────────────

pub fn source_intent_receipt_pda(program_id: &Pubkey, day_tx_id: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[
            SOURCE_INTENT_RECEIPT_SEED,
            day_tx_id,
            MCTP_CONFIG_VERSION_SEED,
        ],
        program_id,
    )
}

pub fn receive_receipt_pda(program_id: &Pubkey, day_tx_id: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[RECEIVE_RECEIPT_SEED, day_tx_id, MCTP_CONFIG_VERSION_SEED],
        program_id,
    )
}

pub fn withdrawal_request_pda(program_id: &Pubkey, request_id: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[
            WITHDRAWAL_REQUEST_SEED,
            request_id,
            MCTP_CONFIG_VERSION_SEED,
        ],
        program_id,
    )
}

pub fn return_receipt_pda(program_id: &Pubkey, withdrawal_id: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[
            RETURN_RECEIPT_SEED,
            withdrawal_id,
            MCTP_CONFIG_VERSION_SEED,
        ],
        program_id,
    )
}

// ── Initiate fixed account prefix (docs/66 §4) ──────────────────────────────
// Fixed roles match runtime buildPathBInitiateAccountMetas. Trailing Mayan
// WITH_FEE CPI accounts remain residual (mayan_cpi_accounts_residual).

/// Mayan payload-writer program (docs/66 source facts).
pub const MAYAN_PAYLOAD_WRITER_PROGRAM_ID: Pubkey =
    solana_program::pubkey!("DwMLtdtJqJQkHzNcrdTBuWHJByJfgpKBnvFvzyKdy3cU");

/// Fixed prefix length before residual Mayan WITH_FEE trailing accounts.
pub const PATH_B_INITIATE_FIXED_ACCOUNT_LEN: usize = 13;

pub const PATH_B_INITIATE_IX_SOURCE_OWNER: usize = 0;
pub const PATH_B_INITIATE_IX_MCTP_CONFIG: usize = 1;
pub const PATH_B_INITIATE_IX_PEER_BINDING: usize = 2;
pub const PATH_B_INITIATE_IX_SOURCE_INTENT: usize = 3;
pub const PATH_B_INITIATE_IX_OWNER_USDC: usize = 4;
pub const PATH_B_INITIATE_IX_CUSTODY_AUTH: usize = 5;
pub const PATH_B_INITIATE_IX_CUSTODY_USDC: usize = 6;
pub const PATH_B_INITIATE_IX_USDC_MINT: usize = 7;
pub const PATH_B_INITIATE_IX_TOKEN_PROGRAM: usize = 8;
pub const PATH_B_INITIATE_IX_ATA_PROGRAM: usize = 9;
pub const PATH_B_INITIATE_IX_SYSTEM_PROGRAM: usize = 10;
pub const PATH_B_INITIATE_IX_MAYAN_MCTP: usize = 11;
pub const PATH_B_INITIATE_IX_PAYLOAD_WRITER: usize = 12;

/// Canonical ATA address for (owner, mint) under SPL Token + ATA program.
pub fn path_b_usdc_ata(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(
        &[owner.as_ref(), SPL_TOKEN_PROGRAM_ID.as_ref(), mint.as_ref()],
        &ASSOCIATED_TOKEN_PROGRAM_ID,
    )
    .0
}

/// Pure fixed-account-key preflight for InitiateHandoffDeposit (docs/66 §4).
///
/// Locks PDA seeds + program pins so a compose that reaches the residual gate
/// cannot silently substitute config/peer/receipt/custody/Mayan identities.
/// Does **not** transfer tokens, allocate receipts, or CPI Mayan — callers still
/// hit `mctp_proof_path_gate` after Ok.
#[allow(clippy::too_many_arguments)]
pub fn validate_path_b_initiate_fixed_account_keys(
    program_id: &Pubkey,
    source_owner: &Pubkey,
    source_owner_is_signer: bool,
    mctp_config: &Pubkey,
    peer_binding: &Pubkey,
    source_intent_receipt: &Pubkey,
    source_owner_usdc: &Pubkey,
    source_custody_authority: &Pubkey,
    source_custody_usdc: &Pubkey,
    canonical_usdc_mint: &Pubkey,
    token_program: &Pubkey,
    associated_token_program: &Pubkey,
    system_program_key: &Pubkey,
    mayan_mctp_program: &Pubkey,
    payload_writer_program: &Pubkey,
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if !source_owner_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if day_tx_id == &[0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // v1 remote peers only (Base / Ethereum) — same namespaces as deposit intent.
    if !matches!(remote_day_chain_id, 8453 | 1) {
        return Err(ProgramError::InvalidInstructionData);
    }

    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_peer, _) = mctp_peer_pda(program_id, remote_day_chain_id);
    let (expected_intent, _) = source_intent_receipt_pda(program_id, day_tx_id);
    let (expected_custody, _) = handoff_custody_pda(program_id, day_tx_id);
    let expected_owner_usdc = path_b_usdc_ata(source_owner, &CANONICAL_USDC_MINT);
    let expected_custody_usdc = path_b_usdc_ata(&expected_custody, &CANONICAL_USDC_MINT);

    if mctp_config != &expected_config
        || peer_binding != &expected_peer
        || source_intent_receipt != &expected_intent
        || source_custody_authority != &expected_custody
        || source_owner_usdc != &expected_owner_usdc
        || source_custody_usdc != &expected_custody_usdc
        || canonical_usdc_mint != &CANONICAL_USDC_MINT
        || token_program != &SPL_TOKEN_PROGRAM_ID
        || associated_token_program != &ASSOCIATED_TOKEN_PROGRAM_ID
        || system_program_key != &solana_program::system_program::ID
        || mayan_mctp_program != &MAYAN_MCTP_PROGRAM_ID
        || payload_writer_program != &MAYAN_PAYLOAD_WRITER_PROGRAM_ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Slice-level fixed-account preflight (docs/66 §4 prefix).
///
/// Requires ≥13 accounts. Trailing Mayan CPI accounts (if any) are ignored here —
/// full CPI verify remains residual (`MctpProofPathNotWired`).
pub fn validate_path_b_initiate_fixed_accounts(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if accounts.len() < PATH_B_INITIATE_FIXED_ACCOUNT_LEN {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    validate_path_b_initiate_fixed_account_keys(
        program_id,
        accounts[PATH_B_INITIATE_IX_SOURCE_OWNER].key,
        accounts[PATH_B_INITIATE_IX_SOURCE_OWNER].is_signer,
        accounts[PATH_B_INITIATE_IX_MCTP_CONFIG].key,
        accounts[PATH_B_INITIATE_IX_PEER_BINDING].key,
        accounts[PATH_B_INITIATE_IX_SOURCE_INTENT].key,
        accounts[PATH_B_INITIATE_IX_OWNER_USDC].key,
        accounts[PATH_B_INITIATE_IX_CUSTODY_AUTH].key,
        accounts[PATH_B_INITIATE_IX_CUSTODY_USDC].key,
        accounts[PATH_B_INITIATE_IX_USDC_MINT].key,
        accounts[PATH_B_INITIATE_IX_TOKEN_PROGRAM].key,
        accounts[PATH_B_INITIATE_IX_ATA_PROGRAM].key,
        accounts[PATH_B_INITIATE_IX_SYSTEM_PROGRAM].key,
        accounts[PATH_B_INITIATE_IX_MAYAN_MCTP].key,
        accounts[PATH_B_INITIATE_IX_PAYLOAD_WRITER].key,
        day_tx_id,
        remote_day_chain_id,
    )
}

// ── Redeem fixed account prefix (docs/66 §5 / runtime buildPathBRedeemAccountMetas) ─
// Fixed roles match JS compose (16 accounts). Trailing Mayan redeem + adapter CPI
// accounts remain residual. Never allocates receipts or moves tokens.

/// Fixed prefix length before residual Mayan redeem / adapter CPI accounts.
pub const PATH_B_REDEEM_FIXED_ACCOUNT_LEN: usize = 16;

pub const PATH_B_REDEEM_IX_RELAYER: usize = 0;
pub const PATH_B_REDEEM_IX_MCTP_CONFIG: usize = 1;
pub const PATH_B_REDEEM_IX_PEER_BINDING: usize = 2;
pub const PATH_B_REDEEM_IX_RECEIVE_RECEIPT: usize = 3;
pub const PATH_B_REDEEM_IX_HANDOFF_POSITION: usize = 4;
pub const PATH_B_REDEEM_IX_CUSTODY_AUTH: usize = 5;
pub const PATH_B_REDEEM_IX_CUSTODY_USDC: usize = 6;
pub const PATH_B_REDEEM_IX_REGISTRY_V2: usize = 7;
pub const PATH_B_REDEEM_IX_USDC_MINT: usize = 8;
pub const PATH_B_REDEEM_IX_TOKEN_PROGRAM: usize = 9;
pub const PATH_B_REDEEM_IX_ATA_PROGRAM: usize = 10;
pub const PATH_B_REDEEM_IX_SYSTEM_PROGRAM: usize = 11;
pub const PATH_B_REDEEM_IX_MAYAN_MCTP: usize = 12;
pub const PATH_B_REDEEM_IX_CCTP_MT: usize = 13;
pub const PATH_B_REDEEM_IX_CCTP_TMM: usize = 14;
pub const PATH_B_REDEEM_IX_WORMHOLE: usize = 15;

/// Pure fixed-account-key preflight for RedeemHandoffDeposit (docs/66 §5).
///
/// Locks PDA seeds + CCTP/Wormhole/Mayan program pins so a redeem compose that
/// reaches the residual gate cannot silently substitute proof-path identities.
/// Does **not** verify CCTP/VAA, allocate receipts, or CPI Mayan — callers still
/// hit `mctp_proof_path_gate` after Ok.
#[allow(clippy::too_many_arguments)]
pub fn validate_path_b_redeem_fixed_account_keys(
    program_id: &Pubkey,
    relayer: &Pubkey,
    relayer_is_signer: bool,
    mctp_config: &Pubkey,
    peer_binding: &Pubkey,
    receive_receipt: &Pubkey,
    handoff_position: &Pubkey,
    custody_authority: &Pubkey,
    custody_usdc: &Pubkey,
    registry_v2: &Pubkey,
    canonical_usdc_mint: &Pubkey,
    token_program: &Pubkey,
    associated_token_program: &Pubkey,
    system_program_key: &Pubkey,
    mayan_mctp_program: &Pubkey,
    cctp_message_transmitter: &Pubkey,
    cctp_token_messenger_minter: &Pubkey,
    wormhole_core: &Pubkey,
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if !relayer_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if day_tx_id == &[0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Redeem source is the remote EVM peer (Base / Ethereum).
    if !matches!(remote_day_chain_id, 8453 | 1) {
        return Err(ProgramError::InvalidInstructionData);
    }

    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_peer, _) = mctp_peer_pda(program_id, remote_day_chain_id);
    let (expected_receive, _) = receive_receipt_pda(program_id, day_tx_id);
    let (expected_position, _) = handoff_position_pda(program_id, day_tx_id);
    let (expected_custody, _) = handoff_custody_pda(program_id, day_tx_id);
    let expected_custody_usdc = path_b_usdc_ata(&expected_custody, &CANONICAL_USDC_MINT);
    let (expected_registry, _) = Pubkey::find_program_address(&[REGISTRY_V2_SEED], program_id);

    if mctp_config != &expected_config
        || peer_binding != &expected_peer
        || receive_receipt != &expected_receive
        || handoff_position != &expected_position
        || custody_authority != &expected_custody
        || custody_usdc != &expected_custody_usdc
        || registry_v2 != &expected_registry
        || canonical_usdc_mint != &CANONICAL_USDC_MINT
        || token_program != &SPL_TOKEN_PROGRAM_ID
        || associated_token_program != &ASSOCIATED_TOKEN_PROGRAM_ID
        || system_program_key != &solana_program::system_program::ID
        || mayan_mctp_program != &MAYAN_MCTP_PROGRAM_ID
        || cctp_message_transmitter != &CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID
        || cctp_token_messenger_minter != &CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID
        || wormhole_core != &WORMHOLE_CORE_PROGRAM_ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    // Relayer is free (any signer); identity is not a DAY PDA.
    let _ = relayer;
    Ok(())
}

/// Slice-level fixed-account preflight for RedeemHandoffDeposit (docs/66 §5).
///
/// Requires ≥16 accounts. Trailing Mayan redeem / adapter CPI accounts (if any)
/// are ignored — full proof verify remains residual (`MctpProofPathNotWired`).
pub fn validate_path_b_redeem_fixed_accounts(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if accounts.len() < PATH_B_REDEEM_FIXED_ACCOUNT_LEN {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    validate_path_b_redeem_fixed_account_keys(
        program_id,
        accounts[PATH_B_REDEEM_IX_RELAYER].key,
        accounts[PATH_B_REDEEM_IX_RELAYER].is_signer,
        accounts[PATH_B_REDEEM_IX_MCTP_CONFIG].key,
        accounts[PATH_B_REDEEM_IX_PEER_BINDING].key,
        accounts[PATH_B_REDEEM_IX_RECEIVE_RECEIPT].key,
        accounts[PATH_B_REDEEM_IX_HANDOFF_POSITION].key,
        accounts[PATH_B_REDEEM_IX_CUSTODY_AUTH].key,
        accounts[PATH_B_REDEEM_IX_CUSTODY_USDC].key,
        accounts[PATH_B_REDEEM_IX_REGISTRY_V2].key,
        accounts[PATH_B_REDEEM_IX_USDC_MINT].key,
        accounts[PATH_B_REDEEM_IX_TOKEN_PROGRAM].key,
        accounts[PATH_B_REDEEM_IX_ATA_PROGRAM].key,
        accounts[PATH_B_REDEEM_IX_SYSTEM_PROGRAM].key,
        accounts[PATH_B_REDEEM_IX_MAYAN_MCTP].key,
        accounts[PATH_B_REDEEM_IX_CCTP_MT].key,
        accounts[PATH_B_REDEEM_IX_CCTP_TMM].key,
        accounts[PATH_B_REDEEM_IX_WORMHOLE].key,
        day_tx_id,
        remote_day_chain_id,
    )
}

// ── Reverse request fixed account prefix (docs/66 §6) ───────────────────────
// WithdrawalRequest PDA identity remains residual (request_id/nonce not in
// Borsh params yet — refuse invent). Fixed keys that *are* derivable are locked.

/// Fixed prefix length for RequestRemoteWithdrawal compose residual.
pub const PATH_B_REVERSE_REQUEST_FIXED_ACCOUNT_LEN: usize = 7;

pub const PATH_B_REVERSE_IX_SOURCE_OWNER: usize = 0;
pub const PATH_B_REVERSE_IX_MCTP_CONFIG: usize = 1;
pub const PATH_B_REVERSE_IX_PEER_BINDING: usize = 2;
pub const PATH_B_REVERSE_IX_SOURCE_INTENT: usize = 3;
pub const PATH_B_REVERSE_IX_WITHDRAWAL_REQUEST: usize = 4;
pub const PATH_B_REVERSE_IX_WORMHOLE: usize = 5;
pub const PATH_B_REVERSE_IX_SYSTEM: usize = 6;

/// Pure fixed-account-key preflight for RequestRemoteWithdrawal (docs/66 §6).
///
/// Locks owner/config/peer/source-intent/Wormhole/system. `withdrawal_request`
/// must be present and non-default but its PDA seed (request_id) is residual
/// until on-chain nonce derivation is wired — never invent request_id.
/// Callers still hit `reverse_attestation_gate` after Ok.
#[allow(clippy::too_many_arguments)]
pub fn validate_path_b_reverse_request_fixed_account_keys(
    program_id: &Pubkey,
    source_owner: &Pubkey,
    source_owner_is_signer: bool,
    mctp_config: &Pubkey,
    peer_binding: &Pubkey,
    source_intent_receipt: &Pubkey,
    withdrawal_request: &Pubkey,
    wormhole_core: &Pubkey,
    system_program_key: &Pubkey,
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if !source_owner_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if day_tx_id == &[0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    if !matches!(remote_day_chain_id, 8453 | 1) {
        return Err(ProgramError::InvalidInstructionData);
    }

    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_peer, _) = mctp_peer_pda(program_id, remote_day_chain_id);
    let (expected_intent, _) = source_intent_receipt_pda(program_id, day_tx_id);

    if mctp_config != &expected_config
        || peer_binding != &expected_peer
        || source_intent_receipt != &expected_intent
        || wormhole_core != &WORMHOLE_CORE_PROGRAM_ID
        || system_program_key != &solana_program::system_program::ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    // WithdrawalRequest PDA identity residual (request_id not in ix params).
    // Refuse the system program / zero key as a stand-in so compose cannot
    // omit the slot; full PDA pin lands with nonce derivation.
    if withdrawal_request == &solana_program::system_program::ID
        || withdrawal_request == &Pubkey::default()
    {
        return Err(DayError::InvalidAccount.into());
    }
    let _ = source_owner;
    Ok(())
}

/// Slice-level reverse-request fixed-account preflight (docs/66 §6).
pub fn validate_path_b_reverse_request_fixed_accounts(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if accounts.len() < PATH_B_REVERSE_REQUEST_FIXED_ACCOUNT_LEN {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    validate_path_b_reverse_request_fixed_account_keys(
        program_id,
        accounts[PATH_B_REVERSE_IX_SOURCE_OWNER].key,
        accounts[PATH_B_REVERSE_IX_SOURCE_OWNER].is_signer,
        accounts[PATH_B_REVERSE_IX_MCTP_CONFIG].key,
        accounts[PATH_B_REVERSE_IX_PEER_BINDING].key,
        accounts[PATH_B_REVERSE_IX_SOURCE_INTENT].key,
        accounts[PATH_B_REVERSE_IX_WITHDRAWAL_REQUEST].key,
        accounts[PATH_B_REVERSE_IX_WORMHOLE].key,
        accounts[PATH_B_REVERSE_IX_SYSTEM].key,
        day_tx_id,
        remote_day_chain_id,
    )
}

// ── Redeem-return fixed account prefix (docs/66 §9) ─────────────────────────

/// Fixed prefix length for RedeemReturnToOwner compose residual.
pub const PATH_B_REDEEM_RETURN_FIXED_ACCOUNT_LEN: usize = 14;

pub const PATH_B_RETURN_IX_RELAYER: usize = 0;
pub const PATH_B_RETURN_IX_MCTP_CONFIG: usize = 1;
pub const PATH_B_RETURN_IX_PEER_BINDING: usize = 2;
pub const PATH_B_RETURN_IX_SOURCE_INTENT: usize = 3;
pub const PATH_B_RETURN_IX_RETURN_RECEIPT: usize = 4;
pub const PATH_B_RETURN_IX_CUSTODY_AUTH: usize = 5;
pub const PATH_B_RETURN_IX_CUSTODY_USDC: usize = 6;
pub const PATH_B_RETURN_IX_OWNER_USDC: usize = 7;
pub const PATH_B_RETURN_IX_USDC_MINT: usize = 8;
pub const PATH_B_RETURN_IX_TOKEN_PROGRAM: usize = 9;
pub const PATH_B_RETURN_IX_MAYAN_MCTP: usize = 10;
pub const PATH_B_RETURN_IX_CCTP_MT: usize = 11;
pub const PATH_B_RETURN_IX_CCTP_TMM: usize = 12;
pub const PATH_B_RETURN_IX_WORMHOLE: usize = 13;

/// Pure fixed-account-key preflight for RedeemReturnToOwner (docs/66 §9).
///
/// Locks exact-owner USDC ATA + return receipt + CCTP/Wormhole/Mayan pins.
/// Never verifies proofs or moves tokens — callers still hit
/// `reverse_attestation_gate` after Ok.
#[allow(clippy::too_many_arguments)]
pub fn validate_path_b_redeem_return_fixed_account_keys(
    program_id: &Pubkey,
    relayer: &Pubkey,
    relayer_is_signer: bool,
    mctp_config: &Pubkey,
    peer_binding: &Pubkey,
    source_intent_receipt: &Pubkey,
    return_receipt: &Pubkey,
    custody_authority: &Pubkey,
    custody_usdc: &Pubkey,
    original_source_owner_usdc: &Pubkey,
    canonical_usdc_mint: &Pubkey,
    token_program: &Pubkey,
    mayan_mctp_program: &Pubkey,
    cctp_message_transmitter: &Pubkey,
    cctp_token_messenger_minter: &Pubkey,
    wormhole_core: &Pubkey,
    day_tx_id: &[u8; 32],
    withdrawal_id: &[u8; 32],
    original_source_owner: &Pubkey,
    remote_day_chain_id: u32,
) -> ProgramResult {
    if !relayer_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if day_tx_id == &[0u8; 32] || withdrawal_id == &[0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    if !matches!(remote_day_chain_id, 8453 | 1) {
        return Err(ProgramError::InvalidInstructionData);
    }

    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_peer, _) = mctp_peer_pda(program_id, remote_day_chain_id);
    let (expected_intent, _) = source_intent_receipt_pda(program_id, day_tx_id);
    let (expected_return, _) = return_receipt_pda(program_id, withdrawal_id);
    let (expected_custody, _) = handoff_custody_pda(program_id, day_tx_id);
    let expected_custody_usdc = path_b_usdc_ata(&expected_custody, &CANONICAL_USDC_MINT);
    let expected_owner_usdc = path_b_usdc_ata(original_source_owner, &CANONICAL_USDC_MINT);

    if mctp_config != &expected_config
        || peer_binding != &expected_peer
        || source_intent_receipt != &expected_intent
        || return_receipt != &expected_return
        || custody_authority != &expected_custody
        || custody_usdc != &expected_custody_usdc
        || original_source_owner_usdc != &expected_owner_usdc
        || canonical_usdc_mint != &CANONICAL_USDC_MINT
        || token_program != &SPL_TOKEN_PROGRAM_ID
        || mayan_mctp_program != &MAYAN_MCTP_PROGRAM_ID
        || cctp_message_transmitter != &CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID
        || cctp_token_messenger_minter != &CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID
        || wormhole_core != &WORMHOLE_CORE_PROGRAM_ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    let _ = relayer;
    Ok(())
}

/// Slice-level redeem-return fixed-account preflight (docs/66 §9).
pub fn validate_path_b_redeem_return_fixed_accounts(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: &[u8; 32],
    withdrawal_id: &[u8; 32],
    original_source_owner: &Pubkey,
    remote_day_chain_id: u32,
) -> ProgramResult {
    if accounts.len() < PATH_B_REDEEM_RETURN_FIXED_ACCOUNT_LEN {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    validate_path_b_redeem_return_fixed_account_keys(
        program_id,
        accounts[PATH_B_RETURN_IX_RELAYER].key,
        accounts[PATH_B_RETURN_IX_RELAYER].is_signer,
        accounts[PATH_B_RETURN_IX_MCTP_CONFIG].key,
        accounts[PATH_B_RETURN_IX_PEER_BINDING].key,
        accounts[PATH_B_RETURN_IX_SOURCE_INTENT].key,
        accounts[PATH_B_RETURN_IX_RETURN_RECEIPT].key,
        accounts[PATH_B_RETURN_IX_CUSTODY_AUTH].key,
        accounts[PATH_B_RETURN_IX_CUSTODY_USDC].key,
        accounts[PATH_B_RETURN_IX_OWNER_USDC].key,
        accounts[PATH_B_RETURN_IX_USDC_MINT].key,
        accounts[PATH_B_RETURN_IX_TOKEN_PROGRAM].key,
        accounts[PATH_B_RETURN_IX_MAYAN_MCTP].key,
        accounts[PATH_B_RETURN_IX_CCTP_MT].key,
        accounts[PATH_B_RETURN_IX_CCTP_TMM].key,
        accounts[PATH_B_RETURN_IX_WORMHOLE].key,
        day_tx_id,
        withdrawal_id,
        original_source_owner,
        remote_day_chain_id,
    )
}

// ── Path-B trailing residual inventories (docs/66 §6–§8) ─────────────────────
// Role *counts* only — addresses stay unbound until measured peer / venue /
// Mayan manifest. JS inventories in day-router-forward.mjs must match.
// Never invent emitter PDAs, adapter program keys, or ceremony digests.

/// Residual Wormhole reverse-publish trailing roles after reverse fixed prefix
/// (docs/66 §6): emitter, sequence, fee_collector, clock, rent.
/// JS pins fee_collector + Clock/Rent from measured mainnet; emitter/sequence
/// stay unbound. Role *count* only — never invent emitter PDAs.
pub const PATH_B_WORMHOLE_REVERSE_PUBLISH_TRAILING_ROLE_COUNT: usize = 5;

/// Residual adapter-exit CPI trailing roles after execute fixed prefix
/// (docs/66 §7): pinned_adapter_program, adapter_position_accounts,
/// adapter_exit_remaining_accounts.
pub const PATH_B_ADAPTER_EXIT_CPI_TRAILING_ROLE_COUNT: usize = 3;

/// Residual Mayan WITH_FEE trailing roles (shared inventory for initiate /
/// execute return / bridge return — ephemeral addresses unbound).
pub const PATH_B_MAYAN_WITH_FEE_CPI_TRAILING_ROLE_COUNT: usize = 7;

/// Residual Mayan inbound MCTP redeem trailing roles after redeem (16) /
/// redeem-return (14) fixed prefixes (docs/66 §5 / §9) — addresses unbound.
pub const PATH_B_MAYAN_REDEEM_CPI_TRAILING_ROLE_COUNT: usize = 6;

/// Residual adapter-deposit CPI trailing roles after redeem fixed prefix
/// (docs/66 §5): pinned_adapter_program, custody_receipt, deposit accounts,
/// remaining — refuse invent program keys.
pub const PATH_B_ADAPTER_DEPOSIT_CPI_TRAILING_ROLE_COUNT: usize = 4;

/// Residual Wormhole guardian VAA verify trailing roles after execute fixed
/// prefix (docs/66 §7): guardian_set, bridge_config, signature_set, posted_vaa,
/// clock. JS pins bridge_config + Clock from measured mainnet; guardian_set /
/// signature_set / posted_vaa stay unbound (VAA-header / ephemeral).
pub const PATH_B_WORMHOLE_VAA_VERIFY_TRAILING_ROLE_COUNT: usize = 5;

/// Residual Circle CCTP token CPI trailing roles (docs/66 §4–§9): local_token,
/// token_minter, authority, remote_token_messenger, event_authority,
/// message_sent_or_received_event. JS pins local_token (USDC) + token_minter
/// from measured mainnet PDAs; authority/remote/event stay unbound.
pub const PATH_B_CCTP_TOKEN_CPI_TRAILING_ROLE_COUNT: usize = 6;

// ── Execute verified withdrawal fixed account prefix (docs/66 §7) ────────────
// Destination-Solana half of an EVM-origin withdrawal. Pins request_id PDA +
// position/custody/registry/Wormhole/Mayan. pinned_adapter_program + adapter
// CPI + Mayan WITH_FEE return trailing remain residual (venue-specific; refuse
// invent adapter program keys).

/// Fixed prefix length before residual adapter / Mayan return CPI accounts.
pub const PATH_B_EXECUTE_FIXED_ACCOUNT_LEN: usize = 12;

pub const PATH_B_EXECUTE_IX_RELAYER: usize = 0;
pub const PATH_B_EXECUTE_IX_MCTP_CONFIG: usize = 1;
pub const PATH_B_EXECUTE_IX_PEER_BINDING: usize = 2;
pub const PATH_B_EXECUTE_IX_HANDOFF_POSITION: usize = 3;
pub const PATH_B_EXECUTE_IX_WITHDRAWAL_REQUEST: usize = 4;
pub const PATH_B_EXECUTE_IX_CUSTODY_AUTH: usize = 5;
pub const PATH_B_EXECUTE_IX_CUSTODY_USDC: usize = 6;
pub const PATH_B_EXECUTE_IX_REGISTRY_V2: usize = 7;
pub const PATH_B_EXECUTE_IX_TOKEN_PROGRAM: usize = 8;
pub const PATH_B_EXECUTE_IX_WORMHOLE: usize = 9;
pub const PATH_B_EXECUTE_IX_MAYAN_MCTP: usize = 10;
pub const PATH_B_EXECUTE_IX_PAYLOAD_WRITER: usize = 11;

/// Pure fixed-account-key preflight for ExecuteVerifiedWithdrawal (docs/66 §7).
///
/// Locks position/custody/request_id/registry/Wormhole/Mayan/payload-writer so a
/// compose that reaches the residual gate cannot silently substitute identities.
/// Does **not** verify VAA, exit adapter, or CPI Mayan — callers still hit
/// `reverse_attestation_gate` after Ok. Adapter program pin stays residual.
#[allow(clippy::too_many_arguments)]
pub fn validate_path_b_execute_fixed_account_keys(
    program_id: &Pubkey,
    relayer: &Pubkey,
    relayer_is_signer: bool,
    mctp_config: &Pubkey,
    peer_binding: &Pubkey,
    handoff_position: &Pubkey,
    withdrawal_request: &Pubkey,
    custody_authority: &Pubkey,
    custody_usdc: &Pubkey,
    registry_v2: &Pubkey,
    token_program: &Pubkey,
    wormhole_core: &Pubkey,
    mayan_mctp_program: &Pubkey,
    payload_writer_program: &Pubkey,
    day_tx_id: &[u8; 32],
    request_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if !relayer_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if day_tx_id == &[0u8; 32] || request_id == &[0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // EVM-origin peer that published the withdrawal VAA (Base / Ethereum).
    if !matches!(remote_day_chain_id, 8453 | 1) {
        return Err(ProgramError::InvalidInstructionData);
    }

    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_peer, _) = mctp_peer_pda(program_id, remote_day_chain_id);
    let (expected_position, _) = handoff_position_pda(program_id, day_tx_id);
    let (expected_wreq, _) = withdrawal_request_pda(program_id, request_id);
    let (expected_custody, _) = handoff_custody_pda(program_id, day_tx_id);
    let expected_custody_usdc = path_b_usdc_ata(&expected_custody, &CANONICAL_USDC_MINT);
    let (expected_registry, _) = Pubkey::find_program_address(&[REGISTRY_V2_SEED], program_id);

    if mctp_config != &expected_config
        || peer_binding != &expected_peer
        || handoff_position != &expected_position
        || withdrawal_request != &expected_wreq
        || custody_authority != &expected_custody
        || custody_usdc != &expected_custody_usdc
        || registry_v2 != &expected_registry
        || token_program != &SPL_TOKEN_PROGRAM_ID
        || wormhole_core != &WORMHOLE_CORE_PROGRAM_ID
        || mayan_mctp_program != &MAYAN_MCTP_PROGRAM_ID
        || payload_writer_program != &MAYAN_PAYLOAD_WRITER_PROGRAM_ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    let _ = relayer;
    Ok(())
}

/// Slice-level execute fixed-account preflight (docs/66 §7).
///
/// Requires ≥12 accounts. Trailing adapter + Mayan WITH_FEE return CPI accounts
/// (if any) are ignored — VAA verify / adapter exit remain residual
/// (`ReverseAttestationNotWired`).
pub fn validate_path_b_execute_fixed_accounts(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: &[u8; 32],
    request_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if accounts.len() < PATH_B_EXECUTE_FIXED_ACCOUNT_LEN {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    validate_path_b_execute_fixed_account_keys(
        program_id,
        accounts[PATH_B_EXECUTE_IX_RELAYER].key,
        accounts[PATH_B_EXECUTE_IX_RELAYER].is_signer,
        accounts[PATH_B_EXECUTE_IX_MCTP_CONFIG].key,
        accounts[PATH_B_EXECUTE_IX_PEER_BINDING].key,
        accounts[PATH_B_EXECUTE_IX_HANDOFF_POSITION].key,
        accounts[PATH_B_EXECUTE_IX_WITHDRAWAL_REQUEST].key,
        accounts[PATH_B_EXECUTE_IX_CUSTODY_AUTH].key,
        accounts[PATH_B_EXECUTE_IX_CUSTODY_USDC].key,
        accounts[PATH_B_EXECUTE_IX_REGISTRY_V2].key,
        accounts[PATH_B_EXECUTE_IX_TOKEN_PROGRAM].key,
        accounts[PATH_B_EXECUTE_IX_WORMHOLE].key,
        accounts[PATH_B_EXECUTE_IX_MAYAN_MCTP].key,
        accounts[PATH_B_EXECUTE_IX_PAYLOAD_WRITER].key,
        day_tx_id,
        request_id,
        remote_day_chain_id,
    )
}

// ── Bridge withdrawal return fixed account prefix (docs/66 §8) ───────────────
// Retry-safe Mayan return bridge after adapter exit. Fixed keys that are
// derivable from day_tx_id + remote peer; ephemeral Mayan WITH_FEE trailing
// accounts remain residual (same inventory as initiate trailing roles).

/// Fixed prefix length before residual Mayan WITH_FEE return CPI accounts.
pub const PATH_B_BRIDGE_RETURN_FIXED_ACCOUNT_LEN: usize = 11;

pub const PATH_B_BRIDGE_IX_RELAYER: usize = 0;
pub const PATH_B_BRIDGE_IX_MCTP_CONFIG: usize = 1;
pub const PATH_B_BRIDGE_IX_PEER_BINDING: usize = 2;
pub const PATH_B_BRIDGE_IX_HANDOFF_POSITION: usize = 3;
pub const PATH_B_BRIDGE_IX_CUSTODY_AUTH: usize = 4;
pub const PATH_B_BRIDGE_IX_CUSTODY_USDC: usize = 5;
pub const PATH_B_BRIDGE_IX_USDC_MINT: usize = 6;
pub const PATH_B_BRIDGE_IX_TOKEN_PROGRAM: usize = 7;
pub const PATH_B_BRIDGE_IX_MAYAN_MCTP: usize = 8;
pub const PATH_B_BRIDGE_IX_PAYLOAD_WRITER: usize = 9;
pub const PATH_B_BRIDGE_IX_SYSTEM: usize = 10;

/// Pure fixed-account-key preflight for BridgeWithdrawalReturn (docs/66 §8).
///
/// Locks position/custody/Mayan/payload-writer so a retry compose cannot
/// redirect exited USDC. Never CPIs Mayan — callers still hit
/// `reverse_attestation_gate` after Ok.
#[allow(clippy::too_many_arguments)]
pub fn validate_path_b_bridge_return_fixed_account_keys(
    program_id: &Pubkey,
    relayer: &Pubkey,
    relayer_is_signer: bool,
    mctp_config: &Pubkey,
    peer_binding: &Pubkey,
    handoff_position: &Pubkey,
    custody_authority: &Pubkey,
    custody_usdc: &Pubkey,
    canonical_usdc_mint: &Pubkey,
    token_program: &Pubkey,
    mayan_mctp_program: &Pubkey,
    payload_writer_program: &Pubkey,
    system_program_key: &Pubkey,
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if !relayer_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if day_tx_id == &[0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Remote peer is the original EVM source executor destination for the return.
    if !matches!(remote_day_chain_id, 8453 | 1) {
        return Err(ProgramError::InvalidInstructionData);
    }

    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_peer, _) = mctp_peer_pda(program_id, remote_day_chain_id);
    let (expected_position, _) = handoff_position_pda(program_id, day_tx_id);
    let (expected_custody, _) = handoff_custody_pda(program_id, day_tx_id);
    let expected_custody_usdc = path_b_usdc_ata(&expected_custody, &CANONICAL_USDC_MINT);

    if mctp_config != &expected_config
        || peer_binding != &expected_peer
        || handoff_position != &expected_position
        || custody_authority != &expected_custody
        || custody_usdc != &expected_custody_usdc
        || canonical_usdc_mint != &CANONICAL_USDC_MINT
        || token_program != &SPL_TOKEN_PROGRAM_ID
        || mayan_mctp_program != &MAYAN_MCTP_PROGRAM_ID
        || payload_writer_program != &MAYAN_PAYLOAD_WRITER_PROGRAM_ID
        || system_program_key != &solana_program::system_program::ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    let _ = relayer;
    Ok(())
}

/// Slice-level bridge-return fixed-account preflight (docs/66 §8).
///
/// Requires ≥11 accounts. Trailing Mayan WITH_FEE return CPI accounts remain
/// residual (`ReverseAttestationNotWired`).
pub fn validate_path_b_bridge_return_fixed_accounts(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: &[u8; 32],
    remote_day_chain_id: u32,
) -> ProgramResult {
    if accounts.len() < PATH_B_BRIDGE_RETURN_FIXED_ACCOUNT_LEN {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    validate_path_b_bridge_return_fixed_account_keys(
        program_id,
        accounts[PATH_B_BRIDGE_IX_RELAYER].key,
        accounts[PATH_B_BRIDGE_IX_RELAYER].is_signer,
        accounts[PATH_B_BRIDGE_IX_MCTP_CONFIG].key,
        accounts[PATH_B_BRIDGE_IX_PEER_BINDING].key,
        accounts[PATH_B_BRIDGE_IX_HANDOFF_POSITION].key,
        accounts[PATH_B_BRIDGE_IX_CUSTODY_AUTH].key,
        accounts[PATH_B_BRIDGE_IX_CUSTODY_USDC].key,
        accounts[PATH_B_BRIDGE_IX_USDC_MINT].key,
        accounts[PATH_B_BRIDGE_IX_TOKEN_PROGRAM].key,
        accounts[PATH_B_BRIDGE_IX_MAYAN_MCTP].key,
        accounts[PATH_B_BRIDGE_IX_PAYLOAD_WRITER].key,
        accounts[PATH_B_BRIDGE_IX_SYSTEM].key,
        day_tx_id,
        remote_day_chain_id,
    )
}

// ── Fail-closed execution gates ─────────────────────────────────────────────

/// Terminal gate for the full MCTP proof path (Initiate/Redeem handoff).
/// Distinct from rail-agnostic tags 17/18 which are already money-path live.
pub fn mctp_proof_path_gate() -> ProgramResult {
    msg!("DAY MCTP proof path residual (DAY-962 path B) — MctpProofPathNotWired");
    Err(DayError::MctpProofPathNotWired.into())
}

/// Terminal gate for Wormhole reverse attestation + return redeem (docs/66 §6–§9).
pub fn reverse_attestation_gate() -> ProgramResult {
    msg!("DAY reverse attestation residual (DAY-962 path B) — ReverseAttestationNotWired");
    Err(DayError::ReverseAttestationNotWired.into())
}

/// Path-B initiate/redeem intent preflight (docs/66 §4–§5).
///
/// Accepts only a well-formed Solidity ABI `DepositIntentV1` with Solana-local
/// source namespaces and a v1 remote destination (Base 8453/6 or Ethereum 1/0).
/// Never moves tokens and never authorizes Mayan/CCTP CPI — callers still hit
/// `mctp_proof_path_gate` after this returns Ok.
pub fn validate_path_b_deposit_intent_abi(deposit_intent_abi: &[u8]) -> ProgramResult {
    let intent = DepositIntentV1::abi_decode(deposit_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    if intent.day_tx_id == [0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Sol-origin initiate: source must be local DAY chain + Solana CCTP domain.
    if intent.source.day_chain_id != DAY_CHAIN_ID_SOLANA
        || intent.source.mctp_domain != CCTP_DOMAIN_SOLANA
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // v1 remote destinations only (matches validate_mctp_peer_params namespaces).
    let dest_ok = matches!(
        (
            intent.destination.day_chain_id,
            intent.destination.mctp_domain
        ),
        (8453, 6) | (1, 0)
    );
    if !dest_ok {
        return Err(ProgramError::InvalidInstructionData);
    }
    if intent.source.owner == [0u8; 32]
        || intent.source.executor == [0u8; 32]
        || intent.destination.executor == [0u8; 32]
        || intent.source_amount == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(())
}

/// Path-B redeem intent preflight (docs/66 §5) — EVM-origin deposit landing on
/// Solana. Source is Base/Eth; destination is Solana. Distinct from initiate
/// (Sol-origin). Never consumes CCTP/VAA — callers still hit
/// `mctp_proof_path_gate` after Ok.
pub fn validate_path_b_redeem_intent_abi(deposit_intent_abi: &[u8]) -> ProgramResult {
    let intent = DepositIntentV1::abi_decode(deposit_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    if intent.day_tx_id == [0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Destination must be Solana (local redeem).
    if intent.destination.day_chain_id != DAY_CHAIN_ID_SOLANA
        || intent.destination.mctp_domain != CCTP_DOMAIN_SOLANA
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Source is the remote EVM peer that initiated.
    let src_ok = matches!(
        (intent.source.day_chain_id, intent.source.mctp_domain),
        (8453, 6) | (1, 0)
    );
    if !src_ok {
        return Err(ProgramError::InvalidInstructionData);
    }
    if intent.destination.owner == [0u8; 32]
        || intent.destination.executor == [0u8; 32]
        || intent.source.executor == [0u8; 32]
        || intent.source_amount == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(())
}

/// Path-B reverse-request preflight (docs/66 §6).
///
/// Sol-origin owner command for an EVM-held position: source is Solana, dest is
/// Base/Eth. Never publishes Wormhole / never moves tokens — callers still hit
/// `reverse_attestation_gate` after Ok.
pub fn validate_path_b_withdrawal_request_abi(withdrawal_request_abi: &[u8]) -> ProgramResult {
    let req = WithdrawalRequestV1::abi_decode(withdrawal_request_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    if req.day_tx_id == [0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    if req.source.day_chain_id != DAY_CHAIN_ID_SOLANA
        || req.source.mctp_domain != CCTP_DOMAIN_SOLANA
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    let dest_ok = matches!(
        (
            req.destination.day_chain_id,
            req.destination.mctp_domain
        ),
        (8453, 6) | (1, 0)
    );
    if !dest_ok {
        return Err(ProgramError::InvalidInstructionData);
    }
    if req.source.owner == [0u8; 32]
        || req.source.executor == [0u8; 32]
        || req.destination.executor == [0u8; 32]
        || req.position_amount == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(())
}

/// Path-B execute-withdrawal preflight (docs/66 §7).
///
/// Destination-Solana half of an EVM-origin withdrawal: source is Base/Eth,
/// destination is Solana. Distinct from Sol-origin reverse request (docs/66 §6).
/// Never verifies VAA / never exits adapter — callers still hit
/// `reverse_attestation_gate` after Ok.
pub fn validate_path_b_execute_withdrawal_request_abi(
    withdrawal_request_abi: &[u8],
) -> ProgramResult {
    let req = WithdrawalRequestV1::abi_decode(withdrawal_request_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    if req.day_tx_id == [0u8; 32] {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Destination must be Solana (local execute + adapter exit).
    if req.destination.day_chain_id != DAY_CHAIN_ID_SOLANA
        || req.destination.mctp_domain != CCTP_DOMAIN_SOLANA
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Source is the remote EVM peer that published the withdrawal VAA.
    let src_ok = matches!(
        (req.source.day_chain_id, req.source.mctp_domain),
        (8453, 6) | (1, 0)
    );
    if !src_ok {
        return Err(ProgramError::InvalidInstructionData);
    }
    if req.destination.owner == [0u8; 32]
        || req.destination.executor == [0u8; 32]
        || req.source.executor == [0u8; 32]
        || req.position_amount == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(())
}

/// Path-B return-intent preflight (docs/66 §9 RedeemReturnToOwner).
///
/// Final Sol-origin payout: destination is Solana; source is a v1 remote
/// (Base/Eth). Never redeems Mayan/CCTP — callers still hit
/// `reverse_attestation_gate` after Ok.
pub fn validate_path_b_return_intent_abi(return_intent_abi: &[u8]) -> ProgramResult {
    let ri = ReturnIntentV1::abi_decode(return_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    if ri.day_tx_id == [0u8; 32]
        || ri.request_id == [0u8; 32]
        || ri.withdrawal_id == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Return lands on Solana.
    if ri.destination.day_chain_id != DAY_CHAIN_ID_SOLANA
        || ri.destination.mctp_domain != CCTP_DOMAIN_SOLANA
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    let src_ok = matches!(
        (ri.source.day_chain_id, ri.source.mctp_domain),
        (8453, 6) | (1, 0)
    );
    if !src_ok {
        return Err(ProgramError::InvalidInstructionData);
    }
    if ri.destination.owner == [0u8; 32]
        || ri.destination.executor == [0u8; 32]
        || ri.source.executor == [0u8; 32]
        || ri.amount == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(())
}

/// Path-B bridge-return intent preflight (docs/66 §8 BridgeWithdrawalReturn).
///
/// Mayan return bridge after Solana adapter exit: source is Solana, destination
/// is the original EVM peer. Distinct from RedeemReturnToOwner (docs/66 §9)
/// which lands USDC back on Solana. Never CPIs Mayan — callers still hit
/// `reverse_attestation_gate` after Ok.
pub fn validate_path_b_bridge_return_intent_abi(return_intent_abi: &[u8]) -> ProgramResult {
    let ri = ReturnIntentV1::abi_decode(return_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    if ri.day_tx_id == [0u8; 32]
        || ri.request_id == [0u8; 32]
        || ri.withdrawal_id == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Bridge leaves Solana.
    if ri.source.day_chain_id != DAY_CHAIN_ID_SOLANA
        || ri.source.mctp_domain != CCTP_DOMAIN_SOLANA
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    let dest_ok = matches!(
        (
            ri.destination.day_chain_id,
            ri.destination.mctp_domain
        ),
        (8453, 6) | (1, 0)
    );
    if !dest_ok {
        return Err(ProgramError::InvalidInstructionData);
    }
    if ri.source.owner == [0u8; 32]
        || ri.source.executor == [0u8; 32]
        || ri.destination.executor == [0u8; 32]
        || ri.amount == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(())
}

/// Borsh-decode param surface + DepositIntent ABI preflight + fixed account-key
/// preflight for layout stability (docs/66 §4).
///
/// Every public process_* entry still returns a terminal residual error before any
/// account mutation, token movement, or Mayan/Wormhole CPI. Account preflight only
/// proves the compose locked the right PDAs/program pins — it never authorizes
/// value movement or flips pair GO.
pub fn process_initiate_handoff_deposit(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: InitiateHandoffParams,
) -> ProgramResult {
    // Reject empty intent early so a malformed compose cannot look like progress.
    if params.deposit_intent_abi.is_empty()
        || params.mayan_quote_commitment == [0u8; 32]
        || params.mayan_instruction_manifest_hash == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    validate_path_b_deposit_intent_abi(&params.deposit_intent_abi)?;
    // Extract day_tx_id + remote chain for PDA preflight (intent already validated).
    let intent = DepositIntentV1::abi_decode(&params.deposit_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    validate_path_b_initiate_fixed_accounts(
        program_id,
        accounts,
        &intent.day_tx_id,
        intent.destination.day_chain_id,
    )?;
    // Optional trailing Mayan WITH_FEE accounts may be present; CPI still residual.
    mctp_proof_path_gate()
}

pub fn process_redeem_handoff_deposit(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: RedeemHandoffParams,
) -> ProgramResult {
    if params.deposit_intent_abi.is_empty()
        || params.cctp_message.is_empty()
        || params.cctp_attestation.is_empty()
        || params.wormhole_signed_vaa.is_empty()
        || params.mayan_redeem_manifest_hash == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Redeem preflight: EVM→Sol namespaces (not Sol-origin initiate shape).
    // Full CCTP/VAA verification remains residual (MctpProofPathNotWired).
    validate_path_b_redeem_intent_abi(&params.deposit_intent_abi)?;
    let intent = DepositIntentV1::abi_decode(&params.deposit_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    // remote peer = EVM source that initiated the handoff.
    validate_path_b_redeem_fixed_accounts(
        program_id,
        accounts,
        &intent.day_tx_id,
        intent.source.day_chain_id,
    )?;
    mctp_proof_path_gate()
}

pub fn process_request_remote_withdrawal(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: RequestRemoteWithdrawalParams,
) -> ProgramResult {
    if params.withdrawal_request_abi.is_empty() {
        return Err(ProgramError::InvalidInstructionData);
    }
    // ABI preflight first so garbage cannot look like reverse progress.
    validate_path_b_withdrawal_request_abi(&params.withdrawal_request_abi)?;
    let req = WithdrawalRequestV1::abi_decode(&params.withdrawal_request_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    // remote peer = EVM destination holding the position.
    validate_path_b_reverse_request_fixed_accounts(
        program_id,
        accounts,
        &req.day_tx_id,
        req.destination.day_chain_id,
    )?;
    reverse_attestation_gate()
}

pub fn process_execute_verified_withdrawal(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: ExecuteVerifiedWithdrawalParams,
) -> ProgramResult {
    if params.request_id == [0u8; 32]
        || params.withdrawal_request_abi.is_empty()
        || params.withdrawal_vaa.is_empty()
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // EVM→Sol execute namespaces (not Sol-origin reverse request shape).
    // Full VAA verify + adapter exit remain residual (ReverseAttestationNotWired).
    validate_path_b_execute_withdrawal_request_abi(&params.withdrawal_request_abi)?;
    let req = WithdrawalRequestV1::abi_decode(&params.withdrawal_request_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    // remote peer = EVM source that published the withdrawal VAA.
    validate_path_b_execute_fixed_accounts(
        program_id,
        accounts,
        &req.day_tx_id,
        &params.request_id,
        req.source.day_chain_id,
    )?;
    reverse_attestation_gate()
}

pub fn process_bridge_withdrawal_return(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: BridgeWithdrawalReturnParams,
) -> ProgramResult {
    if params.withdrawal_id == [0u8; 32]
        || params.return_intent_abi.is_empty()
        || params.mayan_quote_commitment == [0u8; 32]
        || params.mayan_instruction_manifest_hash == [0u8; 32]
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    // Sol→EVM bridge return namespaces (not RedeemReturnToOwner Sol-dest shape).
    validate_path_b_bridge_return_intent_abi(&params.return_intent_abi)?;
    let ri = ReturnIntentV1::abi_decode(&params.return_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    // Refuse mismatched withdrawal_id (params must bind the return intent).
    if ri.withdrawal_id != params.withdrawal_id {
        return Err(ProgramError::InvalidInstructionData);
    }
    // remote peer = EVM destination of the return bridge.
    validate_path_b_bridge_return_fixed_accounts(
        program_id,
        accounts,
        &ri.day_tx_id,
        ri.destination.day_chain_id,
    )?;
    reverse_attestation_gate()
}

pub fn process_redeem_return_to_owner(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: RedeemReturnToOwnerParams,
) -> ProgramResult {
    if params.return_intent_abi.is_empty()
        || params.cctp_message.is_empty()
        || params.cctp_attestation.is_empty()
        || params.wormhole_signed_vaa.is_empty()
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    validate_path_b_return_intent_abi(&params.return_intent_abi)?;
    let ri = ReturnIntentV1::abi_decode(&params.return_intent_abi)
        .ok_or(ProgramError::InvalidInstructionData)?;
    // Exact original owner is the Solana destination owner on the return intent.
    let original_owner = Pubkey::new_from_array(ri.destination.owner);
    validate_path_b_redeem_return_fixed_accounts(
        program_id,
        accounts,
        &ri.day_tx_id,
        &ri.withdrawal_id,
        &original_owner,
        ri.source.day_chain_id,
    )?;
    reverse_attestation_gate()
}

#[cfg(test)]
mod tests {
    use super::*;
    use borsh::to_vec;
    use solana_program::pubkey::Pubkey;

    #[test]
    fn pdas_are_distinct_and_versioned() {
        let pid = crate::id();
        let day_tx = [0xab; 32];
        let req = [0xcd; 32];
        let wid = [0xef; 32];
        let (a, _) = source_intent_receipt_pda(&pid, &day_tx);
        let (b, _) = receive_receipt_pda(&pid, &day_tx);
        let (c, _) = withdrawal_request_pda(&pid, &req);
        let (d, _) = return_receipt_pda(&pid, &wid);
        assert_ne!(a, b);
        assert_ne!(a, c);
        assert_ne!(b, d);
        // Different day_tx_id → different PDA
        let (a2, _) = source_intent_receipt_pda(&pid, &[0x00; 32]);
        assert_ne!(a, a2);
    }

    #[test]
    fn param_borsh_round_trips_and_lengths_locked() {
        let init = InitiateHandoffParams {
            deposit_intent_abi: vec![1, 2, 3],
            adapter_data: vec![4],
            mayan_quote_commitment: [9; 32],
            mayan_instruction_manifest_hash: [8; 32],
        };
        let bytes = to_vec(&init).unwrap();
        let back = InitiateHandoffParams::try_from_slice(&bytes).unwrap();
        assert_eq!(back, init);

        let redeem = RedeemHandoffParams {
            deposit_intent_abi: vec![1],
            adapter_data: vec![],
            cctp_message: vec![2],
            cctp_attestation: vec![3],
            wormhole_signed_vaa: vec![4],
            mayan_redeem_manifest_hash: [7; 32],
        };
        assert_eq!(
            RedeemHandoffParams::try_from_slice(&to_vec(&redeem).unwrap()).unwrap(),
            redeem
        );

        assert_eq!(SOURCE_INTENT_RECEIPT_LEN, 122);
        assert_eq!(RECEIVE_RECEIPT_LEN, 118);
        assert_eq!(WITHDRAWAL_REQUEST_ACCOUNT_LEN, 118);
        assert_eq!(RETURN_RECEIPT_LEN, 118);
    }

    #[test]
    fn gates_are_terminal_fail_closed() {
        assert_eq!(
            mctp_proof_path_gate(),
            Err(ProgramError::Custom(DayError::MctpProofPathNotWired as u32))
        );
        assert_eq!(
            reverse_attestation_gate(),
            Err(ProgramError::Custom(
                DayError::ReverseAttestationNotWired as u32
            ))
        );
    }

    fn sample_path_b_intent_abi() -> Vec<u8> {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        DepositIntentV1 {
            day_tx_id: [0xaa; 32],
            controller: [0xbb; 20],
            source: RouteV1 {
                day_chain_id: DAY_CHAIN_ID_SOLANA,
                mctp_domain: CCTP_DOMAIN_SOLANA,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
            },
            destination: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
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
        }
        .abi_encode()
    }

    #[test]
    fn process_rejects_empty_then_residual() {
        let pid = Pubkey::new_unique();
        let empty_init = InitiateHandoffParams {
            deposit_intent_abi: vec![],
            adapter_data: vec![],
            mayan_quote_commitment: [0; 32],
            mayan_instruction_manifest_hash: [0; 32],
        };
        assert_eq!(
            process_initiate_handoff_deposit(&pid, &[], empty_init),
            Err(ProgramError::InvalidInstructionData)
        );
        // Garbage bytes that pass non-empty + non-zero commitment checks still
        // fail ABI preflight (not residual MctpProofPathNotWired).
        let bad_shape = InitiateHandoffParams {
            deposit_intent_abi: vec![1, 2, 3],
            adapter_data: vec![],
            mayan_quote_commitment: [1; 32],
            mayan_instruction_manifest_hash: [2; 32],
        };
        assert_eq!(
            process_initiate_handoff_deposit(&pid, &[], bad_shape),
            Err(ProgramError::InvalidInstructionData)
        );
        // Well-formed Sol→Base intent without fixed accounts → NotEnoughAccountKeys
        // (account preflight is the next residual step before MctpProofPathNotWired).
        let ok_shape = InitiateHandoffParams {
            deposit_intent_abi: sample_path_b_intent_abi(),
            adapter_data: vec![],
            mayan_quote_commitment: [1; 32],
            mayan_instruction_manifest_hash: [2; 32],
        };
        assert_eq!(
            process_initiate_handoff_deposit(&pid, &[], ok_shape),
            Err(ProgramError::NotEnoughAccountKeys)
        );

        // Garbage reverse ABI fails preflight (not residual ReverseAttestationNotWired).
        let wd_bad = RequestRemoteWithdrawalParams {
            withdrawal_request_abi: vec![9],
        };
        assert_eq!(
            process_request_remote_withdrawal(&pid, &[], wd_bad),
            Err(ProgramError::InvalidInstructionData)
        );
        // Well-formed Sol→Base withdrawal request without fixed accounts →
        // NotEnoughAccountKeys (account preflight before ReverseAttestationNotWired).
        let wd_ok = RequestRemoteWithdrawalParams {
            withdrawal_request_abi: sample_path_b_withdrawal_request_abi(),
        };
        assert_eq!(
            process_request_remote_withdrawal(&pid, &[], wd_ok),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        // Well-formed Base→Sol return intent without fixed accounts → NotEnoughAccountKeys.
        let ret_ok = RedeemReturnToOwnerParams {
            return_intent_abi: sample_path_b_return_intent_abi(),
            cctp_message: vec![1],
            cctp_attestation: vec![2],
            wormhole_signed_vaa: vec![3],
            mayan_redeem_manifest_hash: [7; 32],
        };
        assert_eq!(
            process_redeem_return_to_owner(&pid, &[], ret_ok),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        // Well-formed redeem without fixed accounts → NotEnoughAccountKeys.
        let redeem_ok = RedeemHandoffParams {
            deposit_intent_abi: sample_path_b_redeem_intent_abi(),
            adapter_data: vec![],
            cctp_message: vec![1],
            cctp_attestation: vec![2],
            wormhole_signed_vaa: vec![3],
            mayan_redeem_manifest_hash: [7; 32],
        };
        assert_eq!(
            process_redeem_handoff_deposit(&pid, &[], redeem_ok),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        // Sol-origin withdrawal ABI is wrong shape for execute → InvalidInstructionData
        // (must be EVM→Sol namespaces).
        let exec_wrong_ns = ExecuteVerifiedWithdrawalParams {
            request_id: [0xcd; 32],
            withdrawal_request_abi: sample_path_b_withdrawal_request_abi(),
            withdrawal_vaa: vec![1],
            adapter_data: vec![],
        };
        assert_eq!(
            process_execute_verified_withdrawal(&pid, &[], exec_wrong_ns),
            Err(ProgramError::InvalidInstructionData)
        );
        // Well-formed EVM→Sol execute without fixed accounts → NotEnoughAccountKeys.
        let exec_ok = ExecuteVerifiedWithdrawalParams {
            request_id: [0xcd; 32],
            withdrawal_request_abi: sample_path_b_execute_withdrawal_request_abi(),
            withdrawal_vaa: vec![1],
            adapter_data: vec![],
        };
        assert_eq!(
            process_execute_verified_withdrawal(&pid, &[], exec_ok),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        // RedeemReturn Sol-dest ABI is wrong shape for bridge return → InvalidInstructionData.
        let bridge_wrong_ns = BridgeWithdrawalReturnParams {
            withdrawal_id: [0xcc; 32],
            return_intent_abi: sample_path_b_return_intent_abi(),
            mayan_quote_commitment: [1; 32],
            mayan_instruction_manifest_hash: [2; 32],
        };
        assert_eq!(
            process_bridge_withdrawal_return(&pid, &[], bridge_wrong_ns),
            Err(ProgramError::InvalidInstructionData)
        );
        // Well-formed Sol→EVM bridge return without fixed accounts → NotEnoughAccountKeys.
        let bridge_ok = BridgeWithdrawalReturnParams {
            withdrawal_id: [0xcc; 32],
            return_intent_abi: sample_path_b_bridge_return_intent_abi(),
            mayan_quote_commitment: [1; 32],
            mayan_instruction_manifest_hash: [2; 32],
        };
        assert_eq!(
            process_bridge_withdrawal_return(&pid, &[], bridge_ok),
            Err(ProgramError::NotEnoughAccountKeys)
        );
    }

    fn sample_path_b_redeem_intent_abi() -> Vec<u8> {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        DepositIntentV1 {
            day_tx_id: [0xaa; 32],
            controller: [0xbb; 20],
            source: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
            },
            destination: RouteV1 {
                day_chain_id: DAY_CHAIN_ID_SOLANA,
                mctp_domain: CCTP_DOMAIN_SOLANA,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
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
        }
        .abi_encode()
    }

    fn sample_path_b_withdrawal_request_abi() -> Vec<u8> {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        WithdrawalRequestV1 {
            day_tx_id: [0xaa; 32],
            controller: [0xbb; 20],
            source: RouteV1 {
                day_chain_id: DAY_CHAIN_ID_SOLANA,
                mctp_domain: CCTP_DOMAIN_SOLANA,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
            },
            destination: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
            },
            opportunity_id: [0x01; 32],
            adapter_id: [0x02; 32],
            position_amount: u64_as_uint256(1_000_000),
            min_bridge_return_amount: u64_as_uint256(900_000),
            min_return_amount: u64_as_uint256(880_000),
            deadline: 1_700_000_000,
            redeem_fee: 0,
            adapter_data_hash: [0x03; 32],
            full_refund: false,
        }
        .abi_encode()
    }

    fn sample_path_b_return_intent_abi() -> Vec<u8> {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        ReturnIntentV1 {
            day_tx_id: [0xaa; 32],
            request_id: [0xbb; 32],
            withdrawal_id: [0xcc; 32],
            controller: [0xdd; 20],
            source: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
            },
            destination: RouteV1 {
                day_chain_id: DAY_CHAIN_ID_SOLANA,
                mctp_domain: CCTP_DOMAIN_SOLANA,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
            },
            opportunity_id: [0x01; 32],
            adapter_id: [0x02; 32],
            amount: u64_as_uint256(900_000),
            min_bridge_return_amount: u64_as_uint256(890_000),
            min_amount: u64_as_uint256(880_000),
            deadline: 1_700_000_000,
        }
        .abi_encode()
    }

    /// EVM-origin withdrawal request for ExecuteVerifiedWithdrawal (source Base, dest Sol).
    fn sample_path_b_execute_withdrawal_request_abi() -> Vec<u8> {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        WithdrawalRequestV1 {
            day_tx_id: [0xaa; 32],
            controller: [0xbb; 20],
            source: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
            },
            destination: RouteV1 {
                day_chain_id: DAY_CHAIN_ID_SOLANA,
                mctp_domain: CCTP_DOMAIN_SOLANA,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
            },
            opportunity_id: [0x01; 32],
            adapter_id: [0x02; 32],
            position_amount: u64_as_uint256(1_000_000),
            min_bridge_return_amount: u64_as_uint256(900_000),
            min_return_amount: u64_as_uint256(880_000),
            deadline: 1_700_000_000,
            redeem_fee: 0,
            adapter_data_hash: [0x03; 32],
            full_refund: false,
        }
        .abi_encode()
    }

    /// Sol→EVM ReturnIntent for BridgeWithdrawalReturn (docs/66 §8).
    fn sample_path_b_bridge_return_intent_abi() -> Vec<u8> {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        ReturnIntentV1 {
            day_tx_id: [0xaa; 32],
            request_id: [0xbb; 32],
            withdrawal_id: [0xcc; 32],
            controller: [0xdd; 20],
            source: RouteV1 {
                day_chain_id: DAY_CHAIN_ID_SOLANA,
                mctp_domain: CCTP_DOMAIN_SOLANA,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
            },
            destination: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
            },
            opportunity_id: [0x01; 32],
            adapter_id: [0x02; 32],
            amount: u64_as_uint256(900_000),
            min_bridge_return_amount: u64_as_uint256(890_000),
            min_amount: u64_as_uint256(880_000),
            deadline: 1_700_000_000,
        }
        .abi_encode()
    }

    #[test]
    fn path_b_initiate_fixed_accounts_lock_pdas_then_residual_gate() {
        let pid = crate::id();
        let day_tx = [0xaa; 32];
        let remote = 8453u32;
        let owner = Pubkey::new_from_array([0x11; 32]);
        let (config, _) = crate::mctp_config_pda(&pid);
        let (peer, _) = crate::mctp_peer_pda(&pid, remote);
        let (intent_pda, _) = source_intent_receipt_pda(&pid, &day_tx);
        let (custody, _) = crate::handoff_custody_pda(&pid, &day_tx);
        let owner_usdc = path_b_usdc_ata(&owner, &crate::CANONICAL_USDC_MINT);
        let custody_usdc = path_b_usdc_ata(&custody, &crate::CANONICAL_USDC_MINT);

        // Happy fixed keys → Ok (still no token move; process_* then residual-gates).
        assert_eq!(
            validate_path_b_initiate_fixed_account_keys(
                &pid,
                &owner,
                true,
                &config,
                &peer,
                &intent_pda,
                &owner_usdc,
                &custody,
                &custody_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Ok(())
        );

        // Wrong peer PDA → InvalidAccount.
        assert_eq!(
            validate_path_b_initiate_fixed_account_keys(
                &pid,
                &owner,
                true,
                &config,
                &Pubkey::new_unique(),
                &intent_pda,
                &owner_usdc,
                &custody,
                &custody_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        // Missing owner signature → MissingRequiredSignature.
        assert_eq!(
            validate_path_b_initiate_fixed_account_keys(
                &pid,
                &owner,
                false,
                &config,
                &peer,
                &intent_pda,
                &owner_usdc,
                &custody,
                &custody_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::MissingRequiredSignature)
        );

        // Wrong Mayan program pin → InvalidAccount.
        assert_eq!(
            validate_path_b_initiate_fixed_account_keys(
                &pid,
                &owner,
                true,
                &config,
                &peer,
                &intent_pda,
                &owner_usdc,
                &custody,
                &custody_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &Pubkey::new_unique(),
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        // Too few accounts → NotEnoughAccountKeys.
        assert_eq!(
            validate_path_b_initiate_fixed_accounts(&pid, &[], &day_tx, remote),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        assert_eq!(PATH_B_INITIATE_FIXED_ACCOUNT_LEN, 13);
    }

    #[test]
    fn path_b_redeem_fixed_accounts_lock_pdas_and_cctp_pins() {
        let pid = crate::id();
        let day_tx = [0xaa; 32];
        let remote = 8453u32;
        let relayer = Pubkey::new_from_array([0x99; 32]);
        let (config, _) = crate::mctp_config_pda(&pid);
        let (peer, _) = crate::mctp_peer_pda(&pid, remote);
        let (receive, _) = receive_receipt_pda(&pid, &day_tx);
        let (position, _) = crate::handoff_position_pda(&pid, &day_tx);
        let (custody, _) = crate::handoff_custody_pda(&pid, &day_tx);
        let custody_usdc = path_b_usdc_ata(&custody, &crate::CANONICAL_USDC_MINT);
        let (registry, _) =
            Pubkey::find_program_address(&[crate::REGISTRY_V2_SEED], &pid);

        assert_eq!(
            validate_path_b_redeem_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &receive,
                &position,
                &custody,
                &custody_usdc,
                &registry,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &crate::CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID,
                &crate::CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Ok(())
        );

        // Wrong CCTP transmitter pin → InvalidAccount.
        assert_eq!(
            validate_path_b_redeem_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &receive,
                &position,
                &custody,
                &custody_usdc,
                &registry,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &Pubkey::new_unique(),
                &crate::CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        // Missing relayer signature.
        assert_eq!(
            validate_path_b_redeem_fixed_account_keys(
                &pid,
                &relayer,
                false,
                &config,
                &peer,
                &receive,
                &position,
                &custody,
                &custody_usdc,
                &registry,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::ASSOCIATED_TOKEN_PROGRAM_ID,
                &solana_program::system_program::ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &crate::CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID,
                &crate::CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::MissingRequiredSignature)
        );

        assert_eq!(
            validate_path_b_redeem_fixed_accounts(&pid, &[], &day_tx, remote),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        assert_eq!(PATH_B_REDEEM_FIXED_ACCOUNT_LEN, 16);
    }

    #[test]
    fn path_b_reverse_request_fixed_accounts_lock_derivable_keys() {
        let pid = crate::id();
        let day_tx = [0xaa; 32];
        let remote = 8453u32;
        let owner = Pubkey::new_from_array([0x11; 32]);
        let (config, _) = crate::mctp_config_pda(&pid);
        let (peer, _) = crate::mctp_peer_pda(&pid, remote);
        let (intent_pda, _) = source_intent_receipt_pda(&pid, &day_tx);
        // Withdrawal request identity residual — any non-default non-system key.
        let wreq = Pubkey::new_from_array([0xcd; 32]);

        assert_eq!(
            validate_path_b_reverse_request_fixed_account_keys(
                &pid,
                &owner,
                true,
                &config,
                &peer,
                &intent_pda,
                &wreq,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &solana_program::system_program::ID,
                &day_tx,
                remote,
            ),
            Ok(())
        );

        // System program as withdrawal_request stand-in → InvalidAccount.
        assert_eq!(
            validate_path_b_reverse_request_fixed_account_keys(
                &pid,
                &owner,
                true,
                &config,
                &peer,
                &intent_pda,
                &solana_program::system_program::ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &solana_program::system_program::ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        assert_eq!(
            validate_path_b_reverse_request_fixed_accounts(&pid, &[], &day_tx, remote),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        assert_eq!(PATH_B_REVERSE_REQUEST_FIXED_ACCOUNT_LEN, 7);
    }

    #[test]
    fn path_b_redeem_return_fixed_accounts_lock_exact_owner_ata() {
        let pid = crate::id();
        let day_tx = [0xaa; 32];
        let withdrawal_id = [0xcc; 32];
        let remote = 8453u32;
        let relayer = Pubkey::new_from_array([0x99; 32]);
        let owner = Pubkey::new_from_array([0x11; 32]);
        let (config, _) = crate::mctp_config_pda(&pid);
        let (peer, _) = crate::mctp_peer_pda(&pid, remote);
        let (intent_pda, _) = source_intent_receipt_pda(&pid, &day_tx);
        let (ret, _) = return_receipt_pda(&pid, &withdrawal_id);
        let (custody, _) = crate::handoff_custody_pda(&pid, &day_tx);
        let custody_usdc = path_b_usdc_ata(&custody, &crate::CANONICAL_USDC_MINT);
        let owner_usdc = path_b_usdc_ata(&owner, &crate::CANONICAL_USDC_MINT);

        assert_eq!(
            validate_path_b_redeem_return_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &intent_pda,
                &ret,
                &custody,
                &custody_usdc,
                &owner_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &crate::CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID,
                &crate::CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &day_tx,
                &withdrawal_id,
                &owner,
                remote,
            ),
            Ok(())
        );

        // Wrong owner ATA → InvalidAccount (exact-owner lock).
        assert_eq!(
            validate_path_b_redeem_return_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &intent_pda,
                &ret,
                &custody,
                &custody_usdc,
                &Pubkey::new_unique(),
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &crate::CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID,
                &crate::CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &day_tx,
                &withdrawal_id,
                &owner,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        assert_eq!(PATH_B_REDEEM_RETURN_FIXED_ACCOUNT_LEN, 14);
    }

    #[test]
    fn path_b_execute_fixed_accounts_lock_request_id_and_position() {
        let pid = crate::id();
        let day_tx = [0xaa; 32];
        let request_id = [0xcd; 32];
        let remote = 8453u32;
        let relayer = Pubkey::new_from_array([0x99; 32]);
        let (config, _) = crate::mctp_config_pda(&pid);
        let (peer, _) = crate::mctp_peer_pda(&pid, remote);
        let (position, _) = crate::handoff_position_pda(&pid, &day_tx);
        let (wreq, _) = withdrawal_request_pda(&pid, &request_id);
        let (custody, _) = crate::handoff_custody_pda(&pid, &day_tx);
        let custody_usdc = path_b_usdc_ata(&custody, &crate::CANONICAL_USDC_MINT);
        let (registry, _) =
            Pubkey::find_program_address(&[crate::REGISTRY_V2_SEED], &pid);

        assert_eq!(
            validate_path_b_execute_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &position,
                &wreq,
                &custody,
                &custody_usdc,
                &registry,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &day_tx,
                &request_id,
                remote,
            ),
            Ok(())
        );

        // Wrong request_id PDA → InvalidAccount.
        assert_eq!(
            validate_path_b_execute_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &position,
                &Pubkey::new_unique(),
                &custody,
                &custody_usdc,
                &registry,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::WORMHOLE_CORE_PROGRAM_ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &day_tx,
                &request_id,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        assert_eq!(
            validate_path_b_execute_fixed_accounts(&pid, &[], &day_tx, &request_id, remote),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        assert_eq!(PATH_B_EXECUTE_FIXED_ACCOUNT_LEN, 12);
    }

    #[test]
    fn path_b_bridge_return_fixed_accounts_lock_custody_and_mayan() {
        let pid = crate::id();
        let day_tx = [0xaa; 32];
        let remote = 8453u32;
        let relayer = Pubkey::new_from_array([0x99; 32]);
        let (config, _) = crate::mctp_config_pda(&pid);
        let (peer, _) = crate::mctp_peer_pda(&pid, remote);
        let (position, _) = crate::handoff_position_pda(&pid, &day_tx);
        let (custody, _) = crate::handoff_custody_pda(&pid, &day_tx);
        let custody_usdc = path_b_usdc_ata(&custody, &crate::CANONICAL_USDC_MINT);

        assert_eq!(
            validate_path_b_bridge_return_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &position,
                &custody,
                &custody_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &crate::MAYAN_MCTP_PROGRAM_ID,
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &solana_program::system_program::ID,
                &day_tx,
                remote,
            ),
            Ok(())
        );

        // Wrong Mayan pin → InvalidAccount.
        assert_eq!(
            validate_path_b_bridge_return_fixed_account_keys(
                &pid,
                &relayer,
                true,
                &config,
                &peer,
                &position,
                &custody,
                &custody_usdc,
                &crate::CANONICAL_USDC_MINT,
                &crate::SPL_TOKEN_PROGRAM_ID,
                &Pubkey::new_unique(),
                &MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
                &solana_program::system_program::ID,
                &day_tx,
                remote,
            ),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        assert_eq!(
            validate_path_b_bridge_return_fixed_accounts(&pid, &[], &day_tx, remote),
            Err(ProgramError::NotEnoughAccountKeys)
        );
        assert_eq!(PATH_B_BRIDGE_RETURN_FIXED_ACCOUNT_LEN, 11);
        // Trailing residual role inventories (docs/66 §5–§9) — lockstep with
        // runtime day-router-forward.mjs; addresses remain unbound.
        assert_eq!(PATH_B_WORMHOLE_REVERSE_PUBLISH_TRAILING_ROLE_COUNT, 5);
        assert_eq!(PATH_B_ADAPTER_EXIT_CPI_TRAILING_ROLE_COUNT, 3);
        assert_eq!(PATH_B_MAYAN_WITH_FEE_CPI_TRAILING_ROLE_COUNT, 7);
        assert_eq!(PATH_B_MAYAN_REDEEM_CPI_TRAILING_ROLE_COUNT, 6);
        assert_eq!(PATH_B_ADAPTER_DEPOSIT_CPI_TRAILING_ROLE_COUNT, 4);
        assert_eq!(PATH_B_WORMHOLE_VAA_VERIFY_TRAILING_ROLE_COUNT, 5);
        assert_eq!(PATH_B_CCTP_TOKEN_CPI_TRAILING_ROLE_COUNT, 6);
    }

    #[test]
    fn path_b_intent_preflight_rejects_wrong_namespaces() {
        use crate::{left_pad_address20, u64_as_uint256, RouteV1};
        let mut intent = DepositIntentV1 {
            day_tx_id: [0xaa; 32],
            controller: [0xbb; 20],
            source: RouteV1 {
                day_chain_id: 8453, // wrong — not Solana
                mctp_domain: 6,
                owner: [0x11; 32],
                token: [0x22; 32],
                bridge_token: [0x33; 32],
                executor: [0x44; 32],
            },
            destination: RouteV1 {
                day_chain_id: 8453,
                mctp_domain: 6,
                owner: left_pad_address20(&[0x55; 20]),
                token: left_pad_address20(&[0x66; 20]),
                bridge_token: left_pad_address20(&[0x77; 20]),
                executor: left_pad_address20(&[0x88; 20]),
            },
            opportunity_id: [0x01; 32],
            adapter_id: [0x02; 32],
            source_amount: u64_as_uint256(1),
            source_bridge_amount: u64_as_uint256(1),
            min_destination_amount: u64_as_uint256(1),
            min_bridge_return_amount: u64_as_uint256(1),
            min_return_amount: u64_as_uint256(1),
            deadline: 1,
            adapter_data_hash: [0x03; 32],
        };
        assert_eq!(
            validate_path_b_deposit_intent_abi(&intent.abi_encode()),
            Err(ProgramError::InvalidInstructionData)
        );
        intent.source.day_chain_id = DAY_CHAIN_ID_SOLANA;
        intent.source.mctp_domain = CCTP_DOMAIN_SOLANA;
        intent.destination.day_chain_id = 42161; // arb not in v1 pair set
        intent.destination.mctp_domain = 3;
        assert_eq!(
            validate_path_b_deposit_intent_abi(&intent.abi_encode()),
            Err(ProgramError::InvalidInstructionData)
        );
        intent.destination.day_chain_id = 8453;
        intent.destination.mctp_domain = 6;
        assert_eq!(validate_path_b_deposit_intent_abi(&intent.abi_encode()), Ok(()));
    }
}
