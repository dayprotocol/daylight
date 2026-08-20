// Copyright (c) 2026 Limitless Labs. All rights reserved.
// SPDX-License-Identifier: UNLICENSED
//! DAY YieldRouter + AdapterRegistry — Solana skeleton.
//!
//! Mirrors Sui `day::yield_router` + `day::adapter_registry`:
//! - Fee: 500 bps (5%) yield skim only; deposit/withdraw principal fee = 0
//! - Auto-yield default OFF
//! - No custody of principal
//! - Upgrade authority remains with treasury (do NOT renounce)

use borsh::{BorshDeserialize, BorshSerialize};
use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint,
    entrypoint::ProgramResult,
    instruction::{AccountMeta, Instruction},
    msg,
    program::{invoke, invoke_signed},
    program_error::ProgramError,
    pubkey,
    pubkey::Pubkey,
    rent::Rent,
    system_instruction, system_program,
    sysvar::Sysvar,
};

// DAY-962 path B foundation: Solidity ABI codecs + reverse-attestation ix surface.
pub mod abi_codec;
pub mod reverse_attestation;

pub use abi_codec::{
    left_pad_address20, u64_as_uint256, wormhole_withdrawal_domain_separator, DepositIntentV1,
    ReturnIntentV1, RouteV1, WithdrawalContextV1, WithdrawalRequestV1,
};
pub use reverse_attestation::{
    mctp_proof_path_gate, path_b_usdc_ata, process_bridge_withdrawal_return,
    process_execute_verified_withdrawal, process_initiate_handoff_deposit,
    process_redeem_handoff_deposit, process_redeem_return_to_owner,
    process_request_remote_withdrawal, receive_receipt_pda, return_receipt_pda,
    reverse_attestation_gate, source_intent_receipt_pda, validate_path_b_bridge_return_fixed_account_keys,
    validate_path_b_bridge_return_fixed_accounts, validate_path_b_bridge_return_intent_abi,
    validate_path_b_deposit_intent_abi, validate_path_b_execute_fixed_account_keys,
    validate_path_b_execute_fixed_accounts, validate_path_b_execute_withdrawal_request_abi,
    validate_path_b_initiate_fixed_account_keys, validate_path_b_initiate_fixed_accounts,
    validate_path_b_redeem_fixed_account_keys, validate_path_b_redeem_fixed_accounts,
    validate_path_b_redeem_intent_abi, validate_path_b_redeem_return_fixed_account_keys,
    validate_path_b_redeem_return_fixed_accounts, validate_path_b_return_intent_abi,
    validate_path_b_reverse_request_fixed_account_keys,
    validate_path_b_reverse_request_fixed_accounts, validate_path_b_withdrawal_request_abi,
    withdrawal_request_pda, BridgeWithdrawalReturnParams, ExecuteVerifiedWithdrawalParams,
    InitiateHandoffParams, RedeemHandoffParams, RedeemReturnToOwnerParams,
    RequestRemoteWithdrawalParams, MAYAN_PAYLOAD_WRITER_PROGRAM_ID,
    PATH_B_BRIDGE_RETURN_FIXED_ACCOUNT_LEN, PATH_B_EXECUTE_FIXED_ACCOUNT_LEN,
    PATH_B_INITIATE_FIXED_ACCOUNT_LEN, PATH_B_REDEEM_FIXED_ACCOUNT_LEN,
    PATH_B_REDEEM_RETURN_FIXED_ACCOUNT_LEN, PATH_B_REVERSE_REQUEST_FIXED_ACCOUNT_LEN,
    RECEIVE_RECEIPT_LEN, RECEIVE_RECEIPT_SEED, RETURN_RECEIPT_LEN, RETURN_RECEIPT_SEED,
    SOURCE_INTENT_RECEIPT_LEN, SOURCE_INTENT_RECEIPT_SEED, WITHDRAWAL_REQUEST_ACCOUNT_LEN,
    WITHDRAWAL_REQUEST_SEED,
};

/// Default protocol yield skim: 5% = 500 bps
pub const PROTOCOL_YIELD_SKIM_BPS: u16 = 500;
/// Deposit fee on principal (always 0)
pub const DEPOSIT_FEE_BPS: u16 = 0;

/// DAY-763 non-managed profit fee — PLACEHOLDER, OFF by default. Preset 1% of
/// realized profit, capped $10 (10_000_000 USD micros), enabled=false. Owner
/// may set within [0, MAX_PROFIT_FEE_BPS] and flip enabled later. Never principal.
pub const PROFIT_FEE_BPS_DEFAULT: u16 = 100; // 1%
pub const MAX_PROFIT_FEE_BPS: u16 = 200; // 2% hard ceiling
pub const PROFIT_FEE_CAP_USD_MICROS_DEFAULT: u64 = 10_000_000; // $10
/// Withdraw fee on principal (always 0)
pub const WITHDRAW_FEE_BPS: u16 = 0;
pub const BASIS_POINTS: u16 = 10_000;

/// PDA seeds
pub const REGISTRY_SEED: &[u8] = b"adapter_registry";
/// DAY-823 migration-safe registry. The live V1 account cannot grow to add a
/// protocol program id, so forward paths use a fresh PDA and never fall back.
pub const REGISTRY_V2_SEED: &[u8] = b"adapter_registry_v2";
pub const ROUTER_SEED: &[u8] = b"yield_router";
/// DAY-883 source checkpoint only. This deterministic placeholder is not a
/// deployed OApp id and therefore cannot authorize production execution. It
/// MUST be replaced by the deployed DAY OApp program id before readiness can
/// change; the handler below independently returns RouteBindingNotWired.
pub const DAY_OAPP_PROGRAM_ID: Pubkey = pubkey!("A6GTsqdY3oHC4uUjWthLCPX761WUb4HBvHhA1CFN5FCg");
pub const DAY_OAPP_STORE_SEED: &[u8] = b"Store";
/// DAY-962: independently allocated v1 configuration state for the future
/// Mayan/CCTP peer.  The version participates in every new PDA derivation so
/// a future transport migration cannot reinterpret a v1 account.
pub const MCTP_CONFIG_SEED: &[u8] = b"mctp_config";
pub const MCTP_PEER_SEED: &[u8] = b"mctp_peer";
pub const MCTP_CONFIG_VERSION: u8 = 1;
pub const MCTP_CONFIG_VERSION_SEED: &[u8] = b"v1";
/// DAY-962/980 peer-custody handoff (analog of the Sui `sui_peer_executor`).
/// A HandoffPosition is origin-bound: exit destination == origin owner, never a
/// caller choice. Custody has a per-position signer PDA (no shared router ATA).
pub const HANDOFF_POSITION_SEED: &[u8] = b"handoff_position";
pub const HANDOFF_CUSTODY_SEED: &[u8] = b"handoff_custody";
pub const HANDOFF_POSITION_VERSION: u8 = 1;
pub const HANDOFF_POSITION_DISCRIMINATOR: u64 = 0x4441595f484e4450u64; // "DAY_HNDP"
/// Length of an origin_asset label (UTF-8, right-padded/truncated) and the
/// origin_chain label. Fixed-width so the account layout is frozen.
pub const ORIGIN_CHAIN_LEN: usize = 16;
pub const ORIGIN_ASSET_LEN: usize = 16;
/// DAY routing, CCTP, and Wormhole identifiers deliberately have distinct
/// names/types below.  Do not copy one namespace into another.
pub const DAY_CHAIN_ID_SOLANA: u32 = 501;
pub const CCTP_DOMAIN_SOLANA: u32 = 5;
pub const WORMHOLE_CHAIN_ID_SOLANA: u16 = 1;
/// Canonical mainnet facts.  These are source-pinned constants, never caller
/// selected values or readiness claims.
pub const CANONICAL_USDC_MINT: Pubkey = pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const MAYAN_MCTP_PROGRAM_ID: Pubkey = pubkey!("dkpZqrxHFrhziEMQ931GLtfy11nFkCsfMftH9u6QwBU");
pub const CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID: Pubkey =
    pubkey!("CCTPmbSD7gX1bxKPAmg77w8oFzNFpaQiQUWD43TKaecd");
pub const CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID: Pubkey =
    pubkey!("CCTPiPYPc6AsJuwueEnWgSgucamXDZwBd53dQ11YiKX3");
pub const WORMHOLE_CORE_PROGRAM_ID: Pubkey = pubkey!("worm2ZoG2kUd4vFXhvjh93UUH596ayRfgQ2MgjNMTth");
/// Max adapters in the on-chain allowlist (skeleton-sized)
pub const MAX_ADAPTERS: usize = 16;
/// Fixed adapter id length (UTF-8 padded)
pub const ADAPTER_ID_LEN: usize = 16;

/// Fixed protocol authority (treasury). DAY-282: Initialize must not accept any signer.
/// Matches upgrade authority / `DAY_SOLANA_UPGRADE_AUTHORITY` in runtime config.
pub const PROTOCOL_AUTHORITY: Pubkey = pubkey!("A975vAJtcEB3saDWXwa3YQmM18qe3DCg83T41KWb9eg6");

solana_program::declare_id!("7P7PgkV1LuiMWVs7wTUoNFbLJnxYxQywENtLL9ZP74Mw");

entrypoint!(process_instruction);

#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub enum DayInstruction {
    /// Accounts: [signer PROTOCOL_AUTHORITY (treasury), registry PDA, router PDA, system_program]
    /// Authority is fixed (not any signer). Prefunded PDAs are ok (no lamports>0 DoS).
    Initialize,
    /// Register adapter id (16 bytes padded) + chain tag (8 bytes) + active=true
    /// Data after tag: adapter_id[16] + chain[8]
    /// Accounts: [signer authority, registry PDA]
    RegisterAdapter {
        adapter_id: [u8; ADAPTER_ID_LEN],
        chain: [u8; 8],
    },
    /// Accounts: [signer authority, registry PDA]
    SetActive {
        adapter_id: [u8; ADAPTER_ID_LEN],
        active: bool,
    },
    /// Event-style plan deposit (fee_micros always 0). Does not transfer funds.
    /// Accounts: [signer owner, registry PDA, router PDA]
    PlanDeposit {
        adapter_id: [u8; ADAPTER_ID_LEN],
        amount_micros: u64,
        auto_yield_enabled: bool,
    },
    /// Event-style plan withdraw (fee always 0)
    /// Accounts: [signer owner, registry PDA, router PDA]
    PlanWithdraw {
        adapter_id: [u8; ADAPTER_ID_LEN],
        amount_micros: u64,
    },
    /// Event-style harvest skim accounting (yield only)
    /// Accounts: [signer owner, registry PDA, router PDA]
    PlanHarvestSkim {
        adapter_id: [u8; ADAPTER_ID_LEN],
        gross_yield_micros: u64,
    },
    /// DAY-795: pass-through forwarder DEPOSIT. Router receives the user's input
    /// SPL tokens into a router-authority token account, then CPIs the deposit
    /// into the protocol adapter so funds land in the user's position. Deposits
    /// charge NO profit fee (fee is realized-profit only, taken on withdraw); a
    /// swap/bridge fee may still apply to the swap/bridge legs (handled by those
    /// leg helpers). `protocol_ix_data` carries the adapter-specific CPI payload.
    /// Accounts: [signer owner, registry_v2 PDA, router PDA, protocol_program,
    ///            ...adapter accounts]
    /// (Fable#5: the handler reads the registry PDA after the owner — the doc
    /// previously omitted it, which would make a composer misplace the accounts.)
    ForwardDeposit {
        adapter_id: [u8; ADAPTER_ID_LEN],
        amount_micros: u64,
        /// Opaque per-protocol CPI payload (built off-chain; verified by adapter).
        protocol_ix_data: Vec<u8>,
    },
    /// DAY-795: reserved pass-through forwarder WITHDRAW ABI.  The handler is
    /// deliberately fail-closed until a persisted position record binds the
    /// router-held protocol receipt to this signer.  A signer-owned payout ATA
    /// alone is not sufficient authority to withdraw a router-held position.
    /// The legacy caller-provided amount/profit fields are retained for
    /// instruction compatibility but must both be zero; neither is truth.
    /// Accounts: [signer owner, registry_v2 PDA, router PDA, fee_config PDA,
    ///            protocol_program, router_token, treasury_token, owner_token,
    ///            token_program, ...adapter accounts]
    ForwardWithdraw {
        adapter_id: [u8; ADAPTER_ID_LEN],
        amount_micros: u64,
        realized_profit_usd_micros: u64,
        protocol_ix_data: Vec<u8>,
    },
    /// DAY-763: owner can update the disclosed legacy profit-fee parameters, but
    /// DAY-825/826 require `enabled=false` until authenticated position accounting
    /// derives profit in the withdrawn token's units. Default OFF. Never principal.
    /// Operates on the SEPARATE RouterFeeConfig PDA (not the router).
    /// Accounts: [signer authority, fee_config PDA]
    SetProfitFee {
        profit_fee_bps: u16,
        profit_fee_cap_usd_micros: u64,
        enabled: bool,
    },
    /// DAY-763: create + initialize the RouterFeeConfig PDA (authority-gated,
    /// PROTOCOL_AUTHORITY only — mirrors Initialize's DAY-282 fixed-authority
    /// check). Presets 1% / $10 cap / DISABLED / treasury=authority=PROTOCOL_AUTHORITY.
    /// Appended as the LAST variant (Borsh tag 9) so existing tags 0-8 are stable.
    /// Accounts: [signer authority (PROTOCOL_AUTHORITY), fee_config PDA, system_program]
    InitFeeConfig,
    /// DAY-823: create the migration-safe registry whose entries pin executable
    /// protocol program ids. Appended so deployed Borsh tags 0-9 remain stable.
    /// Accounts: [signer authority, registry_v2 PDA, system_program]
    InitRegistryV2,
    /// DAY-823: register an adapter and its one authorized CPI program id.
    /// Accounts: [signer authority, registry_v2 PDA]
    RegisterAdapterV2 {
        adapter_id: [u8; ADAPTER_ID_LEN],
        chain: [u8; 8],
        protocol_program: Pubkey,
    },
    /// Accounts: [signer authority, registry_v2 PDA]
    SetActiveV2 {
        adapter_id: [u8; ADAPTER_ID_LEN],
        active: bool,
    },
    /// DAY-883 fail-closed LayerZero handoff scaffold. No command fields are
    /// accepted until the canonical combined hub/accounting codec lands.
    /// Accounts: [signer DAY OApp Store PDA, router PDA]
    AuthenticatedCommandScaffold,
    /// DAY-962: initialize only the source-pinned, paused-by-default MCTP
    /// configuration PDA.  This instruction cannot receive, bridge, redeem,
    /// transfer, or authorize principal.
    /// Accounts: [signer PROTOCOL_AUTHORITY, mctp_config PDA, registry_v2 PDA,
    ///            system_program]
    InitializeMctpConfig { params: MctpConfigParams },
    /// DAY-962: reserved one-time immutable remote peer-binding tag.  It
    /// currently returns `MctpPeerManifestNotVerified` before allocation: no
    /// verified bilateral manifest and canonical local emitter pin exist yet.
    /// Accounts: [signer PROTOCOL_AUTHORITY, mctp_config PDA, peer PDA,
    ///            system_program]
    RegisterMctpPeer { params: MctpPeerParams },
    /// DAY-962: controls only a future ingress implementation.  The current
    /// program still has no ingress instruction, so unpausing never grants a
    /// money-moving path.
    /// Accounts: [signer PROTOCOL_AUTHORITY, mctp_config PDA]
    SetMctpIngressPaused { paused: bool },
    /// DAY-962/980 peer-custody RECEIVE — rail-agnostic path A (LIVE money path).
    /// Analog of Sui `receive_and_deposit_suilend`. Takes an ALREADY-DELIVERED
    /// USDC balance in the per-position custody ATA plus an origin record,
    /// ForwardDeposits into the pinned adapter BOUND TO THE ORIGIN OWNER, and
    /// persists a HandoffPosition whose exit is destination-locked to origin.
    /// Proven base→solana jupiter-lend (2026-07-23). Full MCTP proof redeem is
    /// path B (`RedeemHandoffDeposit`, tag 20) — residual.
    /// Accounts: [relayer signer, mctp_config, handoff_position(w),
    ///   custody_authority, custody_usdc(w), registry_v2, pinned_adapter_program,
    ///   system_program, ...adapter deposit accounts]
    ReceiveAndForwardDeposit { params: HandoffReceiveParams },
    /// DAY-962/980 peer-custody EXIT — rail-agnostic path A (LIVE money path).
    /// Exits the origin-bound HandoffPosition through the pinned adapter WITHDRAW
    /// arm and returns measured proceeds to the origin owner's Solana ATA. The
    /// destination is read from the immutable HandoffPosition, never a caller
    /// argument. Pause does NOT block exit. On-chain EVM-dest reverse (path B
    /// tags 21–24) remains residual; owner-direct Mayan reverse is off-chain.
    /// Accounts: [relayer signer, handoff_position(w), custody_authority,
    ///   custody_usdc(w), origin_owner_usdc(w), registry_v2,
    ///   pinned_adapter_program, token_program, ...adapter withdraw accounts]
    ExitHandoffToOrigin {
        day_tx_id: [u8; 32],
        /// Underlying (USDC) amount to redeem this exit. The relayer sets it from
        /// the live jlUSDC share→underlying rate (not 1:1). Safety does NOT depend
        /// on it: the handler measures the actual proceeds delta and enforces the
        /// origin min-return floor + custody nets to zero + a principal upper
        /// bound, so a wrong value fails closed, never over-pays.
        withdraw_amount_micros: u64,
    },
    // ── DAY-962 path B: full MCTP proof + reverse attestation (FAIL-CLOSED) ──
    // Appended after tag 18 so live path-A tags stay stable. Every handler
    // returns MctpProofPathNotWired / ReverseAttestationNotWired before any
    // token movement. docs/66 §4–§9.
    /// Tag 19 — Sol-origin MCTP custom-payload initiate (docs/66 §4). Residual.
    InitiateHandoffDeposit { params: InitiateHandoffParams },
    /// Tag 20 — proof-bound destination redeem+deposit (docs/66 §5). Residual.
    RedeemHandoffDeposit { params: RedeemHandoffParams },
    /// Tag 21 — Wormhole reverse attestation publish (docs/66 §6). Residual.
    RequestRemoteWithdrawal { params: RequestRemoteWithdrawalParams },
    /// Tag 22 — consume remote withdrawal VAA + exit venue (docs/66 §7). Residual.
    ExecuteVerifiedWithdrawal { params: ExecuteVerifiedWithdrawalParams },
    /// Tag 23 — Mayan return bridge from Solana custody (docs/66 §8). Residual.
    BridgeWithdrawalReturn { params: BridgeWithdrawalReturnParams },
    /// Tag 24 — exact original-owner final redeem (docs/66 §9). Residual.
    RedeemReturnToOwner { params: RedeemReturnToOwnerParams },
    /// Tag 25 — PROTOCOL_AUTHORITY recovery of router-held SPL tokens.
    /// Moves `amount_micros` (0 = full balance) from a yield_router-owned token
    /// account to an ATA owned by PROTOCOL_AUTHORITY. Does NOT open user
    /// ForwardWithdraw (shared-router multi-user remains DAY-822 closed).
    /// Accounts: [signer PROTOCOL_AUTHORITY, router PDA, router_token(w),
    ///            dest_token(w owned by authority), token_program]
    AuthorityRecoverRouterToken { amount_micros: u64 },
}

/// Rail-authenticated provenance of a cross-chain arrival, mirrored from the Sui
/// executor's `OriginRecord`. `origin_owner` (32 bytes; an EVM address is left-
/// padded) is the party the resulting position and exit proceeds are bound to.
/// `origin_chain` / `origin_asset` are opaque fixed-width labels for audit + the
/// return leg to re-bind against. Carries NO payout-destination field separable
/// from `origin_owner`: exit is bound to origin, not to a caller choice.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct HandoffReceiveParams {
    /// Globally single-use handoff id (keccak of the source intent).
    pub day_tx_id: [u8; 32],
    pub origin_chain: [u8; ORIGIN_CHAIN_LEN],
    pub origin_owner: [u8; 32],
    pub origin_asset: [u8; ORIGIN_ASSET_LEN],
    /// Registry adapter id the delivered principal must deposit into (e.g.
    /// "jupiter-lend", UTF-8 padded).
    pub adapter_id: [u8; ADAPTER_ID_LEN],
    /// Principal the caller claims was delivered. NOT value-truth: the wired
    /// path measures the custody-ATA delta and rejects any mismatch.
    pub claimed_principal_micros: u64,
    /// Minimum receipt the origin owner must end up exit-capable for.
    pub min_return_micros: u64,
}

/// Caller-supplied initialization values are accepted only when each one is
/// byte-for-byte equal to the canonical source-pinned mainnet fact below.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct MctpConfigParams {
    pub local_day_chain_id: u32,
    pub local_cctp_domain: u32,
    pub local_wormhole_chain_id: u16,
    pub canonical_usdc_mint: Pubkey,
    pub mayan_mctp_program: Pubkey,
    pub cctp_message_transmitter_program: Pubkey,
    pub cctp_token_messenger_minter_program: Pubkey,
    pub wormhole_core_program: Pubkey,
}

/// A peer is immutable after registration.  Its remote IDs remain typed by
/// namespace; `remote_day_chain_id` is never a CCTP or Wormhole substitute.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct MctpPeerParams {
    pub remote_day_chain_id: u32,
    pub remote_cctp_domain: u32,
    pub remote_wormhole_chain_id: u16,
    pub remote_executor: [u8; 32],
    pub remote_withdrawal_emitter: [u8; 32],
    pub evm_code_hash: [u8; 32],
    pub evm_verifier_code_hash: [u8; 32],
}

/// AdapterRegistry PDA state
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone)]
pub struct AdapterRegistry {
    pub discriminator: u64,
    pub authority: Pubkey,
    pub count: u32,
    pub adapters: [AdapterMeta; MAX_ADAPTERS],
}

/// DAY-823 registry used by every CPI-capable forward path. V1 remains readable
/// for non-authoritative plan logs, but it can never authorize a protocol CPI.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone)]
pub struct AdapterRegistryV2 {
    pub discriminator: u64,
    pub authority: Pubkey,
    pub count: u32,
    pub adapters: [AdapterMetaV2; MAX_ADAPTERS],
}

/// YieldRouter config PDA — does NOT hold user principal
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone)]
pub struct YieldRouter {
    pub discriminator: u64,
    pub authority: Pubkey,
    pub protocol_yield_skim_bps: u16,
    pub deposit_fee_bps: u16,
    pub withdraw_fee_bps: u16,
    pub auto_yield_default_off: bool,
    pub paused: bool,
    pub bump: u8,
    // DAY-763 profit fee is NOT stored here — the deployed YieldRouter PDA is a
    // fixed 49-byte layout and MUST NOT grow (Grok CRITICAL: an in-place layout
    // change bricks every load_router borsh-deser after a program upgrade, with
    // no migration). The profit-fee config lives in a SEPARATE `RouterFeeConfig`
    // PDA (see below) created fresh post-upgrade — mirrors the Sui RouterFeeConfig.
}

/// DAY-763 profit-fee config PDA — SEPARATE from YieldRouter so the deployed
/// 49-byte router account layout is never mutated. Created once via
/// InitFeeConfig (authority-gated), then referenced by the forward paths.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone)]
pub struct RouterFeeConfig {
    pub discriminator: u64,
    pub authority: Pubkey,
    /// Fee treasury owner (the SPL owner the fee token account must belong to).
    pub treasury: Pubkey,
    pub profit_fee_bps: u16,
    pub profit_fee_cap_usd_micros: u64,
    pub profit_fee_enabled: bool,
    pub bump: u8,
}

/// DAY-962 configuration lives in its own PDA.  It deliberately does not
/// alter the deployed 49-byte `YieldRouter` layout and contains no token
/// account, custody authority, proof, or live-readiness flag.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct MctpConfig {
    pub discriminator: u64,
    pub version: u8,
    pub authority: Pubkey,
    /// New ingress starts closed.  A later, separately-reviewed implementation
    /// may consult this bit, but this foundation never treats `false` as GO.
    pub ingress_paused: bool,
    pub bump: u8,
    pub params: MctpConfigParams,
    pub registry_v2: Pubkey,
}

/// Immutable bilateral evidence binding for one remote DAY namespace.  It is
/// not an authorization to accept a cross-chain message or move funds.
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct MctpPeerBinding {
    pub discriminator: u64,
    pub version: u8,
    pub bump: u8,
    pub config: Pubkey,
    pub params: MctpPeerParams,
}

pub const FEE_CONFIG_SEED: &[u8] = b"router_fee_config";
pub const FEE_CONFIG_DISCRIMINATOR: u64 = 0x4441_595f_4643_4701; // "DAY_FCG\x01"
pub const MCTP_CONFIG_DISCRIMINATOR: u64 = 0x4441_595f_4d43_4701; // "DAY_MCG\x01"
pub const MCTP_PEER_DISCRIMINATOR: u64 = 0x4441_595f_4d50_4701; // "DAY_MPG\x01"

impl RouterFeeConfig {
    pub const LEN: usize = 8 + 32 + 32 + 2 + 8 + 1 + 1;

    /// DAY-763: profit fee on realized profit (USD micros), applying the $ cap.
    /// Returns 0 while disabled. Never charges principal — caller passes profit.
    pub fn quote_profit_fee(&self, realized_profit_usd_micros: u64) -> u64 {
        if !self.profit_fee_enabled || self.profit_fee_bps == 0 || realized_profit_usd_micros == 0 {
            return 0;
        }
        let raw = (realized_profit_usd_micros as u128).saturating_mul(self.profit_fee_bps as u128)
            / 10_000u128;
        let raw = raw as u64;
        if self.profit_fee_cap_usd_micros != 0 && raw > self.profit_fee_cap_usd_micros {
            self.profit_fee_cap_usd_micros
        } else {
            raw
        }
    }
}

impl MctpConfig {
    pub const LEN: usize = 8 + 1 + 32 + 1 + 1 + 4 + 4 + 2 + (32 * 5) + 32;
}

impl MctpPeerBinding {
    pub const LEN: usize = 8 + 1 + 1 + 32 + 4 + 4 + 2 + (32 * 4);
}

/// DAY-962/980 origin-bound peer-custody position (analog of the Sui executor's
/// origin-bound Suilend Position). `day_tx_id` is globally single-use; the
/// origin owner + destination are immutable after creation, so exit is provably
/// destination-locked to the origin that funded it. `remaining_principal_micros`
/// only decreases by a measured adapter withdrawal (enforced by the wired exit).
/// `state`: 0 = uninitialized, 1 = active (deposited), 2 = exited (tombstone).
#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, PartialEq, Eq)]
pub struct HandoffPosition {
    pub discriminator: u64,
    pub version: u8,
    pub bump: u8,
    pub custody_bump: u8,
    pub state: u8,
    pub day_tx_id: [u8; 32],
    pub origin_chain: [u8; ORIGIN_CHAIN_LEN],
    pub origin_owner: [u8; 32],
    pub origin_asset: [u8; ORIGIN_ASSET_LEN],
    pub adapter_id: [u8; ADAPTER_ID_LEN],
    pub adapter_program: Pubkey,
    pub principal_micros: u64,
    pub remaining_principal_micros: u64,
    pub min_return_micros: u64,
}

impl HandoffPosition {
    pub const LEN: usize = 8 // discriminator
        + 1 + 1 + 1 + 1 // version, bump, custody_bump, state
        + 32 // day_tx_id
        + ORIGIN_CHAIN_LEN
        + 32 // origin_owner
        + ORIGIN_ASSET_LEN
        + ADAPTER_ID_LEN
        + 32 // adapter_program
        + 8 + 8 + 8; // principal, remaining, min_return

    pub const STATE_UNINIT: u8 = 0;
    pub const STATE_ACTIVE: u8 = 1;
    pub const STATE_EXITED: u8 = 2;
}

/// Validate an origin record's binding fields, fail-closed on a null owner or
/// empty chain/asset labels — a malformed arrival can never mint an
/// unattributable or unrecoverable position. Mirrors the Sui
/// `new_origin_record` assertions.
pub fn assert_origin_record_valid(
    origin_owner: &[u8; 32],
    origin_chain: &[u8; ORIGIN_CHAIN_LEN],
    origin_asset: &[u8; ORIGIN_ASSET_LEN],
) -> ProgramResult {
    if origin_owner.iter().all(|b| *b == 0) {
        return Err(DayError::InvalidAccount.into());
    }
    if origin_chain.iter().all(|b| *b == 0) {
        return Err(DayError::InvalidAccount.into());
    }
    if origin_asset.iter().all(|b| *b == 0) {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Canonical origin_chain label for a Solana-origin arrival (UTF-8, null-padded).
pub const ORIGIN_CHAIN_SOLANA: [u8; ORIGIN_CHAIN_LEN] =
    *b"solana\0\0\0\0\0\0\0\0\0\0";

/// Fail-closed guard on `origin_owner` for the owner-direct cross-chain model
/// (analog of base->sui->Suilend): the user controls a Solana wallet; a bridge
/// (any rail — Mayan FAST_MCTP) drops USDC into the per-position custody ATA, and
/// the exit returns to that Solana wallet. `origin_chain` is AUDIT METADATA (where
/// the funds came from) and does NOT gate the exit.
///
/// The exit-PAYABILITY of `origin_owner` is enforced authoritatively at exit time
/// by `assert_spl_token_owner(origin_owner_usdc, origin_owner)` — a real SPL token
/// account can only be owned by a real payable account key, so a left-padded EVM
/// address (which no SPL account can be owned by) can never satisfy the exit and
/// the deposit simply won't be created against it in practice. Here we only
/// fail-closed on the degenerate all-zero owner (also checked in
/// `assert_origin_record_valid`). We deliberately DO NOT call `Pubkey::is_on_curve`
/// — it links curve25519-dalek, whose 2048/4096-wide array (de)serialization
/// overflows the 4 KB SBF stack (undefined behavior) and bloats the program.
pub fn assert_solana_origin_owner(
    origin_owner: &[u8; 32],
    _origin_chain: &[u8; ORIGIN_CHAIN_LEN],
) -> ProgramResult {
    if origin_owner.iter().all(|b| *b == 0) {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Derive the HandoffPosition PDA for a day_tx_id.
pub fn handoff_position_pda(program_id: &Pubkey, day_tx_id: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[HANDOFF_POSITION_SEED, day_tx_id, MCTP_CONFIG_VERSION_SEED],
        program_id,
    )
}

/// Derive the per-position isolated custody authority PDA for a day_tx_id.
pub fn handoff_custody_pda(program_id: &Pubkey, day_tx_id: &[u8; 32]) -> (Pubkey, u8) {
    Pubkey::find_program_address(
        &[HANDOFF_CUSTODY_SEED, day_tx_id, MCTP_CONFIG_VERSION_SEED],
        program_id,
    )
}

#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, Default)]
pub struct AdapterMeta {
    pub adapter_id: [u8; ADAPTER_ID_LEN],
    pub chain: [u8; 8],
    pub active: bool,
    pub used: bool,
}

#[derive(BorshSerialize, BorshDeserialize, Debug, Clone, Copy, Default)]
pub struct AdapterMetaV2 {
    pub adapter_id: [u8; ADAPTER_ID_LEN],
    pub chain: [u8; 8],
    /// The only program this adapter id may invoke with the router PDA signer.
    pub protocol_program: Pubkey,
    pub active: bool,
    pub used: bool,
}

pub const REGISTRY_DISCRIMINATOR: u64 = 0x4441_595f_5245_4701; // "DAY_REG\x01"
pub const REGISTRY_V2_DISCRIMINATOR: u64 = 0x4441_595f_5245_4702; // "DAY_REG\x02"
pub const ROUTER_DISCRIMINATOR: u64 = 0x4441_595f_5254_5201; // "DAY_RTR\x01"

impl AdapterRegistry {
    pub const LEN: usize = 8 + 32 + 4 + (MAX_ADAPTERS * AdapterMeta::LEN);

    pub fn find_index(&self, adapter_id: &[u8; ADAPTER_ID_LEN]) -> Option<usize> {
        self.adapters
            .iter()
            .position(|a| a.used && &a.adapter_id == adapter_id)
    }

    pub fn is_active(&self, adapter_id: &[u8; ADAPTER_ID_LEN]) -> bool {
        self.find_index(adapter_id)
            .map(|i| self.adapters[i].active)
            .unwrap_or(false)
    }
}

impl AdapterMeta {
    pub const LEN: usize = ADAPTER_ID_LEN + 8 + 1 + 1; // 26
}

impl AdapterRegistryV2 {
    pub const LEN: usize = 8 + 32 + 4 + (MAX_ADAPTERS * AdapterMetaV2::LEN);

    pub fn find_index(&self, adapter_id: &[u8; ADAPTER_ID_LEN]) -> Option<usize> {
        self.adapters
            .iter()
            .position(|a| a.used && &a.adapter_id == adapter_id)
    }
}

impl AdapterMetaV2 {
    pub const LEN: usize = ADAPTER_ID_LEN + 8 + 32 + 1 + 1; // 58
}

impl YieldRouter {
    // Original deployed layout — 49 bytes. DO NOT grow (Grok CRITICAL): the live
    // PDA is this exact size; profit-fee config lives in RouterFeeConfig instead.
    pub const LEN: usize = 8 + 32 + 2 + 2 + 2 + 1 + 1 + 1;
}

#[derive(Debug, Clone, Copy)]
pub enum DayError {
    AlreadyInitialized = 0,
    NotAuthority = 1,
    RegistryFull = 2,
    AlreadyRegistered = 3,
    NotAllowlisted = 4,
    ZeroAmount = 5,
    Paused = 6,
    InvalidAccount = 7,
    InvalidInstruction = 8,
    /// DAY-795/798: forward requested for a protocol whose CPI adapter is not yet
    /// wired with verified on-chain addresses. Fail closed — never forward blind.
    AdapterNotWired = 9,
    /// DAY-823: the caller supplied a different program than the registry pins.
    ProtocolProgramMismatch = 10,
    /// DAY-823: CPI targets must be executable program accounts.
    ProtocolProgramNotExecutable = 11,
    /// DAY-825/826: legacy caller-asserted amount/profit fields are not truth.
    CallerAssertedValueUnavailable = 12,
    /// DAY-827: the protocol pull produced no positive measured token delta.
    InvalidBalanceDelta = 13,
    /// DAY-883: caller is not the Store PDA owned by the pinned DAY OApp.
    InvalidOAppAuthority = 14,
    /// DAY-883: exact on-chain asset/opportunity route binding is still absent.
    RouteBindingNotWired = 15,
    /// DAY-962: config did not exactly match the source-pinned v1 facts.
    MctpInvalidConfig = 16,
    /// DAY-962: the remote peer has an invalid namespace/value binding.
    MctpInvalidPeer = 17,
    /// DAY-962: a peer PDA already exists and therefore cannot be replaced.
    MctpPeerAlreadyBound = 18,
    /// DAY-962: future MCTP ingress is administratively paused.
    MctpIngressPaused = 19,
    /// DAY-962: configuration exists but no receive/redeem/transfer path has
    /// been implemented.  This is intentionally terminal and fail-closed.
    MctpIngressNotWired = 20,
    /// DAY-962: no source-pinned bilateral EVM peer manifest and canonical
    /// local Wormhole-emitter verification exist.  Registration must not make
    /// an irreversible binding from arbitrary nonzero caller bytes.
    MctpPeerManifestNotVerified = 21,
    /// DAY-962 path B: full MCTP proof path (Initiate/Redeem handoff with CCTP
    /// + Wormhole + Mayan custom payload) is not execution-true. Distinct from
    /// rail-agnostic tags 17/18 which are already live.
    MctpProofPathNotWired = 22,
    /// DAY-962 path B: Wormhole reverse attestation publish/verify + on-chain
    /// return redeem (docs/66 §6–§9) is not execution-true. Owner-direct Mayan
    /// reverse (path A) is off-chain and does not satisfy this gate.
    ReverseAttestationNotWired = 23,
    /// DAY-822: ForwardWithdraw has no immutable per-position owner binding.
    /// Do not allow an arbitrary signer with a self-owned payout ATA to command
    /// an exit from router-held protocol custody.  This ABI remains terminally
    /// fail-closed until the ExecutionFamily position record is wired.
    ForwardWithdrawOwnerBindingNotWired = 24,
}

impl From<DayError> for ProgramError {
    fn from(e: DayError) -> Self {
        ProgramError::Custom(e as u32)
    }
}

pub fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    instruction_data: &[u8],
) -> ProgramResult {
    // Heap-allocate the decoded instruction. Matching a large DayInstruction on
    // the 4KB SBF stack overflows (build stack-checker + runtime
    // "Access violation in stack frame"). Measured after 2026-08-05 upgrade.
    let ix = Box::new(
        DayInstruction::try_from_slice(instruction_data)
            .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?,
    );
    dispatch_instruction(program_id, accounts, &ix)
}

#[inline(never)]
fn dispatch_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    ix: &DayInstruction,
) -> ProgramResult {
    match ix {
        DayInstruction::Initialize => process_initialize(program_id, accounts),
        DayInstruction::RegisterAdapter { adapter_id, chain } => {
            process_register_adapter(program_id, accounts, *adapter_id, *chain)
        }
        DayInstruction::SetActive { adapter_id, active } => {
            process_set_active(program_id, accounts, *adapter_id, *active)
        }
        DayInstruction::PlanDeposit {
            adapter_id,
            amount_micros,
            auto_yield_enabled,
        } => process_plan_deposit(
            program_id,
            accounts,
            *adapter_id,
            *amount_micros,
            *auto_yield_enabled,
        ),
        DayInstruction::PlanWithdraw {
            adapter_id,
            amount_micros,
        } => process_plan_withdraw(program_id, accounts, *adapter_id, *amount_micros),
        DayInstruction::PlanHarvestSkim {
            adapter_id,
            gross_yield_micros,
        } => process_plan_harvest_skim(program_id, accounts, *adapter_id, *gross_yield_micros),
        DayInstruction::SetProfitFee {
            profit_fee_bps,
            profit_fee_cap_usd_micros,
            enabled,
        } => process_set_profit_fee(
            program_id,
            accounts,
            *profit_fee_bps,
            *profit_fee_cap_usd_micros,
            *enabled,
        ),
        DayInstruction::ForwardDeposit {
            adapter_id,
            amount_micros,
            protocol_ix_data,
        } => process_forward_deposit(
            program_id,
            accounts,
            *adapter_id,
            *amount_micros,
            protocol_ix_data.clone(),
        ),
        DayInstruction::ForwardWithdraw {
            adapter_id,
            amount_micros,
            realized_profit_usd_micros,
            protocol_ix_data,
        } => process_forward_withdraw(
            program_id,
            accounts,
            *adapter_id,
            *amount_micros,
            *realized_profit_usd_micros,
            protocol_ix_data.clone(),
        ),
        DayInstruction::InitFeeConfig => process_init_fee_config(program_id, accounts),
        DayInstruction::InitRegistryV2 => process_init_registry_v2(program_id, accounts),
        DayInstruction::RegisterAdapterV2 {
            adapter_id,
            chain,
            protocol_program,
        } => process_register_adapter_v2(
            program_id,
            accounts,
            *adapter_id,
            *chain,
            *protocol_program,
        ),
        DayInstruction::SetActiveV2 { adapter_id, active } => {
            process_set_active_v2(program_id, accounts, *adapter_id, *active)
        }
        DayInstruction::AuthenticatedCommandScaffold => {
            process_authenticated_command_scaffold(program_id, accounts)
        }
        DayInstruction::InitializeMctpConfig { params } => {
            process_initialize_mctp_config(program_id, accounts, params.clone())
        }
        DayInstruction::RegisterMctpPeer { params } => {
            process_register_mctp_peer(program_id, accounts, params.clone())
        }
        DayInstruction::SetMctpIngressPaused { paused } => {
            process_set_mctp_ingress_paused(program_id, accounts, *paused)
        }
        DayInstruction::ReceiveAndForwardDeposit { params } => {
            process_receive_and_forward_deposit(program_id, accounts, params.clone())
        }
        DayInstruction::ExitHandoffToOrigin {
            day_tx_id,
            withdraw_amount_micros,
        } => process_exit_handoff_to_origin(
            program_id,
            accounts,
            *day_tx_id,
            *withdraw_amount_micros,
        ),
        // DAY-962 path B residual surface (tags 19–24) — always fail-closed.
        DayInstruction::InitiateHandoffDeposit { params } => {
            process_initiate_handoff_deposit(program_id, accounts, params.clone())
        }
        DayInstruction::RedeemHandoffDeposit { params } => {
            process_redeem_handoff_deposit(program_id, accounts, params.clone())
        }
        DayInstruction::RequestRemoteWithdrawal { params } => {
            process_request_remote_withdrawal(program_id, accounts, params.clone())
        }
        DayInstruction::ExecuteVerifiedWithdrawal { params } => {
            process_execute_verified_withdrawal(program_id, accounts, params.clone())
        }
        DayInstruction::BridgeWithdrawalReturn { params } => {
            process_bridge_withdrawal_return(program_id, accounts, params.clone())
        }
        DayInstruction::RedeemReturnToOwner { params } => {
            process_redeem_return_to_owner(program_id, accounts, params.clone())
        }
        DayInstruction::AuthorityRecoverRouterToken { amount_micros } => {
            process_authority_recover_router_token(program_id, accounts, *amount_micros)
        }
    }
}


/// Authenticate the local OApp Store PDA without trusting the permissionless
/// LayerZero delivery payer. This is public for deterministic adversarial tests;
/// the reachable handler still fails closed before execution.
pub fn validate_oapp_authority(
    authority_key: &Pubkey,
    authority_owner: &Pubkey,
    is_signer: bool,
) -> ProgramResult {
    if !is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    let (expected_store, _) =
        Pubkey::find_program_address(&[DAY_OAPP_STORE_SEED], &DAY_OAPP_PROGRAM_ID);
    if authority_key != &expected_store || authority_owner != &DAY_OAPP_PROGRAM_ID {
        return Err(DayError::InvalidOAppAuthority.into());
    }
    Ok(())
}

/// Canonical v1 initialization input.  This is public so adversarial tests can
/// prove every identifier is checked independently; production handlers call
/// the same pure function before allocating state.
pub fn canonical_mctp_config_params() -> MctpConfigParams {
    MctpConfigParams {
        local_day_chain_id: DAY_CHAIN_ID_SOLANA,
        local_cctp_domain: CCTP_DOMAIN_SOLANA,
        local_wormhole_chain_id: WORMHOLE_CHAIN_ID_SOLANA,
        canonical_usdc_mint: CANONICAL_USDC_MINT,
        mayan_mctp_program: MAYAN_MCTP_PROGRAM_ID,
        cctp_message_transmitter_program: CCTP_MESSAGE_TRANSMITTER_PROGRAM_ID,
        cctp_token_messenger_minter_program: CCTP_TOKEN_MESSENGER_MINTER_PROGRAM_ID,
        wormhole_core_program: WORMHOLE_CORE_PROGRAM_ID,
    }
}

pub fn mctp_config_pda(program_id: &Pubkey) -> (Pubkey, u8) {
    Pubkey::find_program_address(&[MCTP_CONFIG_SEED, MCTP_CONFIG_VERSION_SEED], program_id)
}

pub fn mctp_peer_pda(program_id: &Pubkey, remote_day_chain_id: u32) -> (Pubkey, u8) {
    let remote_id = remote_day_chain_id.to_le_bytes();
    Pubkey::find_program_address(
        &[MCTP_PEER_SEED, MCTP_CONFIG_VERSION_SEED, &remote_id],
        program_id,
    )
}

/// No input is advisory: initialization is valid only when all pinned local
/// chain, domain, mint, and program facts match exactly.
pub fn validate_mctp_config_params(params: &MctpConfigParams) -> ProgramResult {
    if params != &canonical_mctp_config_params() {
        return Err(DayError::MctpInvalidConfig.into());
    }
    Ok(())
}

/// `1/0/2` and `8453/6/30` are the only remote namespace tuples planned for
/// v1.  The all-zero values are explicitly rejected so no placeholder can
/// become a peer binding.
pub fn validate_mctp_peer_params(params: &MctpPeerParams) -> ProgramResult {
    let namespace_ok = matches!(
        (
            params.remote_day_chain_id,
            params.remote_cctp_domain,
            params.remote_wormhole_chain_id,
        ),
        (1, 0, 2) | (8453, 6, 30)
    );
    if !namespace_ok
        || params.remote_day_chain_id == DAY_CHAIN_ID_SOLANA
        || params.remote_executor == [0u8; 32]
        || params.remote_withdrawal_emitter == [0u8; 32]
        || params.evm_code_hash == [0u8; 32]
        || params.evm_verifier_code_hash == [0u8; 32]
    {
        return Err(DayError::MctpInvalidPeer.into());
    }
    // A namespace-shaped payload is not evidence of the remote executor,
    // withdrawal emitter, code hashes, or our local Wormhole emitter.  There
    // is deliberately no source-pinned bilateral peer manifest yet, so this
    // release cannot allocate an immutable binding from these caller bytes.
    Err(DayError::MctpPeerManifestNotVerified.into())
}

/// Pure account-key guard for initialization.  It validates the canonical
/// versioned PDAs before any allocation/CPI and does not inspect balances.
pub fn validate_mctp_config_initialize_accounts(
    authority_key: &Pubkey,
    authority_is_signer: bool,
    config_key: &Pubkey,
    registry_v2_key: &Pubkey,
    system_program_key: &Pubkey,
    program_id: &Pubkey,
) -> ProgramResult {
    if !authority_is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if authority_key != &PROTOCOL_AUTHORITY {
        return Err(DayError::NotAuthority.into());
    }
    let (expected_config, _) = mctp_config_pda(program_id);
    let (expected_registry, _) = Pubkey::find_program_address(&[REGISTRY_V2_SEED], program_id);
    if config_key != &expected_config
        || registry_v2_key != &expected_registry
        || system_program_key != &system_program::ID
    {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// There is intentionally no ingress/redeem instruction in this foundation.
/// Even after a valid authority unpauses the config, execution remains blocked
/// until a later receipt/proof/custody implementation proves the full route.
pub fn mctp_ingress_execution_gate(ingress_paused: bool) -> ProgramResult {
    if ingress_paused {
        Err(DayError::MctpIngressPaused.into())
    } else {
        Err(DayError::MctpIngressNotWired.into())
    }
}

/// Establishes the OApp-PDA authentication boundary without guessing the final
/// cross-chain command bytes. The final route-bound instruction will be added
/// only after NativeAssetBinding + the hub route commitment have merged.
fn process_authenticated_command_scaffold(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let oapp_store = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;
    validate_oapp_authority(oapp_store.key, oapp_store.owner, oapp_store.is_signer)?;
    let _router = load_router(router_ai, program_id)?;
    Err(DayError::RouteBindingNotWired.into())
}

/// DAY-962 v1 configuration setup.  This is intentionally the entire mutable
/// surface for canonical local transport facts; it creates no custody account
/// and invokes no third-party program.
fn process_initialize_mctp_config(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: MctpConfigParams,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let config_ai = next_account_info(acc_iter)?;
    let registry_v2_ai = next_account_info(acc_iter)?;
    let system_program_ai = next_account_info(acc_iter)?;

    validate_mctp_config_initialize_accounts(
        authority.key,
        authority.is_signer,
        config_ai.key,
        registry_v2_ai.key,
        system_program_ai.key,
        program_id,
    )?;
    validate_mctp_config_params(&params)?;
    // Configuration cannot be initialized against an arbitrary/uninitialized
    // registry address.  This is a binding only; no adapter is authorized here.
    let _registry = load_registry_v2(registry_v2_ai, program_id)?;
    if config_ai.owner == program_id {
        return Err(DayError::AlreadyInitialized.into());
    }
    let (expected_config, config_bump) = mctp_config_pda(program_id);
    let rent = Rent::get()?;
    create_pda_account(
        authority,
        config_ai,
        system_program_ai,
        program_id,
        MctpConfig::LEN,
        &[MCTP_CONFIG_SEED, MCTP_CONFIG_VERSION_SEED],
        config_bump,
        &rent,
    )?;
    MctpConfig {
        discriminator: MCTP_CONFIG_DISCRIMINATOR,
        version: MCTP_CONFIG_VERSION,
        authority: PROTOCOL_AUTHORITY,
        ingress_paused: true,
        bump: config_bump,
        params,
        registry_v2: *registry_v2_ai.key,
    }
    .serialize(&mut &mut config_ai.data.borrow_mut()[..])?;
    msg!(
        "DAY InitializeMctpConfig config={} version={} ingress_paused=true",
        expected_config,
        MCTP_CONFIG_VERSION
    );
    Ok(())
}

/// The tag is reserved for the eventual immutable bilateral binding, but no
/// verified manifest/local-emitter proof exists in this release.  Reject before
/// touching the peer account: a nonzero user-supplied executor/hash must never
/// turn into irreversible protocol state.
fn process_register_mctp_peer(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: MctpPeerParams,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let config_ai = next_account_info(acc_iter)?;
    let _peer_ai = next_account_info(acc_iter)?;
    let _system_program_ai = next_account_info(acc_iter)?;

    let config = load_mctp_config(config_ai, program_id)?;
    assert_authority(authority, &config.authority)?;
    validate_mctp_peer_params(&params)?;
    Err(DayError::MctpPeerManifestNotVerified.into())
}

/// This flag can only alter the future ingress precondition.  No existing
/// handler calls it as an authorization source, and `mctp_ingress_execution_gate`
/// remains terminally blocked after an authority unpauses the config.
fn process_set_mctp_ingress_paused(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    paused: bool,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let config_ai = next_account_info(acc_iter)?;
    let mut config = load_mctp_config(config_ai, program_id)?;
    assert_authority(authority, &config.authority)?;
    config.ingress_paused = paused;
    config.serialize(&mut &mut config_ai.data.borrow_mut()[..])?;
    msg!(
        "DAY SetMctpIngressPaused paused={} execution_still_not_wired=true",
        paused
    );
    Ok(())
}

/// DAY-962/980 peer-custody RECEIVE (analog of Sui `receive_and_deposit_suilend`).
///
/// Rail-agnostic money path: the bridged USDC is delivered (by any rail — Mayan
/// FAST_MCTP etc.) to the per-position ISOLATED CUSTODY USDC ATA before this
/// call. Like the Sui receiver's linear `Coin<USDC>`, delivery is authenticated
/// off-chain by the relayer; this handler proves VALUE by MEASURING the custody
/// ATA balance (never trusting `claimed_principal_micros` as truth) and then
/// deposits the measured principal into the pinned adapter, bound to the origin
/// owner, with the custody PDA signing the CPI. A new single-use HandoffPosition
/// records the origin binding so the exit is destination-locked to origin.
///
/// Accounts:
///   0 relayer                (signer, rent payer)
///   1 mctp_config
///   2 handoff_position       (writable, PDA ["handoff_position", day_tx_id, v1])
///   3 custody_authority      (PDA ["handoff_custody", day_tx_id, v1]; CPI signer)
///   4 custody_usdc           (writable; ATA(custody_authority, USDC) — delivered)
///   5 registry_v2
///   6 protocol_program       (pinned adapter executable)
///   7 system_program
///   8.. adapter deposit accounts (custody_authority in signer slot 0)
fn process_receive_and_forward_deposit(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    params: HandoffReceiveParams,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let relayer = next_account_info(acc_iter)?;
    let config_ai = next_account_info(acc_iter)?;
    let handoff_position_ai = next_account_info(acc_iter)?;
    let custody_authority_ai = next_account_info(acc_iter)?;
    let custody_usdc_ai = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let protocol_program = next_account_info(acc_iter)?;
    let system_program_ai = next_account_info(acc_iter)?;

    if !relayer.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if system_program_ai.key != &system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }

    // Config must exist; ingress pause blocks ENTRY (exit is unaffected).
    let config = load_mctp_config(config_ai, program_id)?;
    if config.ingress_paused {
        return Err(DayError::MctpIngressPaused.into());
    }

    // Fail-closed origin binding + non-zero claimed principal (Sui asserts analog).
    assert_origin_record_valid(
        &params.origin_owner,
        &params.origin_chain,
        &params.origin_asset,
    )?;
    if params.claimed_principal_micros == 0 {
        return Err(DayError::ZeroAmount.into());
    }

    // FAIL-CLOSED on non-Solana-origin owners. The only exit implemented today is
    // a direct SPL transfer to `origin_owner` as an on-chain Solana address. A
    // left-padded EVM address is not a valid SPL owner, so admitting one here
    // would create a position that CAN NEVER BE EXITED (funds stranded forever).
    // The EVM-origin return leg (bridge-out, docs/66 §9) is not built yet, so we
    // reject any origin_owner that is not a real Solana account key (on-curve).
    // When the bridge-out return lands, relax this to route by origin_chain.
    assert_solana_origin_owner(&params.origin_owner, &params.origin_chain)?;

    // Pin position + custody PDAs so a substituted account is rejected.
    let (expected_position, pos_bump) = handoff_position_pda(program_id, &params.day_tx_id);
    let (expected_custody, cus_bump) = handoff_custody_pda(program_id, &params.day_tx_id);
    if handoff_position_ai.key != &expected_position
        || custody_authority_ai.key != &expected_custody
    {
        return Err(DayError::InvalidAccount.into());
    }

    // day_tx_id is globally single-use — an existing position is a replay.
    if handoff_position_ai.owner == program_id {
        return Err(DayError::AlreadyInitialized.into());
    }

    // The delivered custody ATA must be USDC and OWNED BY the custody PDA — a
    // caller cannot point this at an arbitrary funded account.
    assert_spl_token_owner(custody_usdc_ai, custody_authority_ai.key)?;
    if spl_token_mint(custody_usdc_ai)? != CANONICAL_USDC_MINT {
        return Err(DayError::InvalidAccount.into());
    }

    // MEASURE value. `claimed_principal_micros` is a floor assertion, not truth:
    // the measured custody balance is what actually gets deposited. Reject if the
    // measured balance is below what the caller claims (under-delivery / spoof).
    let measured_principal = spl_token_amount(custody_usdc_ai)?;
    if measured_principal == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    if measured_principal < params.claimed_principal_micros {
        return Err(DayError::InvalidBalanceDelta.into());
    }

    // Deposit the MEASURED principal into the pinned adapter with the CUSTODY PDA
    // signing the CPI. The remaining accounts are the adapter deposit accounts
    // (custody_authority must be in the adapter signer slot). Registry gate +
    // per-adapter market pins fail closed on any substitution.
    let reg = load_registry_v2(registry_ai, program_id)?;
    let protocol_accounts: Vec<AccountInfo> = acc_iter.cloned().collect();
    let custody_seeds: &[&[u8]] = &[
        HANDOFF_CUSTODY_SEED,
        &params.day_tx_id,
        MCTP_CONFIG_VERSION_SEED,
        &[cus_bump],
    ];
    // Encode the deposit ix data for the measured principal (adapter-specific).
    // Only jupiter-lend is a wired deposit arm today; unknown ids fail closed in
    // cpi_protocol_adapter. The composer supplies protocol_ix_data via accounts?
    // No — the receive path builds it from the measured amount to prevent a
    // caller from depositing less than delivered. jupiter-lend Earn Deposit:
    let protocol_ix_data: Vec<u8> = if classify_adapter_dispatch(&params.adapter_id)
        == AdapterDispatchArm::JupiterLend
    {
        // Bind the adapter's token accounts to CUSTODY so a relayer cannot
        // redirect the position. jupiter-lend Earn Deposit layout:
        //   [0] signer = custody PDA, [1] depositor USDC ATA, [2] recipient jlUSDC ATA.
        // The signer slot equality is re-checked inside cpi_adapter_jupiter_lend,
        // but the depositor + recipient must be custody-owned or the shares (and
        // thus the exit proceeds) could accrue to an attacker.
        if protocol_accounts.len() < JUPITER_LEND_DEPOSIT_ACCOUNT_LEN {
            return Err(DayError::InvalidAccount.into());
        }
        if protocol_accounts[JUP_LEND_IX_SIGNER].key != custody_authority_ai.key {
            return Err(DayError::InvalidAccount.into());
        }
        // Depositor USDC ATA must be the delivered custody USDC ATA exactly.
        if protocol_accounts[JUP_LEND_IX_DEPOSITOR_TOKEN].key != custody_usdc_ai.key {
            return Err(DayError::InvalidAccount.into());
        }
        // Recipient jlUSDC (receipt) ATA must be owned by the custody PDA.
        assert_spl_token_owner(
            &protocol_accounts[JUP_LEND_IX_RECIPIENT_TOKEN],
            custody_authority_ai.key,
        )?;
        encode_jupiter_lend_deposit_ix_data(measured_principal).to_vec()
    } else {
        // No other adapter has an audited handoff deposit body yet.
        return Err(DayError::AdapterNotWired.into());
    };

    // Balance-before of the custody ATA so we can prove it nets to (near) zero:
    // all delivered principal must enter the venue, none may be retained.
    let custody_before = measured_principal;
    cpi_protocol_adapter(
        &reg,
        &params.adapter_id,
        protocol_program,
        &protocol_accounts,
        &protocol_ix_data,
        custody_seeds,
        None,
    )?;
    let custody_after = spl_token_amount(custody_usdc_ai)?;
    // The deposit must have consumed the ENTIRE delivered principal — Jupiter
    // Earn deposit is exact-in, so custody must net to exactly zero. Any retained
    // balance would be principal belonging to nobody in this call. `deposited`
    // (the measured amount that actually entered the venue) is what the position
    // records — never the caller's claimed figure. NOTE the deposit REDUCES the
    // custody balance, so the delta is before-minus-after (not the withdraw dir).
    let deposited = custody_before
        .checked_sub(custody_after)
        .ok_or(ProgramError::from(DayError::InvalidBalanceDelta))?;
    if custody_after != 0 {
        return Err(DayError::InvalidBalanceDelta.into());
    }
    if deposited == 0 {
        return Err(DayError::InvalidBalanceDelta.into());
    }

    // Persist the origin-bound position (state=active). Rent paid by relayer.
    let rent = Rent::get()?;
    let pos_seeds: &[&[u8]] = &[HANDOFF_POSITION_SEED, &params.day_tx_id, MCTP_CONFIG_VERSION_SEED];
    create_pda_account(
        relayer,
        handoff_position_ai,
        system_program_ai,
        program_id,
        HandoffPosition::LEN,
        pos_seeds,
        pos_bump,
        &rent,
    )?;
    let position = HandoffPosition {
        discriminator: HANDOFF_POSITION_DISCRIMINATOR,
        version: HANDOFF_POSITION_VERSION,
        bump: pos_bump,
        custody_bump: cus_bump,
        state: HandoffPosition::STATE_ACTIVE,
        day_tx_id: params.day_tx_id,
        origin_chain: params.origin_chain,
        origin_owner: params.origin_owner,
        origin_asset: params.origin_asset,
        adapter_id: params.adapter_id,
        adapter_program: *protocol_program.key,
        // Record the MEASURED amount that actually entered the venue, not the
        // caller's claimed figure (identical here since custody nets to zero).
        principal_micros: deposited,
        remaining_principal_micros: deposited,
        min_return_micros: params.min_return_micros,
    };
    position.serialize(&mut &mut handoff_position_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY ReceiveAndForwardDeposit day_tx_id_bound adapter={:?} measured={} deposited={} origin_bound",
        &params.adapter_id,
        measured_principal,
        deposited
    );
    Ok(())
}

/// DAY-962/980 peer-custody EXIT (analog of Sui `exit_to_origin`).
///
/// Exits the origin-bound position through the pinned adapter WITHDRAW arm and
/// returns the MEASURED proceeds to the origin owner's USDC account. The exit
/// destination comes only from the immutable HandoffPosition — never a caller
/// argument. Pause does NOT block exit. The proceeds are transferred from the
/// custody ATA to the origin owner's ATA (custody PDA signs), and the position
/// remaining balance is decremented by the measured amount.
///
/// Accounts:
///   0 relayer                (signer)
///   1 handoff_position       (writable)
///   2 custody_authority      (PDA; CPI + transfer signer)
///   3 custody_usdc           (writable; proceeds land here from the venue)
///   4 origin_owner_usdc      (writable; ATA whose owner == position.origin_owner-derived)
///   5 registry_v2
///   6 protocol_program
///   7 token_program
///   8.. adapter withdraw accounts (custody_authority in signer slot 0)
fn process_exit_handoff_to_origin(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    day_tx_id: [u8; 32],
    withdraw_amount_micros: u64,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let relayer = next_account_info(acc_iter)?;
    let handoff_position_ai = next_account_info(acc_iter)?;
    let custody_authority_ai = next_account_info(acc_iter)?;
    let custody_usdc_ai = next_account_info(acc_iter)?;
    let origin_owner_usdc_ai = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let protocol_program = next_account_info(acc_iter)?;
    let token_program = next_account_info(acc_iter)?;

    if !relayer.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if token_program.key != &SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }

    // Pin position PDA + load it.
    let (expected_position, _pos_bump) = handoff_position_pda(program_id, &day_tx_id);
    if handoff_position_ai.key != &expected_position {
        return Err(DayError::InvalidAccount.into());
    }
    let mut position = load_handoff_position(handoff_position_ai, program_id)?;
    if position.state != HandoffPosition::STATE_ACTIVE {
        return Err(DayError::InvalidAccount.into());
    }
    if position.day_tx_id != day_tx_id {
        return Err(DayError::InvalidAccount.into());
    }

    // Custody PDA + its USDC ATA are re-derived from the position's own bumps.
    let (expected_custody, _c) = handoff_custody_pda(program_id, &day_tx_id);
    if custody_authority_ai.key != &expected_custody {
        return Err(DayError::InvalidAccount.into());
    }
    assert_spl_token_owner(custody_usdc_ai, custody_authority_ai.key)?;
    if spl_token_mint(custody_usdc_ai)? != CANONICAL_USDC_MINT {
        return Err(DayError::InvalidAccount.into());
    }

    // Pin the exit CPI to the SAME program the position was deposited under, so
    // a post-deposit registry re-point cannot route the withdraw to a different
    // program than minted the shares (defence vs registry-authority mutation).
    if protocol_program.key != &position.adapter_program {
        return Err(DayError::ProtocolProgramMismatch.into());
    }

    // The payout account must belong to the ORIGIN OWNER recorded at deposit —
    // read from immutable position state, never a caller argument. origin_owner
    // is a valid Solana account key (deposit rejects non-Solana origins until the
    // bridge-out return leg exists), so the SPL owner must equal that pubkey.
    let origin_owner_pk = Pubkey::new_from_array(position.origin_owner);
    assert_spl_token_owner(origin_owner_usdc_ai, &origin_owner_pk)?;
    if spl_token_mint(origin_owner_usdc_ai)? != CANONICAL_USDC_MINT {
        return Err(DayError::InvalidAccount.into());
    }

    // Exit the pinned adapter: proceeds land in the custody ATA. The relayer
    // supplies `withdraw_amount_micros` (underlying, from the live jlUSDC share
    // rate — not 1:1). Bounded above by the recorded principal so a relayer cannot
    // try to drain more than this position deposited; safety otherwise rests on
    // the measured-delta + min-return floor below. Registry-gated.
    if withdraw_amount_micros == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    if withdraw_amount_micros > position.remaining_principal_micros {
        return Err(DayError::InvalidBalanceDelta.into());
    }
    if classify_adapter_dispatch(&position.adapter_id) != AdapterDispatchArm::JupiterLend {
        return Err(DayError::AdapterNotWired.into());
    }
    let protocol_ix_data =
        encode_jupiter_lend_withdraw_ix_data(withdraw_amount_micros).to_vec();

    let reg = load_registry_v2(registry_ai, program_id)?;
    let (_c2, cus_bump) = handoff_custody_pda(program_id, &day_tx_id);
    let custody_seeds: &[&[u8]] = &[
        HANDOFF_CUSTODY_SEED,
        &day_tx_id,
        MCTP_CONFIG_VERSION_SEED,
        &[cus_bump],
    ];
    let protocol_accounts: Vec<AccountInfo> = acc_iter.cloned().collect();

    // Bind the withdraw token accounts to CUSTODY so proceeds cannot be routed
    // to an attacker. jupiter-lend Earn Withdraw layout:
    //   [0] signer = custody PDA, [1] source jlUSDC ATA, [2] recipient USDC ATA.
    if protocol_accounts.len() < JUPITER_LEND_WITHDRAW_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    if protocol_accounts[JUP_LEND_WD_SIGNER].key != custody_authority_ai.key {
        return Err(DayError::InvalidAccount.into());
    }
    // Source jlUSDC (receipt) ATA must be owned by the custody PDA.
    assert_spl_token_owner(
        &protocol_accounts[JUP_LEND_WD_SOURCE_FTOKEN],
        custody_authority_ai.key,
    )?;
    // Recipient USDC ATA must be the delivered custody USDC ATA exactly (so the
    // measured delta below reflects the true proceeds before the origin transfer).
    if protocol_accounts[JUP_LEND_WD_RECIPIENT_TOKEN].key != custody_usdc_ai.key {
        return Err(DayError::InvalidAccount.into());
    }

    let custody_before = spl_token_amount(custody_usdc_ai)?;
    cpi_protocol_adapter(
        &reg,
        &position.adapter_id,
        protocol_program,
        &protocol_accounts,
        &protocol_ix_data,
        custody_seeds,
        None,
    )?;
    let custody_after_pull = spl_token_amount(custody_usdc_ai)?;
    let proceeds = measured_withdraw_delta(custody_before, custody_after_pull)?;

    // Enforce the origin's minimum-return floor (never weaken it).
    if proceeds < position.min_return_micros {
        return Err(DayError::InvalidBalanceDelta.into());
    }

    // Transfer the MEASURED proceeds from custody to the origin owner's ATA,
    // custody PDA signing. No admin/relayer recipient is possible.
    invoke_signed(
        &spl_transfer_ix(
            custody_usdc_ai.key,
            origin_owner_usdc_ai.key,
            custody_authority_ai.key,
            proceeds,
        ),
        &[
            custody_usdc_ai.clone(),
            origin_owner_usdc_ai.clone(),
            custody_authority_ai.clone(),
            token_program.clone(),
        ],
        &[custody_seeds],
    )?;
    // Custody must return to its pre-pull balance (no proceeds retained).
    if spl_token_amount(custody_usdc_ai)? != custody_before {
        return Err(DayError::InvalidBalanceDelta.into());
    }

    // Tombstone the position (single-use; remaining -> 0, state -> exited).
    position.remaining_principal_micros = 0;
    position.state = HandoffPosition::STATE_EXITED;
    position.serialize(&mut &mut handoff_position_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY ExitHandoffToOrigin day_tx_id_bound proceeds={} to_origin_owner={} tombstoned",
        proceeds,
        origin_owner_pk
    );
    Ok(())
}

/// Load + validate a HandoffPosition account (owner + discriminator).
fn load_handoff_position(
    ai: &AccountInfo,
    program_id: &Pubkey,
) -> Result<HandoffPosition, ProgramError> {
    if ai.owner != program_id {
        return Err(DayError::InvalidAccount.into());
    }
    let pos = HandoffPosition::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if pos.discriminator != HANDOFF_POSITION_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(pos)
}

fn process_initialize(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;
    let system_program_ai = next_account_info(acc_iter)?;

    // DAY-282: fixed authority model — only PROTOCOL_AUTHORITY (treasury) may init.
    if !authority.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if authority.key != &PROTOCOL_AUTHORITY {
        return Err(DayError::NotAuthority.into());
    }

    // Canonical PDA seeds + bumps (must match find_program_address).
    let (registry_pda, registry_bump) = Pubkey::find_program_address(&[REGISTRY_SEED], program_id);
    let (router_pda, router_bump) = Pubkey::find_program_address(&[ROUTER_SEED], program_id);

    if registry_ai.key != &registry_pda || router_ai.key != &router_pda {
        return Err(DayError::InvalidAccount.into());
    }
    if system_program_ai.key != &system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }

    // Already-initialized = owned by this program (not "has lamports").
    // Pre-funding the PDA with 1 lamport must not DoS init.
    if registry_ai.owner == program_id || router_ai.owner == program_id {
        return Err(DayError::AlreadyInitialized.into());
    }

    let rent = Rent::get()?;
    create_pda_account(
        authority,
        registry_ai,
        system_program_ai,
        program_id,
        AdapterRegistry::LEN,
        &[REGISTRY_SEED],
        registry_bump,
        &rent,
    )?;
    create_pda_account(
        authority,
        router_ai,
        system_program_ai,
        program_id,
        YieldRouter::LEN,
        &[ROUTER_SEED],
        router_bump,
        &rent,
    )?;

    let registry = AdapterRegistry {
        discriminator: REGISTRY_DISCRIMINATOR,
        authority: PROTOCOL_AUTHORITY,
        count: 0,
        adapters: [AdapterMeta::default(); MAX_ADAPTERS],
    };
    registry.serialize(&mut &mut registry_ai.data.borrow_mut()[..])?;

    let router = YieldRouter {
        discriminator: ROUTER_DISCRIMINATOR,
        authority: PROTOCOL_AUTHORITY,
        protocol_yield_skim_bps: PROTOCOL_YIELD_SKIM_BPS,
        deposit_fee_bps: DEPOSIT_FEE_BPS,
        withdraw_fee_bps: WITHDRAW_FEE_BPS,
        auto_yield_default_off: true,
        paused: false,
        bump: router_bump,
    };
    router.serialize(&mut &mut router_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY Initialize registry={} router={} skim_bps={} authority={} reg_bump={} rtr_bump={}",
        registry_pda,
        router_pda,
        PROTOCOL_YIELD_SKIM_BPS,
        PROTOCOL_AUTHORITY,
        registry_bump,
        router_bump
    );
    Ok(())
}

/// Create a program-owned PDA, resistant to lamport pre-fund griefing.
///
/// - Already program-owned → AlreadyInitialized
/// - Empty system account with 0 lamports → `create_account`
/// - Prefunded system account (data empty) → top-up rent + `allocate` + `assign`
fn create_pda_account<'a>(
    payer: &AccountInfo<'a>,
    pda: &AccountInfo<'a>,
    system_program_ai: &AccountInfo<'a>,
    program_id: &Pubkey,
    space: usize,
    seeds: &[&[u8]],
    bump: u8,
    rent: &Rent,
) -> ProgramResult {
    if pda.owner == program_id {
        return Err(DayError::AlreadyInitialized.into());
    }
    if pda.owner != &system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }
    if !pda.data_is_empty() {
        return Err(DayError::InvalidAccount.into());
    }

    let rent_lamports = rent.minimum_balance(space);
    let bump_slice = [bump];
    let mut signer_seeds: Vec<&[u8]> = seeds.to_vec();
    signer_seeds.push(&bump_slice);
    let signers: &[&[&[u8]]] = &[signer_seeds.as_slice()];

    if pda.lamports() == 0 {
        invoke_signed(
            &system_instruction::create_account(
                payer.key,
                pda.key,
                rent_lamports,
                space as u64,
                program_id,
            ),
            &[payer.clone(), pda.clone(), system_program_ai.clone()],
            signers,
        )?;
    } else {
        // Prefunded empty account: cannot create_account; allocate+assign instead.
        let current = pda.lamports();
        if current < rent_lamports {
            let needed = rent_lamports.saturating_sub(current);
            invoke(
                &system_instruction::transfer(payer.key, pda.key, needed),
                &[payer.clone(), pda.clone(), system_program_ai.clone()],
            )?;
        }
        invoke_signed(
            &system_instruction::allocate(pda.key, space as u64),
            &[pda.clone(), system_program_ai.clone()],
            signers,
        )?;
        invoke_signed(
            &system_instruction::assign(pda.key, program_id),
            &[pda.clone(), system_program_ai.clone()],
            signers,
        )?;
    }
    Ok(())
}

fn load_registry(ai: &AccountInfo, program_id: &Pubkey) -> Result<AdapterRegistry, ProgramError> {
    if ai.owner != program_id {
        return Err(DayError::InvalidAccount.into());
    }
    let reg = AdapterRegistry::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if reg.discriminator != REGISTRY_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(reg)
}

fn load_registry_v2(
    ai: &AccountInfo,
    program_id: &Pubkey,
) -> Result<AdapterRegistryV2, ProgramError> {
    let (expected, _) = Pubkey::find_program_address(&[REGISTRY_V2_SEED], program_id);
    if ai.owner != program_id || ai.key != &expected {
        return Err(DayError::InvalidAccount.into());
    }
    let reg = AdapterRegistryV2::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if reg.discriminator != REGISTRY_V2_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(reg)
}

/// Require the only router account that may represent DAY router state.
///
/// The router PDA is also the signer used by the CPI adapters; callers must
/// never be able to supply a different program-owned account as router state.
pub fn assert_canonical_router_pda(
    router_key: &Pubkey,
    program_id: &Pubkey,
) -> ProgramResult {
    let (expected, _) = Pubkey::find_program_address(&[ROUTER_SEED], program_id);
    if router_key != &expected {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

fn load_router(ai: &AccountInfo, program_id: &Pubkey) -> Result<YieldRouter, ProgramError> {
    // Every flow that loads the router subsequently treats the canonical
    // yield_router PDA as the authority.  Accepting any program-owned account
    // with a valid serialized Router shape would split that identity boundary
    // between the supplied account and the PDA signer.  Bind the account here
    // once so all callers share the same invariant.
    if ai.owner != program_id {
        return Err(DayError::InvalidAccount.into());
    }
    assert_canonical_router_pda(ai.key, program_id)?;
    let r = YieldRouter::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if r.discriminator != ROUTER_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(r)
}

/// Require the only fee configuration account that may control router fees.
///
/// Fee configuration is a separate migration-safe PDA, but it is still part of
/// the router authority boundary. Callers must never substitute another
/// program-owned account with a valid serialized fee-config shape.
pub fn assert_canonical_fee_config_pda(
    fee_config_key: &Pubkey,
    program_id: &Pubkey,
) -> ProgramResult {
    let (expected, _) = Pubkey::find_program_address(&[FEE_CONFIG_SEED], program_id);
    if fee_config_key != &expected {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// DAY-763: load the SEPARATE RouterFeeConfig PDA (mirrors load_router).
fn load_fee_config(ai: &AccountInfo, program_id: &Pubkey) -> Result<RouterFeeConfig, ProgramError> {
    if ai.owner != program_id {
        return Err(DayError::InvalidAccount.into());
    }
    assert_canonical_fee_config_pda(ai.key, program_id)?;
    let c = RouterFeeConfig::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if c.discriminator != FEE_CONFIG_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(c)
}

fn load_mctp_config(ai: &AccountInfo, program_id: &Pubkey) -> Result<MctpConfig, ProgramError> {
    let (expected, _) = mctp_config_pda(program_id);
    if ai.owner != program_id || ai.key != &expected {
        return Err(DayError::InvalidAccount.into());
    }
    let config = MctpConfig::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if config.discriminator != MCTP_CONFIG_DISCRIMINATOR
        || config.version != MCTP_CONFIG_VERSION
        || config.authority != PROTOCOL_AUTHORITY
    {
        return Err(DayError::InvalidAccount.into());
    }
    validate_mctp_config_params(&config.params)?;
    let (expected_registry, _) = Pubkey::find_program_address(&[REGISTRY_V2_SEED], program_id);
    if config.registry_v2 != expected_registry {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(config)
}

fn assert_authority(authority: &AccountInfo, expected: &Pubkey) -> ProgramResult {
    if !authority.is_signer || authority.key != expected {
        return Err(DayError::NotAuthority.into());
    }
    Ok(())
}

/// DAY-823 migration initializer. The existing V1 PDA is deliberately left
/// untouched because its allocated account length cannot hold a program id.
fn process_init_registry_v2(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let system_program_ai = next_account_info(acc_iter)?;

    assert_authority(authority, &PROTOCOL_AUTHORITY)?;
    let (registry_pda, registry_bump) =
        Pubkey::find_program_address(&[REGISTRY_V2_SEED], program_id);
    if registry_ai.key != &registry_pda || system_program_ai.key != &system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }
    if registry_ai.owner == program_id {
        return Err(DayError::AlreadyInitialized.into());
    }

    let rent = Rent::get()?;
    create_pda_account(
        authority,
        registry_ai,
        system_program_ai,
        program_id,
        AdapterRegistryV2::LEN,
        &[REGISTRY_V2_SEED],
        registry_bump,
        &rent,
    )?;
    AdapterRegistryV2 {
        discriminator: REGISTRY_V2_DISCRIMINATOR,
        authority: PROTOCOL_AUTHORITY,
        count: 0,
        adapters: [AdapterMetaV2::default(); MAX_ADAPTERS],
    }
    .serialize(&mut &mut registry_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY InitRegistryV2 registry={} authority={} bump={}",
        registry_pda,
        PROTOCOL_AUTHORITY,
        registry_bump
    );
    Ok(())
}

/// DAY-763: create + initialize the SEPARATE RouterFeeConfig PDA. Authority-gated
/// to PROTOCOL_AUTHORITY (mirrors Initialize's DAY-282 fixed-authority check —
/// not any signer). Presets 1% / $10 cap / DISABLED with treasury and authority
/// both = PROTOCOL_AUTHORITY. Kept out of YieldRouter so the deployed 49-byte
/// router layout is never mutated (Grok CRITICAL).
/// Accounts: [signer authority (PROTOCOL_AUTHORITY), fee_config PDA, system_program]
fn process_init_fee_config(program_id: &Pubkey, accounts: &[AccountInfo]) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let fee_config_ai = next_account_info(acc_iter)?;
    let system_program_ai = next_account_info(acc_iter)?;

    // DAY-282: fixed authority model — only PROTOCOL_AUTHORITY (treasury) may init.
    if !authority.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if authority.key != &PROTOCOL_AUTHORITY {
        return Err(DayError::NotAuthority.into());
    }

    let (fee_config_pda, fee_config_bump) =
        Pubkey::find_program_address(&[FEE_CONFIG_SEED], program_id);
    if fee_config_ai.key != &fee_config_pda {
        return Err(DayError::InvalidAccount.into());
    }
    if system_program_ai.key != &system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }

    // Already-initialized = owned by this program (not "has lamports").
    if fee_config_ai.owner == program_id {
        return Err(DayError::AlreadyInitialized.into());
    }

    let rent = Rent::get()?;
    create_pda_account(
        authority,
        fee_config_ai,
        system_program_ai,
        program_id,
        RouterFeeConfig::LEN,
        &[FEE_CONFIG_SEED],
        fee_config_bump,
        &rent,
    )?;

    let config = RouterFeeConfig {
        discriminator: FEE_CONFIG_DISCRIMINATOR,
        authority: PROTOCOL_AUTHORITY,
        treasury: PROTOCOL_AUTHORITY,
        profit_fee_bps: PROFIT_FEE_BPS_DEFAULT,
        profit_fee_cap_usd_micros: PROFIT_FEE_CAP_USD_MICROS_DEFAULT,
        profit_fee_enabled: false,
        bump: fee_config_bump,
    };
    config.serialize(&mut &mut fee_config_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY InitFeeConfig fee_config={} bps={} cap_usd_micros={} enabled=false authority={} bump={}",
        fee_config_pda,
        PROFIT_FEE_BPS_DEFAULT,
        PROFIT_FEE_CAP_USD_MICROS_DEFAULT,
        PROTOCOL_AUTHORITY,
        fee_config_bump
    );
    Ok(())
}

/// DAY-825/826: the legacy fee config remains editable for disclosure, but it
/// cannot be enabled until profit is derived from authenticated position state
/// in token units. A caller-provided USD value must never become transfer truth.
/// Accounts: [signer authority, fee_config PDA]
fn process_set_profit_fee(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    profit_fee_bps: u16,
    profit_fee_cap_usd_micros: u64,
    enabled: bool,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let fee_config_ai = next_account_info(acc_iter)?;

    let mut config = load_fee_config(fee_config_ai, program_id)?;
    assert_authority(authority, &config.authority)?;

    if profit_fee_bps > MAX_PROFIT_FEE_BPS {
        return Err(DayError::InvalidInstruction.into());
    }
    if enabled {
        return Err(DayError::CallerAssertedValueUnavailable.into());
    }

    config.profit_fee_bps = profit_fee_bps;
    config.profit_fee_cap_usd_micros = profit_fee_cap_usd_micros;
    config.profit_fee_enabled = enabled;
    config.serialize(&mut &mut fee_config_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY SetProfitFee bps={} cap_usd_micros={} enabled=false",
        profit_fee_bps,
        profit_fee_cap_usd_micros
    );
    Ok(())
}

// ── DAY-795 pass-through forwarder ───────────────────────────────────────────
//
// The router is the on-chain entry point the user calls for deposit/withdraw.
// Funds flow THROUGH the router so the fee is captured atomically in the middle
// of the outflow (withdraw) while never being custodied (atomic forward — the
// router-owned token account nets to zero within the instruction). The actual
// protocol interaction is a CPI into the protocol program, dispatched through a
// per-protocol ADAPTER. The adapter implementations are DAY-798-gated (they need
// the real on-chain program + account layout per protocol); until then the
// dispatch resolves to a stub that fails closed rather than move funds wrongly.

/// SPL Token program id (transfers of principal/fee are SPL transfers).
pub const SPL_TOKEN_PROGRAM_ID: Pubkey = pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");

/// Codex #3: assert an SPL token account is owned by `expected_owner`. The SPL
/// token account layout stores the owner pubkey at bytes 32..64. Also verifies
/// the account is owned by the SPL Token program (not a spoofed account). Fails
/// closed on any parse/mismatch so the fee/payout cannot be redirected.
fn assert_spl_token_owner(token_account: &AccountInfo, expected_owner: &Pubkey) -> ProgramResult {
    if token_account.owner != &SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    let data = token_account.data.borrow();
    // Mint(32) + Owner(32) = owner at offset 32..64. Account must be >= 72 bytes.
    if data.len() < 72 {
        return Err(DayError::InvalidAccount.into());
    }
    let owner_bytes: [u8; 32] = data[32..64]
        .try_into()
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if &Pubkey::new_from_array(owner_bytes) != expected_owner {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Read the canonical SPL Account amount field (bytes 64..72). Token-2022 is
/// deliberately not accepted by this legacy path because its program id differs.
fn spl_token_amount(token_account: &AccountInfo) -> Result<u64, ProgramError> {
    if token_account.owner != &SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    let data = token_account.data.borrow();
    let amount_bytes: [u8; 8] = data
        .get(64..72)
        .ok_or(DayError::InvalidAccount)?
        .try_into()
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    Ok(u64::from_le_bytes(amount_bytes))
}

fn spl_token_mint(token_account: &AccountInfo) -> Result<Pubkey, ProgramError> {
    if token_account.owner != &SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    let data = token_account.data.borrow();
    let mint_bytes: [u8; 32] = data
        .get(0..32)
        .ok_or(DayError::InvalidAccount)?
        .try_into()
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    Ok(Pubkey::new_from_array(mint_bytes))
}

/// All transfer legs must use one SPL mint. The typed adapter dispatcher must
/// additionally bind this mint to its validated market/reserve before CPI.
pub fn validate_payout_token_mints(
    router_mint: &Pubkey,
    treasury_mint: &Pubkey,
    owner_mint: &Pubkey,
) -> ProgramResult {
    if router_mint != treasury_mint || router_mint != owner_mint {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// DAY-827: only a positive balance increase created by this adapter call may
/// be paid out. Pre-existing router balance is never part of the withdrawal.
pub fn measured_withdraw_delta(before: u64, after: u64) -> Result<u64, ProgramError> {
    let delta = after
        .checked_sub(before)
        .ok_or_else(|| ProgramError::from(DayError::InvalidBalanceDelta))?;
    if delta == 0 {
        return Err(DayError::InvalidBalanceDelta.into());
    }
    Ok(delta)
}

/// DAY-825/826 fail-closed gate for legacy caller claims. Neither the ambiguous
/// USD-micros amount nor profit field may authorize a token transfer. The typed
/// adapter payload and measured token delta are the only future money inputs.
pub fn assert_legacy_withdraw_claims_quarantined(
    caller_amount_micros: u64,
    fee_enabled: bool,
    caller_realized_profit_usd_micros: u64,
) -> ProgramResult {
    if caller_amount_micros != 0 || fee_enabled || caller_realized_profit_usd_micros != 0 {
        return Err(DayError::CallerAssertedValueUnavailable.into());
    }
    Ok(())
}

/// Build an SPL `Transfer` instruction (amount from `src` to `dst`, `authority` signs).
fn spl_transfer_ix(
    src: &Pubkey,
    dst: &Pubkey,
    authority: &Pubkey,
    amount: u64,
) -> solana_program::instruction::Instruction {
    // SPL Token `Transfer` = tag 3 + u64 amount (little-endian).
    let mut data = Vec::with_capacity(9);
    data.push(3u8);
    data.extend_from_slice(&amount.to_le_bytes());
    solana_program::instruction::Instruction {
        program_id: SPL_TOKEN_PROGRAM_ID,
        accounts: vec![
            solana_program::instruction::AccountMeta::new(*src, false),
            solana_program::instruction::AccountMeta::new(*dst, false),
            solana_program::instruction::AccountMeta::new_readonly(*authority, true),
        ],
        data,
    }
}

/// DAY-915 dispatch arm for a padded adapter id. Known families get explicit
/// match arms in `cpi_protocol_adapter`; unknown ids still fail closed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterDispatchArm {
    Kamino,
    Marginfi,
    JupiterLend,
    /// DAY-978 Save (ex-Solend) — source CPI body for Main Market bSOL.
    Save,
    /// Registered or not — no typed CPI path exists for this id yet.
    Unknown,
}

/// Compare a fixed-width adapter id to a short ASCII tag (null-padded to 16).
pub fn adapter_id_matches(adapter_id: &[u8; ADAPTER_ID_LEN], tag: &str) -> bool {
    *adapter_id == pad_adapter_id(tag)
}

/// Classify a padded adapter id into a known CPI dispatch arm.
pub fn classify_adapter_dispatch(adapter_id: &[u8; ADAPTER_ID_LEN]) -> AdapterDispatchArm {
    if adapter_id_matches(adapter_id, "kamino") {
        AdapterDispatchArm::Kamino
    } else if adapter_id_matches(adapter_id, "marginfi") {
        AdapterDispatchArm::Marginfi
    } else if adapter_id_matches(adapter_id, "jupiter-lend") {
        AdapterDispatchArm::JupiterLend
    } else if adapter_id_matches(adapter_id, "save") {
        AdapterDispatchArm::Save
    } else {
        AdapterDispatchArm::Unknown
    }
}

/// Host-testable DAY-915 pure registry gate (no account metas).
///
/// Order (fail closed, never silently Ok):
/// 1. `validate_protocol_program` — adapter must be active in RegistryV2 with
///    the exact executable program id (missing registry entry → NotAllowlisted).
/// 2. Classify the adapter arm (kamino / marginfi / jupiter-lend / unknown).
/// 3. Always return `AdapterNotWired` — this pure gate has no account metas and
///    must never authorize fund movement alone.
///
/// Real money path is `cpi_protocol_adapter` → per-arm helpers (jupiter-lend
/// + kamino + save + marginfi have `invoke_signed` + market/bank pins).
pub fn dispatch_protocol_adapter(
    reg: &AdapterRegistryV2,
    adapter_id: &[u8; ADAPTER_ID_LEN],
    supplied_program: &Pubkey,
    supplied_program_executable: bool,
) -> Result<AdapterDispatchArm, ProgramError> {
    validate_protocol_program(
        reg,
        adapter_id,
        supplied_program,
        supplied_program_executable,
    )?;
    // Classification is intentional for logging/tests; pure gate always stops.
    let arm = classify_adapter_dispatch(adapter_id);
    match arm {
        AdapterDispatchArm::Kamino
        | AdapterDispatchArm::Marginfi
        | AdapterDispatchArm::JupiterLend
        | AdapterDispatchArm::Save
        | AdapterDispatchArm::Unknown => Err(DayError::AdapterNotWired.into()),
    }
}

/// DAY-915/DAY-976: registry-gated CPI dispatch into a protocol program.
///
/// Callers must load RegistryV2 first. This function re-validates the active
/// adapter → program binding, then matches a per-adapter arm. Arms without a
/// verified CPI body fail closed with `AdapterNotWired`. Wired arms still pin
/// exact program + market accounts before `invoke_signed`.
///
/// We NEVER fabricate a protocol CPI against an unverified address. Withdraw
/// snapshots the router token account around this call, pays only the positive
/// delta, and rejects legacy caller-provided USD amount/profit surfaces.
fn cpi_protocol_adapter<'a>(
    reg: &AdapterRegistryV2,
    adapter_id: &[u8; ADAPTER_ID_LEN],
    protocol_program: &AccountInfo<'a>,
    protocol_accounts: &[AccountInfo<'a>],
    protocol_ix_data: &[u8],
    router_signer_seeds: &[&[u8]],
    expected_owner: Option<&Pubkey>,
) -> ProgramResult {
    // Shared pure gate: missing/inactive registry entry or program mismatch
    // fails before any per-adapter arm runs.
    validate_protocol_program(
        reg,
        adapter_id,
        protocol_program.key,
        protocol_program.executable,
    )?;

    match classify_adapter_dispatch(adapter_id) {
        AdapterDispatchArm::Kamino => cpi_adapter_kamino(
            protocol_program,
            protocol_accounts,
            protocol_ix_data,
            expected_owner,
        ),
        AdapterDispatchArm::Marginfi => cpi_adapter_marginfi(
            protocol_program,
            protocol_accounts,
            protocol_ix_data,
            router_signer_seeds,
            expected_owner,
        ),
        AdapterDispatchArm::JupiterLend => cpi_adapter_jupiter_lend(
            protocol_program,
            protocol_accounts,
            protocol_ix_data,
            router_signer_seeds,
        ),
        AdapterDispatchArm::Save => cpi_adapter_save(
            protocol_program,
            protocol_accounts,
            protocol_ix_data,
            router_signer_seeds,
        ),
        AdapterDispatchArm::Unknown => {
            msg!(
                "DAY ForwardAdapterCPI unknown adapter={:?} program={} fail-closed",
                adapter_id,
                protocol_program.key
            );
            Err(DayError::AdapterNotWired.into())
        }
    }
}

// ─── DAY-976: Kamino KLend Main Market USDC CPI arm ─────────────────────────
// Evidence: mainnet deposit digests (D6q6 reserve) + KLend IDL
// `depositReserveLiquidityAndObligationCollateralV2` /
// `withdrawObligationCollateralAndRedeemReserveCollateralV2`.
// Live GO still requires SBF upgrade + RegisterAdapterV2 + measured RT.
// depositableLive must stay false until that measured bar is pinned.

/// Kamino Lend mainnet program (KLend).
/// Matches `SOLANA_PROTOCOL_IDS.kaminoLendProgram` / residual inventory programIds.
pub const KAMINO_KLEND_PROGRAM_ID: Pubkey =
    pubkey!("KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD");

/// Main Market (Main Market USDC pilot — DAY-976 / DAY-905).
pub const KAMINO_MAIN_MARKET: Pubkey =
    pubkey!("7u3HeHxYDLhnCoErrtycNokbQYbWGzLs6JSDqGAv5PfF");

/// Main Market lending-market authority PDA (pinned from mainnet deposit).
pub const KAMINO_MAIN_MARKET_AUTHORITY: Pubkey =
    pubkey!("9DrvZvyWh1HuAoZxvYWMvkf2XCzryCpGgHqrMjyDWpmo");

/// Main Market open USDC reserve (D6q6…).
pub const KAMINO_MAIN_MARKET_USDC_RESERVE: Pubkey =
    pubkey!("D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59");

/// USDC mint (same as jupiter-lend pin).
pub const KAMINO_USDC_MINT: Pubkey =
    pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");

/// Reserve liquidity supply vault for D6q6 USDC.
pub const KAMINO_USDC_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("Bgq7trRgVMeq33yt235zM2onQ4bRDBsY5EWiTetF4qw6");

/// Reserve collateral (cToken) mint for D6q6 USDC.
pub const KAMINO_USDC_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D");

/// Reserve collateral supply vault (deposit destination / withdraw source).
pub const KAMINO_USDC_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("3DzjXRfxRm6iejfyyMynR4tScddaanrePJ1NJU2XnPPL");

/// Kamino Farms program (V2 deposit/withdraw farmsAccounts tail).
pub const KAMINO_FARMS_PROGRAM_ID: Pubkey =
    pubkey!("FarmsPZpWu9i7Kky8tPN37rs2TpmMrAZrC7S7vJa91Hr");

/// Main Market USDC reserve farm state (optional farm slot; pin when farms on).
pub const KAMINO_USDC_RESERVE_FARM_STATE: Pubkey =
    pubkey!("JAvnB9AKtgPsTEoKmn24Bq64UMoYcrtWtq42HHBdsPkh");

// ── DAY-930: Main Market multi-reserve source pins (on-chain KLend Reserve decode) ──
// Host inventory: runtime/adapters/forms/solana-lend-markets.mjs KAMINO_LEND_MARKETS
// + kamino-lend-materialize KAMINO_DAY_ROUTER_RESERVE_PINS.
// Source-pinned only — day_router LIVE GO residual until SBF + RegisterAdapterV2
// + measured ForwardDeposit RT (never invent depositableLive). USDC remains the
// preparePath / body-wired anchor; siblings accept the same CPI layout.

/// Main Market SOL reserve (host marketId kamino-sol).
pub const KAMINO_MAIN_MARKET_SOL_RESERVE: Pubkey =
    pubkey!("d4A2prbA2whesmvHaL88BH6Ewn5N4bTSU2Ze8P6Bc4Q");
pub const KAMINO_SOL_MINT: Pubkey =
    pubkey!("So11111111111111111111111111111111111111112");
pub const KAMINO_SOL_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("GafNuUXj9rxGLn4y79dPu6MHSuPWeJR6UtTWuexpGh3U");
pub const KAMINO_SOL_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("2UywZrUdyqs5vDchy7fKQJKau2RVyuzBev2XKGPDSiX1");
pub const KAMINO_SOL_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("8NXMyRD91p3nof61BTkJvrfpGTASHygz1cUvc3HvwyGS");
pub const KAMINO_SOL_RESERVE_FARM_STATE: Pubkey =
    pubkey!("955xWFhSDcDiUgUr4sBRtCpTLiMd4H5uZLAmgtP3R3sX");

/// Main Market USDT reserve (host marketId kamino-usdt).
pub const KAMINO_MAIN_MARKET_USDT_RESERVE: Pubkey =
    pubkey!("H3t6qZ1JkguCNTi9uzVKqQ7dvt2cum4XiXWom6Gn5e5S");
pub const KAMINO_USDT_MINT: Pubkey =
    pubkey!("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB");
pub const KAMINO_USDT_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("2Eff8Udy2G2gzNcf2619AnTx3xM4renEv4QrHKjS1o9N");
pub const KAMINO_USDT_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("B8zf4kojJbwgCRKA7rLaLhRCZBGhgAJp8wPBVZZHMhSv");
pub const KAMINO_USDT_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("CTCpzgNbPwWQSYamu4ZomgFuHf8DUGwq8hSYWVLurSJD");
pub const KAMINO_USDT_RESERVE_FARM_STATE: Pubkey =
    pubkey!("5pCqu9RFdL6QoN7KK4gKnAU6CjQFJot8nU7wpFK8Zwou");

/// Main Market PYUSD reserve (host marketId kamino-pyusd).
pub const KAMINO_MAIN_MARKET_PYUSD_RESERVE: Pubkey =
    pubkey!("2gc9Dm1eB6UgVYFBUN9bWks6Kes9PbWSaPaa9DqyvEiN");
pub const KAMINO_PYUSD_MINT: Pubkey =
    pubkey!("2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo");
pub const KAMINO_PYUSD_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("Gm2itCNPBpBSSrgCA194pmErjwHAFVpvBBFvpdTF5LuJ");
pub const KAMINO_PYUSD_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("2dQkXr1e9LBvT2QcfKrzZaWY6gGAAVoCjLgkWFk3Mhkj");
pub const KAMINO_PYUSD_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("6LNyxFoeThPa3kPAWUYjEXPMsEd93VQUo5cuJfxcXaGp");
pub const KAMINO_PYUSD_RESERVE_FARM_STATE: Pubkey =
    pubkey!("DEe2NZ5dAXGxC7M8Gs9Esd9wZRPdQzG8jNamXqhL5yku");

/// Main Market jitoSOL reserve (host marketId kamino-jitosol). No farm_collateral.
pub const KAMINO_MAIN_MARKET_JITOSOL_RESERVE: Pubkey =
    pubkey!("EVbyPKrHG6WBfm4dLxLMJpUDY43cCAcHSpV3KYjKsktW");
pub const KAMINO_JITOSOL_MINT: Pubkey =
    pubkey!("J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn");
pub const KAMINO_JITOSOL_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("6sga1yRArgQRqa8Darhm54EBromEpV3z8iDAvMTVYXB3");
pub const KAMINO_JITOSOL_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("9ucQp7thL38MDDTSER5ou24QnVSTZFLevDsZC1cAFkKy");
pub const KAMINO_JITOSOL_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("7y5Nko765HcZiTd2gFtxorELuJZcbQqmrmTbUVoiwGyS");

/// Main Market mSOL reserve (host marketId kamino-msol). No farm_collateral.
pub const KAMINO_MAIN_MARKET_MSOL_RESERVE: Pubkey =
    pubkey!("FBSyPnxtHKLBZ4UeeUyAnbtFuAmTHLtso9YtsqRDRWpM");
pub const KAMINO_MSOL_MINT: Pubkey =
    pubkey!("mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So");
pub const KAMINO_MSOL_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("CQWUdThEbNMjcoEjGyCMTGXHpKvW1aB8JF31hKa1FQQN");
pub const KAMINO_MSOL_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("HTHAb6CigDQXtKuYX1Tad5hoguguRnRmt6DguosVsKWC");
pub const KAMINO_MSOL_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("G9tjwEXduCMuz6PFwBW6o73Lu36MwhAvt2deS7o1MQaS");

/// Main Market bSOL reserve (host marketId kamino-bsol).
pub const KAMINO_MAIN_MARKET_BSOL_RESERVE: Pubkey =
    pubkey!("H9vmCVd77N1HZa36eBn3UnftYmg4vQzPfm1RxabHAMER");
pub const KAMINO_BSOL_MINT: Pubkey =
    pubkey!("bSo13r4TkiE4KumL71LsHTPpL2euBYLFx6h9HP3piy1");
pub const KAMINO_BSOL_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("AQeaZUp248NPCBwRuVPzCsN3DX6DsgVHyiE25z6eEeAs");
pub const KAMINO_BSOL_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("FtLmvJvsGW41fE7hwsp53uv2UqHakZ3QS7UBb5WoZtZg");
pub const KAMINO_BSOL_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("5JYgSp95BqxEAZteg7QmS2afk7pH7dvuqsqfUDorxKZb");
pub const KAMINO_BSOL_RESERVE_FARM_STATE: Pubkey =
    pubkey!("3NurSUwLF5dsVBFYSGPEBSQFo1AdFo8bHA3GK46qcmLD");

/// Main Market jupSOL reserve (host marketId kamino-jupsol). No farm_collateral.
pub const KAMINO_MAIN_MARKET_JUPSOL_RESERVE: Pubkey =
    pubkey!("DGQZWCY17gGtBUgdaFs1VreJWsodkjFxndPsskwFKGpp");
pub const KAMINO_JUPSOL_MINT: Pubkey =
    pubkey!("jupSoLaHXQiZZTSfEWMTRRgpnyFm8f6sZdosWBjx93v");
pub const KAMINO_JUPSOL_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("FbbgvvnwfN25cyX52Zqut2ZTbtvCWZbhKS177gfdUd6K");
pub const KAMINO_JUPSOL_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("8euYpQt56z9hA2ZcFCQuWK6gAptrLcJuMZ5PtMpUwbuY");
pub const KAMINO_JUPSOL_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("9w2hfobbGi94e7mg1HxchKuhpfHJ2CENnAfyeezDF46c");

/// Main Market USDG reserve (host marketId kamino-usdg; Token-2022 mint).
pub const KAMINO_MAIN_MARKET_USDG_RESERVE: Pubkey =
    pubkey!("ESCkPWKHmgNE7Msf77n9yzqJd5kQVWWGy3o5Mgxhvavp");
pub const KAMINO_USDG_MINT: Pubkey =
    pubkey!("2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH");
pub const KAMINO_USDG_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("DGBo8HmL7pBWBZLGePjHQ73JKRE37HVZ7ZbjA2FYUZHZ");
pub const KAMINO_USDG_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("BG6gsv8goyoJguEbLquUZFNiZ8aGTXgo4DyH9h8z9qao");
pub const KAMINO_USDG_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("BKGYpZxa2QpTSiRV7Jwc8P8cJaUQwq7maxREFFxboW6m");
pub const KAMINO_USDG_RESERVE_FARM_STATE: Pubkey =
    pubkey!("3W4tNzMoRXCBhirSSoHf5413Cx9P8kqXk4QpZtkjiLCG");

/// Main Market cbBTC reserve (host marketId kamino-cbbtc).
pub const KAMINO_MAIN_MARKET_CBBTC_RESERVE: Pubkey =
    pubkey!("37Jk2zkz23vkAYBT66HM2gaqJuNg2nYLsCreQAVt5MWK");
pub const KAMINO_CBBTC_MINT: Pubkey =
    pubkey!("cbbtcf3aa214zXHbiAZQwf4122FBYbraNdFqgw4iMij");
pub const KAMINO_CBBTC_RESERVE_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("BcPpdmg4vxXSenvkp12XbVp6XnzwKChnzfNa6cQXLW96");
pub const KAMINO_CBBTC_RESERVE_COLLATERAL_MINT: Pubkey =
    pubkey!("B3ieCZaTUp8qM9zbPqH2WDhzWpwrvHB2Q2aWB25DW97U");
pub const KAMINO_CBBTC_RESERVE_COLLATERAL_SUPPLY: Pubkey =
    pubkey!("hY6yiVepYxxv6dpzayYQ9LnhkX7yrFFpep3oxFRKRgi");
pub const KAMINO_CBBTC_RESERVE_FARM_STATE: Pubkey =
    pubkey!("9CinLHLAcMkzs4Ji8pwS2qwyz1LU46A4Ry7BNLGLubxs");

/// Instructions sysvar (KLend deposit/withdraw require it).
pub const SYSVAR_INSTRUCTIONS_ID: Pubkey =
    pubkey!("Sysvar1nstructions1111111111111111111111111");

/// Anchor disc for `deposit_reserve_liquidity_and_obligation_collateral_v2`.
/// Source: sha256("global:deposit_reserve_liquidity_and_obligation_collateral_v2")[:8]
/// + mainnet digest `5xGJc15P…2vvrsK` (amount 50000).
pub const KAMINO_DEPOSIT_V2_DISCRIMINATOR: [u8; 8] =
    [0xd8, 0xe0, 0xbf, 0x1b, 0xcc, 0x97, 0x66, 0xaf];

/// Anchor disc for `withdraw_obligation_collateral_and_redeem_reserve_collateral_v2`.
/// Source: sha256("global:withdraw_obligation_collateral_and_redeem_reserve_collateral_v2")[:8]
/// (IDL-aligned; host tests pin disc + market keys before any invoke).
pub const KAMINO_WITHDRAW_V2_DISCRIMINATOR: [u8; 8] =
    [0xeb, 0x34, 0x77, 0x98, 0x95, 0xc5, 0x14, 0x07];

/// KLend `refresh_reserve` and `refresh_obligation` discriminators.
/// Source: the primary `klend-interface` generated instruction definitions.
pub const KAMINO_REFRESH_RESERVE_DISCRIMINATOR: [u8; 8] =
    [0x02, 0xda, 0x8a, 0xeb, 0x4f, 0xc9, 0x19, 0x66];
pub const KAMINO_REFRESH_OBLIGATION_DISCRIMINATOR: [u8; 8] =
    [0x21, 0x84, 0x93, 0xe4, 0x97, 0xc0, 0x48, 0x59];

/// Flattened V2 deposit/withdraw account count (14 base + 2 farms + farmsProgram).
/// IDL: depositAccounts (14) + farmsAccounts (2) + farmsProgram (1) = 17.
pub const KAMINO_V2_ACCOUNT_LEN: usize = 17;

/// Deposit/withdraw refresh prefix: one source-pinned Scope account followed by existing
/// writable deposit reserves, a KLend delimiter, existing writable borrow
/// reserves, a second KLend delimiter, then borrow referrer-token-state metas.
/// The reserve being deposited is refreshed separately; it belongs in
/// RefreshObligation only when it is already an obligation position.
pub const KAMINO_DEPOSIT_FIXED_ACCOUNT_LEN: usize = KAMINO_V2_ACCOUNT_LEN + 1;
pub const KAMINO_DEPOSIT_ACCOUNT_LEN: usize = KAMINO_DEPOSIT_FIXED_ACCOUNT_LEN + 2;

// Shared account indices (deposit + withdraw share owner…authority + token/sysvar tail).
pub const KAMINO_IX_OWNER: usize = 0;
pub const KAMINO_IX_OBLIGATION: usize = 1;
pub const KAMINO_IX_LENDING_MARKET: usize = 2;
pub const KAMINO_IX_LENDING_MARKET_AUTHORITY: usize = 3;
pub const KAMINO_IX_RESERVE: usize = 4;
pub const KAMINO_IX_RESERVE_LIQUIDITY_MINT: usize = 5;
// Deposit: liquidity_supply @6, collateral_mint @7, dest_collateral @8, user_source @9
// Withdraw: source_collateral @6, collateral_mint @7, liquidity_supply @8, user_dest @9
pub const KAMINO_IX_SLOT_6: usize = 6;
pub const KAMINO_IX_SLOT_7: usize = 7;
pub const KAMINO_IX_SLOT_8: usize = 8;
pub const KAMINO_IX_USER_LIQUIDITY: usize = 9;
pub const KAMINO_IX_PLACEHOLDER_COLLATERAL: usize = 10;
pub const KAMINO_IX_COLLATERAL_TOKEN_PROGRAM: usize = 11;
pub const KAMINO_IX_LIQUIDITY_TOKEN_PROGRAM: usize = 12;
pub const KAMINO_IX_INSTRUCTION_SYSVAR: usize = 13;
pub const KAMINO_IX_OBLIGATION_FARM_USER: usize = 14;
pub const KAMINO_IX_RESERVE_FARM_STATE: usize = 15;
pub const KAMINO_IX_FARMS_PROGRAM: usize = 16;
pub const KAMINO_IX_SCOPE_PRICES: usize = 17;
pub const KAMINO_IX_OBLIGATION_RESERVES_START: usize = 18;

/// Main Market reserves currently share this Scope price feed. The binding is
/// taken from the primary KLend SDK's generated RefreshReserve instruction for
/// the exact D6q6… USDC reserve used by the no-broadcast GO ceremony.
pub const KAMINO_MAIN_MARKET_SCOPE_PRICES: Pubkey =
    pubkey!("3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH");

/// Source honesty: kamino KLend deposit/withdraw CPI body is implemented
/// (not the AdapterNotWired stub). Live fund-flow GO still requires SBF
/// upgrade, RegisterAdapterV2(kamino→KLend), mainnet ForwardDeposit/Withdraw
/// simulate err=null, exact-owner exit evidence, and operator attestation.
/// **depositableLive must remain false until that measured bar is pinned.**
pub const KAMINO_CPI_BODY_WIRED: bool = true;

/// Host-testable: true only when the kamino arm is the real CPI body.
pub fn kamino_cpi_body_wired() -> bool {
    KAMINO_CPI_BODY_WIRED
}

/// Host-testable pin check for the kamino arm (DAY-976).
pub fn assert_kamino_program_pin(
    protocol_program: &Pubkey,
    protocol_program_executable: bool,
) -> ProgramResult {
    if protocol_program != &KAMINO_KLEND_PROGRAM_ID {
        return Err(DayError::ProtocolProgramMismatch.into());
    }
    if !protocol_program_executable {
        return Err(DayError::ProtocolProgramNotExecutable.into());
    }
    Ok(())
}

/// Host-testable deposit V2 ix data: 8-byte disc + little-endian u64 amount > 0.
pub fn assert_kamino_deposit_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != 16 {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0..8] != KAMINO_DEPOSIT_V2_DISCRIMINATOR {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(
        data[8..16]
            .try_into()
            .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?,
    );
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Host-testable withdraw V2 ix data: 8-byte disc + little-endian u64 collateral > 0.
pub fn assert_kamino_withdraw_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != 16 {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0..8] != KAMINO_WITHDRAW_V2_DISCRIMINATOR {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(
        data[8..16]
            .try_into()
            .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?,
    );
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Encode deposit V2 ix data (disc + liquidity_amount). Host/composer helper.
pub fn encode_kamino_deposit_ix_data(amount: u64) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&KAMINO_DEPOSIT_V2_DISCRIMINATOR);
    out[8..16].copy_from_slice(&amount.to_le_bytes());
    out
}

/// Encode withdraw V2 ix data (disc + collateral_amount). Host/composer helper.
pub fn encode_kamino_withdraw_ix_data(collateral_amount: u64) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&KAMINO_WITHDRAW_V2_DISCRIMINATOR);
    out[8..16].copy_from_slice(&collateral_amount.to_le_bytes());
    out
}

/// Resolve Main Market reserve vault pins by reserve account.
/// Returns (liquidity_mint, liquidity_supply, collateral_mint, collateral_supply,
/// optional_farm_state). `None` farm means only KLend program id is accepted in
/// the farm slot (no on-chain farm_collateral). Unlisted reserves fail closed.
pub fn kamino_main_market_reserve_vault_pins(
    reserve: &Pubkey,
) -> Option<(Pubkey, Pubkey, Pubkey, Pubkey, Option<Pubkey>)> {
    if reserve == &KAMINO_MAIN_MARKET_USDC_RESERVE {
        Some((
            KAMINO_USDC_MINT,
            KAMINO_USDC_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_USDC_RESERVE_COLLATERAL_MINT,
            KAMINO_USDC_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_USDC_RESERVE_FARM_STATE),
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_SOL_RESERVE {
        Some((
            KAMINO_SOL_MINT,
            KAMINO_SOL_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_SOL_RESERVE_COLLATERAL_MINT,
            KAMINO_SOL_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_SOL_RESERVE_FARM_STATE),
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_USDT_RESERVE {
        Some((
            KAMINO_USDT_MINT,
            KAMINO_USDT_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_USDT_RESERVE_COLLATERAL_MINT,
            KAMINO_USDT_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_USDT_RESERVE_FARM_STATE),
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_PYUSD_RESERVE {
        Some((
            KAMINO_PYUSD_MINT,
            KAMINO_PYUSD_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_PYUSD_RESERVE_COLLATERAL_MINT,
            KAMINO_PYUSD_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_PYUSD_RESERVE_FARM_STATE),
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_JITOSOL_RESERVE {
        Some((
            KAMINO_JITOSOL_MINT,
            KAMINO_JITOSOL_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_JITOSOL_RESERVE_COLLATERAL_MINT,
            KAMINO_JITOSOL_RESERVE_COLLATERAL_SUPPLY,
            None,
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_MSOL_RESERVE {
        Some((
            KAMINO_MSOL_MINT,
            KAMINO_MSOL_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_MSOL_RESERVE_COLLATERAL_MINT,
            KAMINO_MSOL_RESERVE_COLLATERAL_SUPPLY,
            None,
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_BSOL_RESERVE {
        Some((
            KAMINO_BSOL_MINT,
            KAMINO_BSOL_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_BSOL_RESERVE_COLLATERAL_MINT,
            KAMINO_BSOL_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_BSOL_RESERVE_FARM_STATE),
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_JUPSOL_RESERVE {
        Some((
            KAMINO_JUPSOL_MINT,
            KAMINO_JUPSOL_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_JUPSOL_RESERVE_COLLATERAL_MINT,
            KAMINO_JUPSOL_RESERVE_COLLATERAL_SUPPLY,
            None,
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_USDG_RESERVE {
        Some((
            KAMINO_USDG_MINT,
            KAMINO_USDG_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_USDG_RESERVE_COLLATERAL_MINT,
            KAMINO_USDG_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_USDG_RESERVE_FARM_STATE),
        ))
    } else if reserve == &KAMINO_MAIN_MARKET_CBBTC_RESERVE {
        Some((
            KAMINO_CBBTC_MINT,
            KAMINO_CBBTC_RESERVE_LIQUIDITY_SUPPLY,
            KAMINO_CBBTC_RESERVE_COLLATERAL_MINT,
            KAMINO_CBBTC_RESERVE_COLLATERAL_SUPPLY,
            Some(KAMINO_CBBTC_RESERVE_FARM_STATE),
        ))
    } else {
        None
    }
}

/// Shared Main Market multi-reserve core pins (market / authority / token programs).
/// Reserve must resolve via `kamino_main_market_reserve_vault_pins`.
/// Returns (liquidity_supply, collateral_mint, collateral_supply) for vault slots.
fn assert_kamino_main_market_core(
    keys: &[Pubkey],
) -> Result<(Pubkey, Pubkey, Pubkey), ProgramError> {
    if keys.len() != KAMINO_V2_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    // User-specific slots must be non-default (bound by composer at CPI time).
    if keys[KAMINO_IX_OWNER] == Pubkey::default()
        || keys[KAMINO_IX_OBLIGATION] == Pubkey::default()
        || keys[KAMINO_IX_USER_LIQUIDITY] == Pubkey::default()
    {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_LENDING_MARKET] != KAMINO_MAIN_MARKET {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_LENDING_MARKET_AUTHORITY] != KAMINO_MAIN_MARKET_AUTHORITY {
        return Err(DayError::InvalidAccount.into());
    }
    let (mint, liq_supply, col_mint, col_supply, farm_opt) =
        kamino_main_market_reserve_vault_pins(&keys[KAMINO_IX_RESERVE])
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
    if keys[KAMINO_IX_RESERVE_LIQUIDITY_MINT] != mint {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_SLOT_7] != col_mint {
        return Err(DayError::InvalidAccount.into());
    }
    // Token-2022 (USDG) still uses Tokenkeg for collateral cToken; liquidity
    // token program may be Token-2022 — accept either Tokenkeg or Token-2022
    // program id only when mint is USDG; otherwise Tokenkeg only.
    if keys[KAMINO_IX_COLLATERAL_TOKEN_PROGRAM] != SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if mint == KAMINO_USDG_MINT {
        // USDG liquidity is Token-2022; collateral mint remains Tokenkeg cToken.
        if keys[KAMINO_IX_LIQUIDITY_TOKEN_PROGRAM] != SPL_TOKEN_PROGRAM_ID
            && keys[KAMINO_IX_LIQUIDITY_TOKEN_PROGRAM] != TOKEN_2022_PROGRAM_ID
        {
            return Err(DayError::InvalidAccount.into());
        }
    } else if keys[KAMINO_IX_LIQUIDITY_TOKEN_PROGRAM] != SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_INSTRUCTION_SYSVAR] != SYSVAR_INSTRUCTIONS_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_FARMS_PROGRAM] != KAMINO_FARMS_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    // Farms optional: program id = unset; otherwise pin reserve farm state.
    let farm = keys[KAMINO_IX_RESERVE_FARM_STATE];
    match farm_opt {
        Some(farm_state) => {
            if farm != KAMINO_KLEND_PROGRAM_ID && farm != farm_state {
                return Err(DayError::InvalidAccount.into());
            }
        }
        None => {
            if farm != KAMINO_KLEND_PROGRAM_ID {
                return Err(DayError::InvalidAccount.into());
            }
        }
    }
    Ok((liq_supply, col_mint, col_supply))
}

/// Host-testable market-account pin check for KLend Main Market multi-reserve Deposit V2.
///
/// Account order matches KLend IDL flatten + mainnet deposit `5xGJc15P…2vvrsK`:
/// ```text
///  0 owner (must equal the outer ForwardDeposit signer)
///  1 obligation                          (owner-scoped — KLend verifies owner)
///  2 lendingMarket                       = Main Market 7u3…
///  3 lendingMarketAuthority              = 9Drv…
///  4 reserve                             = Main Market multi-reserve pin
///  5 reserveLiquidityMint                = reserve mint
///  6 reserveLiquiditySupply              = pin
///  7 reserveCollateralMint               = pin
///  8 reserveDestinationDepositCollateral = pin
///  9 userSourceLiquidity                 (owner ATA — not pin-checked here)
/// 10 placeholderUserDestinationCollateral (optional; program id ok)
/// 11 collateralTokenProgram              = Tokenkeg
/// 12 liquidityTokenProgram               = Tokenkeg (Token-2022 for USDG)
/// 13 instructionSysvarAccount
/// 14 obligationFarmUserState             (optional)
/// 15 reserveFarmState                    = pin or program id
/// 16 farmsProgram                        = FarmsPZp…
/// ```
pub fn assert_kamino_deposit_accounts(keys: &[Pubkey]) -> ProgramResult {
    let (liq_supply, _col_mint, col_supply) = assert_kamino_main_market_core(keys)?;
    if keys[KAMINO_IX_SLOT_6] != liq_supply {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_SLOT_8] != col_supply {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Host-testable market-account pin check for KLend Main Market multi-reserve Withdraw V2.
///
/// Slot order differs from deposit for reserve vaults (IDL withdrawAccounts):
/// ```text
///  6 reserveSourceCollateral  = collateral supply
///  7 reserveCollateralMint    = pin
///  8 reserveLiquiditySupply   = pin
///  9 userDestinationLiquidity (router ATA)
/// ```
pub fn assert_kamino_withdraw_accounts(keys: &[Pubkey]) -> ProgramResult {
    let (liq_supply, _col_mint, col_supply) = assert_kamino_main_market_core(keys)?;
    if keys[KAMINO_IX_SLOT_6] != col_supply {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[KAMINO_IX_SLOT_8] != liq_supply {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Host-testable Instruction builder for KLend Deposit V2 (Main Market USDC).
pub fn build_kamino_deposit_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    expected_owner: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_kamino_deposit_accounts(account_keys)?;
    let _amount = assert_kamino_deposit_ix_data(protocol_ix_data)?;
    if account_keys.len() != is_writable.len() {
        return Err(DayError::InvalidAccount.into());
    }
    if &account_keys[KAMINO_IX_OWNER] != expected_owner {
        return Err(DayError::InvalidAccount.into());
    }
    let accounts: Vec<AccountMeta> = account_keys
        .iter()
        .zip(is_writable.iter())
        .enumerate()
        .map(|(i, (key, writable))| {
            let is_signer = i == KAMINO_IX_OWNER;
            if *writable {
                AccountMeta::new(*key, is_signer)
            } else {
                AccountMeta::new_readonly(*key, is_signer)
            }
        })
        .collect();
    Ok(Instruction {
        program_id: KAMINO_KLEND_PROGRAM_ID,
        accounts,
        data: protocol_ix_data.to_vec(),
    })
}

/// Build the exact atomic KLend deposit sequence required by the primary SDK:
/// RefreshReserve(existing positions, then current reserve) -> RefreshObligation
/// (existing deposits, existing borrows, borrow referrer states) ->
/// DepositReserveLiquidityAndObligationCollateralV2.
///
/// The obligation remains bound to the outer human signer through the deposit
/// instruction; refreshes introduce no authority substitution. The current
/// reserve is writable in RefreshObligation only when it was already a position,
/// matching the primary SDK's generated account roles.
pub fn build_kamino_deposit_sequence(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    expected_owner: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Vec<Instruction>, ProgramError> {
    if account_keys.len() < KAMINO_DEPOSIT_ACCOUNT_LEN
        || is_writable.len() != account_keys.len()
        || is_writable[KAMINO_IX_SCOPE_PRICES]
        || account_keys[KAMINO_IX_SCOPE_PRICES] != KAMINO_MAIN_MARKET_SCOPE_PRICES
    {
        return Err(DayError::InvalidAccount.into());
    }

    let deposit_delimiter_offset = account_keys[KAMINO_IX_OBLIGATION_RESERVES_START..]
        .iter()
        .position(|key| key == &KAMINO_KLEND_PROGRAM_ID)
        .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
    let deposit_delimiter_index =
        KAMINO_IX_OBLIGATION_RESERVES_START + deposit_delimiter_offset;
    let borrow_delimiter_offset = account_keys[deposit_delimiter_index + 1..]
        .iter()
        .position(|key| key == &KAMINO_KLEND_PROGRAM_ID)
        .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
    let borrow_delimiter_index = deposit_delimiter_index + 1 + borrow_delimiter_offset;
    if is_writable[deposit_delimiter_index]
        || is_writable[borrow_delimiter_index]
        || account_keys[borrow_delimiter_index + 1..]
            .contains(&KAMINO_KLEND_PROGRAM_ID)
    {
        return Err(DayError::InvalidAccount.into());
    }
    let deposit_reserves = &account_keys
        [KAMINO_IX_OBLIGATION_RESERVES_START..deposit_delimiter_index];
    let borrow_reserves =
        &account_keys[deposit_delimiter_index + 1..borrow_delimiter_index];
    let referrer_token_states = &account_keys[borrow_delimiter_index + 1..];
    for (index, reserve) in deposit_reserves.iter().enumerate() {
        if !is_writable[KAMINO_IX_OBLIGATION_RESERVES_START + index]
            || kamino_main_market_reserve_vault_pins(reserve).is_none()
            || deposit_reserves[..index].contains(reserve)
        {
            return Err(DayError::InvalidAccount.into());
        }
    }
    for (index, reserve) in borrow_reserves.iter().enumerate() {
        if !is_writable[deposit_delimiter_index + 1 + index]
            || kamino_main_market_reserve_vault_pins(reserve).is_none()
            || borrow_reserves[..index].contains(reserve)
        {
            return Err(DayError::InvalidAccount.into());
        }
    }
    if !referrer_token_states.is_empty()
        && referrer_token_states.len() != borrow_reserves.len()
    {
        return Err(DayError::InvalidAccount.into());
    }
    for (index, state) in referrer_token_states.iter().enumerate() {
        if !is_writable[borrow_delimiter_index + 1 + index]
            || *state == Pubkey::default()
            || kamino_main_market_reserve_vault_pins(state).is_some()
            || referrer_token_states[..index].contains(state)
        {
            return Err(DayError::InvalidAccount.into());
        }
    }

    let deposit = build_kamino_deposit_instruction(
        &account_keys[..KAMINO_V2_ACCOUNT_LEN],
        &is_writable[..KAMINO_V2_ACCOUNT_LEN],
        expected_owner,
        protocol_ix_data,
    )?;

    // Primary klend-interface RefreshReserve layout:
    // reserve, market, pyth?, switchboard price?, switchboard twap?, scope.
    // This reserve uses Scope only, so absent optionals are the KLend program
    // sentinel exactly as emitted by @kamino-finance/klend-sdk.
    let current_reserve = account_keys[KAMINO_IX_RESERVE];
    let mut refresh_reserves = Vec::with_capacity(deposit_reserves.len() + borrow_reserves.len() + 1);
    for reserve in deposit_reserves.iter().chain(borrow_reserves.iter()) {
        if *reserve != current_reserve && !refresh_reserves.contains(reserve) {
            refresh_reserves.push(*reserve);
        }
    }
    refresh_reserves.push(current_reserve);

    let mut sequence = Vec::with_capacity(refresh_reserves.len() + 2);
    for reserve in &refresh_reserves {
        sequence.push(Instruction {
            program_id: KAMINO_KLEND_PROGRAM_ID,
            accounts: vec![
                AccountMeta::new(*reserve, false),
                AccountMeta::new_readonly(account_keys[KAMINO_IX_LENDING_MARKET], false),
                AccountMeta::new_readonly(KAMINO_KLEND_PROGRAM_ID, false),
                AccountMeta::new_readonly(KAMINO_KLEND_PROGRAM_ID, false),
                AccountMeta::new_readonly(KAMINO_KLEND_PROGRAM_ID, false),
                AccountMeta::new_readonly(account_keys[KAMINO_IX_SCOPE_PRICES], false),
            ],
            data: KAMINO_REFRESH_RESERVE_DISCRIMINATOR.to_vec(),
        });
    }

    let mut refresh_obligation_accounts = vec![
        AccountMeta::new_readonly(account_keys[KAMINO_IX_LENDING_MARKET], false),
        AccountMeta::new(account_keys[KAMINO_IX_OBLIGATION], false),
    ];
    refresh_obligation_accounts.extend(
        deposit_reserves
            .iter()
            .map(|reserve| AccountMeta::new(*reserve, false)),
    );
    refresh_obligation_accounts.extend(
        borrow_reserves
            .iter()
            .map(|reserve| AccountMeta::new(*reserve, false)),
    );
    refresh_obligation_accounts.extend(
        referrer_token_states
            .iter()
            .map(|state| AccountMeta::new(*state, false)),
    );
    sequence.push(Instruction {
        program_id: KAMINO_KLEND_PROGRAM_ID,
        accounts: refresh_obligation_accounts,
        data: KAMINO_REFRESH_OBLIGATION_DISCRIMINATOR.to_vec(),
    });
    sequence.push(deposit);

    Ok(sequence)
}

/// Host-testable Instruction builder for KLend Withdraw V2 (Main Market USDC).
pub fn build_kamino_withdraw_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    expected_owner: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_kamino_withdraw_accounts(account_keys)?;
    let _amount = assert_kamino_withdraw_ix_data(protocol_ix_data)?;
    if account_keys.len() != is_writable.len() {
        return Err(DayError::InvalidAccount.into());
    }
    if &account_keys[KAMINO_IX_OWNER] != expected_owner {
        return Err(DayError::InvalidAccount.into());
    }
    let accounts: Vec<AccountMeta> = account_keys
        .iter()
        .zip(is_writable.iter())
        .enumerate()
        .map(|(i, (key, writable))| {
            let is_signer = i == KAMINO_IX_OWNER;
            if *writable {
                AccountMeta::new(*key, is_signer)
            } else {
                AccountMeta::new_readonly(*key, is_signer)
            }
        })
        .collect();
    Ok(Instruction {
        program_id: KAMINO_KLEND_PROGRAM_ID,
        accounts,
        data: protocol_ix_data.to_vec(),
    })
}

/// Build the atomic KLend withdraw sequence required by the primary SDK:
/// RefreshReserve for every owner position -> RefreshObligation -> Withdraw V2.
/// The trailing refresh frame is identical to deposit (Scope, deposit reserves,
/// delimiter, borrow reserves, delimiter, referrer token states).
pub fn build_kamino_withdraw_sequence(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    expected_owner: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Vec<Instruction>, ProgramError> {
    if account_keys.len() < KAMINO_DEPOSIT_ACCOUNT_LEN
        || is_writable.len() != account_keys.len()
        || is_writable[KAMINO_IX_SCOPE_PRICES]
        || account_keys[KAMINO_IX_SCOPE_PRICES] != KAMINO_MAIN_MARKET_SCOPE_PRICES
    {
        return Err(DayError::InvalidAccount.into());
    }
    let deposit_delimiter_index = KAMINO_IX_OBLIGATION_RESERVES_START
        + account_keys[KAMINO_IX_OBLIGATION_RESERVES_START..]
            .iter()
            .position(|key| key == &KAMINO_KLEND_PROGRAM_ID)
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
    let borrow_delimiter_index = deposit_delimiter_index + 1
        + account_keys[deposit_delimiter_index + 1..]
            .iter()
            .position(|key| key == &KAMINO_KLEND_PROGRAM_ID)
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
    if is_writable[deposit_delimiter_index]
        || is_writable[borrow_delimiter_index]
        || account_keys[borrow_delimiter_index + 1..].contains(&KAMINO_KLEND_PROGRAM_ID)
    {
        return Err(DayError::InvalidAccount.into());
    }
    let deposit_reserves =
        &account_keys[KAMINO_IX_OBLIGATION_RESERVES_START..deposit_delimiter_index];
    let borrow_reserves = &account_keys[deposit_delimiter_index + 1..borrow_delimiter_index];
    let referrer_token_states = &account_keys[borrow_delimiter_index + 1..];
    let current_reserve = account_keys[KAMINO_IX_RESERVE];
    if !deposit_reserves.contains(&current_reserve) {
        return Err(DayError::InvalidAccount.into());
    }
    for (index, reserve) in deposit_reserves.iter().enumerate() {
        if !is_writable[KAMINO_IX_OBLIGATION_RESERVES_START + index]
            || kamino_main_market_reserve_vault_pins(reserve).is_none()
            || deposit_reserves[..index].contains(reserve)
        {
            return Err(DayError::InvalidAccount.into());
        }
    }
    for (index, reserve) in borrow_reserves.iter().enumerate() {
        if !is_writable[deposit_delimiter_index + 1 + index]
            || kamino_main_market_reserve_vault_pins(reserve).is_none()
            || borrow_reserves[..index].contains(reserve)
        {
            return Err(DayError::InvalidAccount.into());
        }
    }
    if !referrer_token_states.is_empty() && referrer_token_states.len() != borrow_reserves.len() {
        return Err(DayError::InvalidAccount.into());
    }
    for (index, state) in referrer_token_states.iter().enumerate() {
        if !is_writable[borrow_delimiter_index + 1 + index]
            || *state == Pubkey::default()
            || kamino_main_market_reserve_vault_pins(state).is_some()
            || referrer_token_states[..index].contains(state)
        {
            return Err(DayError::InvalidAccount.into());
        }
    }
    let withdraw = build_kamino_withdraw_instruction(
        &account_keys[..KAMINO_V2_ACCOUNT_LEN],
        &is_writable[..KAMINO_V2_ACCOUNT_LEN],
        expected_owner,
        protocol_ix_data,
    )?;
    let mut refresh_reserves = Vec::new();
    for reserve in deposit_reserves.iter().chain(borrow_reserves.iter()) {
        if *reserve != current_reserve && !refresh_reserves.contains(reserve) {
            refresh_reserves.push(*reserve);
        }
    }
    refresh_reserves.push(current_reserve);
    let mut sequence = Vec::with_capacity(refresh_reserves.len() + 2);
    for reserve in &refresh_reserves {
        sequence.push(Instruction {
            program_id: KAMINO_KLEND_PROGRAM_ID,
            accounts: vec![
                AccountMeta::new(*reserve, false),
                AccountMeta::new_readonly(account_keys[KAMINO_IX_LENDING_MARKET], false),
                AccountMeta::new_readonly(KAMINO_KLEND_PROGRAM_ID, false),
                AccountMeta::new_readonly(KAMINO_KLEND_PROGRAM_ID, false),
                AccountMeta::new_readonly(KAMINO_KLEND_PROGRAM_ID, false),
                AccountMeta::new_readonly(account_keys[KAMINO_IX_SCOPE_PRICES], false),
            ],
            data: KAMINO_REFRESH_RESERVE_DISCRIMINATOR.to_vec(),
        });
    }
    let mut obligation_accounts = vec![
        AccountMeta::new_readonly(account_keys[KAMINO_IX_LENDING_MARKET], false),
        AccountMeta::new(account_keys[KAMINO_IX_OBLIGATION], false),
    ];
    obligation_accounts.extend(deposit_reserves.iter().map(|r| AccountMeta::new(*r, false)));
    obligation_accounts.extend(borrow_reserves.iter().map(|r| AccountMeta::new(*r, false)));
    obligation_accounts.extend(referrer_token_states.iter().map(|s| AccountMeta::new(*s, false)));
    sequence.push(Instruction {
        program_id: KAMINO_KLEND_PROGRAM_ID,
        accounts: obligation_accounts,
        data: KAMINO_REFRESH_OBLIGATION_DISCRIMINATOR.to_vec(),
    });
    sequence.push(withdraw);
    Ok(sequence)
}

/// Canonical writable mask for Deposit V2 (from mainnet deposit evidence).
pub fn kamino_deposit_default_writables() -> [bool; KAMINO_V2_ACCOUNT_LEN] {
    let mut w = [false; KAMINO_V2_ACCOUNT_LEN];
    w[KAMINO_IX_OWNER] = true;
    w[KAMINO_IX_OBLIGATION] = true;
    w[KAMINO_IX_RESERVE] = true;
    w[KAMINO_IX_SLOT_6] = true; // liquidity supply
    w[KAMINO_IX_SLOT_7] = true; // collateral mint
    w[KAMINO_IX_SLOT_8] = true; // dest collateral
    w[KAMINO_IX_USER_LIQUIDITY] = true;
    w[KAMINO_IX_OBLIGATION_FARM_USER] = true;
    w[KAMINO_IX_RESERVE_FARM_STATE] = true;
    w
}

/// Canonical writable mask for Withdraw V2 (IDL isMut flags).
pub fn kamino_withdraw_default_writables() -> [bool; KAMINO_V2_ACCOUNT_LEN] {
    let mut w = [false; KAMINO_V2_ACCOUNT_LEN];
    w[KAMINO_IX_OWNER] = true;
    w[KAMINO_IX_OBLIGATION] = true;
    w[KAMINO_IX_RESERVE] = true;
    w[KAMINO_IX_SLOT_6] = true; // source collateral
    w[KAMINO_IX_SLOT_7] = true; // collateral mint
    w[KAMINO_IX_SLOT_8] = true; // liquidity supply
    w[KAMINO_IX_USER_LIQUIDITY] = true;
    w[KAMINO_IX_OBLIGATION_FARM_USER] = true;
    w[KAMINO_IX_RESERVE_FARM_STATE] = true;
    w
}

/// Kamino KLend deposit/withdraw CPI (DAY-976). Registry binding already
/// validated by `cpi_protocol_adapter`.
///
/// 1. Assert KLend program pin
/// 2. Branch on disc (deposit V2 vs withdraw V2) — unknown disc fails closed
/// 3. Bind exact Main Market USDC metas — reject caller-arbitrary markets
/// 4. Require owner slot == outer owner signer; invoke without DAY PDA custody
///
/// Residual before money-path GO: SBF upgrade, RegisterAdapterV2, mainnet
/// ForwardDeposit/Withdraw simulate, exact-owner RT, depositableLive pin.
fn cpi_adapter_kamino<'a>(
    protocol_program: &AccountInfo<'a>,
    protocol_accounts: &[AccountInfo<'a>],
    protocol_ix_data: &[u8],
    expected_owner: Option<&Pubkey>,
) -> ProgramResult {
    assert_kamino_program_pin(protocol_program.key, protocol_program.executable)?;

    let keys: Vec<Pubkey> = protocol_accounts.iter().map(|a| *a.key).collect();
    let owner = expected_owner.ok_or(ProgramError::from(DayError::InvalidAccount))?;
    if protocol_accounts
        .first()
        .map(|a| a.key != owner || !a.is_signer)
        .unwrap_or(true)
    {
        msg!(
            "DAY CPI kamino signer must equal ForwardDeposit owner {} (got {:?})",
            owner,
            protocol_accounts.first().map(|a| a.key)
        );
        return Err(DayError::InvalidAccount.into());
    }

    let is_writable: Vec<bool> = protocol_accounts.iter().map(|a| a.is_writable).collect();

    if protocol_ix_data.len() >= 8
        && protocol_ix_data[0..8] == KAMINO_DEPOSIT_V2_DISCRIMINATOR
    {
        let amount = assert_kamino_deposit_ix_data(protocol_ix_data)?;
        let sequence = build_kamino_deposit_sequence(
            &keys,
            &is_writable,
            owner,
            protocol_ix_data,
        )?;
        msg!(
            "DAY CPI arm=kamino deposit program={} accounts={} amount={} owner_signed refresh_reserve+refresh_obligation",
            protocol_program.key,
            protocol_accounts.len(),
            amount
        );

        // Refresh every existing position reserve, then the current deposit
        // reserve. RefreshObligation itself receives only existing deposits,
        // existing borrows, then borrow referrer states (primary SDK order).
        let deposit_delimiter_index = protocol_accounts
            [KAMINO_IX_OBLIGATION_RESERVES_START..]
            .iter()
            .position(|account| account.key == &KAMINO_KLEND_PROGRAM_ID)
            .map(|offset| KAMINO_IX_OBLIGATION_RESERVES_START + offset)
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
        let borrow_delimiter_index = protocol_accounts[deposit_delimiter_index + 1..]
            .iter()
            .position(|account| account.key == &KAMINO_KLEND_PROGRAM_ID)
            .map(|offset| deposit_delimiter_index + 1 + offset)
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
        let mut refresh_reserve_infos: Vec<AccountInfo> = Vec::new();
        for account in protocol_accounts[KAMINO_IX_OBLIGATION_RESERVES_START
            ..deposit_delimiter_index]
            .iter()
            .chain(protocol_accounts[deposit_delimiter_index + 1..borrow_delimiter_index].iter())
        {
            if account.key != protocol_accounts[KAMINO_IX_RESERVE].key
                && !refresh_reserve_infos
                    .iter()
                    .any(|existing| existing.key == account.key)
            {
                refresh_reserve_infos.push(account.clone());
            }
        }
        refresh_reserve_infos.push(protocol_accounts[KAMINO_IX_RESERVE].clone());
        for (refresh_info, refresh_ix) in refresh_reserve_infos.iter().zip(sequence.iter()) {
            invoke(
                refresh_ix,
                &[
                    refresh_info.clone(),
                    protocol_accounts[KAMINO_IX_LENDING_MARKET].clone(),
                    protocol_program.clone(),
                    protocol_program.clone(),
                    protocol_program.clone(),
                    protocol_accounts[KAMINO_IX_SCOPE_PRICES].clone(),
                ],
            )?;
        }
        let refresh_obligation_index = refresh_reserve_infos.len();
        let mut refresh_obligation_infos = vec![
            protocol_accounts[KAMINO_IX_LENDING_MARKET].clone(),
            protocol_accounts[KAMINO_IX_OBLIGATION].clone(),
        ];
        refresh_obligation_infos.extend_from_slice(
            &protocol_accounts
                [KAMINO_IX_OBLIGATION_RESERVES_START..deposit_delimiter_index],
        );
        refresh_obligation_infos.extend_from_slice(
            &protocol_accounts[deposit_delimiter_index + 1..borrow_delimiter_index],
        );
        refresh_obligation_infos
            .extend_from_slice(&protocol_accounts[borrow_delimiter_index + 1..]);
        invoke(
            &sequence[refresh_obligation_index],
            &refresh_obligation_infos,
        )?;

        // The human owner signed ForwardDeposit and remains a signer in the
        // KLend deposit CPI. No DAY PDA impersonates the obligation owner.
        return invoke(
            &sequence[refresh_obligation_index + 1],
            &protocol_accounts[..KAMINO_V2_ACCOUNT_LEN],
        );
    } else if protocol_ix_data.len() >= 8
        && protocol_ix_data[0..8] == KAMINO_WITHDRAW_V2_DISCRIMINATOR
    {
        let amount = assert_kamino_withdraw_ix_data(protocol_ix_data)?;
        let sequence = build_kamino_withdraw_sequence(
            &keys,
            &is_writable,
            owner,
            protocol_ix_data,
        )?;
        msg!(
            "DAY CPI arm=kamino withdraw program={} accounts={} amount={} owner_signed refresh_reserve+refresh_obligation",
            protocol_program.key,
            protocol_accounts.len(),
            amount
        );
        let deposit_delimiter_index = protocol_accounts
            [KAMINO_IX_OBLIGATION_RESERVES_START..]
            .iter()
            .position(|account| account.key == &KAMINO_KLEND_PROGRAM_ID)
            .map(|offset| KAMINO_IX_OBLIGATION_RESERVES_START + offset)
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
        let borrow_delimiter_index = protocol_accounts[deposit_delimiter_index + 1..]
            .iter()
            .position(|account| account.key == &KAMINO_KLEND_PROGRAM_ID)
            .map(|offset| deposit_delimiter_index + 1 + offset)
            .ok_or_else(|| ProgramError::from(DayError::InvalidAccount))?;
        let mut refresh_infos: Vec<AccountInfo> = Vec::new();
        for account in protocol_accounts[KAMINO_IX_OBLIGATION_RESERVES_START
            ..deposit_delimiter_index]
            .iter()
            .chain(protocol_accounts[deposit_delimiter_index + 1..borrow_delimiter_index].iter())
        {
            if account.key != protocol_accounts[KAMINO_IX_RESERVE].key
                && !refresh_infos.iter().any(|existing| existing.key == account.key)
            {
                refresh_infos.push(account.clone());
            }
        }
        refresh_infos.push(protocol_accounts[KAMINO_IX_RESERVE].clone());
        for (refresh_info, refresh_ix) in refresh_infos.iter().zip(sequence.iter()) {
            invoke(
                refresh_ix,
                &[
                    refresh_info.clone(),
                    protocol_accounts[KAMINO_IX_LENDING_MARKET].clone(),
                    protocol_program.clone(),
                    protocol_program.clone(),
                    protocol_program.clone(),
                    protocol_accounts[KAMINO_IX_SCOPE_PRICES].clone(),
                ],
            )?;
        }
        let obligation_ix_index = refresh_infos.len();
        let mut obligation_infos = vec![
            protocol_accounts[KAMINO_IX_LENDING_MARKET].clone(),
            protocol_accounts[KAMINO_IX_OBLIGATION].clone(),
        ];
        obligation_infos.extend_from_slice(
            &protocol_accounts[KAMINO_IX_OBLIGATION_RESERVES_START..deposit_delimiter_index],
        );
        obligation_infos.extend_from_slice(
            &protocol_accounts[deposit_delimiter_index + 1..borrow_delimiter_index],
        );
        obligation_infos.extend_from_slice(&protocol_accounts[borrow_delimiter_index + 1..]);
        invoke(&sequence[obligation_ix_index], &obligation_infos)?;
        return invoke(
            &sequence[obligation_ix_index + 1],
            &protocol_accounts[..KAMINO_V2_ACCOUNT_LEN],
        );
    } else {
        msg!(
            "DAY CPI arm=kamino unknown disc data_len={} fail-closed",
            protocol_ix_data.len()
        );
        return Err(DayError::InvalidInstruction.into());
    }
}

// ─── DAY-930: Marginfi multi-bank ForwardDeposit CPI arm ───────────────────
// Instruction: LendingAccountDeposit (Anchor global:lending_account_deposit).
// Program MFv2… group 4qp6… USDC bank 2s37… vault 7jai… measured from treasury
// digests 2NeJXxXc… / FAFA1i4G… (status/2026-07-12-marginfi-live.md).
// Multi-bank vault pins: on-chain Bank decode (mint@8 vault@112 group@41)
// validated vs USDC measured vault. Source-pinned only — day_router LIVE GO
// residual until SBF + RegisterAdapterV2 + measured ForwardDeposit RT.
// depositableLive must stay false until that measured bar is pinned.

/// Marginfi v2 mainnet lending program.
pub const MARGINFI_PROGRAM_ID: Pubkey =
    pubkey!("MFv2hWf31Z9kbCa1snEPYctwafyhdvnV7FZnsebVacA");

/// Production marginfi group (mrgn getConfig("production")).
pub const MARGINFI_GROUP: Pubkey =
    pubkey!("4qp6Fx6tnZkY5Wropq9wUYgtFxXKwE6viZxFHg3rdAG8");

/// Anchor disc for `lending_account_deposit`.
/// Source: sha256("global:lending_account_deposit")[:8]
/// + mainnet digest `2NeJXxXc…EuF6x` (amount 50000).
pub const MARGINFI_LENDING_ACCOUNT_DEPOSIT_DISCRIMINATOR: [u8; 8] =
    [0xab, 0x5e, 0xeb, 0x67, 0x52, 0x40, 0xd4, 0x8c];
pub const MARGINFI_ACCOUNT_INITIALIZE_PDA_DISCRIMINATOR: [u8; 8] =
    [87, 177, 91, 80, 218, 119, 245, 31];

/// LendingAccountDeposit account count (group…token_program).
pub const MARGINFI_DEPOSIT_ACCOUNT_LEN: usize = 7;
pub const MARGINFI_FORWARD_DEPOSIT_ACCOUNT_LEN: usize = 10;

pub const MARGINFI_IX_GROUP: usize = 0;
pub const MARGINFI_IX_ACCOUNT: usize = 1;
pub const MARGINFI_IX_AUTHORITY: usize = 2;
pub const MARGINFI_IX_BANK: usize = 3;
pub const MARGINFI_IX_SIGNER_TOKEN: usize = 4;
pub const MARGINFI_IX_LIQUIDITY_VAULT: usize = 5;
pub const MARGINFI_IX_TOKEN_PROGRAM: usize = 6;
pub const MARGINFI_IX_FEE_PAYER: usize = 7;
pub const MARGINFI_IX_INSTRUCTIONS_SYSVAR: usize = 8;
pub const MARGINFI_IX_SYSTEM_PROGRAM: usize = 9;

// ── Multi-bank source pins (production group) ──────────────────────────────
// Host: runtime/adapters/forms/marginfi-day-router-materialize.mjs
// MARGINFI_DAY_ROUTER_BANK_PINS. preparePath verified remains USDC only.

/// USDC bank (measured venue-SDK deposit digests 2NeJXxXc… / FAFA1i4G…).
pub const MARGINFI_USDC_BANK: Pubkey =
    pubkey!("2s37akK2eyBbp8DZgCm7RtsaEz8eJP3Nxd4urLHQv7yB");
pub const MARGINFI_USDC_MINT: Pubkey =
    pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const MARGINFI_USDC_LIQUIDITY_VAULT: Pubkey =
    pubkey!("7jaiZR5Sk8hdYN9MxTpczTcwbWpb5WEoxSANuUwveuat");

pub const MARGINFI_USDT_BANK: Pubkey =
    pubkey!("HmpMfL8942u22htC4EMiWgLX931g3sacXFR6KjuLgKLV");
pub const MARGINFI_USDT_MINT: Pubkey =
    pubkey!("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB");
pub const MARGINFI_USDT_LIQUIDITY_VAULT: Pubkey =
    pubkey!("77t6Fi9qj4s4z22K1toufHtstM8rEy7Y3ytxik7mcsTy");

pub const MARGINFI_SOL_BANK: Pubkey =
    pubkey!("CCKtUs6Cgwo4aaQUmBPmyoApH2gUDErxNZCAntD6LYGh");
pub const MARGINFI_SOL_MINT: Pubkey =
    pubkey!("So11111111111111111111111111111111111111112");
pub const MARGINFI_SOL_LIQUIDITY_VAULT: Pubkey =
    pubkey!("2eicbpitfJXDwqCuFAmPgDP7t2oUotnAzbGzRKLMgSLe");

pub const MARGINFI_MSOL_BANK: Pubkey =
    pubkey!("22DcjMZrMwC5Bpa5AGBsmjc5V9VuQrXG6N9ZtdUNyYGE");
pub const MARGINFI_MSOL_MINT: Pubkey =
    pubkey!("mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So");
pub const MARGINFI_MSOL_LIQUIDITY_VAULT: Pubkey =
    pubkey!("B6HqNn83a2bLqo4i5ygjLHJgD11ePtQksUyx4MjD55DV");

pub const MARGINFI_JITOSOL_BANK: Pubkey =
    pubkey!("Bohoc1ikHLD7xKJuzTyiTyCwzaL5N7ggJQu75A8mKYM8");
pub const MARGINFI_JITOSOL_MINT: Pubkey =
    pubkey!("J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn");
pub const MARGINFI_JITOSOL_LIQUIDITY_VAULT: Pubkey =
    pubkey!("38VGtXd2pDPq9FMh1z6AVjcHCoHgvWyMhdNyamDTeeks");

pub const MARGINFI_JUPSOL_BANK: Pubkey =
    pubkey!("8LaUZadNqtzuCG7iCvZd7d5cbquuYfv19KjAg6GPuuCb");
pub const MARGINFI_JUPSOL_MINT: Pubkey =
    pubkey!("jupSoLaHXQiZZTSfEWMTRRgpnyFm8f6sZdosWBjx93v");
pub const MARGINFI_JUPSOL_LIQUIDITY_VAULT: Pubkey =
    pubkey!("B1zjqKPoYp9bTMhzFADaAvjyGb49FMitLpi6P3Pa3YR6");

pub const MARGINFI_BSOL_BANK: Pubkey =
    pubkey!("6hS9i46WyTq1KXcoa2Chas2Txh9TJAVr6n1t3tnrE23K");
pub const MARGINFI_BSOL_MINT: Pubkey =
    pubkey!("bSo13r4TkiE4KumL71LsHTPpL2euBYLFx6h9HP3piy1");
pub const MARGINFI_BSOL_LIQUIDITY_VAULT: Pubkey =
    pubkey!("2WMipeKDB2CENxbzdmnVrRbsxCA2LY6kCtBe6AAqDP9p");

pub const MARGINFI_PYUSD_BANK: Pubkey =
    pubkey!("8UEiPmgZHXXEDrqLS3oiTxQxTbeYTtPbeMBxAd2XGbpu");
pub const MARGINFI_PYUSD_MINT: Pubkey =
    pubkey!("2b1kV6DkPAnxd5ixfnxCpjxmKwqjjaYmCZfHsFu24GXo");
pub const MARGINFI_PYUSD_LIQUIDITY_VAULT: Pubkey =
    pubkey!("HUmHLAXvcoUgWAtanAnCPNssBnAUzEfSRsb4MZYw7R73");

pub const MARGINFI_CBBTC_BANK: Pubkey =
    pubkey!("Ac4KV5K5isDqtABtg6h5DiwzZMe3Sp9bc3pBiCUvUpaQ");
pub const MARGINFI_CBBTC_MINT: Pubkey =
    pubkey!("cbbtcf3aa214zXHbiAZQwf4122FBYbraNdFqgw4iMij");
pub const MARGINFI_CBBTC_LIQUIDITY_VAULT: Pubkey =
    pubkey!("FvrJsHu7X9jkT9rTuR6Kfs6wSjPvjV6zhH4gVSiJ8LFT");

pub const MARGINFI_USDS_BANK: Pubkey =
    pubkey!("FDsf8sj6SoV313qrA91yms3u5b3P4hBxEPvanVs8LtJV");
pub const MARGINFI_USDS_MINT: Pubkey =
    pubkey!("USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA");
pub const MARGINFI_USDS_LIQUIDITY_VAULT: Pubkey =
    pubkey!("3WozDBEqbWJ7oe8CDd2MEJYAv4ZUaxNTuMesQ6kwTvki");

pub const MARGINFI_USDG_BANK: Pubkey =
    pubkey!("Dj2CwMF3GM7mMT5hcyGXKuYSQ2kQ5zaVCkA1zX1qaTva");
pub const MARGINFI_USDG_MINT: Pubkey =
    pubkey!("2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH");
pub const MARGINFI_USDG_LIQUIDITY_VAULT: Pubkey =
    pubkey!("5Euy1GJaWcF8BcZa2wbvKZq9ZU95anedL9TW416ZJNpK");

/// Source honesty: marginfi LendingAccountDeposit CPI body is implemented
/// (not the AdapterNotWired stub). Live fund-flow GO still requires SBF
/// upgrade, RegisterAdapterV2(marginfi), mainnet ForwardDeposit simulate
/// err=null, exact-owner exit evidence, and operator attestation.
/// **depositableLive must remain false until that measured bar is pinned.**
pub const MARGINFI_CPI_BODY_WIRED: bool = true;

/// Host-testable: true only when the marginfi arm is the real CPI body.
pub fn marginfi_cpi_body_wired() -> bool {
    MARGINFI_CPI_BODY_WIRED
}

/// Host-testable pin check for the marginfi arm (DAY-930).
pub fn assert_marginfi_program_pin(
    protocol_program: &Pubkey,
    protocol_program_executable: bool,
) -> ProgramResult {
    if protocol_program != &MARGINFI_PROGRAM_ID {
        return Err(DayError::ProtocolProgramMismatch.into());
    }
    if !protocol_program_executable {
        return Err(DayError::ProtocolProgramNotExecutable.into());
    }
    Ok(())
}

/// Host-testable deposit ix data: 8-byte disc + LE u64 amount > 0
/// + optional deposit_up_to_limit bool (measured layout is 17 bytes).
pub fn assert_marginfi_deposit_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != 16 && data.len() != 17 {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0..8] != MARGINFI_LENDING_ACCOUNT_DEPOSIT_DISCRIMINATOR {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(
        data[8..16]
            .try_into()
            .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?,
    );
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Bind the outer ForwardDeposit amount to the Marginfi CPI amount.
pub fn assert_marginfi_forward_deposit_amount(
    protocol_ix_data: &[u8],
    expected_amount: u64,
) -> ProgramResult {
    if assert_marginfi_deposit_ix_data(protocol_ix_data)? != expected_amount {
        return Err(DayError::InvalidInstruction.into());
    }
    Ok(())
}

/// Encode deposit ix data (disc + amount + deposit_up_to_limit=false).
pub fn encode_marginfi_deposit_ix_data(amount: u64) -> [u8; 17] {
    let mut out = [0u8; 17];
    out[0..8].copy_from_slice(&MARGINFI_LENDING_ACCOUNT_DEPOSIT_DISCRIMINATOR);
    out[8..16].copy_from_slice(&amount.to_le_bytes());
    out[16] = 0; // deposit_up_to_limit = false (measured)
    out
}

/// Resolve production-group bank vault pin by bank account.
/// Returns (mint, liquidity_vault, token_program). Unlisted banks fail closed.
pub fn marginfi_bank_vault_pins(bank: &Pubkey) -> Option<(Pubkey, Pubkey, Pubkey)> {
    if bank == &MARGINFI_USDC_BANK {
        Some((
            MARGINFI_USDC_MINT,
            MARGINFI_USDC_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_USDT_BANK {
        Some((
            MARGINFI_USDT_MINT,
            MARGINFI_USDT_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_SOL_BANK {
        Some((
            MARGINFI_SOL_MINT,
            MARGINFI_SOL_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_MSOL_BANK {
        Some((
            MARGINFI_MSOL_MINT,
            MARGINFI_MSOL_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_JITOSOL_BANK {
        Some((
            MARGINFI_JITOSOL_MINT,
            MARGINFI_JITOSOL_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_JUPSOL_BANK {
        Some((
            MARGINFI_JUPSOL_MINT,
            MARGINFI_JUPSOL_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_BSOL_BANK {
        Some((
            MARGINFI_BSOL_MINT,
            MARGINFI_BSOL_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_PYUSD_BANK {
        Some((
            MARGINFI_PYUSD_MINT,
            MARGINFI_PYUSD_LIQUIDITY_VAULT,
            TOKEN_2022_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_CBBTC_BANK {
        Some((
            MARGINFI_CBBTC_MINT,
            MARGINFI_CBBTC_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_USDS_BANK {
        Some((
            MARGINFI_USDS_MINT,
            MARGINFI_USDS_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        ))
    } else if bank == &MARGINFI_USDG_BANK {
        Some((
            MARGINFI_USDG_MINT,
            MARGINFI_USDG_LIQUIDITY_VAULT,
            TOKEN_2022_PROGRAM_ID,
        ))
    } else {
        None
    }
}

/// Host-testable market-account pin check for marginfi multi-bank deposit.
///
/// Slot order (measured LendingAccountDeposit):
/// ```text
///  0 group              = MARGINFI_GROUP
///  1 marginfi_account   = non-default (composer-bound)
///  2 authority          = non-default (must be yield_router PDA at build)
///  3 bank               = source-pinned multi-bank set
///  4 signer_token       = non-default (router ATA)
///  5 liquidity_vault    = pin for bank
///  6 token_program      = Token / Token-2022 matching bank mint
/// ```
pub fn assert_marginfi_deposit_accounts(keys: &[Pubkey]) -> ProgramResult {
    if keys.len() != MARGINFI_DEPOSIT_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[MARGINFI_IX_GROUP] != MARGINFI_GROUP {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[MARGINFI_IX_ACCOUNT] == Pubkey::default()
        || keys[MARGINFI_IX_AUTHORITY] == Pubkey::default()
        || keys[MARGINFI_IX_SIGNER_TOKEN] == Pubkey::default()
    {
        return Err(DayError::InvalidAccount.into());
    }
    let Some((_mint, liq_vault, token_program)) =
        marginfi_bank_vault_pins(&keys[MARGINFI_IX_BANK])
    else {
        return Err(DayError::InvalidAccount.into());
    };
    if keys[MARGINFI_IX_LIQUIDITY_VAULT] != liq_vault {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[MARGINFI_IX_TOKEN_PROGRAM] != token_program {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Marginfi initialize_pda seeds, fixed to DAY's canonical index=0/tpid=0.
pub fn marginfi_router_account_pda(router_pda: &Pubkey) -> (Pubkey, u8) {
    let account_index = 0u16.to_le_bytes();
    let third_party_id = 0u16.to_le_bytes();
    Pubkey::find_program_address(
        &[
            b"marginfi_account",
            MARGINFI_GROUP.as_ref(),
            router_pda.as_ref(),
            &account_index,
            &third_party_id,
        ],
        &MARGINFI_PROGRAM_ID,
    )
}

pub fn marginfi_router_source_ata(
    router_pda: &Pubkey,
    mint: &Pubkey,
    token_program: &Pubkey,
) -> Pubkey {
    Pubkey::find_program_address(
        &[router_pda.as_ref(), token_program.as_ref(), mint.as_ref()],
        &ASSOCIATED_TOKEN_PROGRAM_ID,
    )
    .0
}

/// Product binding: reject substituted account/source/payer before any CPI.
pub fn assert_marginfi_forward_deposit_accounts(
    keys: &[Pubkey],
    router_pda: &Pubkey,
    expected_owner: &Pubkey,
) -> ProgramResult {
    if keys.len() != MARGINFI_FORWARD_DEPOSIT_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    assert_marginfi_deposit_accounts(&keys[..MARGINFI_DEPOSIT_ACCOUNT_LEN])?;
    if keys[MARGINFI_IX_AUTHORITY] != *router_pda
        || keys[MARGINFI_IX_FEE_PAYER] != *expected_owner
        || keys[MARGINFI_IX_INSTRUCTIONS_SYSVAR] != solana_program::sysvar::instructions::id()
        || keys[MARGINFI_IX_SYSTEM_PROGRAM] != solana_program::system_program::id()
    {
        return Err(DayError::InvalidAccount.into());
    }
    let (expected_account, _) = marginfi_router_account_pda(router_pda);
    if keys[MARGINFI_IX_ACCOUNT] != expected_account {
        return Err(DayError::InvalidAccount.into());
    }
    let Some((mint, _vault, token_program)) =
        marginfi_bank_vault_pins(&keys[MARGINFI_IX_BANK])
    else {
        return Err(DayError::InvalidAccount.into());
    };
    if keys[MARGINFI_IX_SIGNER_TOKEN]
        != marginfi_router_source_ata(router_pda, &mint, &token_program)
    {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

pub fn encode_marginfi_init_pda_ix_data() -> [u8; 11] {
    let mut out = [0u8; 11];
    out[..8].copy_from_slice(&MARGINFI_ACCOUNT_INITIALIZE_PDA_DISCRIMINATOR);
    out
}

pub fn build_marginfi_init_pda_instruction(
    account_keys: &[Pubkey],
    router_pda: &Pubkey,
    expected_owner: &Pubkey,
) -> Result<Instruction, ProgramError> {
    assert_marginfi_forward_deposit_accounts(account_keys, router_pda, expected_owner)?;
    Ok(Instruction {
        program_id: MARGINFI_PROGRAM_ID,
        accounts: vec![
            AccountMeta::new_readonly(account_keys[MARGINFI_IX_GROUP], false),
            AccountMeta::new(account_keys[MARGINFI_IX_ACCOUNT], false),
            AccountMeta::new_readonly(*router_pda, true),
            AccountMeta::new(account_keys[MARGINFI_IX_FEE_PAYER], true),
            AccountMeta::new_readonly(account_keys[MARGINFI_IX_INSTRUCTIONS_SYSVAR], false),
            AccountMeta::new_readonly(account_keys[MARGINFI_IX_SYSTEM_PROGRAM], false),
        ],
        data: encode_marginfi_init_pda_ix_data().to_vec(),
    })
}

/// Host-testable Instruction builder for marginfi LendingAccountDeposit.
pub fn build_marginfi_deposit_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    router_pda: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_marginfi_deposit_accounts(account_keys)?;
    let _amount = assert_marginfi_deposit_ix_data(protocol_ix_data)?;
    if account_keys.len() != is_writable.len() {
        return Err(DayError::InvalidAccount.into());
    }
    if &account_keys[MARGINFI_IX_AUTHORITY] != router_pda {
        return Err(DayError::InvalidAccount.into());
    }
    let accounts: Vec<AccountMeta> = account_keys
        .iter()
        .zip(is_writable.iter())
        .enumerate()
        .map(|(i, (key, writable))| {
            let is_signer = i == MARGINFI_IX_AUTHORITY;
            if *writable {
                AccountMeta::new(*key, is_signer)
            } else {
                AccountMeta::new_readonly(*key, is_signer)
            }
        })
        .collect();
    Ok(Instruction {
        program_id: MARGINFI_PROGRAM_ID,
        accounts,
        data: protocol_ix_data.to_vec(),
    })
}

/// Canonical writable mask for LendingAccountDeposit (measured mainnet mask).
pub fn marginfi_deposit_default_writables() -> [bool; MARGINFI_DEPOSIT_ACCOUNT_LEN] {
    let mut w = [false; MARGINFI_DEPOSIT_ACCOUNT_LEN];
    // group readonly; account/authority/bank/signer_token/vault writable
    w[MARGINFI_IX_ACCOUNT] = true;
    w[MARGINFI_IX_AUTHORITY] = true;
    w[MARGINFI_IX_BANK] = true;
    w[MARGINFI_IX_SIGNER_TOKEN] = true;
    w[MARGINFI_IX_LIQUIDITY_VAULT] = true;
    w
}

/// Marginfi LendingAccountDeposit CPI (DAY-930). Registry binding already
/// validated by `cpi_protocol_adapter`.
///
/// 1. Assert marginfi program pin
/// 2. Require lending_account_deposit disc + amount > 0
/// 3. Bind production group + multi-bank vault pins — reject invent banks
/// 4. Require authority slot == yield_router PDA; `invoke_signed` with router seeds
///
/// Residual before money-path GO: SBF upgrade, RegisterAdapterV2, mainnet
/// ForwardDeposit simulate, exact-owner RT, depositableLive pin.
fn cpi_adapter_marginfi(
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    router_signer_seeds: &[&[u8]],
    expected_owner: Option<&Pubkey>,
) -> ProgramResult {
    assert_marginfi_program_pin(protocol_program.key, protocol_program.executable)?;

    let keys: Vec<Pubkey> = protocol_accounts.iter().map(|a| *a.key).collect();
    let router_pda = Pubkey::create_program_address(router_signer_seeds, &id())
        .map_err(|_| ProgramError::InvalidSeeds)?;
    let owner = expected_owner.ok_or(DayError::InvalidAccount)?;
    assert_marginfi_forward_deposit_accounts(&keys, &router_pda, owner)?;

    let marginfi_account = protocol_accounts
        .get(MARGINFI_IX_ACCOUNT)
        .ok_or(DayError::InvalidAccount)?;
    if marginfi_account.lamports() == 0 {
        let init_ix = build_marginfi_init_pda_instruction(&keys, &router_pda, owner)?;
        let init_infos = vec![
            protocol_accounts[MARGINFI_IX_GROUP].clone(),
            protocol_accounts[MARGINFI_IX_ACCOUNT].clone(),
            protocol_accounts[MARGINFI_IX_AUTHORITY].clone(),
            protocol_accounts[MARGINFI_IX_FEE_PAYER].clone(),
            protocol_accounts[MARGINFI_IX_INSTRUCTIONS_SYSVAR].clone(),
            protocol_accounts[MARGINFI_IX_SYSTEM_PROGRAM].clone(),
        ];
        invoke_signed(&init_ix, &init_infos, &[router_signer_seeds])?;
    } else if marginfi_account.owner != &MARGINFI_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }

    let amount = assert_marginfi_deposit_ix_data(protocol_ix_data)?;
    let is_writable: Vec<bool> = protocol_accounts.iter().map(|a| a.is_writable).collect();
    let ix = build_marginfi_deposit_instruction(
        &keys[..MARGINFI_DEPOSIT_ACCOUNT_LEN],
        &is_writable[..MARGINFI_DEPOSIT_ACCOUNT_LEN],
        &router_pda,
        protocol_ix_data,
    )?;

    msg!(
        "DAY CPI arm=marginfi deposit program={} accounts={} amount={} invoke_signed",
        protocol_program.key,
        MARGINFI_DEPOSIT_ACCOUNT_LEN,
        amount
    );

    invoke_signed(
        &ix,
        &protocol_accounts[..MARGINFI_DEPOSIT_ACCOUNT_LEN],
        &[router_signer_seeds],
    )
}

// ─── DAY-978/DAY-930: Save (ex-Solend) multi-market multi-reserve CPI arm ───
// Instruction heritage: solend token-lending DepositReserveLiquidity (tag 4) /
// RedeemReserveCollateral (tag 5). Program So1end… (Save rebrand).
// Market/reserve pins: api.save.finance /v1/markets/configs —
//   Main Market `4UpD2fh7…` bSOL anchor + multi-reserve (USDC/USDT/SOL/
//   MSOL/JITOSOL/JUPSOL/CBBTC/JSOL) from frozen SAVE_INVENTORY_RESERVE_PINS;
//   ScarCoin `E2PfMAjU…` STCC + LST `xpP9zdDE…` DAI source-pinned (DAY-930 r5).
// Live GO still requires SBF upgrade + RegisterAdapterV2(save) + measured RT.
// depositableLive must stay false until that measured bar is pinned.

/// Save / Solend mainnet lending program.
/// Matches `SAVE_PROGRAM_ID` / Category-B pin / residual inventory.
pub const SAVE_PROGRAM_ID: Pubkey =
    pubkey!("So1endDq2YkqhipRh3WViPa8hdiSpxWy6z3Z6tMCpAo");

/// Save Main Market (primary lending market).
pub const SAVE_MAIN_MARKET: Pubkey =
    pubkey!("4UpD2fh7xH3VP9QQaXtsS1YY3bxzWhtfpks7FatyKvdY");

/// Main Market authority PDA (program-derived from market; configs authorityAddress).
pub const SAVE_MAIN_MARKET_AUTHORITY: Pubkey =
    pubkey!("DdZR6zRFiUt4S5mg7AV1uKB2z1f1WzcNYCaTEEWPAuby");

/// Main Market bSOL reserve (catalog BSOL cell dayope6fe983cd4).
pub const SAVE_MAIN_MARKET_BSOL_RESERVE: Pubkey =
    pubkey!("3DjAsrew4ZmBwcLjp2wUmjqvSKs4vpJ43ZKxaCjjEdur");

/// bSOL mint (BlazeStake staked SOL).
pub const SAVE_BSOL_MINT: Pubkey =
    pubkey!("bSo13r4TkiE4KumL71LsHTPpL2euBYLFx6h9HP3piy1");

/// Reserve liquidity supply vault for Main Market bSOL.
pub const SAVE_BSOL_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("8STS7KeeoKsA8oBD2TwEEeNrYHQJh9dyKSLFhVUhGk4z");

/// Reserve collateral (cToken / cBSOL) mint for Main Market bSOL.
pub const SAVE_BSOL_COLLATERAL_MINT: Pubkey =
    pubkey!("FZ8KVvJ1QiytR29ykNz6kkhV6tvsB7XdiKW2s14DftFt");

// ── DAY-930: Main Market multi-reserve source pins (Save API configs SSOT) ──
// Host inventory: runtime/adapters/forms/save-materialize.mjs SAVE_INVENTORY_*.
// Source-pinned only — day_router LIVE GO residual until SBF + RegisterAdapterV2
// + measured ForwardDeposit RT (never invent depositableLive).

/// Main Market USDC reserve (inventory dayopa91cedaef6 / LIVE dayop2ef578f579).
pub const SAVE_MAIN_MARKET_USDC_RESERVE: Pubkey =
    pubkey!("BgxfHJDzm44T7XG68MYKx7YisTjZu73tVovyZSjJMpmw");
pub const SAVE_USDC_MINT: Pubkey =
    pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
pub const SAVE_USDC_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("8SheGtsopRUDzdiD6v6BR9a6bqZ9QwywYQY99Fp5meNf");
pub const SAVE_USDC_COLLATERAL_MINT: Pubkey =
    pubkey!("993dVFL2uXWYeoXuEBFXR4BijeXdTv4s6BzsCjJZuwqk");

/// Main Market USDT reserve (inventory dayopa9e4f5cfee / LIVE dayop111507736b).
pub const SAVE_MAIN_MARKET_USDT_RESERVE: Pubkey =
    pubkey!("8K9WC8xoh2rtQNY7iEGXtPvfbDCi563SdWhCAhuMP2xE");
pub const SAVE_USDT_MINT: Pubkey =
    pubkey!("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB");
pub const SAVE_USDT_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("3CdpSW5dxM7RTxBgxeyt8nnnjqoDbZe48tsBs9QUrmuN");
pub const SAVE_USDT_COLLATERAL_MINT: Pubkey =
    pubkey!("BTsbZDV7aCMRJ3VNy9ygV4Q2UeEo9GpR8D6VvmMZzNr8");

/// Main Market SOL (wSOL) reserve (inventory dayop88a5d6f8d3 / LIVE dayope3b1f6238b).
pub const SAVE_MAIN_MARKET_SOL_RESERVE: Pubkey =
    pubkey!("8PbodeaosQP19SjYFx855UMqWxH2HynZLdBXmsrbac36");
pub const SAVE_SOL_MINT: Pubkey =
    pubkey!("So11111111111111111111111111111111111111112");
pub const SAVE_SOL_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("8UviNr47S8eL6J3WfDxMRa3hvLta1VDJwNWqsDgtN3Cv");
pub const SAVE_SOL_COLLATERAL_MINT: Pubkey =
    pubkey!("5h6ssFpeDeRbzsEHDbTQNH7nVGgsKrZydxdSTnLm6QdV");

/// Main Market mSOL reserve (inventory dayopab9c6a5b40 / LIVE dayopd42c4e4095).
pub const SAVE_MAIN_MARKET_MSOL_RESERVE: Pubkey =
    pubkey!("CCpirWrgNuBVLdkP2haxLTbD6XqEgaYuVXixbbpxUB6");
pub const SAVE_MSOL_MINT: Pubkey =
    pubkey!("mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So");
pub const SAVE_MSOL_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("3R5SVe3qABRUYozgeMNVkSotVoa4HhTFFgWgx2G2QMov");
pub const SAVE_MSOL_COLLATERAL_MINT: Pubkey =
    pubkey!("3JFC4cB56Er45nWVe29Bhnn5GnwQzSmHVf6eUq9ac91h");

/// Main Market jitoSOL reserve (inventory dayop6a797e372e / LIVE dayopa17003f2b7).
pub const SAVE_MAIN_MARKET_JITOSOL_RESERVE: Pubkey =
    pubkey!("BRsz1xVQMuVLbc4YjLP1FXhEx1LxSYig2nLqRgJEzR9r");
pub const SAVE_JITOSOL_MINT: Pubkey =
    pubkey!("J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn");
pub const SAVE_JITOSOL_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("2Khz77qDAL4yY1wG6mTLhLnKiN7sDjQCtrFDEEUFPpiB");
pub const SAVE_JITOSOL_COLLATERAL_MINT: Pubkey =
    pubkey!("6mFgUsvXQTEYrYgowc9pVzYi49XEJA5uHA9gVDURc2pM");

/// Main Market jupSOL reserve (inventory dayop5cd6bf037f / LIVE dayop9d287402e6).
pub const SAVE_MAIN_MARKET_JUPSOL_RESERVE: Pubkey =
    pubkey!("Aj3MjwEeAcT5Phan6unxbpKYR8Jx1bNZUoWxA59yg1cF");
pub const SAVE_JUPSOL_MINT: Pubkey =
    pubkey!("jupSoLaHXQiZZTSfEWMTRRgpnyFm8f6sZdosWBjx93v");
pub const SAVE_JUPSOL_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("9AhGbhV7L98mzkMurV8Zcz5WJvvJeRDSQhvH3Wem73QM");
pub const SAVE_JUPSOL_COLLATERAL_MINT: Pubkey =
    pubkey!("Mkfee8Xp3njW8AJMXrdDgbJbtAZRCSPvEyKJhrQ9Kpn");

/// Main Market cbBTC reserve (inventory dayop046277f871 / LIVE dayopd347401b82).
pub const SAVE_MAIN_MARKET_CBBTC_RESERVE: Pubkey =
    pubkey!("Ag7UiqS5kqcsjNFWQfeUAiEXo27auFvdwLVJQwzYCBkZ");
pub const SAVE_CBBTC_MINT: Pubkey =
    pubkey!("cbbtcf3aa214zXHbiAZQwf4122FBYbraNdFqgw4iMij");
pub const SAVE_CBBTC_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("GMzFQtWWUL7z4e2HGBx3Y5LbnH69WuENfH9mqnm6mG5h");
pub const SAVE_CBBTC_COLLATERAL_MINT: Pubkey =
    pubkey!("5unMtvRrfgu8ofLancHyYKWQrqsd7vZqVu8RquGceM6X");

/// Main Market JSOL reserve (inventory dayop9b3f34c0b5).
pub const SAVE_MAIN_MARKET_JSOL_RESERVE: Pubkey =
    pubkey!("2MwiTp5oBwbmUVu7NwnoKE1QLaqtFggQ86xpkvhCFBq7");
pub const SAVE_JSOL_MINT: Pubkey =
    pubkey!("7Q2afV64in6N6SeZsAAB81TJzwDoD6zpqmHkzi9Dcavn");
pub const SAVE_JSOL_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("67cMu9ny7QAkFZ7pFzukTakeJtstDGy883nLhUWN4wH");
pub const SAVE_JSOL_COLLATERAL_MINT: Pubkey =
    pubkey!("EaxVjZ4qFxCeg3mAus5epMSpfsh3pmMuqVUzmUgHuE5p");

// ── DAY-930 r5: non-Main market source pins (Save API configs SSOT) ──────────
// Validated 2026-07-29 vs api.save.finance /v1/markets/configs (inventory match).
// Source-pinned only — day_router LIVE GO residual until SBF + RegisterAdapterV2
// + measured ForwardDeposit RT (never invent depositableLive).

/// ScarCoin market (inventory dayop055f9f1e73 STCC).
pub const SAVE_SCARCOIN_MARKET: Pubkey =
    pubkey!("E2PfMAjUWkTZG81nWY9bm1DRi72uZkfL79RWrRxVWw6s");
pub const SAVE_SCARCOIN_MARKET_AUTHORITY: Pubkey =
    pubkey!("7kjQH2j9Yi98JndysLadyhEqSRA7BYnVHS5PxKqBx4PJ");
pub const SAVE_SCARCOIN_STCC_RESERVE: Pubkey =
    pubkey!("7MpyjrvzpFATwSy981an9ek2jkt3sEdduYRpjffz2BMH");
pub const SAVE_STCC_MINT: Pubkey =
    pubkey!("CstPrRuU13B6QHmNr4J24Qto48HC5uQ2WXZbWiWef4a6");
pub const SAVE_STCC_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("CKQhSpryhPkqDiF13twEoLdLEz1Fb3AgZFhQ7ieD4ZvB");
pub const SAVE_STCC_COLLATERAL_MINT: Pubkey =
    pubkey!("BeVGxmScjAgHzWvKAcApu9hVfghJq5mwnNPMxSZ3SpEz");

/// LST market DAI reserve (inventory dayopab1c351d11).
pub const SAVE_LST_MARKET: Pubkey =
    pubkey!("xpP9zdDE7mVgXM1nc3nQq2gqQE5B5QfF6zFA8sLTinq");
pub const SAVE_LST_MARKET_AUTHORITY: Pubkey =
    pubkey!("E9NmBhEspsEXN9crwTGvjeP9xc3hB45z4tNFEVcLSQNT");
pub const SAVE_LST_DAI_RESERVE: Pubkey =
    pubkey!("J429uoTV1SUQPaRApxUKPsL1Qgx1gB2KAGs5weoCRfVy");
pub const SAVE_DAI_MINT: Pubkey =
    pubkey!("FWhZyxJQas4s52kusCQRwgYRYkUhx9AfQYs3uhtEs9sQ");
pub const SAVE_DAI_LIQUIDITY_SUPPLY: Pubkey =
    pubkey!("E28p65Nf4eaZfpxfknMtBpt963s6pJs7ABwvtBfEanmL");
pub const SAVE_DAI_COLLATERAL_MINT: Pubkey =
    pubkey!("6Kn2G4taFT743kQrKkyonJsPZP5o1TFu2k9mQV1JeBUq");

/// Clock sysvar (DepositReserveLiquidity / RedeemReserveCollateral require it).
pub const SYSVAR_CLOCK_ID: Pubkey =
    pubkey!("SysvarC1ock11111111111111111111111111111111");

/// LendingInstruction::DepositReserveLiquidity tag (solend heritage).
pub const SAVE_DEPOSIT_TAG: u8 = 4;
/// LendingInstruction::RedeemReserveCollateral tag.
pub const SAVE_REDEEM_TAG: u8 = 5;
/// Instruction data: 1-byte tag + u64 amount LE.
pub const SAVE_IX_DATA_LEN: usize = 9;
/// Account count for deposit/redeem (9 metas).
/// Save/Solend sdk 0.14+ dropped the Clock sysvar account (uses Clock::get()).
/// Layout: source, dest, reserve, vault_a, vault_b, market, market_auth,
/// transfer_auth (router PDA), token_program.
pub const SAVE_ACCOUNT_LEN: usize = 9;

// Account indices (shared deposit/redeem layout; slots 3/4 vault order differs).
pub const SAVE_IX_SOURCE: usize = 0;
pub const SAVE_IX_DEST: usize = 1;
pub const SAVE_IX_RESERVE: usize = 2;
pub const SAVE_IX_SLOT_3: usize = 3;
pub const SAVE_IX_SLOT_4: usize = 4;
pub const SAVE_IX_MARKET: usize = 5;
pub const SAVE_IX_MARKET_AUTH: usize = 6;
/// Transfer authority — MUST equal yield_router PDA for invoke_signed.
pub const SAVE_IX_TRANSFER_AUTH: usize = 7;
pub const SAVE_IX_TOKEN_PROGRAM: usize = 8;

/// Source-truth flag: Save arm has a real `invoke_signed` CPI body + market pins.
/// Live money-path GO still needs SBF upgrade, RegisterAdapterV2, mainnet
/// ForwardDeposit/Withdraw simulate, and depositableLive pin (never invent).
pub const SAVE_CPI_BODY_WIRED: bool = true;

/// Host-testable: true only when the save arm is the real CPI body.
pub fn save_cpi_body_wired() -> bool {
    SAVE_CPI_BODY_WIRED
}

/// Host-testable pin check for the save arm (DAY-978).
pub fn assert_save_program_pin(
    protocol_program: &Pubkey,
    protocol_program_executable: bool,
) -> ProgramResult {
    if protocol_program != &SAVE_PROGRAM_ID {
        return Err(DayError::ProtocolProgramMismatch.into());
    }
    if !protocol_program_executable {
        return Err(DayError::ProtocolProgramNotExecutable.into());
    }
    Ok(())
}

/// Encode DepositReserveLiquidity ix data: tag 4 + amount u64 LE.
pub fn encode_save_deposit_ix_data(amount: u64) -> [u8; SAVE_IX_DATA_LEN] {
    let mut out = [0u8; SAVE_IX_DATA_LEN];
    out[0] = SAVE_DEPOSIT_TAG;
    out[1..9].copy_from_slice(&amount.to_le_bytes());
    out
}

/// Encode RedeemReserveCollateral ix data: tag 5 + amount u64 LE.
pub fn encode_save_redeem_ix_data(amount: u64) -> [u8; SAVE_IX_DATA_LEN] {
    let mut out = [0u8; SAVE_IX_DATA_LEN];
    out[0] = SAVE_REDEEM_TAG;
    out[1..9].copy_from_slice(&amount.to_le_bytes());
    out
}

/// Assert deposit ix data: tag 4 + non-zero amount.
pub fn assert_save_deposit_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != SAVE_IX_DATA_LEN {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0] != SAVE_DEPOSIT_TAG {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(data[1..9].try_into().unwrap());
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Assert redeem ix data: tag 5 + non-zero amount.
pub fn assert_save_redeem_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != SAVE_IX_DATA_LEN {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0] != SAVE_REDEEM_TAG {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(data[1..9].try_into().unwrap());
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Resolve Main Market reserve vault pins by reserve account.
/// Returns (liquidity_supply, collateral_mint). Unlisted reserves fail closed.
/// Prefer `save_reserve_market_vault_pins` when market pairing is required.
pub fn save_main_market_reserve_vault_pins(
    reserve: &Pubkey,
) -> Option<(Pubkey, Pubkey)> {
    save_reserve_market_vault_pins(reserve).and_then(|(market, _auth, liq, col)| {
        if market == SAVE_MAIN_MARKET {
            Some((liq, col))
        } else {
            None
        }
    })
}

/// Resolve Save source-pinned reserve → (market, market_authority, liquidity_supply, collateral_mint).
/// Main Market multi-reserve + ScarCoin STCC + LST DAI (DAY-930). Unlisted fail closed.
pub fn save_reserve_market_vault_pins(
    reserve: &Pubkey,
) -> Option<(Pubkey, Pubkey, Pubkey, Pubkey)> {
    if reserve == &SAVE_MAIN_MARKET_BSOL_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_BSOL_LIQUIDITY_SUPPLY,
            SAVE_BSOL_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_USDC_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_USDC_LIQUIDITY_SUPPLY,
            SAVE_USDC_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_USDT_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_USDT_LIQUIDITY_SUPPLY,
            SAVE_USDT_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_SOL_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_SOL_LIQUIDITY_SUPPLY,
            SAVE_SOL_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_MSOL_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_MSOL_LIQUIDITY_SUPPLY,
            SAVE_MSOL_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_JITOSOL_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_JITOSOL_LIQUIDITY_SUPPLY,
            SAVE_JITOSOL_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_JUPSOL_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_JUPSOL_LIQUIDITY_SUPPLY,
            SAVE_JUPSOL_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_CBBTC_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_CBBTC_LIQUIDITY_SUPPLY,
            SAVE_CBBTC_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_MAIN_MARKET_JSOL_RESERVE {
        Some((
            SAVE_MAIN_MARKET,
            SAVE_MAIN_MARKET_AUTHORITY,
            SAVE_JSOL_LIQUIDITY_SUPPLY,
            SAVE_JSOL_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_SCARCOIN_STCC_RESERVE {
        Some((
            SAVE_SCARCOIN_MARKET,
            SAVE_SCARCOIN_MARKET_AUTHORITY,
            SAVE_STCC_LIQUIDITY_SUPPLY,
            SAVE_STCC_COLLATERAL_MINT,
        ))
    } else if reserve == &SAVE_LST_DAI_RESERVE {
        Some((
            SAVE_LST_MARKET,
            SAVE_LST_MARKET_AUTHORITY,
            SAVE_DAI_LIQUIDITY_SUPPLY,
            SAVE_DAI_COLLATERAL_MINT,
        ))
    } else {
        None
    }
}

/// Shared multi-market multi-reserve core pins (market / authority / clock / token).
/// Reserve must resolve via `save_reserve_market_vault_pins`; market+authority pair
/// must match the reserve (cross-market mash fails closed).
fn assert_save_main_market_core(keys: &[Pubkey]) -> Result<(Pubkey, Pubkey), ProgramError> {
    if keys.len() != SAVE_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[SAVE_IX_SOURCE] == Pubkey::default() || keys[SAVE_IX_DEST] == Pubkey::default() {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[SAVE_IX_TRANSFER_AUTH] == Pubkey::default() {
        return Err(DayError::InvalidAccount.into());
    }
    // Clock sysvar no longer required (Save sdk 0.14+ uses Clock::get()).
    if keys[SAVE_IX_TOKEN_PROGRAM] != SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    let Some((market, auth, liq_supply, col_mint)) =
        save_reserve_market_vault_pins(&keys[SAVE_IX_RESERVE])
    else {
        return Err(DayError::InvalidAccount.into());
    };
    if keys[SAVE_IX_MARKET] != market {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[SAVE_IX_MARKET_AUTH] != auth {
        return Err(DayError::InvalidAccount.into());
    }
    Ok((liq_supply, col_mint))
}

/// Deposit account pin: slot3 = liquidity supply, slot4 = collateral mint.
/// Accepts Main Market multi-reserve + ScarCoin/LST non-Main source pins (DAY-930);
/// unlisted fail closed.
pub fn assert_save_deposit_accounts(keys: &[Pubkey]) -> ProgramResult {
    let (liq_supply, col_mint) = assert_save_main_market_core(keys)?;
    if keys[SAVE_IX_SLOT_3] != liq_supply {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[SAVE_IX_SLOT_4] != col_mint {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Redeem account pin: slot3 = collateral mint, slot4 = liquidity supply.
/// Accepts Main Market multi-reserve + ScarCoin/LST non-Main source pins (DAY-930);
/// unlisted fail closed.
pub fn assert_save_redeem_accounts(keys: &[Pubkey]) -> ProgramResult {
    let (liq_supply, col_mint) = assert_save_main_market_core(keys)?;
    if keys[SAVE_IX_SLOT_3] != col_mint {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[SAVE_IX_SLOT_4] != liq_supply {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

fn save_deposit_default_writables() -> [bool; SAVE_ACCOUNT_LEN] {
    let mut w = [false; SAVE_ACCOUNT_LEN];
    w[SAVE_IX_SOURCE] = true;
    w[SAVE_IX_DEST] = true;
    w[SAVE_IX_RESERVE] = true;
    w[SAVE_IX_SLOT_3] = true; // liquidity supply
    w[SAVE_IX_SLOT_4] = true; // collateral mint
    w
}

fn save_redeem_default_writables() -> [bool; SAVE_ACCOUNT_LEN] {
    let mut w = [false; SAVE_ACCOUNT_LEN];
    w[SAVE_IX_SOURCE] = true;
    w[SAVE_IX_DEST] = true;
    w[SAVE_IX_RESERVE] = true;
    w[SAVE_IX_SLOT_3] = true; // collateral mint
    w[SAVE_IX_SLOT_4] = true; // liquidity supply
    w
}

/// Build DepositReserveLiquidity instruction after pin checks.
pub fn build_save_deposit_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    router_pda: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_save_deposit_accounts(account_keys)?;
    let _amount = assert_save_deposit_ix_data(protocol_ix_data)?;
    if account_keys[SAVE_IX_TRANSFER_AUTH] != *router_pda {
        return Err(DayError::InvalidAccount.into());
    }
    if is_writable.len() != SAVE_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    let expected_w = save_deposit_default_writables();
    for i in 0..SAVE_ACCOUNT_LEN {
        if is_writable[i] != expected_w[i] {
            // Soft: require writable where expected; extra writable on RO slots rejected
            if expected_w[i] && !is_writable[i] {
                return Err(DayError::InvalidAccount.into());
            }
        }
    }
    let mut metas = Vec::with_capacity(SAVE_ACCOUNT_LEN);
    for i in 0..SAVE_ACCOUNT_LEN {
        let is_signer = i == SAVE_IX_TRANSFER_AUTH;
        metas.push(if is_writable[i] || expected_w[i] {
            if is_signer {
                AccountMeta::new(account_keys[i], true)
            } else {
                AccountMeta::new(account_keys[i], false)
            }
        } else if is_signer {
            AccountMeta::new_readonly(account_keys[i], true)
        } else {
            AccountMeta::new_readonly(account_keys[i], false)
        });
    }
    // Force transfer authority as signer meta regardless of writable table.
    metas[SAVE_IX_TRANSFER_AUTH] = AccountMeta::new_readonly(*router_pda, true);
    Ok(Instruction {
        program_id: SAVE_PROGRAM_ID,
        accounts: metas,
        data: protocol_ix_data.to_vec(),
    })
}

/// Build RedeemReserveCollateral instruction after pin checks.
pub fn build_save_redeem_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    router_pda: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_save_redeem_accounts(account_keys)?;
    let _amount = assert_save_redeem_ix_data(protocol_ix_data)?;
    if account_keys[SAVE_IX_TRANSFER_AUTH] != *router_pda {
        return Err(DayError::InvalidAccount.into());
    }
    if is_writable.len() != SAVE_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    let expected_w = save_redeem_default_writables();
    for i in 0..SAVE_ACCOUNT_LEN {
        if expected_w[i] && !is_writable[i] {
            return Err(DayError::InvalidAccount.into());
        }
    }
    let mut metas = Vec::with_capacity(SAVE_ACCOUNT_LEN);
    for i in 0..SAVE_ACCOUNT_LEN {
        let is_signer = i == SAVE_IX_TRANSFER_AUTH;
        metas.push(if is_writable[i] || expected_w[i] {
            if is_signer {
                AccountMeta::new(account_keys[i], true)
            } else {
                AccountMeta::new(account_keys[i], false)
            }
        } else if is_signer {
            AccountMeta::new_readonly(account_keys[i], true)
        } else {
            AccountMeta::new_readonly(account_keys[i], false)
        });
    }
    metas[SAVE_IX_TRANSFER_AUTH] = AccountMeta::new_readonly(*router_pda, true);
    Ok(Instruction {
        program_id: SAVE_PROGRAM_ID,
        accounts: metas,
        data: protocol_ix_data.to_vec(),
    })
}

/// Save (Solend) deposit/redeem CPI (DAY-978/DAY-930). Registry binding already
/// validated by `cpi_protocol_adapter`.
///
/// 1. Assert Save program pin
/// 2. Branch on tag (deposit 4 vs redeem 5) — unknown tag fails closed
/// 3. Bind multi-market multi-reserve metas (Main + ScarCoin STCC + LST DAI) —
///    reject caller-arbitrary markets / cross-market mash
/// 4. Require transfer-authority slot == yield_router PDA; `invoke_signed`
///
/// Residual before money-path GO: SBF upgrade, RegisterAdapterV2, mainnet
/// ForwardDeposit/Withdraw simulate, exact-owner RT, depositableLive pin.
fn cpi_adapter_save(
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    router_signer_seeds: &[&[u8]],
) -> ProgramResult {
    assert_save_program_pin(protocol_program.key, protocol_program.executable)?;

    let keys: Vec<Pubkey> = protocol_accounts.iter().map(|a| *a.key).collect();
    let router_pda = Pubkey::create_program_address(router_signer_seeds, &id())
        .map_err(|_| ProgramError::InvalidSeeds)?;
    if protocol_accounts
        .get(SAVE_IX_TRANSFER_AUTH)
        .map(|a| a.key != &router_pda)
        .unwrap_or(true)
    {
        msg!(
            "DAY CPI save transfer authority must be yield_router PDA {} (got {:?})",
            router_pda,
            protocol_accounts
                .get(SAVE_IX_TRANSFER_AUTH)
                .map(|a| a.key)
        );
        return Err(DayError::InvalidAccount.into());
    }

    let is_writable: Vec<bool> = protocol_accounts.iter().map(|a| a.is_writable).collect();

    let (ix, amount, arm) = if !protocol_ix_data.is_empty()
        && protocol_ix_data[0] == SAVE_DEPOSIT_TAG
    {
        let amount = assert_save_deposit_ix_data(protocol_ix_data)?;
        let ix = build_save_deposit_instruction(
            &keys,
            &is_writable,
            &router_pda,
            protocol_ix_data,
        )?;
        (ix, amount, "deposit")
    } else if !protocol_ix_data.is_empty() && protocol_ix_data[0] == SAVE_REDEEM_TAG {
        let amount = assert_save_redeem_ix_data(protocol_ix_data)?;
        let ix = build_save_redeem_instruction(
            &keys,
            &is_writable,
            &router_pda,
            protocol_ix_data,
        )?;
        (ix, amount, "redeem")
    } else {
        msg!(
            "DAY CPI arm=save unknown tag data_len={} fail-closed",
            protocol_ix_data.len()
        );
        return Err(DayError::InvalidInstruction.into());
    };

    msg!(
        "DAY CPI arm=save {} program={} accounts={} amount={} invoke_signed",
        arm,
        protocol_program.key,
        protocol_accounts.len(),
        amount
    );

    invoke_signed(&ix, protocol_accounts, &[router_signer_seeds])
}

/// DAY-930 first-path pin: Jupiter Lend Earn mainnet program.
/// Must match `SOLANA_DAY_FORWARDER_CHAIN_FACTS.path.protocolProgramId` and
/// `runtime/config/jupiter-lend-programs.mjs` (`earnMainnet`). RegistryV2 must
/// bind adapter id `jupiter-lend` to this exact executable before any invoke.
pub const JUPITER_LEND_EARN_PROGRAM_ID: Pubkey =
    pubkey!("jup3YeL8QhtSx1e253b2FDvsMNC87fDrgQZivbrndc9");

/// Jupiter Lend Liquidity program (inner CPI target of Earn Deposit).
/// Matches `JUPITER_LEND_PROGRAM_IDS.liquidityMainnet`.
pub const JUPITER_LEND_LIQUIDITY_PROGRAM_ID: Pubkey =
    pubkey!("jupeiUmn818Jg1ekPURTpr4mFo29p46vygyykFJ3wZC");

/// Mainnet USDC mint (DAY-909 jupiter-lend USDC market pin).
pub const JUPITER_LEND_USDC_MINT: Pubkey =
    pubkey!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");

/// jlUSDC fToken mint (DAY-909 receipt + market pin).
pub const JUPITER_LEND_JLUSDC_MINT: Pubkey =
    pubkey!("9BEcn9aPEmhSPbPQeFGjidRiEKki46fVQDyPpSQXPA2D");

/// Associated Token Account program.
pub const ASSOCIATED_TOKEN_PROGRAM_ID: Pubkey =
    pubkey!("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");

/// Anchor discriminator for Earn `Deposit` (hex `f223c68952e1f2b6`).
/// Source: landed mainnet digest `42h9HKEu…7cMM` + `JUPITER_LEND_INSTRUCTION_DISCRIMINATORS.deposit`.
pub const JUPITER_LEND_DEPOSIT_DISCRIMINATOR: [u8; 8] =
    [0xf2, 0x23, 0xc6, 0x89, 0x52, 0xe1, 0xf2, 0xb6];

/// Earn Deposit account count (signer + 13 context + token/ATA/system).
/// Layout from Jupiter Earn CPI docs + mainnet deposit `42h9HKEu…7cMM`.
pub const JUPITER_LEND_DEPOSIT_ACCOUNT_LEN: usize = 17;

// Account indices for Earn Deposit (DAY-909 USDC binding).
pub const JUP_LEND_IX_SIGNER: usize = 0;
pub const JUP_LEND_IX_DEPOSITOR_TOKEN: usize = 1;
pub const JUP_LEND_IX_RECIPIENT_TOKEN: usize = 2;
pub const JUP_LEND_IX_MINT: usize = 3;
pub const JUP_LEND_IX_LENDING_ADMIN: usize = 4;
pub const JUP_LEND_IX_LENDING: usize = 5;
pub const JUP_LEND_IX_FTOKEN_MINT: usize = 6;
pub const JUP_LEND_IX_SUPPLY_RESERVES: usize = 7;
pub const JUP_LEND_IX_SUPPLY_POSITION: usize = 8;
pub const JUP_LEND_IX_RATE_MODEL: usize = 9;
pub const JUP_LEND_IX_VAULT: usize = 10;
pub const JUP_LEND_IX_LIQUIDITY: usize = 11;
pub const JUP_LEND_IX_LIQUIDITY_PROGRAM: usize = 12;
pub const JUP_LEND_IX_REWARDS_RATE_MODEL: usize = 13;
pub const JUP_LEND_IX_TOKEN_PROGRAM: usize = 14;
pub const JUP_LEND_IX_ATA_PROGRAM: usize = 15;
pub const JUP_LEND_IX_SYSTEM_PROGRAM: usize = 16;

/// USDC Earn market PDAs — pinned from mainnet deposit evidence (DAY-909).
/// These are protocol-global for the jlUSDC pool; user ATAs are not pinned.
pub const JUPITER_LEND_USDC_LENDING_ADMIN: Pubkey =
    pubkey!("5nmGjA4s7ATzpBQXC5RNceRpaJ7pYw2wKsNBWyuSAZV6");
pub const JUPITER_LEND_USDC_LENDING: Pubkey =
    pubkey!("2vVYHYM8VYnvZqQWpTJSj8o8DBf1wM8pVs3bsTgYZiqJ");
pub const JUPITER_LEND_USDC_SUPPLY_RESERVES: Pubkey =
    pubkey!("94vK29npVbyRHXH63rRcTiSr26SFhrQTzbpNJuhQEDu");
pub const JUPITER_LEND_USDC_SUPPLY_POSITION: Pubkey =
    pubkey!("Hf9gtkM4dpVBahVSzEXSVCAPpKzBsBcns3s8As3z77oF");
pub const JUPITER_LEND_USDC_RATE_MODEL: Pubkey =
    pubkey!("5pjzT5dFTsXcwixoab1QDLvZQvpYJxJeBphkyfHGn688");
pub const JUPITER_LEND_USDC_VAULT: Pubkey =
    pubkey!("BmkUoKMFYBxNSzWXyUjyMJjMAaVz4d8ZnxwwmhDCUXFB");
pub const JUPITER_LEND_USDC_LIQUIDITY: Pubkey =
    pubkey!("7s1da8DduuBFqGra5bJBjpnvL5E9mGzCuMk1Qkh4or2Z");
pub const JUPITER_LEND_USDC_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("5xSPBiD3TibamAnwHDhZABdB4z4F9dcj5PnbteroBTTd");

// ── DAY-930 multi-mint source pins (venue-SDK measured digests; day_router LIVE
// GO remains USDC-only until SBF upgrade + measured ForwardDeposit RT).
// Evidence: USDT deposit eixnW2nr… / withdraw 3zGi6nSq…; WSOL deposit 25Uv53um… /
// withdraw 5QyGzuNA…; EURC 3Pj2i7y7… / 5CdH7CkM…; USDG hu8axVJX… / 5SDuBTAv…;
// USDS EZdnpF65… / 5kUs9FGM…; JUPUSD 476R8grr… / kXJBpyeq… (prodApiRoundTripAttested).

/// Mainnet USDT mint.
pub const JUPITER_LEND_USDT_MINT: Pubkey =
    pubkey!("Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB");
/// jlUSDT fToken mint.
pub const JUPITER_LEND_JLUSDT_MINT: Pubkey =
    pubkey!("Cmn4v2wipYV41dkakDvCgFJpxhtaaKt11NyWV8pjSE8A");
/// Mainnet WSOL mint.
pub const JUPITER_LEND_WSOL_MINT: Pubkey =
    pubkey!("So11111111111111111111111111111111111111112");
/// jlWSOL fToken mint.
pub const JUPITER_LEND_JLWSOL_MINT: Pubkey =
    pubkey!("2uQsyo1fXXQkDtcpXnLofWy88PxcvnfH2L8FPSE62FVU");
/// Mainnet EURC mint.
pub const JUPITER_LEND_EURC_MINT: Pubkey =
    pubkey!("HzwqbKZw8HxMN6bF2yFZNrht3c2iXXzpKcFu7uBEDKtr");
/// jlEURC fToken mint.
pub const JUPITER_LEND_JLEURC_MINT: Pubkey =
    pubkey!("GcV9tEj62VncGithz4o4N9x6HWXARxuRgEAYk9zahNA8");
/// Mainnet USDG mint (Token-2022 underlying).
pub const JUPITER_LEND_USDG_MINT: Pubkey =
    pubkey!("2u1tszSeqZ3qBWF3uNGPFc8TzMk2tdiwknnRMWGWjGWH");
/// jlUSDG fToken mint.
pub const JUPITER_LEND_JLUSDG_MINT: Pubkey =
    pubkey!("9fvHrYNw1A8Evpcj7X2yy4k4fT7nNHcA9L6UsamNHAif");
/// Mainnet USDS mint.
pub const JUPITER_LEND_USDS_MINT: Pubkey =
    pubkey!("USDSwr9ApdHk5bvJKMjzff41FfuX8bSxdKcR81vTwcA");
/// jlUSDS fToken mint.
pub const JUPITER_LEND_JLUSDS_MINT: Pubkey =
    pubkey!("j14XLJZSVMcUYpAfajdZRpnfHUpJieZHS4aPektLWvh");
/// Mainnet JUPUSD mint.
pub const JUPITER_LEND_JUPUSD_MINT: Pubkey =
    pubkey!("JuprjznTrTSp2UFa3ZBUFgwdAmtZCq4MQCwysN55USD");
/// jlJUPUSD fToken mint.
pub const JUPITER_LEND_JLJUPUSD_MINT: Pubkey =
    pubkey!("7GxATsNMnaC88vdwd2t3mwrFuQwwGvmYPrUQ4D6FotXk");

/// Token-2022 program — measured USDG Earn deposit uses Tokenz (not Tokenkeg).
pub const TOKEN_2022_PROGRAM_ID: Pubkey =
    pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");

/// Shared lendingAdmin across Earn markets (measured).
pub const JUPITER_LEND_LENDING_ADMIN: Pubkey =
    pubkey!("5nmGjA4s7ATzpBQXC5RNceRpaJ7pYw2wKsNBWyuSAZV6");
/// Shared liquidity account across Earn markets (measured).
pub const JUPITER_LEND_LIQUIDITY: Pubkey =
    pubkey!("7s1da8DduuBFqGra5bJBjpnvL5E9mGzCuMk1Qkh4or2Z");

// USDT Earn market PDAs — measured mainnet deposit eixnW2nr…aq1dQJC.
pub const JUPITER_LEND_USDT_LENDING: Pubkey =
    pubkey!("F7tLdeF2YZZex9MR8HgGggyFiz7UU2UgUube2tmfwNPE");
pub const JUPITER_LEND_USDT_SUPPLY_RESERVES: Pubkey =
    pubkey!("Enao27EWUV2fv3rUqwknJ1eRaM5aAeN5ijeCrM9tayRX");
pub const JUPITER_LEND_USDT_SUPPLY_POSITION: Pubkey =
    pubkey!("HVPCmWZ1TN4jUpmewkALAsHSFGLJ1YnYcfVjVai3Pcix");
pub const JUPITER_LEND_USDT_RATE_MODEL: Pubkey =
    pubkey!("6sAbVeSvEfjQGRAGg9W4PAfhB5qNhYiGdx6Fh9uVEsEC");
pub const JUPITER_LEND_USDT_VAULT: Pubkey =
    pubkey!("4HTRHjdgy4VSVRcsumuzVFCgWywNhjGsD5oG3kqAt5vo");
pub const JUPITER_LEND_USDT_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("AU7sGinWFZkurwrEdQ9Q8qMtgU6W3GNKfCeCnGQKcBeQ");
/// USDT Earn withdraw-only claim — measured 3zGi6nSq…RCBCA3U.
pub const JUPITER_LEND_USDT_WITHDRAW_CLAIM: Pubkey =
    pubkey!("CGgS9fo5ZCFm6weVBotQ7M9qVKuhLrVZnqXH7tee1SZ5");

// WSOL Earn market PDAs — measured mainnet deposit 25Uv53um…uCGX2kk.
pub const JUPITER_LEND_WSOL_LENDING: Pubkey =
    pubkey!("BeAqbxfrcXmzEYT2Ra62oW2MqkuFDHaCtps47Mzg6Zj3");
pub const JUPITER_LEND_WSOL_SUPPLY_RESERVES: Pubkey =
    pubkey!("4Y66HtUEqbbbpZdENGtFdVhUMS3tnagffn3M4do59Nfy");
pub const JUPITER_LEND_WSOL_SUPPLY_POSITION: Pubkey =
    pubkey!("4SkEYxmiRgQ4VYyvh9VB4k39M49BpqazyzDUFDzJhXQm");
pub const JUPITER_LEND_WSOL_RATE_MODEL: Pubkey =
    pubkey!("Acvyi9HBGmqh3Exe1N4PjBVyY8fokq2AdC6fSLqV6KSo");
pub const JUPITER_LEND_WSOL_VAULT: Pubkey =
    pubkey!("5JP5zgYCb9W37QQLgAHRHuinFLrKt87akDY1CgZoTPzr");
pub const JUPITER_LEND_WSOL_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("CkeQGDRsgMZcCaU8cZEdC2aFAohia4jLzL36RaLcUDsR");
/// WSOL Earn withdraw-only claim — measured 5QyGzuNA…m33xgRV.
pub const JUPITER_LEND_WSOL_WITHDRAW_CLAIM: Pubkey =
    pubkey!("6AQGR8zK4KTVZfZ9UZaRzyEL5ynvwVaF5ywVdmtJT24N");

// EURC Earn market PDAs — measured mainnet deposit 3Pj2i7y7…tuVqTSy.
pub const JUPITER_LEND_EURC_LENDING: Pubkey =
    pubkey!("3vejrc7HzHszWjn5YpntjiQEtJNB4Yd1Fff2cs9Hh7JZ");
pub const JUPITER_LEND_EURC_SUPPLY_RESERVES: Pubkey =
    pubkey!("FGFqvYQis8sg8xEkPWcNxc4hsrMz6UAHSW4rWK3CSZGr");
pub const JUPITER_LEND_EURC_SUPPLY_POSITION: Pubkey =
    pubkey!("EMCFG8nFXas42F26CR6KryWBTGvv2Tb1WjAhU6ASpWnt");
pub const JUPITER_LEND_EURC_RATE_MODEL: Pubkey =
    pubkey!("EWsCESwa63ReamtFEYQfaN1RPVgRNMypupmepNJsv866");
pub const JUPITER_LEND_EURC_VAULT: Pubkey =
    pubkey!("3SUQLu18sWYHyCb4jXGGCQiQqEoE2LxeCyPYybYRFrpa");
pub const JUPITER_LEND_EURC_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("FpSMmwXtSconpPeaCfx5TB6aB6cjLkodMqV7s8d7PCZN");
/// EURC Earn withdraw-only claim — measured 5CdH7CkM…L5kFwgbi.
pub const JUPITER_LEND_EURC_WITHDRAW_CLAIM: Pubkey =
    pubkey!("GfKC1DZyeeJEXS8veajyC1P7xtyKhECnWpBs2jqjKgaf");

// USDG Earn market PDAs — measured mainnet deposit hu8axVJX…ypQcySy (Token-2022).
pub const JUPITER_LEND_USDG_LENDING: Pubkey =
    pubkey!("xRVWEc2J4o5BPxEaiZ6jKyvcNmFovrVuYhuowp9hPM4");
pub const JUPITER_LEND_USDG_SUPPLY_RESERVES: Pubkey =
    pubkey!("G4KAenCBfybnZLtVe4LdNrmEtQoW3x93oTowFJUPSvx6");
pub const JUPITER_LEND_USDG_SUPPLY_POSITION: Pubkey =
    pubkey!("FQgZ6p5sV1HUMs1Aq8eXxR5jC6ak7ZayjU1Ke2yjkGwg");
pub const JUPITER_LEND_USDG_RATE_MODEL: Pubkey =
    pubkey!("6iHHKAK9Mqjn57CVmWe4szAPyTH8s8pniXSj6vWaKW5r");
pub const JUPITER_LEND_USDG_VAULT: Pubkey =
    pubkey!("E1prFSvCtp5ze1hAegjdtN3kQWVoRuSGWLoc8Vj9h4nm");
pub const JUPITER_LEND_USDG_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("ChnL2VdEsQkZYbHNMmrdYpmhHtDzTLiG1ca2Vtsap9Vs");
/// USDG Earn withdraw-only claim — measured 5SDuBTAv…YS7DwVib.
pub const JUPITER_LEND_USDG_WITHDRAW_CLAIM: Pubkey =
    pubkey!("AfbHM89oHKXCbHKRZ2G31kgBRuADGyAso7rsyzcqdzDY");

// USDS Earn market PDAs — measured mainnet deposit EZdnpF65…u2gNCUE.
pub const JUPITER_LEND_USDS_LENDING: Pubkey =
    pubkey!("Ey9UTFK5KDMZJuHqndU8kYrSrWHQb5uQqNEaTk57Toc");
pub const JUPITER_LEND_USDS_SUPPLY_RESERVES: Pubkey =
    pubkey!("BWC9tYzhfDGL9iozaKnxCxACoHLWvyruKddL5ZkGQNrz");
pub const JUPITER_LEND_USDS_SUPPLY_POSITION: Pubkey =
    pubkey!("29maDH9uBqt7TVKCtLrK8DxgDE9wTTmwFPL6atL9TFEz");
pub const JUPITER_LEND_USDS_RATE_MODEL: Pubkey =
    pubkey!("TTVqDjkSxXBzCF3khfYwvpfv7SkTM41uG4EYtLm3NRS");
pub const JUPITER_LEND_USDS_VAULT: Pubkey =
    pubkey!("Fk7zHKR5evWj1bQnHS6QH3J9FdQMRn22pDhNNWoz23Cj");
pub const JUPITER_LEND_USDS_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("6Sa1GFTmVfPf6F7VFh5b9Zd9a3bwuUVWrNL3PPxLcAYh");
/// USDS Earn withdraw-only claim — measured 5kUs9FGM…J1DSdqu.
pub const JUPITER_LEND_USDS_WITHDRAW_CLAIM: Pubkey =
    pubkey!("HNCbgw4YJwQmkjxCbQJXJpCfPxWAyk8SrsYH9AMeM52Q");

// JUPUSD Earn market PDAs — measured mainnet deposit 476R8grr…TRyUo7s3.
pub const JUPITER_LEND_JUPUSD_LENDING: Pubkey =
    pubkey!("papYEgeG5uPE4niUWZhihUUzVVotJn1mAWbYo2UBSHi");
pub const JUPITER_LEND_JUPUSD_SUPPLY_RESERVES: Pubkey =
    pubkey!("2tQE8jVR5ezDw3PDa21BNzfyQ14Ug5cTf6n3swJNjkod");
pub const JUPITER_LEND_JUPUSD_SUPPLY_POSITION: Pubkey =
    pubkey!("DXFoJruECdEch2KpzLQ2cSpxoBSsyg4bpYPnHYofsbD4");
pub const JUPITER_LEND_JUPUSD_RATE_MODEL: Pubkey =
    pubkey!("2hT44GA9r5PiqsbbmqN5CuF7ymtquoEdokRncAs9CVej");
pub const JUPITER_LEND_JUPUSD_VAULT: Pubkey =
    pubkey!("9kGqd5zsQGaFfFPdUuEgbRM4V7x72Jdt7WTS4uRouAQ7");
pub const JUPITER_LEND_JUPUSD_REWARDS_RATE_MODEL: Pubkey =
    pubkey!("E3U32h49TL9Qof3NeLja9qJxTrGYpY1o1NQPtrSLJjcc");
/// JUPUSD Earn withdraw-only claim — measured kXJBpyeq…pte3MP1.
pub const JUPITER_LEND_JUPUSD_WITHDRAW_CLAIM: Pubkey =
    pubkey!("6q9vTzAsTMEPUCwuhEdJSJdpRNXnubwKZbi2go1B8nvg");

/// Source honesty flag: jupiter-lend deposit CPI body is implemented (not the
/// AdapterNotWired stub). Live fund-flow GO still requires SBF upgrade,
/// InitRegistryV2 + RegisterAdapterV2, mainnet ForwardDeposit simulate, and
/// operator attestation — see status/DAY-930-solana-day-forwarder.md.
pub const JUPITER_LEND_CPI_BODY_WIRED: bool = true;

/// Host-testable: true only when the jupiter-lend arm is the real CPI body.
pub fn jupiter_lend_cpi_body_wired() -> bool {
    JUPITER_LEND_CPI_BODY_WIRED
}

/// Host-testable pin check for the jupiter-lend arm (DAY-930).
/// Returns Ok only when the supplied program is the audited Earn mainnet id
/// AND is marked executable.
pub fn assert_jupiter_lend_program_pin(
    protocol_program: &Pubkey,
    protocol_program_executable: bool,
) -> ProgramResult {
    if protocol_program != &JUPITER_LEND_EARN_PROGRAM_ID {
        // Distinct from AdapterNotWired so logs/tests show pin mismatch vs unwired body.
        return Err(DayError::ProtocolProgramMismatch.into());
    }
    if !protocol_program_executable {
        return Err(DayError::ProtocolProgramNotExecutable.into());
    }
    Ok(())
}

/// Host-testable Earn Deposit ix data: 8-byte disc + little-endian u64 amount > 0.
pub fn assert_jupiter_lend_deposit_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != 16 {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0..8] != JUPITER_LEND_DEPOSIT_DISCRIMINATOR {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(
        data[8..16]
            .try_into()
            .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?,
    );
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Encode Earn Deposit ix data (disc + amount). Host/composer helper.
pub fn encode_jupiter_lend_deposit_ix_data(amount: u64) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&JUPITER_LEND_DEPOSIT_DISCRIMINATOR);
    out[8..16].copy_from_slice(&amount.to_le_bytes());
    out
}

/// Host-testable market-account pin check for jupiter-lend USDC Earn Deposit.
///
/// Account order matches Jupiter Earn CPI context + landed mainnet deposit:
/// ```text
///  0 signer (must be DAY yield_router PDA for invoke_signed)
///  1 depositorTokenAccount   (caller-owned / router ATA — not pin-checked)
///  2 recipientTokenAccount   (jlUSDC ATA — not pin-checked)
///  3 mint                    = USDC
///  4 lendingAdmin            = pin
///  5 lending                 = pin
///  6 fTokenMint              = jlUSDC
///  7 supplyTokenReserves     = pin
///  8 lendingSupplyPosition   = pin
///  9 rateModel               = pin
/// 10 vault                   = pin
/// 11 liquidity               = pin
/// 12 liquidityProgram        = jupei…
/// 13 rewardsRateModel        = pin
/// 14 tokenProgram            = Tokenkeg…
/// 15 associatedTokenProgram  = AToken…
/// 16 systemProgram           = 11111…
/// ```
/// Fails closed on wrong count or any pinned market key mismatch. Does not
/// authorize a CPI by itself — `cpi_adapter_jupiter_lend` still needs registry
/// + program pin + router PDA signer + invoke_signed.
/// Resolve a source-pinned Earn deposit market by underlying mint.
/// USDC / USDT / WSOL / EURC / USDG / USDS / JUPUSD — unlisted mints fail closed.
pub fn jupiter_lend_deposit_market_pins(
    mint: &Pubkey,
) -> Option<(Pubkey, Pubkey, Pubkey, Pubkey, Pubkey, Pubkey, Pubkey)> {
    // (fToken, lending, supplyReserves, supplyPosition, rateModel, vault, rewardsRateModel)
    if mint == &JUPITER_LEND_USDC_MINT {
        Some((
            JUPITER_LEND_JLUSDC_MINT,
            JUPITER_LEND_USDC_LENDING,
            JUPITER_LEND_USDC_SUPPLY_RESERVES,
            JUPITER_LEND_USDC_SUPPLY_POSITION,
            JUPITER_LEND_USDC_RATE_MODEL,
            JUPITER_LEND_USDC_VAULT,
            JUPITER_LEND_USDC_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_USDT_MINT {
        Some((
            JUPITER_LEND_JLUSDT_MINT,
            JUPITER_LEND_USDT_LENDING,
            JUPITER_LEND_USDT_SUPPLY_RESERVES,
            JUPITER_LEND_USDT_SUPPLY_POSITION,
            JUPITER_LEND_USDT_RATE_MODEL,
            JUPITER_LEND_USDT_VAULT,
            JUPITER_LEND_USDT_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_WSOL_MINT {
        Some((
            JUPITER_LEND_JLWSOL_MINT,
            JUPITER_LEND_WSOL_LENDING,
            JUPITER_LEND_WSOL_SUPPLY_RESERVES,
            JUPITER_LEND_WSOL_SUPPLY_POSITION,
            JUPITER_LEND_WSOL_RATE_MODEL,
            JUPITER_LEND_WSOL_VAULT,
            JUPITER_LEND_WSOL_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_EURC_MINT {
        Some((
            JUPITER_LEND_JLEURC_MINT,
            JUPITER_LEND_EURC_LENDING,
            JUPITER_LEND_EURC_SUPPLY_RESERVES,
            JUPITER_LEND_EURC_SUPPLY_POSITION,
            JUPITER_LEND_EURC_RATE_MODEL,
            JUPITER_LEND_EURC_VAULT,
            JUPITER_LEND_EURC_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_USDG_MINT {
        Some((
            JUPITER_LEND_JLUSDG_MINT,
            JUPITER_LEND_USDG_LENDING,
            JUPITER_LEND_USDG_SUPPLY_RESERVES,
            JUPITER_LEND_USDG_SUPPLY_POSITION,
            JUPITER_LEND_USDG_RATE_MODEL,
            JUPITER_LEND_USDG_VAULT,
            JUPITER_LEND_USDG_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_USDS_MINT {
        Some((
            JUPITER_LEND_JLUSDS_MINT,
            JUPITER_LEND_USDS_LENDING,
            JUPITER_LEND_USDS_SUPPLY_RESERVES,
            JUPITER_LEND_USDS_SUPPLY_POSITION,
            JUPITER_LEND_USDS_RATE_MODEL,
            JUPITER_LEND_USDS_VAULT,
            JUPITER_LEND_USDS_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_JUPUSD_MINT {
        Some((
            JUPITER_LEND_JLJUPUSD_MINT,
            JUPITER_LEND_JUPUSD_LENDING,
            JUPITER_LEND_JUPUSD_SUPPLY_RESERVES,
            JUPITER_LEND_JUPUSD_SUPPLY_POSITION,
            JUPITER_LEND_JUPUSD_RATE_MODEL,
            JUPITER_LEND_JUPUSD_VAULT,
            JUPITER_LEND_JUPUSD_REWARDS_RATE_MODEL,
        ))
    } else {
        None
    }
}

/// Token program pin for a source-pinned Earn market mint.
/// USDG measured digests use Token-2022; all other pinned markets use classic SPL.
pub fn jupiter_lend_token_program_for_mint(mint: &Pubkey) -> Option<Pubkey> {
    if mint == &JUPITER_LEND_USDG_MINT {
        Some(TOKEN_2022_PROGRAM_ID)
    } else if jupiter_lend_deposit_market_pins(mint).is_some() {
        Some(SPL_TOKEN_PROGRAM_ID)
    } else {
        None
    }
}

/// Host-testable market-account pin check for jupiter-lend Earn Deposit.
/// Accepts source-pinned USDC / USDT / WSOL / EURC / USDG / USDS / JUPUSD markets
/// (DAY-930 multi-mint). Unmeasured mints fail closed — never silent USDC rebind.
pub fn assert_jupiter_lend_deposit_accounts(keys: &[Pubkey]) -> ProgramResult {
    if keys.len() != JUPITER_LEND_DEPOSIT_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    // User-specific slots (0–2) are non-default only — exact keys bound at CPI time.
    if keys[JUP_LEND_IX_SIGNER] == Pubkey::default()
        || keys[JUP_LEND_IX_DEPOSITOR_TOKEN] == Pubkey::default()
        || keys[JUP_LEND_IX_RECIPIENT_TOKEN] == Pubkey::default()
    {
        return Err(DayError::InvalidAccount.into());
    }
    let mint = keys[JUP_LEND_IX_MINT];
    let Some((
        ftoken,
        lending,
        supply_reserves,
        supply_position,
        rate_model,
        vault,
        rewards,
    )) = jupiter_lend_deposit_market_pins(&mint)
    else {
        return Err(DayError::InvalidAccount.into());
    };
    let Some(token_program) = jupiter_lend_token_program_for_mint(&mint) else {
        return Err(DayError::InvalidAccount.into());
    };
    // lendingAdmin + liquidity are shared across Earn markets.
    if keys[JUP_LEND_IX_LENDING_ADMIN] != JUPITER_LEND_USDC_LENDING_ADMIN {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LENDING] != lending {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_FTOKEN_MINT] != ftoken {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_SUPPLY_RESERVES] != supply_reserves {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_SUPPLY_POSITION] != supply_position {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_RATE_MODEL] != rate_model {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_VAULT] != vault {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LIQUIDITY] != JUPITER_LEND_USDC_LIQUIDITY {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] != JUPITER_LEND_LIQUIDITY_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_REWARDS_RATE_MODEL] != rewards {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_TOKEN_PROGRAM] != token_program {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_ATA_PROGRAM] != ASSOCIATED_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_SYSTEM_PROGRAM] != system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Host-testable Instruction builder for jupiter-lend Earn Deposit.
///
/// Requires `account_keys[0] == router_pda` (DAY yield_router PDA is the CPI
/// signer). Writable flags come from the composer; index 0 is forced signer.
pub fn build_jupiter_lend_deposit_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    router_pda: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_jupiter_lend_deposit_accounts(account_keys)?;
    let _amount = assert_jupiter_lend_deposit_ix_data(protocol_ix_data)?;
    if account_keys.len() != is_writable.len() {
        return Err(DayError::InvalidAccount.into());
    }
    if &account_keys[JUP_LEND_IX_SIGNER] != router_pda {
        return Err(DayError::InvalidAccount.into());
    }
    let accounts: Vec<AccountMeta> = account_keys
        .iter()
        .zip(is_writable.iter())
        .enumerate()
        .map(|(i, (key, writable))| {
            let is_signer = i == JUP_LEND_IX_SIGNER;
            if *writable {
                AccountMeta::new(*key, is_signer)
            } else {
                AccountMeta::new_readonly(*key, is_signer)
            }
        })
        .collect();
    Ok(Instruction {
        program_id: JUPITER_LEND_EARN_PROGRAM_ID,
        accounts,
        data: protocol_ix_data.to_vec(),
    })
}

/// Canonical writable mask for Earn Deposit (from mainnet deposit evidence).
/// Signer + token accounts + vault-side positions are writable; programs/mints
/// that are not mutated are readonly.
pub fn jupiter_lend_deposit_default_writables() -> [bool; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN] {
    let mut w = [false; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN];
    w[JUP_LEND_IX_SIGNER] = true;
    w[JUP_LEND_IX_DEPOSITOR_TOKEN] = true;
    w[JUP_LEND_IX_RECIPIENT_TOKEN] = true;
    w[JUP_LEND_IX_LENDING_ADMIN] = true;
    w[JUP_LEND_IX_LENDING] = true;
    w[JUP_LEND_IX_FTOKEN_MINT] = true;
    w[JUP_LEND_IX_SUPPLY_RESERVES] = true;
    w[JUP_LEND_IX_SUPPLY_POSITION] = true;
    w[JUP_LEND_IX_VAULT] = true;
    w[JUP_LEND_IX_LIQUIDITY] = true;
    w
}

// ─── DAY-962/980: Jupiter Lend Earn WITHDRAW CPI arm ────────────────────────
// Evidence: measured mainnet product-API withdraw `45HDPE…7cMM` (USDC Earn).
// disc `b712469c946da122` + u64 amount (== JUPITER_LEND_INSTRUCTION_DISCRIMINATORS
// .withdraw in runtime/config/jupiter-lend-programs.mjs). 18 accounts (deposit=17):
// vs deposit, slots 1/2 reverse role (source=jlUSDC ATA, recipient=USDC ATA) and a
// USDC-market-specific CLAIM account is inserted at index 11 (owned by the Jupiter
// Liquidity program; USDT market uses a different one — never share across markets).
// This arm unwires nothing until an SBF upgrade lands; source-honest + fail-closed.

/// Anchor disc for Earn `Withdraw` (hex `b712469c946da122`).
pub const JUPITER_LEND_WITHDRAW_DISCRIMINATOR: [u8; 8] =
    [0xb7, 0x12, 0x46, 0x9c, 0x94, 0x6d, 0xa1, 0x22];

/// Earn Withdraw account count (measured `45HDPE…`).
pub const JUPITER_LEND_WITHDRAW_ACCOUNT_LEN: usize = 18;

// Account indices for Earn Withdraw (DAY-962 USDC binding). Order verified against
// the measured mainnet withdraw; NOT a re-index of the deposit layout.
pub const JUP_LEND_WD_SIGNER: usize = 0;
pub const JUP_LEND_WD_SOURCE_FTOKEN: usize = 1; // owner jlUSDC ATA (burned from)
pub const JUP_LEND_WD_RECIPIENT_TOKEN: usize = 2; // owner USDC ATA (redeemed to)
pub const JUP_LEND_WD_LENDING_ADMIN: usize = 3;
pub const JUP_LEND_WD_LENDING: usize = 4;
pub const JUP_LEND_WD_MINT: usize = 5;
pub const JUP_LEND_WD_FTOKEN_MINT: usize = 6;
pub const JUP_LEND_WD_SUPPLY_RESERVES: usize = 7;
pub const JUP_LEND_WD_SUPPLY_POSITION: usize = 8;
pub const JUP_LEND_WD_RATE_MODEL: usize = 9;
pub const JUP_LEND_WD_VAULT: usize = 10;
pub const JUP_LEND_WD_CLAIM: usize = 11; // USDC-market withdraw claim account (jupei-owned)
pub const JUP_LEND_WD_LIQUIDITY: usize = 12;
pub const JUP_LEND_WD_LIQUIDITY_PROGRAM: usize = 13;
pub const JUP_LEND_WD_REWARDS_RATE_MODEL: usize = 14;
pub const JUP_LEND_WD_TOKEN_PROGRAM: usize = 15;
pub const JUP_LEND_WD_ATA_PROGRAM: usize = 16;
pub const JUP_LEND_WD_SYSTEM_PROGRAM: usize = 17;

/// USDC Earn withdraw-only market pin (claim account) — measured `45HDPE…`.
/// Per-market: the USDT market's claim account differs; never substitute.
pub const JUPITER_LEND_USDC_WITHDRAW_CLAIM: Pubkey =
    pubkey!("HN1r4VfkDn53xQQfeGDYrNuDKFdemAhZsHYRwBrFhsW");

/// Host-testable Earn Withdraw ix data: 8-byte disc + little-endian u64 amount > 0.
pub fn assert_jupiter_lend_withdraw_ix_data(data: &[u8]) -> Result<u64, ProgramError> {
    if data.len() != 16 {
        return Err(DayError::InvalidInstruction.into());
    }
    if data[0..8] != JUPITER_LEND_WITHDRAW_DISCRIMINATOR {
        return Err(DayError::InvalidInstruction.into());
    }
    let amount = u64::from_le_bytes(
        data[8..16]
            .try_into()
            .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?,
    );
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    Ok(amount)
}

/// Encode Earn Withdraw ix data (disc + amount). Host/composer helper.
pub fn encode_jupiter_lend_withdraw_ix_data(amount: u64) -> [u8; 16] {
    let mut out = [0u8; 16];
    out[0..8].copy_from_slice(&JUPITER_LEND_WITHDRAW_DISCRIMINATOR);
    out[8..16].copy_from_slice(&amount.to_le_bytes());
    out
}

/// Host-testable market-account pin check for jupiter-lend USDC Earn Withdraw.
///
/// Fails closed on wrong count or any pinned market key mismatch. User slots
/// (0–2) are non-default only (exact keys bound at CPI time). Does not authorize
/// a CPI by itself — `cpi_adapter_jupiter_lend` still needs registry + program
/// pin + router PDA signer + invoke_signed.
/// Resolve a source-pinned Earn withdraw market by underlying mint.
/// Returns (fToken, lending, supplyReserves, supplyPosition, rateModel, vault, claim, rewards).
pub fn jupiter_lend_withdraw_market_pins(
    mint: &Pubkey,
) -> Option<(Pubkey, Pubkey, Pubkey, Pubkey, Pubkey, Pubkey, Pubkey, Pubkey)> {
    if mint == &JUPITER_LEND_USDC_MINT {
        Some((
            JUPITER_LEND_JLUSDC_MINT,
            JUPITER_LEND_USDC_LENDING,
            JUPITER_LEND_USDC_SUPPLY_RESERVES,
            JUPITER_LEND_USDC_SUPPLY_POSITION,
            JUPITER_LEND_USDC_RATE_MODEL,
            JUPITER_LEND_USDC_VAULT,
            JUPITER_LEND_USDC_WITHDRAW_CLAIM,
            JUPITER_LEND_USDC_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_USDT_MINT {
        Some((
            JUPITER_LEND_JLUSDT_MINT,
            JUPITER_LEND_USDT_LENDING,
            JUPITER_LEND_USDT_SUPPLY_RESERVES,
            JUPITER_LEND_USDT_SUPPLY_POSITION,
            JUPITER_LEND_USDT_RATE_MODEL,
            JUPITER_LEND_USDT_VAULT,
            JUPITER_LEND_USDT_WITHDRAW_CLAIM,
            JUPITER_LEND_USDT_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_WSOL_MINT {
        Some((
            JUPITER_LEND_JLWSOL_MINT,
            JUPITER_LEND_WSOL_LENDING,
            JUPITER_LEND_WSOL_SUPPLY_RESERVES,
            JUPITER_LEND_WSOL_SUPPLY_POSITION,
            JUPITER_LEND_WSOL_RATE_MODEL,
            JUPITER_LEND_WSOL_VAULT,
            JUPITER_LEND_WSOL_WITHDRAW_CLAIM,
            JUPITER_LEND_WSOL_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_EURC_MINT {
        Some((
            JUPITER_LEND_JLEURC_MINT,
            JUPITER_LEND_EURC_LENDING,
            JUPITER_LEND_EURC_SUPPLY_RESERVES,
            JUPITER_LEND_EURC_SUPPLY_POSITION,
            JUPITER_LEND_EURC_RATE_MODEL,
            JUPITER_LEND_EURC_VAULT,
            JUPITER_LEND_EURC_WITHDRAW_CLAIM,
            JUPITER_LEND_EURC_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_USDG_MINT {
        Some((
            JUPITER_LEND_JLUSDG_MINT,
            JUPITER_LEND_USDG_LENDING,
            JUPITER_LEND_USDG_SUPPLY_RESERVES,
            JUPITER_LEND_USDG_SUPPLY_POSITION,
            JUPITER_LEND_USDG_RATE_MODEL,
            JUPITER_LEND_USDG_VAULT,
            JUPITER_LEND_USDG_WITHDRAW_CLAIM,
            JUPITER_LEND_USDG_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_USDS_MINT {
        Some((
            JUPITER_LEND_JLUSDS_MINT,
            JUPITER_LEND_USDS_LENDING,
            JUPITER_LEND_USDS_SUPPLY_RESERVES,
            JUPITER_LEND_USDS_SUPPLY_POSITION,
            JUPITER_LEND_USDS_RATE_MODEL,
            JUPITER_LEND_USDS_VAULT,
            JUPITER_LEND_USDS_WITHDRAW_CLAIM,
            JUPITER_LEND_USDS_REWARDS_RATE_MODEL,
        ))
    } else if mint == &JUPITER_LEND_JUPUSD_MINT {
        Some((
            JUPITER_LEND_JLJUPUSD_MINT,
            JUPITER_LEND_JUPUSD_LENDING,
            JUPITER_LEND_JUPUSD_SUPPLY_RESERVES,
            JUPITER_LEND_JUPUSD_SUPPLY_POSITION,
            JUPITER_LEND_JUPUSD_RATE_MODEL,
            JUPITER_LEND_JUPUSD_VAULT,
            JUPITER_LEND_JUPUSD_WITHDRAW_CLAIM,
            JUPITER_LEND_JUPUSD_REWARDS_RATE_MODEL,
        ))
    } else {
        None
    }
}

/// Host-testable market-account pin check for jupiter-lend Earn Withdraw.
/// Accepts source-pinned USDC / USDT / WSOL / EURC / USDG / USDS / JUPUSD markets.
/// Claim accounts are per-market — never share across markets.
pub fn assert_jupiter_lend_withdraw_accounts(keys: &[Pubkey]) -> ProgramResult {
    if keys.len() != JUPITER_LEND_WITHDRAW_ACCOUNT_LEN {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_SIGNER] == Pubkey::default()
        || keys[JUP_LEND_WD_SOURCE_FTOKEN] == Pubkey::default()
        || keys[JUP_LEND_WD_RECIPIENT_TOKEN] == Pubkey::default()
    {
        return Err(DayError::InvalidAccount.into());
    }
    let mint = keys[JUP_LEND_WD_MINT];
    let Some((
        ftoken,
        lending,
        supply_reserves,
        supply_position,
        rate_model,
        vault,
        claim,
        rewards,
    )) = jupiter_lend_withdraw_market_pins(&mint)
    else {
        return Err(DayError::InvalidAccount.into());
    };
    let Some(token_program) = jupiter_lend_token_program_for_mint(&mint) else {
        return Err(DayError::InvalidAccount.into());
    };
    if keys[JUP_LEND_WD_LENDING_ADMIN] != JUPITER_LEND_USDC_LENDING_ADMIN {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_LENDING] != lending {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_FTOKEN_MINT] != ftoken {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_SUPPLY_RESERVES] != supply_reserves {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_SUPPLY_POSITION] != supply_position {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_RATE_MODEL] != rate_model {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_VAULT] != vault {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_CLAIM] != claim {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_LIQUIDITY] != JUPITER_LEND_USDC_LIQUIDITY {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_LIQUIDITY_PROGRAM] != JUPITER_LEND_LIQUIDITY_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_REWARDS_RATE_MODEL] != rewards {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_TOKEN_PROGRAM] != token_program {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_ATA_PROGRAM] != ASSOCIATED_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_WD_SYSTEM_PROGRAM] != system_program::ID {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(())
}

/// Host-testable Instruction builder for jupiter-lend Earn Withdraw.
/// Requires `account_keys[0] == router_pda` (router PDA is the CPI signer).
pub fn build_jupiter_lend_withdraw_instruction(
    account_keys: &[Pubkey],
    is_writable: &[bool],
    router_pda: &Pubkey,
    protocol_ix_data: &[u8],
) -> Result<Instruction, ProgramError> {
    assert_jupiter_lend_withdraw_accounts(account_keys)?;
    let _amount = assert_jupiter_lend_withdraw_ix_data(protocol_ix_data)?;
    if account_keys.len() != is_writable.len() {
        return Err(DayError::InvalidAccount.into());
    }
    if &account_keys[JUP_LEND_WD_SIGNER] != router_pda {
        return Err(DayError::InvalidAccount.into());
    }
    let accounts: Vec<AccountMeta> = account_keys
        .iter()
        .zip(is_writable.iter())
        .enumerate()
        .map(|(i, (key, writable))| {
            let is_signer = i == JUP_LEND_WD_SIGNER;
            if *writable {
                AccountMeta::new(*key, is_signer)
            } else {
                AccountMeta::new_readonly(*key, is_signer)
            }
        })
        .collect();
    Ok(Instruction {
        program_id: JUPITER_LEND_EARN_PROGRAM_ID,
        accounts,
        data: protocol_ix_data.to_vec(),
    })
}

/// Canonical writable mask for Earn Withdraw (from mainnet withdraw evidence
/// `45HDPE…`). LENDING_ADMIN is readonly on withdraw (writable on deposit).
pub fn jupiter_lend_withdraw_default_writables() -> [bool; JUPITER_LEND_WITHDRAW_ACCOUNT_LEN] {
    let mut w = [false; JUPITER_LEND_WITHDRAW_ACCOUNT_LEN];
    w[JUP_LEND_WD_SIGNER] = true;
    w[JUP_LEND_WD_SOURCE_FTOKEN] = true;
    w[JUP_LEND_WD_RECIPIENT_TOKEN] = true;
    w[JUP_LEND_WD_LENDING] = true;
    w[JUP_LEND_WD_FTOKEN_MINT] = true;
    w[JUP_LEND_WD_SUPPLY_RESERVES] = true;
    w[JUP_LEND_WD_SUPPLY_POSITION] = true;
    w[JUP_LEND_WD_VAULT] = true;
    w[JUP_LEND_WD_CLAIM] = true;
    w[JUP_LEND_WD_LIQUIDITY] = true;
    w
}

/// Jupiter Lend Earn CPI (DAY-915 deposit / DAY-962 withdraw). Registry binding
/// already validated by `cpi_protocol_adapter`. Dispatches on the leading Anchor
/// discriminator (deposit vs withdraw); any other disc fails closed. Each arm
/// pins the exact USDC market metas (deposit / withdraw layouts differ) and
/// requires the yield_router PDA as the CPI signer.
///
/// 1. Assert Earn program pin
/// 2. Classify deposit vs withdraw by discriminator (unknown → InvalidInstruction)
/// 3. Bind exact source-pinned market metas (USDC/USDT/WSOL) — reject unpinned
/// 4. Require signer slot == yield_router PDA; `invoke_signed` with router seeds
///
/// Residual before money-path GO: SBF upgrade of deployed `7P7PgkV1…`, on-chain
/// InitRegistryV2 + RegisterAdapterV2, mainnet Forward{Deposit,Withdraw} simulate.
fn cpi_adapter_jupiter_lend(
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    router_signer_seeds: &[&[u8]],
) -> ProgramResult {
    assert_jupiter_lend_program_pin(protocol_program.key, protocol_program.executable)?;

    let keys: Vec<Pubkey> = protocol_accounts.iter().map(|a| *a.key).collect();
    let is_writable: Vec<bool> = protocol_accounts.iter().map(|a| a.is_writable).collect();

    let router_pda = Pubkey::create_program_address(router_signer_seeds, &id())
        .map_err(|_| ProgramError::InvalidSeeds)?;

    let is_deposit = protocol_ix_data.len() >= 8
        && protocol_ix_data[0..8] == JUPITER_LEND_DEPOSIT_DISCRIMINATOR;
    let is_withdraw = protocol_ix_data.len() >= 8
        && protocol_ix_data[0..8] == JUPITER_LEND_WITHDRAW_DISCRIMINATOR;

    // Signer slot is index 0 for both layouts.
    if protocol_accounts
        .first()
        .map(|a| a.key != &router_pda)
        .unwrap_or(true)
    {
        msg!(
            "DAY CPI jupiter-lend signer must be yield_router PDA {} (got {:?})",
            router_pda,
            protocol_accounts.first().map(|a| a.key)
        );
        return Err(DayError::InvalidAccount.into());
    }

    let (ix, amount, arm) = if is_deposit {
        assert_jupiter_lend_deposit_accounts(&keys)?;
        let amount = assert_jupiter_lend_deposit_ix_data(protocol_ix_data)?;
        let ix = build_jupiter_lend_deposit_instruction(
            &keys,
            &is_writable,
            &router_pda,
            protocol_ix_data,
        )?;
        (ix, amount, "deposit")
    } else if is_withdraw {
        assert_jupiter_lend_withdraw_accounts(&keys)?;
        let amount = assert_jupiter_lend_withdraw_ix_data(protocol_ix_data)?;
        let ix = build_jupiter_lend_withdraw_instruction(
            &keys,
            &is_writable,
            &router_pda,
            protocol_ix_data,
        )?;
        (ix, amount, "withdraw")
    } else {
        msg!(
            "DAY CPI arm=jupiter-lend unknown disc data_len={} fail-closed",
            protocol_ix_data.len()
        );
        return Err(DayError::InvalidInstruction.into());
    };

    msg!(
        "DAY CPI arm=jupiter-lend {} program={} accounts={} amount={} invoke_signed",
        arm,
        protocol_program.key,
        protocol_accounts.len(),
        amount
    );

    // Router PDA signs the Earn CPI (DAY money path, not venue-SDK owner path).
    invoke_signed(&ix, protocol_accounts, &[router_signer_seeds])
}

/// DAY-795 forward DEPOSIT: no profit fee on deposit (fee is realized-profit at
/// withdraw). Router forwards principal into the protocol via CPI adapter.
fn process_forward_deposit(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    amount_micros: u64,
    protocol_ix_data: Vec<u8>,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let owner = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;
    let protocol_program = next_account_info(acc_iter)?;

    if !owner.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if amount_micros == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    let reg = load_registry_v2(registry_ai, program_id)?;
    let router = load_router(router_ai, program_id)?;
    if router.paused {
        return Err(DayError::Paused.into());
    }
    validate_protocol_program(
        &reg,
        &adapter_id,
        protocol_program.key,
        protocol_program.executable,
    )?;

    // Remaining accounts are the protocol adapter's accounts.
    let protocol_accounts: Vec<AccountInfo> = acc_iter.cloned().collect();
    let (_router_pda, router_bump) = Pubkey::find_program_address(&[ROUTER_SEED], program_id);
    let seeds: &[&[u8]] = &[ROUTER_SEED, &[router_bump]];

    if classify_adapter_dispatch(&adapter_id) == AdapterDispatchArm::Marginfi {
        assert_marginfi_forward_deposit_amount(&protocol_ix_data, amount_micros)?;
    }

    // Deposit charges no fee; forward the full principal to the protocol.
    // DAY-915: registry-gated dispatch (re-validates + per-adapter fail-closed arms).
    cpi_protocol_adapter(
        &reg,
        &adapter_id,
        protocol_program,
        &protocol_accounts,
        &protocol_ix_data,
        seeds,
        Some(owner.key),
    )?;

    msg!(
        "DAY ForwardDeposit owner={} adapter={:?} amount={} fee=0",
        owner.key,
        &adapter_id,
        amount_micros
    );
    Ok(())
}

/// DAY-795 forward WITHDRAW: router CPIs the protocol withdraw so funds return
/// through the router, then skims the profit fee (0 while placeholder disabled)
/// to treasury and forwards the remainder to the owner. Fee is on realized
/// profit only — computed via `RouterFeeConfig::quote_profit_fee` (separate PDA).
/// Never principal.
#[allow(clippy::too_many_arguments)]

/// PROTOCOL_AUTHORITY-only recovery of tokens sitting on yield_router ATAs.
/// Used when product ForwardDeposit parked receipt on the shared router and
/// ForwardWithdraw is correctly fail-closed (no owner binding). Not a user path.
#[inline(never)]
fn process_authority_recover_router_token(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    amount_micros: u64,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;
    let router_token = next_account_info(acc_iter)?;
    let dest_token = next_account_info(acc_iter)?;
    let token_program = next_account_info(acc_iter)?;

    if !authority.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if authority.key != &PROTOCOL_AUTHORITY {
        return Err(DayError::NotAuthority.into());
    }
    if token_program.key != &SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    let _router = load_router(router_ai, program_id)?;
    assert_spl_token_owner(router_token, router_ai.key)?;
    assert_spl_token_owner(dest_token, &PROTOCOL_AUTHORITY)?;
    let mint_r = spl_token_mint(router_token)?;
    let mint_d = spl_token_mint(dest_token)?;
    if mint_r != mint_d {
        return Err(DayError::InvalidAccount.into());
    }

    let bal = spl_token_amount(router_token)?;
    let amount = if amount_micros == 0 { bal } else { amount_micros };
    if amount == 0 {
        return Err(DayError::ZeroAmount.into());
    }
    if amount > bal {
        return Err(DayError::InvalidBalanceDelta.into());
    }

    let (_router_pda, router_bump) = Pubkey::find_program_address(&[ROUTER_SEED], program_id);
    let seeds: &[&[u8]] = &[ROUTER_SEED, &[router_bump]];

    invoke_signed(
        &spl_transfer_ix(
            router_token.key,
            dest_token.key,
            router_ai.key,
            amount,
        ),
        &[
            router_token.clone(),
            dest_token.clone(),
            router_ai.clone(),
            token_program.clone(),
        ],
        &[seeds],
    )?;

    msg!(
        "DAY AuthorityRecoverRouterToken authority={} mint={} amount={}",
        authority.key,
        mint_r,
        amount
    );
    Ok(())
}

fn process_forward_withdraw(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    amount_micros: u64,
    realized_profit_usd_micros: u64,
    protocol_ix_data: Vec<u8>,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let owner = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;
    // DAY-763: fee config lives in a SEPARATE PDA (inserted right after router).
    let fee_config_ai = next_account_info(acc_iter)?;
    let protocol_program = next_account_info(acc_iter)?;
    let router_token = next_account_info(acc_iter)?;
    let treasury_token = next_account_info(acc_iter)?;
    let owner_token = next_account_info(acc_iter)?;
    let token_program = next_account_info(acc_iter)?;

    if !owner.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    // Router-receipt adapters remain closed without a DAY position record.
    // Kamino is different: ForwardDeposit binds KLend's native obligation to
    // this exact signer, and KLend enforces obligation.has_one(owner) again on
    // withdraw. That venue-native owner root is the immutable position binding.
    assert_forward_withdraw_owner_binding(&adapter_id)?;
    if token_program.key != &SPL_TOKEN_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    let reg = load_registry_v2(registry_ai, program_id)?;
    let router = load_router(router_ai, program_id)?;
    let fee_config = load_fee_config(fee_config_ai, program_id)?;
    if router.paused {
        return Err(DayError::Paused.into());
    }
    validate_protocol_program(
        &reg,
        &adapter_id,
        protocol_program.key,
        protocol_program.executable,
    )?;

    // Codex #3: the fee treasury must NOT be caller-redirectable. The
    // treasury_token account's SPL owner must be the CONFIGURED fee treasury
    // (fee_config.treasury). Otherwise a withdrawer could pass their own token
    // account as `treasury_token` and skim the fee to themselves.
    assert_spl_token_owner(treasury_token, &fee_config.treasury)?;
    // The owner payout account must belong to the signing owner (no redirect).
    assert_spl_token_owner(owner_token, owner.key)?;
    // The router's working token account must be owned by the router PDA.
    assert_spl_token_owner(router_token, router_ai.key)?;
    validate_payout_token_mints(
        &spl_token_mint(router_token)?,
        &spl_token_mint(treasury_token)?,
        &spl_token_mint(owner_token)?,
    )?;

    assert_legacy_withdraw_claims_quarantined(
        amount_micros,
        fee_config.profit_fee_enabled,
        realized_profit_usd_micros,
    )?;

    let protocol_accounts: Vec<AccountInfo> = acc_iter.cloned().collect();
    if classify_adapter_dispatch(&adapter_id) == AdapterDispatchArm::Kamino {
        if protocol_accounts.len() < KAMINO_DEPOSIT_ACCOUNT_LEN
            || protocol_accounts[KAMINO_IX_OWNER].key != owner.key
            || protocol_accounts[KAMINO_IX_USER_LIQUIDITY].key != owner_token.key
        {
            return Err(DayError::InvalidAccount.into());
        }
        // KLend requires the withdraw destination token authority to equal the
        // obligation owner. Measure the exact positive delta in that owner ATA;
        // never route it through shared DAY custody merely to reuse the generic
        // receipt-token payout path.
        let owner_before = spl_token_amount(owner_token)?;
        let no_router_seeds: &[&[u8]] = &[];
        cpi_protocol_adapter(
            &reg,
            &adapter_id,
            protocol_program,
            &protocol_accounts,
            &protocol_ix_data,
            no_router_seeds,
            Some(owner.key),
        )?;
        let owner_amount = measured_withdraw_delta(owner_before, spl_token_amount(owner_token)?)?;
        msg!(
            "DAY ForwardWithdraw owner={} adapter=kamino requested={} measured={} fee=0 direct_owner=true",
            owner.key,
            amount_micros,
            owner_amount
        );
        return Ok(());
    }
    let (_router_pda, router_bump) = Pubkey::find_program_address(&[ROUTER_SEED], program_id);
    let seeds: &[&[u8]] = &[ROUTER_SEED, &[router_bump]];

    // 1) Pull funds out of the protocol INTO the router token account (CPI).
    // Snapshot first: pre-existing stray balance belongs to nobody in this call.
    // DAY-915: registry-gated dispatch (re-validates + per-adapter fail-closed arms).
    let balance_before = spl_token_amount(router_token)?;
    cpi_protocol_adapter(
        &reg,
        &adapter_id,
        protocol_program,
        &protocol_accounts,
        &protocol_ix_data,
        seeds,
        Some(owner.key),
    )?;
    let balance_after_pull = spl_token_amount(router_token)?;
    let owner_amount = measured_withdraw_delta(balance_before, balance_after_pull)?;

    // 2) The legacy profit fee is quarantined at zero (DAY-825/826). Transfer
    // only the measured token-unit delta, never caller amount or USD micros.
    invoke_signed(
        &spl_transfer_ix(
            router_token.key,
            owner_token.key,
            router_ai.key,
            owner_amount,
        ),
        &[
            router_token.clone(),
            owner_token.clone(),
            router_ai.clone(),
            token_program.clone(),
        ],
        &[seeds],
    )?;
    if spl_token_amount(router_token)? != balance_before {
        return Err(DayError::InvalidBalanceDelta.into());
    }

    msg!(
        "DAY ForwardWithdraw owner={} adapter={:?} requested={} measured={} fee=0 to_owner={}",
        owner.key,
        &adapter_id,
        amount_micros,
        owner_amount,
        owner_amount
    );
    Ok(())
}

/// Router-receipt adapters have no immutable position account carrying the
/// depositor/receipt binding. This gate prevents treating a payout ATA as
/// authority. Kamino is the narrow exception: KLend's obligation is natively
/// owner-scoped and its withdraw CPI enforces both `obligation.owner` and the
/// owner-controlled destination ATA.
///
/// When a position-record-backed withdraw path is implemented, replace this
/// gate with verification of the stored owner, adapter, receipt, and immutable
/// destination; do not merely remove it.
pub fn assert_forward_withdraw_owner_binding(
    adapter_id: &[u8; ADAPTER_ID_LEN],
) -> ProgramResult {
    if classify_adapter_dispatch(adapter_id) == AdapterDispatchArm::Kamino {
        Ok(())
    } else {
        Err(DayError::ForwardWithdrawOwnerBindingNotWired.into())
    }
}

fn process_register_adapter(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    chain: [u8; 8],
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;

    let mut reg = load_registry(registry_ai, program_id)?;
    assert_authority(authority, &reg.authority)?;

    if reg.find_index(&adapter_id).is_some() {
        return Err(DayError::AlreadyRegistered.into());
    }
    let slot = reg
        .adapters
        .iter()
        .position(|a| !a.used)
        .ok_or(DayError::RegistryFull)?;

    reg.adapters[slot] = AdapterMeta {
        adapter_id,
        chain,
        active: true,
        used: true,
    };
    reg.count = reg.count.saturating_add(1);
    reg.serialize(&mut &mut registry_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY AdapterRegistered id={:?} chain={:?} count={}",
        &adapter_id,
        &chain,
        reg.count
    );
    Ok(())
}

fn process_set_active(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    active: bool,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;

    let mut reg = load_registry(registry_ai, program_id)?;
    assert_authority(authority, &reg.authority)?;

    let idx = reg
        .find_index(&adapter_id)
        .ok_or(DayError::NotAllowlisted)?;
    reg.adapters[idx].active = active;
    reg.serialize(&mut &mut registry_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY AdapterSetActive id={:?} active={}",
        &adapter_id,
        active
    );
    Ok(())
}

fn process_register_adapter_v2(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    chain: [u8; 8],
    protocol_program: Pubkey,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;

    if protocol_program == Pubkey::default() {
        return Err(DayError::InvalidAccount.into());
    }
    let mut reg = load_registry_v2(registry_ai, program_id)?;
    assert_authority(authority, &reg.authority)?;
    if reg.find_index(&adapter_id).is_some() {
        return Err(DayError::AlreadyRegistered.into());
    }
    let slot = reg
        .adapters
        .iter()
        .position(|a| !a.used)
        .ok_or(DayError::RegistryFull)?;
    reg.adapters[slot] = AdapterMetaV2 {
        adapter_id,
        chain,
        protocol_program,
        active: true,
        used: true,
    };
    reg.count = reg.count.saturating_add(1);
    reg.serialize(&mut &mut registry_ai.data.borrow_mut()[..])?;

    msg!(
        "DAY AdapterRegisteredV2 id={:?} chain={:?} program={} count={}",
        &adapter_id,
        &chain,
        protocol_program,
        reg.count
    );
    Ok(())
}

fn process_set_active_v2(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    active: bool,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let authority = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;

    let mut reg = load_registry_v2(registry_ai, program_id)?;
    assert_authority(authority, &reg.authority)?;
    let idx = reg
        .find_index(&adapter_id)
        .ok_or(DayError::NotAllowlisted)?;
    reg.adapters[idx].active = active;
    reg.serialize(&mut &mut registry_ai.data.borrow_mut()[..])?;
    msg!(
        "DAY AdapterSetActiveV2 id={:?} active={}",
        &adapter_id,
        active
    );
    Ok(())
}

/// Validate the exact target before any router-PDA-signed CPI. This helper is
/// public so adversarial tests and future adapter dispatchers use one gate.
pub fn validate_protocol_program(
    reg: &AdapterRegistryV2,
    adapter_id: &[u8; ADAPTER_ID_LEN],
    supplied_program: &Pubkey,
    supplied_program_executable: bool,
) -> ProgramResult {
    let idx = reg.find_index(adapter_id).ok_or(DayError::NotAllowlisted)?;
    let adapter = &reg.adapters[idx];
    if !adapter.active {
        return Err(DayError::NotAllowlisted.into());
    }
    if &adapter.protocol_program != supplied_program {
        return Err(DayError::ProtocolProgramMismatch.into());
    }
    if !supplied_program_executable {
        return Err(DayError::ProtocolProgramNotExecutable.into());
    }
    Ok(())
}

fn assert_adapter_active(
    reg: &AdapterRegistry,
    adapter_id: &[u8; ADAPTER_ID_LEN],
) -> ProgramResult {
    if !reg.is_active(adapter_id) {
        return Err(DayError::NotAllowlisted.into());
    }
    Ok(())
}

fn process_plan_deposit(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    amount_micros: u64,
    auto_yield_enabled: bool,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let owner = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;

    if !owner.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if amount_micros == 0 {
        return Err(DayError::ZeroAmount.into());
    }

    let reg = load_registry(registry_ai, program_id)?;
    let router = load_router(router_ai, program_id)?;
    if router.paused {
        return Err(DayError::Paused.into());
    }
    assert_adapter_active(&reg, &adapter_id)?;

    // Principal fee always 0 (product invariant)
    // DAY-126: plan_* logs are NON-AUTHORITATIVE intent only (signer-bound; not balance proof).
    let fee_micros: u64 = 0;
    msg!(
        "DAY DepositPlanned intent_only=1 owner={} adapter={:?} amount={} fee={} auto_yield={}",
        owner.key,
        &adapter_id,
        amount_micros,
        fee_micros,
        auto_yield_enabled
    );
    // auto_yield_enabled is recorded in logs only; strategy remains OFF by default
    let _ = auto_yield_enabled;
    let _ = router.deposit_fee_bps; // always 0
    Ok(())
}

fn process_plan_withdraw(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    amount_micros: u64,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let owner = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;

    if !owner.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if amount_micros == 0 {
        return Err(DayError::ZeroAmount.into());
    }

    let reg = load_registry(registry_ai, program_id)?;
    let router = load_router(router_ai, program_id)?;
    if router.paused {
        return Err(DayError::Paused.into());
    }
    assert_adapter_active(&reg, &adapter_id)?;

    // DAY-126: NON-AUTHORITATIVE intent log only
    let fee_micros: u64 = 0;
    msg!(
        "DAY WithdrawPlanned intent_only=1 owner={} adapter={:?} amount={} fee={}",
        owner.key,
        &adapter_id,
        amount_micros,
        fee_micros
    );
    Ok(())
}

fn process_plan_harvest_skim(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    adapter_id: [u8; ADAPTER_ID_LEN],
    gross_yield_micros: u64,
) -> ProgramResult {
    let acc_iter = &mut accounts.iter();
    let owner = next_account_info(acc_iter)?;
    let registry_ai = next_account_info(acc_iter)?;
    let router_ai = next_account_info(acc_iter)?;

    if !owner.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }

    let reg = load_registry(registry_ai, program_id)?;
    let router = load_router(router_ai, program_id)?;
    if router.paused {
        return Err(DayError::Paused.into());
    }
    assert_adapter_active(&reg, &adapter_id)?;

    // DAY-126: NON-AUTHORITATIVE intent; gross must be proven offchain/on venue, not from this log.
    let skim = mul_bps(gross_yield_micros, router.protocol_yield_skim_bps);
    let net = gross_yield_micros.saturating_sub(skim);
    msg!(
        "DAY HarvestSkimmed intent_only=1 owner={} adapter={:?} gross={} skim={} net={} fee_bps={}",
        owner.key,
        &adapter_id,
        gross_yield_micros,
        skim,
        net,
        router.protocol_yield_skim_bps
    );
    Ok(())
}

/// Skim amount = amount * bps / 10_000
/// DAY-128: bps must be <= BASIS_POINTS (10_000); panics in tests / returns saturating 0 path via checked math.
pub fn mul_bps(amount: u64, bps: u16) -> u64 {
    assert!(
        (bps as u64) <= (BASIS_POINTS as u64),
        "mul_bps: bps exceeds BASIS_POINTS"
    );
    ((amount as u128) * (bps as u128) / (BASIS_POINTS as u128)) as u64
}

/// Pad a short adapter id string into a fixed 16-byte array.
pub fn pad_adapter_id(s: &str) -> [u8; ADAPTER_ID_LEN] {
    let mut out = [0u8; ADAPTER_ID_LEN];
    let b = s.as_bytes();
    let n = b.len().min(ADAPTER_ID_LEN);
    out[..n].copy_from_slice(&b[..n]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skim_math_and_default_500_bps() {
        assert_eq!(mul_bps(1_000_000, 100), 10_000); // 1% path
        assert_eq!(mul_bps(1_000_000, 500), 50_000); // default performance skim
        assert_eq!(mul_bps(1_000_000, 0), 0);
        assert_eq!(PROTOCOL_YIELD_SKIM_BPS, 500);
        assert_eq!(DEPOSIT_FEE_BPS, 0);
        assert_eq!(WITHDRAW_FEE_BPS, 0);
    }

    #[test]
    fn pad_id() {
        let id = pad_adapter_id("kamino");
        assert_eq!(&id[..6], b"kamino");
        assert_eq!(id[6], 0);
    }

    #[test]
    fn day_915_classify_known_and_unknown_adapter_arms() {
        assert_eq!(
            classify_adapter_dispatch(&pad_adapter_id("kamino")),
            AdapterDispatchArm::Kamino
        );
        assert_eq!(
            classify_adapter_dispatch(&pad_adapter_id("marginfi")),
            AdapterDispatchArm::Marginfi
        );
        assert_eq!(
            classify_adapter_dispatch(&pad_adapter_id("jupiter-lend")),
            AdapterDispatchArm::JupiterLend
        );
        assert_eq!(
            classify_adapter_dispatch(&pad_adapter_id("save")),
            AdapterDispatchArm::Save
        );
        assert_eq!(
            classify_adapter_dispatch(&pad_adapter_id("marinade")),
            AdapterDispatchArm::Unknown
        );
        assert_eq!(
            classify_adapter_dispatch(&pad_adapter_id("")),
            AdapterDispatchArm::Unknown
        );
        assert!(adapter_id_matches(
            &pad_adapter_id("jupiter-lend"),
            "jupiter-lend"
        ));
    }

    #[test]
    fn day_930_jupiter_lend_program_pin_fail_closed() {
        // Earn mainnet pin accepts only when executable; wrong program fails.
        assert_eq!(
            assert_jupiter_lend_program_pin(&JUPITER_LEND_EARN_PROGRAM_ID, true),
            Ok(())
        );
        assert_eq!(
            assert_jupiter_lend_program_pin(&JUPITER_LEND_EARN_PROGRAM_ID, false),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramNotExecutable as u32
            ))
        );
        assert_eq!(
            assert_jupiter_lend_program_pin(&Pubkey::default(), true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
        assert_eq!(
            assert_jupiter_lend_program_pin(&PROTOCOL_AUTHORITY, true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
    }

    #[test]
    fn day_915_jupiter_lend_cpi_body_wired_flag() {
        assert!(
            jupiter_lend_cpi_body_wired() && JUPITER_LEND_CPI_BODY_WIRED,
            "jupiter-lend CPI body must report wired after DAY-915 implementation"
        );
    }

    #[test]
    fn day_915_pure_dispatch_still_fails_closed_without_account_metas() {
        // dispatch_protocol_adapter is a pure registry gate with no account metas —
        // it must never silently Ok even when the jupiter arm has a real CPI body.
        // Full path is cpi_adapter_jupiter_lend + build_jupiter_lend_deposit_instruction.
        let id = pad_adapter_id("jupiter-lend");
        let reg = registry_v2_with(id, JUPITER_LEND_EARN_PROGRAM_ID, true);
        assert_eq!(
            dispatch_protocol_adapter(&reg, &id, &JUPITER_LEND_EARN_PROGRAM_ID, true),
            Err(ProgramError::Custom(DayError::AdapterNotWired as u32)),
            "pure dispatch without metas must remain fail-closed"
        );
        // Missing registry still NotAllowlisted (not AdapterNotWired).
        assert_eq!(
            dispatch_protocol_adapter(
                &empty_registry_v2(),
                &id,
                &JUPITER_LEND_EARN_PROGRAM_ID,
                true
            ),
            Err(ProgramError::Custom(DayError::NotAllowlisted as u32))
        );
    }

    /// Canonical USDC Earn Deposit keys from mainnet digest 42h9HKEu…7cMM
    /// with a synthetic router PDA in the signer slot.
    fn jupiter_lend_usdc_deposit_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_DEPOSIT_ACCOUNT_LEN];
        keys[JUP_LEND_IX_SIGNER] = router_pda;
        keys[JUP_LEND_IX_DEPOSITOR_TOKEN] =
            pubkey!("56RcjTtzUjAdgng5Uz6ASuV3myo8pvFjbtpz4zEZdCVr");
        keys[JUP_LEND_IX_RECIPIENT_TOKEN] =
            pubkey!("BvcCNmXWrmhEVjAV3QJNcdg3pAEzc59r3BPSoJbFGTxT");
        keys[JUP_LEND_IX_MINT] = JUPITER_LEND_USDC_MINT;
        keys[JUP_LEND_IX_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_IX_LENDING] = JUPITER_LEND_USDC_LENDING;
        keys[JUP_LEND_IX_FTOKEN_MINT] = JUPITER_LEND_JLUSDC_MINT;
        keys[JUP_LEND_IX_SUPPLY_RESERVES] = JUPITER_LEND_USDC_SUPPLY_RESERVES;
        keys[JUP_LEND_IX_SUPPLY_POSITION] = JUPITER_LEND_USDC_SUPPLY_POSITION;
        keys[JUP_LEND_IX_RATE_MODEL] = JUPITER_LEND_USDC_RATE_MODEL;
        keys[JUP_LEND_IX_VAULT] = JUPITER_LEND_USDC_VAULT;
        keys[JUP_LEND_IX_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_IX_REWARDS_RATE_MODEL] = JUPITER_LEND_USDC_REWARDS_RATE_MODEL;
        keys[JUP_LEND_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    #[test]
    fn day_915_jupiter_lend_deposit_accounts_accept_pinned_usdc_market() {
        let router = Pubkey::new_unique();
        let keys = jupiter_lend_usdc_deposit_keys(router);
        assert_eq!(assert_jupiter_lend_deposit_accounts(&keys), Ok(()));
    }

    fn jupiter_lend_usdt_deposit_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_DEPOSIT_ACCOUNT_LEN];
        keys[JUP_LEND_IX_SIGNER] = router_pda;
        keys[JUP_LEND_IX_DEPOSITOR_TOKEN] =
            pubkey!("6tocHSgzLcECoAziP5HTgBU3Z5MPDs6oAkYG7uZTeX9R");
        keys[JUP_LEND_IX_RECIPIENT_TOKEN] =
            pubkey!("4fjrBSCu7iRifde55KapwpbGX87wHgxb9gFnxfXgo7Bp");
        keys[JUP_LEND_IX_MINT] = JUPITER_LEND_USDT_MINT;
        keys[JUP_LEND_IX_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_IX_LENDING] = JUPITER_LEND_USDT_LENDING;
        keys[JUP_LEND_IX_FTOKEN_MINT] = JUPITER_LEND_JLUSDT_MINT;
        keys[JUP_LEND_IX_SUPPLY_RESERVES] = JUPITER_LEND_USDT_SUPPLY_RESERVES;
        keys[JUP_LEND_IX_SUPPLY_POSITION] = JUPITER_LEND_USDT_SUPPLY_POSITION;
        keys[JUP_LEND_IX_RATE_MODEL] = JUPITER_LEND_USDT_RATE_MODEL;
        keys[JUP_LEND_IX_VAULT] = JUPITER_LEND_USDT_VAULT;
        keys[JUP_LEND_IX_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_IX_REWARDS_RATE_MODEL] = JUPITER_LEND_USDT_REWARDS_RATE_MODEL;
        keys[JUP_LEND_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    fn jupiter_lend_wsol_deposit_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_DEPOSIT_ACCOUNT_LEN];
        keys[JUP_LEND_IX_SIGNER] = router_pda;
        keys[JUP_LEND_IX_DEPOSITOR_TOKEN] =
            pubkey!("DXwMRATmiZkLnmjGRue1WE2ALnANp2ZR5kdhHP2QycJL");
        keys[JUP_LEND_IX_RECIPIENT_TOKEN] =
            pubkey!("7FUhXVcyeFNCPuvkZ7RXBGdKoNtW5rkELV3VaHJeEpiy");
        keys[JUP_LEND_IX_MINT] = JUPITER_LEND_WSOL_MINT;
        keys[JUP_LEND_IX_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_IX_LENDING] = JUPITER_LEND_WSOL_LENDING;
        keys[JUP_LEND_IX_FTOKEN_MINT] = JUPITER_LEND_JLWSOL_MINT;
        keys[JUP_LEND_IX_SUPPLY_RESERVES] = JUPITER_LEND_WSOL_SUPPLY_RESERVES;
        keys[JUP_LEND_IX_SUPPLY_POSITION] = JUPITER_LEND_WSOL_SUPPLY_POSITION;
        keys[JUP_LEND_IX_RATE_MODEL] = JUPITER_LEND_WSOL_RATE_MODEL;
        keys[JUP_LEND_IX_VAULT] = JUPITER_LEND_WSOL_VAULT;
        keys[JUP_LEND_IX_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_IX_REWARDS_RATE_MODEL] = JUPITER_LEND_WSOL_REWARDS_RATE_MODEL;
        keys[JUP_LEND_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    fn jupiter_lend_eurc_deposit_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_DEPOSIT_ACCOUNT_LEN];
        keys[JUP_LEND_IX_SIGNER] = router_pda;
        keys[JUP_LEND_IX_DEPOSITOR_TOKEN] =
            pubkey!("3ToX3gfgWps2SK4QyFNeREEAmTVkWcQvMsW64xbZSWXB");
        keys[JUP_LEND_IX_RECIPIENT_TOKEN] =
            pubkey!("4n4vyhF3SqgDZS9de6DotNs8AizoooP7Ew9fAVXz5js1");
        keys[JUP_LEND_IX_MINT] = JUPITER_LEND_EURC_MINT;
        keys[JUP_LEND_IX_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_IX_LENDING] = JUPITER_LEND_EURC_LENDING;
        keys[JUP_LEND_IX_FTOKEN_MINT] = JUPITER_LEND_JLEURC_MINT;
        keys[JUP_LEND_IX_SUPPLY_RESERVES] = JUPITER_LEND_EURC_SUPPLY_RESERVES;
        keys[JUP_LEND_IX_SUPPLY_POSITION] = JUPITER_LEND_EURC_SUPPLY_POSITION;
        keys[JUP_LEND_IX_RATE_MODEL] = JUPITER_LEND_EURC_RATE_MODEL;
        keys[JUP_LEND_IX_VAULT] = JUPITER_LEND_EURC_VAULT;
        keys[JUP_LEND_IX_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_IX_REWARDS_RATE_MODEL] = JUPITER_LEND_EURC_REWARDS_RATE_MODEL;
        keys[JUP_LEND_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    fn jupiter_lend_usdg_deposit_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_DEPOSIT_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_DEPOSIT_ACCOUNT_LEN];
        keys[JUP_LEND_IX_SIGNER] = router_pda;
        keys[JUP_LEND_IX_DEPOSITOR_TOKEN] =
            pubkey!("EpV6tGUyp12m6JuSe3ifFBNVyeJFDZFvPQ6qCc6h1kgb");
        keys[JUP_LEND_IX_RECIPIENT_TOKEN] =
            pubkey!("3CNFy4o8WPjkPmiJpHWfWFe5MDncHv5NDp939WYzXWmN");
        keys[JUP_LEND_IX_MINT] = JUPITER_LEND_USDG_MINT;
        keys[JUP_LEND_IX_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_IX_LENDING] = JUPITER_LEND_USDG_LENDING;
        keys[JUP_LEND_IX_FTOKEN_MINT] = JUPITER_LEND_JLUSDG_MINT;
        keys[JUP_LEND_IX_SUPPLY_RESERVES] = JUPITER_LEND_USDG_SUPPLY_RESERVES;
        keys[JUP_LEND_IX_SUPPLY_POSITION] = JUPITER_LEND_USDG_SUPPLY_POSITION;
        keys[JUP_LEND_IX_RATE_MODEL] = JUPITER_LEND_USDG_RATE_MODEL;
        keys[JUP_LEND_IX_VAULT] = JUPITER_LEND_USDG_VAULT;
        keys[JUP_LEND_IX_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_IX_REWARDS_RATE_MODEL] = JUPITER_LEND_USDG_REWARDS_RATE_MODEL;
        // Measured USDG Earn deposit uses Token-2022 (Tokenz…), not Tokenkeg.
        keys[JUP_LEND_IX_TOKEN_PROGRAM] = TOKEN_2022_PROGRAM_ID;
        keys[JUP_LEND_IX_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_IX_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    #[test]
    fn day_930_jupiter_lend_deposit_accounts_accept_usdt_and_wsol_source_pins() {
        let router = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&jupiter_lend_usdt_deposit_keys(router)),
            Ok(())
        );
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&jupiter_lend_wsol_deposit_keys(router)),
            Ok(())
        );
        // Cross-market mash: USDT mint with USDC lending → fail closed.
        let mut mash = jupiter_lend_usdt_deposit_keys(router);
        mash[JUP_LEND_IX_LENDING] = JUPITER_LEND_USDC_LENDING;
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&mash),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_930_jupiter_lend_deposit_accounts_accept_eurc_usdg_usds_jupusd_source_pins() {
        let router = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&jupiter_lend_eurc_deposit_keys(router)),
            Ok(())
        );
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&jupiter_lend_usdg_deposit_keys(router)),
            Ok(())
        );
        // USDG with classic SPL Tokenkeg (wrong for this mint) → fail closed.
        let mut usdg_wrong_token = jupiter_lend_usdg_deposit_keys(router);
        usdg_wrong_token[JUP_LEND_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&usdg_wrong_token),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // EURC mint with USDC market keys → fail closed.
        let mut mash = jupiter_lend_eurc_deposit_keys(router);
        mash[JUP_LEND_IX_LENDING] = JUPITER_LEND_USDC_LENDING;
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&mash),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // USDS / JUPUSD pin resolve returns Some.
        assert!(jupiter_lend_deposit_market_pins(&JUPITER_LEND_USDS_MINT).is_some());
        assert!(jupiter_lend_deposit_market_pins(&JUPITER_LEND_JUPUSD_MINT).is_some());
        assert_eq!(
            jupiter_lend_token_program_for_mint(&JUPITER_LEND_USDG_MINT),
            Some(TOKEN_2022_PROGRAM_ID)
        );
        assert_eq!(
            jupiter_lend_token_program_for_mint(&JUPITER_LEND_EURC_MINT),
            Some(SPL_TOKEN_PROGRAM_ID)
        );
    }

    #[test]
    fn day_915_jupiter_lend_deposit_accounts_reject_wrong_count_or_mint() {
        let router = Pubkey::new_unique();
        let keys = jupiter_lend_usdc_deposit_keys(router);
        // Wrong length
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&keys[..16]),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong USDC mint → fail closed (no arbitrary market)
        let mut bad = keys;
        bad[JUP_LEND_IX_MINT] = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&bad),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong jlUSDC mint
        let mut bad2 = keys;
        bad2[JUP_LEND_IX_FTOKEN_MINT] = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&bad2),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong liquidity program
        let mut bad3 = keys;
        bad3[JUP_LEND_IX_LIQUIDITY_PROGRAM] = JUPITER_LEND_EARN_PROGRAM_ID;
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&bad3),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Default signer rejected
        let mut bad4 = keys;
        bad4[JUP_LEND_IX_SIGNER] = Pubkey::default();
        assert_eq!(
            assert_jupiter_lend_deposit_accounts(&bad4),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_915_jupiter_lend_deposit_ix_data_disc_and_amount() {
        let data = encode_jupiter_lend_deposit_ix_data(10_000);
        assert_eq!(assert_jupiter_lend_deposit_ix_data(&data), Ok(10_000));
        // Matches landed mainnet amount layout (10000 micros).
        assert_eq!(&data[0..8], &JUPITER_LEND_DEPOSIT_DISCRIMINATOR);
        // Zero amount rejected
        assert_eq!(
            assert_jupiter_lend_deposit_ix_data(&encode_jupiter_lend_deposit_ix_data(0)),
            Err(ProgramError::Custom(DayError::ZeroAmount as u32))
        );
        // Wrong disc
        let mut bad = data;
        bad[0] ^= 0xff;
        assert_eq!(
            assert_jupiter_lend_deposit_ix_data(&bad),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );
        // Wrong length
        assert_eq!(
            assert_jupiter_lend_deposit_ix_data(&data[..8]),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );
    }

    #[test]
    fn day_915_jupiter_lend_build_ix_requires_router_signer_and_structure() {
        let router = Pubkey::new_unique();
        let keys = jupiter_lend_usdc_deposit_keys(router);
        let writables = jupiter_lend_deposit_default_writables();
        let data = encode_jupiter_lend_deposit_ix_data(10_000);

        let ix = build_jupiter_lend_deposit_instruction(&keys, &writables, &router, &data)
            .expect("valid structure must build");
        assert_eq!(ix.program_id, JUPITER_LEND_EARN_PROGRAM_ID);
        assert_eq!(ix.accounts.len(), JUPITER_LEND_DEPOSIT_ACCOUNT_LEN);
        assert!(ix.accounts[0].is_signer, "router PDA must be CPI signer");
        assert_eq!(ix.accounts[0].pubkey, router);
        assert_eq!(ix.data, data.to_vec());

        // Wrong router in signer slot → fail closed (no invoke of arbitrary authority)
        let other = Pubkey::new_unique();
        assert_eq!(
            build_jupiter_lend_deposit_instruction(&keys, &writables, &other, &data)
                .err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        // Wrong market pin → fail closed
        let mut bad_keys = keys;
        bad_keys[JUP_LEND_IX_VAULT] = Pubkey::new_unique();
        assert_eq!(
            build_jupiter_lend_deposit_instruction(&bad_keys, &writables, &router, &data)
                .err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    // ── DAY-962/980 Jupiter Lend Earn WITHDRAW arm ──────────────────────────
    // Authentic USDC Earn Withdraw layout from measured mainnet product-API
    // withdraw `45HDPE…7cMM` (18 accounts; disc b712469c946da122).
    fn jupiter_lend_usdc_withdraw_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_WITHDRAW_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_WITHDRAW_ACCOUNT_LEN];
        keys[JUP_LEND_WD_SIGNER] = router_pda;
        // Owner jlUSDC ATA (source, burned from) and USDC ATA (recipient) —
        // reversed vs deposit slot order.
        keys[JUP_LEND_WD_SOURCE_FTOKEN] =
            pubkey!("BvcCNmXWrmhEVjAV3QJNcdg3pAEzc59r3BPSoJbFGTxT");
        keys[JUP_LEND_WD_RECIPIENT_TOKEN] =
            pubkey!("56RcjTtzUjAdgng5Uz6ASuV3myo8pvFjbtpz4zEZdCVr");
        keys[JUP_LEND_WD_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_WD_LENDING] = JUPITER_LEND_USDC_LENDING;
        keys[JUP_LEND_WD_MINT] = JUPITER_LEND_USDC_MINT;
        keys[JUP_LEND_WD_FTOKEN_MINT] = JUPITER_LEND_JLUSDC_MINT;
        keys[JUP_LEND_WD_SUPPLY_RESERVES] = JUPITER_LEND_USDC_SUPPLY_RESERVES;
        keys[JUP_LEND_WD_SUPPLY_POSITION] = JUPITER_LEND_USDC_SUPPLY_POSITION;
        keys[JUP_LEND_WD_RATE_MODEL] = JUPITER_LEND_USDC_RATE_MODEL;
        keys[JUP_LEND_WD_VAULT] = JUPITER_LEND_USDC_VAULT;
        keys[JUP_LEND_WD_CLAIM] = JUPITER_LEND_USDC_WITHDRAW_CLAIM;
        keys[JUP_LEND_WD_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_WD_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_WD_REWARDS_RATE_MODEL] = JUPITER_LEND_USDC_REWARDS_RATE_MODEL;
        keys[JUP_LEND_WD_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_WD_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_WD_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    #[test]
    fn day_962_jupiter_lend_withdraw_accounts_accept_pinned_usdc_market() {
        let router = Pubkey::new_unique();
        let keys = jupiter_lend_usdc_withdraw_keys(router);
        assert_eq!(assert_jupiter_lend_withdraw_accounts(&keys), Ok(()));
    }

    fn jupiter_lend_usdt_withdraw_keys(router_pda: Pubkey) -> [Pubkey; JUPITER_LEND_WITHDRAW_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); JUPITER_LEND_WITHDRAW_ACCOUNT_LEN];
        keys[JUP_LEND_WD_SIGNER] = router_pda;
        keys[JUP_LEND_WD_SOURCE_FTOKEN] =
            pubkey!("4fjrBSCu7iRifde55KapwpbGX87wHgxb9gFnxfXgo7Bp");
        keys[JUP_LEND_WD_RECIPIENT_TOKEN] =
            pubkey!("6tocHSgzLcECoAziP5HTgBU3Z5MPDs6oAkYG7uZTeX9R");
        keys[JUP_LEND_WD_LENDING_ADMIN] = JUPITER_LEND_USDC_LENDING_ADMIN;
        keys[JUP_LEND_WD_LENDING] = JUPITER_LEND_USDT_LENDING;
        keys[JUP_LEND_WD_MINT] = JUPITER_LEND_USDT_MINT;
        keys[JUP_LEND_WD_FTOKEN_MINT] = JUPITER_LEND_JLUSDT_MINT;
        keys[JUP_LEND_WD_SUPPLY_RESERVES] = JUPITER_LEND_USDT_SUPPLY_RESERVES;
        keys[JUP_LEND_WD_SUPPLY_POSITION] = JUPITER_LEND_USDT_SUPPLY_POSITION;
        keys[JUP_LEND_WD_RATE_MODEL] = JUPITER_LEND_USDT_RATE_MODEL;
        keys[JUP_LEND_WD_VAULT] = JUPITER_LEND_USDT_VAULT;
        keys[JUP_LEND_WD_CLAIM] = JUPITER_LEND_USDT_WITHDRAW_CLAIM;
        keys[JUP_LEND_WD_LIQUIDITY] = JUPITER_LEND_USDC_LIQUIDITY;
        keys[JUP_LEND_WD_LIQUIDITY_PROGRAM] = JUPITER_LEND_LIQUIDITY_PROGRAM_ID;
        keys[JUP_LEND_WD_REWARDS_RATE_MODEL] = JUPITER_LEND_USDT_REWARDS_RATE_MODEL;
        keys[JUP_LEND_WD_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_WD_ATA_PROGRAM] = ASSOCIATED_TOKEN_PROGRAM_ID;
        keys[JUP_LEND_WD_SYSTEM_PROGRAM] = system_program::ID;
        keys
    }

    #[test]
    fn day_930_jupiter_lend_withdraw_accounts_accept_usdt_source_pin() {
        let router = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&jupiter_lend_usdt_withdraw_keys(router)),
            Ok(())
        );
        // USDT mint with USDC claim → fail closed (per-market claim).
        let mut mash = jupiter_lend_usdt_withdraw_keys(router);
        mash[JUP_LEND_WD_CLAIM] = JUPITER_LEND_USDC_WITHDRAW_CLAIM;
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&mash),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_962_jupiter_lend_withdraw_accounts_reject_wrong_count_or_market() {
        let router = Pubkey::new_unique();
        let keys = jupiter_lend_usdc_withdraw_keys(router);
        // Deposit count (17) rejected — withdraw needs exactly 18.
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&keys[..17]),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong withdraw-only claim account → fail closed (USDT market's claim,
        // or any other, must not pass on the USDC market).
        let mut bad = keys;
        bad[JUP_LEND_WD_CLAIM] = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&bad),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong USDC mint → fail closed
        let mut bad2 = keys;
        bad2[JUP_LEND_WD_MINT] = Pubkey::new_unique();
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&bad2),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong liquidity program → fail closed
        let mut bad3 = keys;
        bad3[JUP_LEND_WD_LIQUIDITY_PROGRAM] = JUPITER_LEND_EARN_PROGRAM_ID;
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&bad3),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Default source/recipient token slot rejected
        let mut bad4 = keys;
        bad4[JUP_LEND_WD_SOURCE_FTOKEN] = Pubkey::default();
        assert_eq!(
            assert_jupiter_lend_withdraw_accounts(&bad4),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_962_jupiter_lend_withdraw_ix_data_disc_and_amount() {
        let data = encode_jupiter_lend_withdraw_ix_data(100_000);
        assert_eq!(assert_jupiter_lend_withdraw_ix_data(&data), Ok(100_000));
        // Matches measured mainnet withdraw amount layout (100000 micros).
        assert_eq!(&data[0..8], &JUPITER_LEND_WITHDRAW_DISCRIMINATOR);
        // Zero amount rejected
        assert_eq!(
            assert_jupiter_lend_withdraw_ix_data(&encode_jupiter_lend_withdraw_ix_data(0)),
            Err(ProgramError::Custom(DayError::ZeroAmount as u32))
        );
        // A DEPOSIT disc must NOT satisfy the withdraw ix-data check.
        assert_eq!(
            assert_jupiter_lend_withdraw_ix_data(&encode_jupiter_lend_deposit_ix_data(100_000)),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );
    }

    #[test]
    fn day_962_jupiter_lend_withdraw_build_ix_requires_router_signer_and_structure() {
        let router = Pubkey::new_unique();
        let keys = jupiter_lend_usdc_withdraw_keys(router);
        let writables = jupiter_lend_withdraw_default_writables();
        let data = encode_jupiter_lend_withdraw_ix_data(100_000);

        let ix = build_jupiter_lend_withdraw_instruction(&keys, &writables, &router, &data)
            .expect("valid withdraw structure must build");
        assert_eq!(ix.program_id, JUPITER_LEND_EARN_PROGRAM_ID);
        assert_eq!(ix.accounts.len(), JUPITER_LEND_WITHDRAW_ACCOUNT_LEN);
        assert!(ix.accounts[0].is_signer, "router PDA must be CPI signer");
        assert_eq!(ix.accounts[0].pubkey, router);
        assert_eq!(ix.data, data.to_vec());
        // LENDING_ADMIN is readonly on withdraw (writable on deposit).
        assert!(!ix.accounts[JUP_LEND_WD_LENDING_ADMIN].is_writable);

        // Wrong router in signer slot → fail closed
        let other = Pubkey::new_unique();
        assert_eq!(
            build_jupiter_lend_withdraw_instruction(&keys, &writables, &other, &data).err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    /// Canonical Main Market USDC Deposit V2 keys from mainnet digest 5xGJc15P…2vvrsK
    /// with a synthetic router PDA in the owner/signer slot.
    fn kamino_main_market_usdc_deposit_keys(router_pda: Pubkey) -> [Pubkey; KAMINO_V2_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); KAMINO_V2_ACCOUNT_LEN];
        keys[KAMINO_IX_OWNER] = router_pda;
        keys[KAMINO_IX_OBLIGATION] =
            pubkey!("AcCvMvVKEoah5Ee9owAZBC7CwGt614cBW6vudWniWnqd");
        keys[KAMINO_IX_LENDING_MARKET] = KAMINO_MAIN_MARKET;
        keys[KAMINO_IX_LENDING_MARKET_AUTHORITY] = KAMINO_MAIN_MARKET_AUTHORITY;
        keys[KAMINO_IX_RESERVE] = KAMINO_MAIN_MARKET_USDC_RESERVE;
        keys[KAMINO_IX_RESERVE_LIQUIDITY_MINT] = KAMINO_USDC_MINT;
        keys[KAMINO_IX_SLOT_6] = KAMINO_USDC_RESERVE_LIQUIDITY_SUPPLY;
        keys[KAMINO_IX_SLOT_7] = KAMINO_USDC_RESERVE_COLLATERAL_MINT;
        keys[KAMINO_IX_SLOT_8] = KAMINO_USDC_RESERVE_COLLATERAL_SUPPLY;
        keys[KAMINO_IX_USER_LIQUIDITY] =
            pubkey!("56RcjTtzUjAdgng5Uz6ASuV3myo8pvFjbtpz4zEZdCVr");
        keys[KAMINO_IX_PLACEHOLDER_COLLATERAL] = KAMINO_KLEND_PROGRAM_ID;
        keys[KAMINO_IX_COLLATERAL_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[KAMINO_IX_LIQUIDITY_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[KAMINO_IX_INSTRUCTION_SYSVAR] = SYSVAR_INSTRUCTIONS_ID;
        keys[KAMINO_IX_OBLIGATION_FARM_USER] =
            pubkey!("4XSDXSe7E5nWhyJDy2vnReDTCvMbDr983uCgy14NJTN1");
        keys[KAMINO_IX_RESERVE_FARM_STATE] = KAMINO_USDC_RESERVE_FARM_STATE;
        keys[KAMINO_IX_FARMS_PROGRAM] = KAMINO_FARMS_PROGRAM_ID;
        keys
    }

    fn kamino_main_market_usdc_withdraw_keys(router_pda: Pubkey) -> [Pubkey; KAMINO_V2_ACCOUNT_LEN] {
        let mut keys = kamino_main_market_usdc_deposit_keys(router_pda);
        // Withdraw vault order: source collateral @6, liquidity supply @8
        keys[KAMINO_IX_SLOT_6] = KAMINO_USDC_RESERVE_COLLATERAL_SUPPLY;
        keys[KAMINO_IX_SLOT_8] = KAMINO_USDC_RESERVE_LIQUIDITY_SUPPLY;
        keys
    }

    fn kamino_main_market_usdc_deposit_refresh_keys(
        router_pda: Pubkey,
    ) -> [Pubkey; KAMINO_DEPOSIT_ACCOUNT_LEN] {
        let deposit = kamino_main_market_usdc_deposit_keys(router_pda);
        let mut keys = [Pubkey::default(); KAMINO_DEPOSIT_ACCOUNT_LEN];
        keys[..KAMINO_V2_ACCOUNT_LEN].copy_from_slice(&deposit);
        keys[KAMINO_IX_SCOPE_PRICES] = KAMINO_MAIN_MARKET_SCOPE_PRICES;
        keys[KAMINO_IX_OBLIGATION_RESERVES_START] = KAMINO_KLEND_PROGRAM_ID;
        keys[KAMINO_IX_OBLIGATION_RESERVES_START + 1] = KAMINO_KLEND_PROGRAM_ID;
        keys
    }

    #[test]
    fn day_976_kamino_cpi_body_wired_flag() {
        assert!(
            kamino_cpi_body_wired() && KAMINO_CPI_BODY_WIRED,
            "kamino CPI body must report wired after DAY-976 implementation"
        );
    }

    #[test]
    fn day_976_kamino_program_pin_fail_closed() {
        assert_eq!(
            assert_kamino_program_pin(&KAMINO_KLEND_PROGRAM_ID, true),
            Ok(())
        );
        assert_eq!(
            assert_kamino_program_pin(&KAMINO_KLEND_PROGRAM_ID, false),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramNotExecutable as u32
            ))
        );
        assert_eq!(
            assert_kamino_program_pin(&Pubkey::default(), true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
        // Wrong program (e.g. jupiter earn) must not pass kamino pin.
        assert_eq!(
            assert_kamino_program_pin(&JUPITER_LEND_EARN_PROGRAM_ID, true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
    }

    #[test]
    fn day_976_kamino_deposit_accounts_accept_main_market_usdc() {
        let router = Pubkey::new_unique();
        let keys = kamino_main_market_usdc_deposit_keys(router);
        assert_eq!(assert_kamino_deposit_accounts(&keys), Ok(()));
    }

    #[test]
    fn day_976_kamino_deposit_accounts_reject_wrong_market_or_unbound() {
        let router = Pubkey::new_unique();
        let keys = kamino_main_market_usdc_deposit_keys(router);
        // Wrong length
        assert_eq!(
            assert_kamino_deposit_accounts(&keys[..16]),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong reserve (unbound / other market) → fail closed
        let mut bad = keys;
        bad[KAMINO_IX_RESERVE] = pubkey!("6pazpY4icuXZ5sb2jMWAqdG4TtbUoY1SJ45237Fjht9h");
        assert_eq!(
            assert_kamino_deposit_accounts(&bad),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong Main Market
        let mut bad2 = keys;
        bad2[KAMINO_IX_LENDING_MARKET] = Pubkey::new_unique();
        assert_eq!(
            assert_kamino_deposit_accounts(&bad2),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong mint
        let mut bad3 = keys;
        bad3[KAMINO_IX_RESERVE_LIQUIDITY_MINT] = Pubkey::new_unique();
        assert_eq!(
            assert_kamino_deposit_accounts(&bad3),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Unbound owner/signer default
        let mut bad4 = keys;
        bad4[KAMINO_IX_OWNER] = Pubkey::default();
        assert_eq!(
            assert_kamino_deposit_accounts(&bad4),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Unbound obligation default
        let mut bad5 = keys;
        bad5[KAMINO_IX_OBLIGATION] = Pubkey::default();
        assert_eq!(
            assert_kamino_deposit_accounts(&bad5),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong farm state (neither pin nor program placeholder)
        let mut bad6 = keys;
        bad6[KAMINO_IX_RESERVE_FARM_STATE] = Pubkey::new_unique();
        assert_eq!(
            assert_kamino_deposit_accounts(&bad6),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_976_kamino_withdraw_accounts_reject_wrong_vault_order() {
        let router = Pubkey::new_unique();
        // Deposit-shaped vault order must fail withdraw pin check.
        let deposit_shape = kamino_main_market_usdc_deposit_keys(router);
        assert_eq!(
            assert_kamino_withdraw_accounts(&deposit_shape),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        let withdraw = kamino_main_market_usdc_withdraw_keys(router);
        assert_eq!(assert_kamino_withdraw_accounts(&withdraw), Ok(()));
        let mut bad_reserve = withdraw;
        bad_reserve[KAMINO_IX_RESERVE] = Pubkey::new_unique();
        assert_eq!(
            assert_kamino_withdraw_accounts(&bad_reserve),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_976_kamino_ix_data_disc_and_amount() {
        let data = encode_kamino_deposit_ix_data(50_000);
        assert_eq!(assert_kamino_deposit_ix_data(&data), Ok(50_000));
        assert_eq!(&data[0..8], &KAMINO_DEPOSIT_V2_DISCRIMINATOR);
        // Matches mainnet deposit amount layout (50000 micros).
        assert_eq!(
            assert_kamino_deposit_ix_data(&encode_kamino_deposit_ix_data(0)),
            Err(ProgramError::Custom(DayError::ZeroAmount as u32))
        );
        let mut bad = data;
        bad[0] ^= 0xff;
        assert_eq!(
            assert_kamino_deposit_ix_data(&bad),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );
        // Deposit disc rejected as withdraw
        assert_eq!(
            assert_kamino_withdraw_ix_data(&data),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );
        let wdata = encode_kamino_withdraw_ix_data(12_345);
        assert_eq!(assert_kamino_withdraw_ix_data(&wdata), Ok(12_345));
        assert_eq!(&wdata[0..8], &KAMINO_WITHDRAW_V2_DISCRIMINATOR);
    }

    #[test]
    fn day_1105_kamino_build_ix_requires_exact_owner_signer_and_structure() {
        let router = Pubkey::new_unique();
        let keys = kamino_main_market_usdc_deposit_keys(router);
        let writables = kamino_deposit_default_writables();
        let data = encode_kamino_deposit_ix_data(50_000);

        let ix = build_kamino_deposit_instruction(&keys, &writables, &router, &data)
            .expect("valid structure must build");
        assert_eq!(ix.program_id, KAMINO_KLEND_PROGRAM_ID);
        assert_eq!(ix.accounts.len(), KAMINO_V2_ACCOUNT_LEN);
        assert!(ix.accounts[0].is_signer, "router PDA must be CPI signer");
        assert_eq!(ix.accounts[0].pubkey, router);
        assert_eq!(ix.data, data.to_vec());

        let other = Pubkey::new_unique();
        assert_eq!(
            build_kamino_deposit_instruction(&keys, &writables, &other, &data).err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        let mut bad_keys = keys;
        bad_keys[KAMINO_IX_RESERVE] = Pubkey::new_unique();
        assert_eq!(
            build_kamino_deposit_instruction(&bad_keys, &writables, &router, &data).err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        let wkeys = kamino_main_market_usdc_withdraw_keys(router);
        let wwritables = kamino_withdraw_default_writables();
        let wdata = encode_kamino_withdraw_ix_data(1_000);
        let wix = build_kamino_withdraw_instruction(&wkeys, &wwritables, &router, &wdata)
            .expect("valid withdraw structure must build");
        assert_eq!(wix.program_id, KAMINO_KLEND_PROGRAM_ID);
        assert_eq!(wix.accounts[0].pubkey, router);
    }

    #[test]
    fn day_1105_kamino_withdraw_refreshes_reserve_and_obligation_before_exit() {
        // intent: live exact-owner exit hit KLend 6009 ReserveStale when DAY
        // invoked Withdraw V2 without the primary SDK's current-slot refreshes.
        let owner = Pubkey::new_unique();
        let mut keys = kamino_main_market_usdc_deposit_refresh_keys(owner).to_vec();
        keys[..KAMINO_V2_ACCOUNT_LEN]
            .copy_from_slice(&kamino_main_market_usdc_withdraw_keys(owner));
        keys.insert(
            KAMINO_IX_OBLIGATION_RESERVES_START,
            KAMINO_MAIN_MARKET_USDC_RESERVE,
        );
        let mut writables = vec![false; keys.len()];
        writables[..KAMINO_V2_ACCOUNT_LEN]
            .copy_from_slice(&kamino_withdraw_default_writables());
        writables[KAMINO_IX_OBLIGATION_RESERVES_START] = true;
        let data = encode_kamino_withdraw_ix_data(836);
        let sequence = build_kamino_withdraw_sequence(&keys, &writables, &owner, &data)
            .expect("withdraw refresh sequence must build");
        assert_eq!(sequence.len(), 3);
        assert_eq!(sequence[0].data, KAMINO_REFRESH_RESERVE_DISCRIMINATOR);
        assert_eq!(sequence[0].accounts[0].pubkey, KAMINO_MAIN_MARKET_USDC_RESERVE);
        assert_eq!(sequence[1].data, KAMINO_REFRESH_OBLIGATION_DISCRIMINATOR);
        assert_eq!(sequence[1].accounts[2].pubkey, KAMINO_MAIN_MARKET_USDC_RESERVE);
        assert_eq!(&sequence[2].data[..8], &KAMINO_WITHDRAW_V2_DISCRIMINATOR);

        // Sabotage: omitting the current reserve from RefreshObligation must
        // fail closed instead of recreating the stale-withdraw regression.
        keys.remove(KAMINO_IX_OBLIGATION_RESERVES_START);
        writables.remove(KAMINO_IX_OBLIGATION_RESERVES_START);
        assert_eq!(
            build_kamino_withdraw_sequence(&keys, &writables, &owner, &data).err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_1105_kamino_deposit_refreshes_reserve_and_obligation_in_exact_order() {
        // intent: KLend rejected the otherwise-correct V2 deposit with 6017
        // ObligationStale when DAY invoked it without the SDK refresh prefix.
        let owner = Pubkey::new_unique();
        let keys = kamino_main_market_usdc_deposit_refresh_keys(owner);
        let mut writables = [false; KAMINO_DEPOSIT_ACCOUNT_LEN];
        writables[..KAMINO_V2_ACCOUNT_LEN]
            .copy_from_slice(&kamino_deposit_default_writables());
        let data = encode_kamino_deposit_ix_data(1_000);
        let sequence = build_kamino_deposit_sequence(&keys, &writables, &owner, &data)
            .expect("source-pinned refresh + deposit sequence must build");

        assert_eq!(sequence[0].data, KAMINO_REFRESH_RESERVE_DISCRIMINATOR);
        assert_eq!(sequence[1].data, KAMINO_REFRESH_OBLIGATION_DISCRIMINATOR);
        assert_eq!(&sequence[2].data[..8], &KAMINO_DEPOSIT_V2_DISCRIMINATOR);
        assert_eq!(sequence[0].accounts.len(), 6);
        assert_eq!(sequence[0].accounts[0].pubkey, KAMINO_MAIN_MARKET_USDC_RESERVE);
        assert!(sequence[0].accounts[0].is_writable);
        assert_eq!(sequence[0].accounts[1].pubkey, KAMINO_MAIN_MARKET);
        assert_eq!(sequence[0].accounts[2].pubkey, KAMINO_KLEND_PROGRAM_ID);
        assert_eq!(sequence[0].accounts[3].pubkey, KAMINO_KLEND_PROGRAM_ID);
        assert_eq!(sequence[0].accounts[4].pubkey, KAMINO_KLEND_PROGRAM_ID);
        assert_eq!(sequence[0].accounts[5].pubkey, KAMINO_MAIN_MARKET_SCOPE_PRICES);
        assert!(!sequence[0].accounts[5].is_writable);
        assert_eq!(sequence[1].accounts.len(), 2);
        assert_eq!(sequence[1].accounts[0].pubkey, KAMINO_MAIN_MARKET);
        assert_eq!(sequence[1].accounts[1].pubkey, keys[KAMINO_IX_OBLIGATION]);
        assert!(sequence[1].accounts[1].is_writable);
        assert_eq!(sequence[2].accounts[0].pubkey, owner);
        assert!(sequence[2].accounts[0].is_signer);

        let mut wrong_scope = keys;
        wrong_scope[KAMINO_IX_SCOPE_PRICES] = Pubkey::new_unique();
        assert_eq!(
            build_kamino_deposit_sequence(&wrong_scope, &writables, &owner, &data).err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        // Existing deposits are refreshed before the current reserve and are
        // forwarded to RefreshObligation in SDK position order.
        let mut multi_keys = keys.to_vec();
        multi_keys.insert(
            KAMINO_IX_OBLIGATION_RESERVES_START,
            KAMINO_MAIN_MARKET_SOL_RESERVE,
        );
        let mut multi_writables = writables.to_vec();
        multi_writables.insert(KAMINO_IX_OBLIGATION_RESERVES_START, true);
        let multi = build_kamino_deposit_sequence(
            &multi_keys,
            &multi_writables,
            &owner,
            &data,
        )
        .expect("complete multi-reserve refresh set must build");
        assert_eq!(multi.len(), 4);
        assert_eq!(multi[0].accounts[0].pubkey, KAMINO_MAIN_MARKET_SOL_RESERVE);
        assert_eq!(multi[1].accounts[0].pubkey, KAMINO_MAIN_MARKET_USDC_RESERVE);
        assert_eq!(multi[2].data, KAMINO_REFRESH_OBLIGATION_DISCRIMINATOR);
        assert_eq!(multi[2].accounts.len(), 3);
        assert_eq!(multi[2].accounts[2].pubkey, KAMINO_MAIN_MARKET_SOL_RESERVE);
        assert_eq!(&multi[3].data[..8], &KAMINO_DEPOSIT_V2_DISCRIMINATOR);

        // intent: a newly deposited reserve is refreshed but must not occupy
        // a RefreshObligation position/referrer slot. Model an existing SOL
        // borrow with a referrer while depositing new USDC.
        let referrer_state = Pubkey::new_unique();
        let mut referred_keys = keys.to_vec();
        referred_keys.insert(
            KAMINO_IX_OBLIGATION_RESERVES_START + 1,
            KAMINO_MAIN_MARKET_SOL_RESERVE,
        );
        referred_keys.push(referrer_state);
        let mut referred_writables = writables.to_vec();
        referred_writables.insert(KAMINO_IX_OBLIGATION_RESERVES_START + 1, true);
        referred_writables.push(true);
        let referred = build_kamino_deposit_sequence(
            &referred_keys,
            &referred_writables,
            &owner,
            &data,
        )
        .expect("new reserve must stay separate from existing referred borrow");
        assert_eq!(referred[2].accounts.len(), 4);
        assert_eq!(referred[2].accounts[2].pubkey, KAMINO_MAIN_MARKET_SOL_RESERVE);
        assert_eq!(referred[2].accounts[3].pubkey, referrer_state);
        assert!(referred[2].accounts[3].is_writable);
        assert!(!referred[2]
            .accounts
            .iter()
            .any(|meta| meta.pubkey == KAMINO_MAIN_MARKET_USDC_RESERVE));

        // Referrer states without matching existing borrows fail closed instead
        // of shifting the KLend account parser.
        let mut shifted_referrer = keys.to_vec();
        shifted_referrer.push(referrer_state);
        let mut shifted_writables = writables.to_vec();
        shifted_writables.push(true);
        assert_eq!(
            build_kamino_deposit_sequence(
                &shifted_referrer,
                &shifted_writables,
                &owner,
                &data,
            )
            .err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_976_pure_dispatch_still_fails_closed_without_account_metas() {
        // Pure registry gate must never Ok for kamino even when CPI body is wired.
        let id = pad_adapter_id("kamino");
        let reg = registry_v2_with(id, KAMINO_KLEND_PROGRAM_ID, true);
        assert_eq!(
            dispatch_protocol_adapter(&reg, &id, &KAMINO_KLEND_PROGRAM_ID, true),
            Err(ProgramError::Custom(DayError::AdapterNotWired as u32)),
            "pure dispatch without metas must remain fail-closed"
        );
        assert_eq!(
            dispatch_protocol_adapter(
                &empty_registry_v2(),
                &id,
                &KAMINO_KLEND_PROGRAM_ID,
                true
            ),
            Err(ProgramError::Custom(DayError::NotAllowlisted as u32))
        );
    }


    fn save_main_market_bsol_deposit_keys(router_pda: Pubkey) -> [Pubkey; SAVE_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); SAVE_ACCOUNT_LEN];
        keys[SAVE_IX_SOURCE] = Pubkey::new_unique(); // router BSOL ATA
        keys[SAVE_IX_DEST] = Pubkey::new_unique(); // router cBSOL ATA
        keys[SAVE_IX_RESERVE] = SAVE_MAIN_MARKET_BSOL_RESERVE;
        keys[SAVE_IX_SLOT_3] = SAVE_BSOL_LIQUIDITY_SUPPLY;
        keys[SAVE_IX_SLOT_4] = SAVE_BSOL_COLLATERAL_MINT;
        keys[SAVE_IX_MARKET] = SAVE_MAIN_MARKET;
        keys[SAVE_IX_MARKET_AUTH] = SAVE_MAIN_MARKET_AUTHORITY;
        keys[SAVE_IX_TRANSFER_AUTH] = router_pda;
        // keys[SAVE_IX_CLOCK] = SYSVAR_CLOCK_ID;
        keys[SAVE_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys
    }

    fn save_main_market_bsol_redeem_keys(router_pda: Pubkey) -> [Pubkey; SAVE_ACCOUNT_LEN] {
        let mut keys = save_main_market_bsol_deposit_keys(router_pda);
        // Redeem vault order: collateral mint @3, liquidity supply @4
        keys[SAVE_IX_SLOT_3] = SAVE_BSOL_COLLATERAL_MINT;
        keys[SAVE_IX_SLOT_4] = SAVE_BSOL_LIQUIDITY_SUPPLY;
        keys
    }

    /// Helper: build deposit keys for any Main Market multi-reserve pin.
    fn kamino_main_market_reserve_deposit_keys(
        router_pda: Pubkey,
        reserve: Pubkey,
        mint: Pubkey,
        liq_supply: Pubkey,
        col_mint: Pubkey,
        col_supply: Pubkey,
        farm: Option<Pubkey>,
        liquidity_token_program: Pubkey,
    ) -> [Pubkey; KAMINO_V2_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); KAMINO_V2_ACCOUNT_LEN];
        keys[KAMINO_IX_OWNER] = router_pda;
        keys[KAMINO_IX_OBLIGATION] = Pubkey::new_unique();
        keys[KAMINO_IX_LENDING_MARKET] = KAMINO_MAIN_MARKET;
        keys[KAMINO_IX_LENDING_MARKET_AUTHORITY] = KAMINO_MAIN_MARKET_AUTHORITY;
        keys[KAMINO_IX_RESERVE] = reserve;
        keys[KAMINO_IX_RESERVE_LIQUIDITY_MINT] = mint;
        keys[KAMINO_IX_SLOT_6] = liq_supply;
        keys[KAMINO_IX_SLOT_7] = col_mint;
        keys[KAMINO_IX_SLOT_8] = col_supply;
        keys[KAMINO_IX_USER_LIQUIDITY] = Pubkey::new_unique();
        keys[KAMINO_IX_PLACEHOLDER_COLLATERAL] = KAMINO_KLEND_PROGRAM_ID;
        keys[KAMINO_IX_COLLATERAL_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys[KAMINO_IX_LIQUIDITY_TOKEN_PROGRAM] = liquidity_token_program;
        keys[KAMINO_IX_INSTRUCTION_SYSVAR] = SYSVAR_INSTRUCTIONS_ID;
        keys[KAMINO_IX_OBLIGATION_FARM_USER] = Pubkey::new_unique();
        keys[KAMINO_IX_RESERVE_FARM_STATE] = farm.unwrap_or(KAMINO_KLEND_PROGRAM_ID);
        keys[KAMINO_IX_FARMS_PROGRAM] = KAMINO_FARMS_PROGRAM_ID;
        keys
    }

    #[test]
    fn day_930_kamino_deposit_accounts_accept_main_market_multi_reserve_source_pins() {
        let router = Pubkey::new_unique();
        let pairs = [
            (
                KAMINO_MAIN_MARKET_USDC_RESERVE,
                KAMINO_USDC_MINT,
                KAMINO_USDC_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_USDC_RESERVE_COLLATERAL_MINT,
                KAMINO_USDC_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_USDC_RESERVE_FARM_STATE),
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_SOL_RESERVE,
                KAMINO_SOL_MINT,
                KAMINO_SOL_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_SOL_RESERVE_COLLATERAL_MINT,
                KAMINO_SOL_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_SOL_RESERVE_FARM_STATE),
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_USDT_RESERVE,
                KAMINO_USDT_MINT,
                KAMINO_USDT_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_USDT_RESERVE_COLLATERAL_MINT,
                KAMINO_USDT_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_USDT_RESERVE_FARM_STATE),
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_PYUSD_RESERVE,
                KAMINO_PYUSD_MINT,
                KAMINO_PYUSD_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_PYUSD_RESERVE_COLLATERAL_MINT,
                KAMINO_PYUSD_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_PYUSD_RESERVE_FARM_STATE),
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_JITOSOL_RESERVE,
                KAMINO_JITOSOL_MINT,
                KAMINO_JITOSOL_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_JITOSOL_RESERVE_COLLATERAL_MINT,
                KAMINO_JITOSOL_RESERVE_COLLATERAL_SUPPLY,
                None,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_MSOL_RESERVE,
                KAMINO_MSOL_MINT,
                KAMINO_MSOL_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_MSOL_RESERVE_COLLATERAL_MINT,
                KAMINO_MSOL_RESERVE_COLLATERAL_SUPPLY,
                None,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_BSOL_RESERVE,
                KAMINO_BSOL_MINT,
                KAMINO_BSOL_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_BSOL_RESERVE_COLLATERAL_MINT,
                KAMINO_BSOL_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_BSOL_RESERVE_FARM_STATE),
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_JUPSOL_RESERVE,
                KAMINO_JUPSOL_MINT,
                KAMINO_JUPSOL_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_JUPSOL_RESERVE_COLLATERAL_MINT,
                KAMINO_JUPSOL_RESERVE_COLLATERAL_SUPPLY,
                None,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_USDG_RESERVE,
                KAMINO_USDG_MINT,
                KAMINO_USDG_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_USDG_RESERVE_COLLATERAL_MINT,
                KAMINO_USDG_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_USDG_RESERVE_FARM_STATE),
                TOKEN_2022_PROGRAM_ID,
            ),
            (
                KAMINO_MAIN_MARKET_CBBTC_RESERVE,
                KAMINO_CBBTC_MINT,
                KAMINO_CBBTC_RESERVE_LIQUIDITY_SUPPLY,
                KAMINO_CBBTC_RESERVE_COLLATERAL_MINT,
                KAMINO_CBBTC_RESERVE_COLLATERAL_SUPPLY,
                Some(KAMINO_CBBTC_RESERVE_FARM_STATE),
                SPL_TOKEN_PROGRAM_ID,
            ),
        ];
        for (reserve, mint, liq, col_mint, col_supply, farm, liq_tp) in pairs {
            let keys = kamino_main_market_reserve_deposit_keys(
                router, reserve, mint, liq, col_mint, col_supply, farm, liq_tp,
            );
            assert_eq!(
                assert_kamino_deposit_accounts(&keys),
                Ok(()),
                "deposit pin for reserve {}",
                reserve
            );
            // Withdraw vault order: collateral supply @6, liquidity supply @8
            let mut withdraw = keys;
            withdraw[KAMINO_IX_SLOT_6] = col_supply;
            withdraw[KAMINO_IX_SLOT_8] = liq;
            assert_eq!(
                assert_kamino_withdraw_accounts(&withdraw),
                Ok(()),
                "withdraw pin for reserve {}",
                reserve
            );
            // Cross-reserve mash: reserve A with USDC vaults → fail closed (unless USDC).
            if reserve != KAMINO_MAIN_MARKET_USDC_RESERVE {
                let mut mash = keys;
                mash[KAMINO_IX_SLOT_6] = KAMINO_USDC_RESERVE_LIQUIDITY_SUPPLY;
                mash[KAMINO_IX_SLOT_8] = KAMINO_USDC_RESERVE_COLLATERAL_SUPPLY;
                assert_eq!(
                    assert_kamino_deposit_accounts(&mash),
                    Err(ProgramError::Custom(DayError::InvalidAccount as u32)),
                    "cross-reserve vault mash must fail for {}",
                    reserve
                );
            }
        }
        assert!(kamino_main_market_reserve_vault_pins(&KAMINO_MAIN_MARKET_USDC_RESERVE).is_some());
        assert!(kamino_main_market_reserve_vault_pins(&KAMINO_MAIN_MARKET_SOL_RESERVE).is_some());
        assert!(kamino_main_market_reserve_vault_pins(&Pubkey::new_unique()).is_none());
    }

    #[test]
    fn day_978_save_cpi_body_wired_flag() {
        assert!(
            save_cpi_body_wired() && SAVE_CPI_BODY_WIRED,
            "save CPI body must report wired after DAY-978 implementation"
        );
    }

    #[test]
    fn day_978_save_program_pin_fail_closed() {
        assert_eq!(
            assert_save_program_pin(&SAVE_PROGRAM_ID, true),
            Ok(())
        );
        assert_eq!(
            assert_save_program_pin(&SAVE_PROGRAM_ID, false),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramNotExecutable as u32
            ))
        );
        assert_eq!(
            assert_save_program_pin(&Pubkey::default(), true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
        assert_eq!(
            assert_save_program_pin(&JUPITER_LEND_EARN_PROGRAM_ID, true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
    }

    #[test]
    fn day_978_save_deposit_accounts_accept_main_market_bsol() {
        let router = Pubkey::new_unique();
        let keys = save_main_market_bsol_deposit_keys(router);
        assert_eq!(assert_save_deposit_accounts(&keys), Ok(()));
    }

    fn save_main_market_reserve_deposit_keys(
        router_pda: Pubkey,
        reserve: Pubkey,
        liq_supply: Pubkey,
        col_mint: Pubkey,
    ) -> [Pubkey; SAVE_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); SAVE_ACCOUNT_LEN];
        keys[SAVE_IX_SOURCE] = Pubkey::new_unique();
        keys[SAVE_IX_DEST] = Pubkey::new_unique();
        keys[SAVE_IX_RESERVE] = reserve;
        keys[SAVE_IX_SLOT_3] = liq_supply;
        keys[SAVE_IX_SLOT_4] = col_mint;
        keys[SAVE_IX_MARKET] = SAVE_MAIN_MARKET;
        keys[SAVE_IX_MARKET_AUTH] = SAVE_MAIN_MARKET_AUTHORITY;
        keys[SAVE_IX_TRANSFER_AUTH] = router_pda;
        // keys[SAVE_IX_CLOCK] = SYSVAR_CLOCK_ID;
        keys[SAVE_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys
    }

    #[test]
    fn day_930_save_deposit_accounts_accept_main_market_multi_reserve_source_pins() {
        let router = Pubkey::new_unique();
        let pairs = [
            (
                SAVE_MAIN_MARKET_USDC_RESERVE,
                SAVE_USDC_LIQUIDITY_SUPPLY,
                SAVE_USDC_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_USDT_RESERVE,
                SAVE_USDT_LIQUIDITY_SUPPLY,
                SAVE_USDT_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_SOL_RESERVE,
                SAVE_SOL_LIQUIDITY_SUPPLY,
                SAVE_SOL_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_MSOL_RESERVE,
                SAVE_MSOL_LIQUIDITY_SUPPLY,
                SAVE_MSOL_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_JITOSOL_RESERVE,
                SAVE_JITOSOL_LIQUIDITY_SUPPLY,
                SAVE_JITOSOL_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_JUPSOL_RESERVE,
                SAVE_JUPSOL_LIQUIDITY_SUPPLY,
                SAVE_JUPSOL_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_CBBTC_RESERVE,
                SAVE_CBBTC_LIQUIDITY_SUPPLY,
                SAVE_CBBTC_COLLATERAL_MINT,
            ),
            (
                SAVE_MAIN_MARKET_JSOL_RESERVE,
                SAVE_JSOL_LIQUIDITY_SUPPLY,
                SAVE_JSOL_COLLATERAL_MINT,
            ),
        ];
        for (reserve, liq, col) in pairs {
            let keys = save_main_market_reserve_deposit_keys(router, reserve, liq, col);
            assert_eq!(
                assert_save_deposit_accounts(&keys),
                Ok(()),
                "deposit pin for reserve {}",
                reserve
            );
            // Redeem vault order: collateral mint @3, liquidity supply @4
            let mut redeem = keys;
            redeem[SAVE_IX_SLOT_3] = col;
            redeem[SAVE_IX_SLOT_4] = liq;
            assert_eq!(
                assert_save_redeem_accounts(&redeem),
                Ok(()),
                "redeem pin for reserve {}",
                reserve
            );
            // Cross-reserve mash: reserve A with vaults of B → fail closed.
            let mut mash = keys;
            mash[SAVE_IX_SLOT_3] = SAVE_BSOL_LIQUIDITY_SUPPLY;
            mash[SAVE_IX_SLOT_4] = SAVE_BSOL_COLLATERAL_MINT;
            if reserve != SAVE_MAIN_MARKET_BSOL_RESERVE {
                assert_eq!(
                    assert_save_deposit_accounts(&mash),
                    Err(ProgramError::Custom(DayError::InvalidAccount as u32)),
                    "cross-reserve mash must fail for {}",
                    reserve
                );
            }
        }
        // Vault pin resolver covers all Main Market source pins + bSOL.
        assert!(save_main_market_reserve_vault_pins(&SAVE_MAIN_MARKET_BSOL_RESERVE).is_some());
        assert!(save_main_market_reserve_vault_pins(&SAVE_MAIN_MARKET_USDC_RESERVE).is_some());
        assert!(save_main_market_reserve_vault_pins(&Pubkey::new_unique()).is_none());
        // Non-Main reserves are not Main Market vault pins (market-aware API).
        assert!(save_main_market_reserve_vault_pins(&SAVE_SCARCOIN_STCC_RESERVE).is_none());
        assert!(save_main_market_reserve_vault_pins(&SAVE_LST_DAI_RESERVE).is_none());
        assert!(save_reserve_market_vault_pins(&SAVE_SCARCOIN_STCC_RESERVE).is_some());
        assert!(save_reserve_market_vault_pins(&SAVE_LST_DAI_RESERVE).is_some());
    }

    fn save_non_main_reserve_deposit_keys(
        router_pda: Pubkey,
        market: Pubkey,
        market_auth: Pubkey,
        reserve: Pubkey,
        liq_supply: Pubkey,
        col_mint: Pubkey,
    ) -> [Pubkey; SAVE_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); SAVE_ACCOUNT_LEN];
        keys[SAVE_IX_SOURCE] = Pubkey::new_unique();
        keys[SAVE_IX_DEST] = Pubkey::new_unique();
        keys[SAVE_IX_RESERVE] = reserve;
        keys[SAVE_IX_SLOT_3] = liq_supply;
        keys[SAVE_IX_SLOT_4] = col_mint;
        keys[SAVE_IX_MARKET] = market;
        keys[SAVE_IX_MARKET_AUTH] = market_auth;
        keys[SAVE_IX_TRANSFER_AUTH] = router_pda;
        // keys[SAVE_IX_CLOCK] = SYSVAR_CLOCK_ID;
        keys[SAVE_IX_TOKEN_PROGRAM] = SPL_TOKEN_PROGRAM_ID;
        keys
    }

    #[test]
    fn day_930_save_deposit_accounts_accept_non_main_scarcion_lst_source_pins() {
        let router = Pubkey::new_unique();
        let pairs = [
            (
                SAVE_SCARCOIN_MARKET,
                SAVE_SCARCOIN_MARKET_AUTHORITY,
                SAVE_SCARCOIN_STCC_RESERVE,
                SAVE_STCC_LIQUIDITY_SUPPLY,
                SAVE_STCC_COLLATERAL_MINT,
            ),
            (
                SAVE_LST_MARKET,
                SAVE_LST_MARKET_AUTHORITY,
                SAVE_LST_DAI_RESERVE,
                SAVE_DAI_LIQUIDITY_SUPPLY,
                SAVE_DAI_COLLATERAL_MINT,
            ),
        ];
        for (market, auth, reserve, liq, col) in pairs {
            let keys =
                save_non_main_reserve_deposit_keys(router, market, auth, reserve, liq, col);
            assert_eq!(
                assert_save_deposit_accounts(&keys),
                Ok(()),
                "deposit pin for non-main reserve {}",
                reserve
            );
            let mut redeem = keys;
            redeem[SAVE_IX_SLOT_3] = col;
            redeem[SAVE_IX_SLOT_4] = liq;
            assert_eq!(
                assert_save_redeem_accounts(&redeem),
                Ok(()),
                "redeem pin for non-main reserve {}",
                reserve
            );
            // Cross-market mash: correct reserve vaults but Main Market slot → fail.
            let mut mash = keys;
            mash[SAVE_IX_MARKET] = SAVE_MAIN_MARKET;
            mash[SAVE_IX_MARKET_AUTH] = SAVE_MAIN_MARKET_AUTHORITY;
            assert_eq!(
                assert_save_deposit_accounts(&mash),
                Err(ProgramError::Custom(DayError::InvalidAccount as u32)),
                "cross-market mash must fail for {}",
                reserve
            );
            // Cross-reserve mash within non-main set.
            let mut mash2 = keys;
            mash2[SAVE_IX_SLOT_3] = SAVE_BSOL_LIQUIDITY_SUPPLY;
            mash2[SAVE_IX_SLOT_4] = SAVE_BSOL_COLLATERAL_MINT;
            assert_eq!(
                assert_save_deposit_accounts(&mash2),
                Err(ProgramError::Custom(DayError::InvalidAccount as u32)),
                "cross-reserve mash must fail for {}",
                reserve
            );
        }
    }

    #[test]
    fn day_978_save_deposit_accounts_reject_wrong_market_or_unbound() {
        let router = Pubkey::new_unique();
        let keys = save_main_market_bsol_deposit_keys(router);
        // Wrong length: truncated account list must fail closed.
        assert_eq!(
            assert_save_deposit_accounts(&keys[..8]),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        let mut bad = keys;
        bad[SAVE_IX_RESERVE] = Pubkey::new_unique();
        assert_eq!(
            assert_save_deposit_accounts(&bad),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        let mut bad2 = keys;
        bad2[SAVE_IX_MARKET] = Pubkey::new_unique();
        assert_eq!(
            assert_save_deposit_accounts(&bad2),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        let mut bad3 = keys;
        bad3[SAVE_IX_SLOT_3] = Pubkey::new_unique();
        assert_eq!(
            assert_save_deposit_accounts(&bad3),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        let mut bad4 = keys;
        bad4[SAVE_IX_SOURCE] = Pubkey::default();
        assert_eq!(
            assert_save_deposit_accounts(&bad4),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Redeem vault order must fail deposit pin
        let redeem = save_main_market_bsol_redeem_keys(router);
        // deposit expects liquidity@3 collateral@4; redeem has collateral@3 liquidity@4
        // when collateral mint != liquidity supply, deposit pin fails on slot3
        assert_eq!(
            assert_save_deposit_accounts(&redeem),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_978_save_redeem_accounts_and_ix_data() {
        let router = Pubkey::new_unique();
        let redeem = save_main_market_bsol_redeem_keys(router);
        assert_eq!(assert_save_redeem_accounts(&redeem), Ok(()));
        let deposit = save_main_market_bsol_deposit_keys(router);
        assert_eq!(
            assert_save_redeem_accounts(&deposit),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        let data = encode_save_deposit_ix_data(50_000);
        assert_eq!(assert_save_deposit_ix_data(&data), Ok(50_000));
        assert_eq!(data[0], SAVE_DEPOSIT_TAG);
        assert_eq!(
            assert_save_deposit_ix_data(&encode_save_deposit_ix_data(0)),
            Err(ProgramError::Custom(DayError::ZeroAmount as u32))
        );
        assert_eq!(
            assert_save_redeem_ix_data(&data),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );
        let rdata = encode_save_redeem_ix_data(12_345);
        assert_eq!(assert_save_redeem_ix_data(&rdata), Ok(12_345));
        assert_eq!(rdata[0], SAVE_REDEEM_TAG);
    }

    #[test]
    fn day_978_save_build_ix_requires_router_transfer_authority() {
        let router = Pubkey::new_unique();
        let keys = save_main_market_bsol_deposit_keys(router);
        let writables = save_deposit_default_writables();
        let data = encode_save_deposit_ix_data(50_000);

        let ix = build_save_deposit_instruction(&keys, &writables, &router, &data)
            .expect("valid structure must build");
        assert_eq!(ix.program_id, SAVE_PROGRAM_ID);
        assert_eq!(ix.accounts.len(), SAVE_ACCOUNT_LEN);
        assert!(
            ix.accounts[SAVE_IX_TRANSFER_AUTH].is_signer,
            "router PDA must be CPI signer at transfer-authority slot"
        );
        assert_eq!(ix.accounts[SAVE_IX_TRANSFER_AUTH].pubkey, router);
        assert_eq!(ix.data, data.to_vec());

        let other = Pubkey::new_unique();
        assert_eq!(
            build_save_deposit_instruction(&keys, &writables, &other, &data).err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );

        let rkeys = save_main_market_bsol_redeem_keys(router);
        let rwritables = save_redeem_default_writables();
        let rdata = encode_save_redeem_ix_data(1_000);
        let rix = build_save_redeem_instruction(&rkeys, &rwritables, &router, &rdata)
            .expect("valid redeem structure must build");
        assert_eq!(rix.program_id, SAVE_PROGRAM_ID);
        assert_eq!(rix.accounts[SAVE_IX_TRANSFER_AUTH].pubkey, router);
    }

    #[test]
    fn day_978_pure_dispatch_still_fails_closed_without_account_metas() {
        let id = pad_adapter_id("save");
        let reg = registry_v2_with(id, SAVE_PROGRAM_ID, true);
        assert_eq!(
            dispatch_protocol_adapter(&reg, &id, &SAVE_PROGRAM_ID, true),
            Err(ProgramError::Custom(DayError::AdapterNotWired as u32)),
            "pure dispatch without metas must remain fail-closed"
        );
        assert_eq!(
            dispatch_protocol_adapter(&empty_registry_v2(), &id, &SAVE_PROGRAM_ID, true),
            Err(ProgramError::Custom(DayError::NotAllowlisted as u32))
        );
    }

    fn empty_registry_v2() -> AdapterRegistryV2 {
        AdapterRegistryV2 {
            discriminator: REGISTRY_V2_DISCRIMINATOR,
            authority: PROTOCOL_AUTHORITY,
            count: 0,
            adapters: [AdapterMetaV2::default(); MAX_ADAPTERS],
        }
    }

    fn registry_v2_with(
        id: [u8; ADAPTER_ID_LEN],
        protocol_program: Pubkey,
        active: bool,
    ) -> AdapterRegistryV2 {
        let mut adapters = [AdapterMetaV2::default(); MAX_ADAPTERS];
        adapters[0] = AdapterMetaV2 {
            adapter_id: id,
            chain: *b"solana\0\0",
            protocol_program,
            active,
            used: true,
        };
        AdapterRegistryV2 {
            discriminator: REGISTRY_V2_DISCRIMINATOR,
            authority: PROTOCOL_AUTHORITY,
            count: 1,
            adapters,
        }
    }

    #[test]
    fn day_930_marginfi_cpi_body_wired_flag() {
        assert!(
            marginfi_cpi_body_wired() && MARGINFI_CPI_BODY_WIRED,
            "marginfi CPI body must report wired after DAY-930 implementation"
        );
    }

    #[test]
    fn day_930_marginfi_program_pin_fail_closed() {
        assert_eq!(
            assert_marginfi_program_pin(&MARGINFI_PROGRAM_ID, true),
            Ok(())
        );
        assert_eq!(
            assert_marginfi_program_pin(&MARGINFI_PROGRAM_ID, false),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramNotExecutable as u32
            ))
        );
        assert_eq!(
            assert_marginfi_program_pin(&Pubkey::default(), true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
        assert_eq!(
            assert_marginfi_program_pin(&JUPITER_LEND_EARN_PROGRAM_ID, true),
            Err(ProgramError::Custom(
                DayError::ProtocolProgramMismatch as u32
            ))
        );
    }

    fn marginfi_deposit_keys(
        router: Pubkey,
        bank: Pubkey,
        liq_vault: Pubkey,
        token_program: Pubkey,
    ) -> [Pubkey; MARGINFI_DEPOSIT_ACCOUNT_LEN] {
        let mut keys = [Pubkey::default(); MARGINFI_DEPOSIT_ACCOUNT_LEN];
        keys[MARGINFI_IX_GROUP] = MARGINFI_GROUP;
        keys[MARGINFI_IX_ACCOUNT] = Pubkey::new_unique();
        keys[MARGINFI_IX_AUTHORITY] = router;
        keys[MARGINFI_IX_BANK] = bank;
        keys[MARGINFI_IX_SIGNER_TOKEN] = Pubkey::new_unique();
        keys[MARGINFI_IX_LIQUIDITY_VAULT] = liq_vault;
        keys[MARGINFI_IX_TOKEN_PROGRAM] = token_program;
        keys
    }

    #[test]
    fn day_930_marginfi_deposit_accounts_accept_multi_bank_source_pins() {
        let router = Pubkey::new_unique();
        let pairs = [
            (
                MARGINFI_USDC_BANK,
                MARGINFI_USDC_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_USDT_BANK,
                MARGINFI_USDT_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_SOL_BANK,
                MARGINFI_SOL_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_MSOL_BANK,
                MARGINFI_MSOL_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_JITOSOL_BANK,
                MARGINFI_JITOSOL_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_JUPSOL_BANK,
                MARGINFI_JUPSOL_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_BSOL_BANK,
                MARGINFI_BSOL_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_PYUSD_BANK,
                MARGINFI_PYUSD_LIQUIDITY_VAULT,
                TOKEN_2022_PROGRAM_ID,
            ),
            (
                MARGINFI_CBBTC_BANK,
                MARGINFI_CBBTC_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_USDS_BANK,
                MARGINFI_USDS_LIQUIDITY_VAULT,
                SPL_TOKEN_PROGRAM_ID,
            ),
            (
                MARGINFI_USDG_BANK,
                MARGINFI_USDG_LIQUIDITY_VAULT,
                TOKEN_2022_PROGRAM_ID,
            ),
        ];
        for (bank, vault, tp) in pairs {
            let keys = marginfi_deposit_keys(router, bank, vault, tp);
            assert_eq!(
                assert_marginfi_deposit_accounts(&keys),
                Ok(()),
                "deposit pin for bank {}",
                bank
            );
            // Cross-bank mash: bank A with USDC vault → fail closed (unless USDC).
            if bank != MARGINFI_USDC_BANK {
                let mut mash = keys;
                mash[MARGINFI_IX_LIQUIDITY_VAULT] = MARGINFI_USDC_LIQUIDITY_VAULT;
                assert_eq!(
                    assert_marginfi_deposit_accounts(&mash),
                    Err(ProgramError::Custom(DayError::InvalidAccount as u32)),
                    "cross-bank vault mash must fail for {}",
                    bank
                );
            }
        }
        assert!(marginfi_bank_vault_pins(&MARGINFI_USDC_BANK).is_some());
        assert!(marginfi_bank_vault_pins(&MARGINFI_SOL_BANK).is_some());
        assert!(marginfi_bank_vault_pins(&Pubkey::new_unique()).is_none());
    }

    #[test]
    fn day_930_marginfi_deposit_ix_data_and_build() {
        let data = encode_marginfi_deposit_ix_data(50_000);
        assert_eq!(assert_marginfi_deposit_ix_data(&data), Ok(50_000));
        // 16-byte form (disc+amount, no bool) also accepted.
        let mut short = [0u8; 16];
        short.copy_from_slice(&data[0..16]);
        assert_eq!(assert_marginfi_deposit_ix_data(&short), Ok(50_000));
        assert_eq!(
            assert_marginfi_deposit_ix_data(&encode_marginfi_deposit_ix_data(0)),
            Err(ProgramError::Custom(DayError::ZeroAmount as u32))
        );
        let mut bad = data;
        bad[0] ^= 0xff;
        assert_eq!(
            assert_marginfi_deposit_ix_data(&bad),
            Err(ProgramError::Custom(DayError::InvalidInstruction as u32))
        );

        let router = Pubkey::new_unique();
        let keys = marginfi_deposit_keys(
            router,
            MARGINFI_USDC_BANK,
            MARGINFI_USDC_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        );
        let w = marginfi_deposit_default_writables();
        let ix = build_marginfi_deposit_instruction(&keys, &w, &router, &data)
            .expect("build usdc deposit");
        assert_eq!(ix.program_id, MARGINFI_PROGRAM_ID);
        assert_eq!(ix.accounts.len(), MARGINFI_DEPOSIT_ACCOUNT_LEN);
        assert!(ix.accounts[MARGINFI_IX_AUTHORITY].is_signer);
        assert_eq!(
            build_marginfi_deposit_instruction(
                &keys,
                &w,
                &Pubkey::new_unique(),
                &data
            )
            .err(),
            Some(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong account count fails closed.
        assert_eq!(
            assert_marginfi_deposit_accounts(&keys[..6]),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Wrong group fails closed.
        let mut bad_group = keys;
        bad_group[MARGINFI_IX_GROUP] = Pubkey::new_unique();
        assert_eq!(
            assert_marginfi_deposit_accounts(&bad_group),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Token-2022 bank must not accept Tokenkeg.
        let pyusd = marginfi_deposit_keys(
            router,
            MARGINFI_PYUSD_BANK,
            MARGINFI_PYUSD_LIQUIDITY_VAULT,
            SPL_TOKEN_PROGRAM_ID,
        );
        assert_eq!(
            assert_marginfi_deposit_accounts(&pyusd),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
        fn day_915_missing_registry_entry_fails_closed() {
        let empty = empty_registry_v2();
        let program = Pubkey::new_unique();
        // No adapters registered → NotAllowlisted (not a silent Ok).
        assert_eq!(
            dispatch_protocol_adapter(&empty, &pad_adapter_id("kamino"), &program, true),
            Err(ProgramError::Custom(DayError::NotAllowlisted as u32))
        );
        assert_eq!(
            dispatch_protocol_adapter(&empty, &pad_adapter_id("unknown-xyz"), &program, true),
            Err(ProgramError::Custom(DayError::NotAllowlisted as u32))
        );
    }

    #[test]
    fn day_915_registered_known_arms_fail_adapter_not_wired() {
        let program = Pubkey::new_unique();
        for tag in ["kamino", "marginfi", "jupiter-lend", "save"] {
            let id = pad_adapter_id(tag);
            let reg = registry_v2_with(id, program, true);
            assert_eq!(
                dispatch_protocol_adapter(&reg, &id, &program, true),
                Err(ProgramError::Custom(DayError::AdapterNotWired as u32)),
                "arm {tag} must fail closed AdapterNotWired"
            );
        }
    }

    #[test]
    fn day_915_unknown_registered_adapter_still_not_wired() {
        // Even if authority registers an id we have no arm for, CPI fails closed.
        let program = Pubkey::new_unique();
        let id = pad_adapter_id("marinade");
        let reg = registry_v2_with(id, program, true);
        assert_eq!(classify_adapter_dispatch(&id), AdapterDispatchArm::Unknown);
        assert_eq!(
            dispatch_protocol_adapter(&reg, &id, &program, true),
            Err(ProgramError::Custom(DayError::AdapterNotWired as u32))
        );
    }

    #[test]
    fn day_915_no_dispatch_path_returns_ok() {
        // Exhaustive: empty registry, inactive, mismatch, not-executable, wired-stub.
        let program = Pubkey::new_unique();
        let id = pad_adapter_id("kamino");
        let cases: Vec<Result<AdapterDispatchArm, ProgramError>> = vec![
            dispatch_protocol_adapter(&empty_registry_v2(), &id, &program, true),
            dispatch_protocol_adapter(&registry_v2_with(id, program, false), &id, &program, true),
            dispatch_protocol_adapter(
                &registry_v2_with(id, program, true),
                &id,
                &Pubkey::new_unique(),
                true,
            ),
            dispatch_protocol_adapter(&registry_v2_with(id, program, true), &id, &program, false),
            dispatch_protocol_adapter(&registry_v2_with(id, program, true), &id, &program, true),
        ];
        for (i, result) in cases.into_iter().enumerate() {
            assert!(
                result.is_err(),
                "case {i}: dispatch must never silently succeed, got {result:?}"
            );
        }
    }

    // DAY-763: non-managed profit fee placeholder + cap math. Lives in the
    // SEPARATE RouterFeeConfig PDA (never grows the 49-byte YieldRouter layout).
    fn fee_config_with(bps: u16, cap: u64, enabled: bool) -> RouterFeeConfig {
        RouterFeeConfig {
            discriminator: FEE_CONFIG_DISCRIMINATOR,
            authority: PROTOCOL_AUTHORITY,
            treasury: PROTOCOL_AUTHORITY,
            profit_fee_bps: bps,
            profit_fee_cap_usd_micros: cap,
            profit_fee_enabled: enabled,
            bump: 255,
        }
    }

    #[test]
    fn profit_fee_off_charges_zero() {
        // Placeholder default: preset 1% / $10 but disabled => 0 on any profit.
        let c = fee_config_with(
            PROFIT_FEE_BPS_DEFAULT,
            PROFIT_FEE_CAP_USD_MICROS_DEFAULT,
            false,
        );
        assert_eq!(c.quote_profit_fee(1_000_000_000), 0);
        assert_eq!(c.quote_profit_fee(0), 0);
        assert_eq!(PROFIT_FEE_BPS_DEFAULT, 100);
        assert_eq!(PROFIT_FEE_CAP_USD_MICROS_DEFAULT, 10_000_000);
        assert!(PROFIT_FEE_BPS_DEFAULT <= MAX_PROFIT_FEE_BPS);
    }

    #[test]
    fn legacy_profit_fee_math_is_not_money_path_authority() {
        // Retained only to decode/display an existing config. The instruction
        // gate and forward path reject enabled configs and caller assertions.
        let c = fee_config_with(100, 10_000_000, true); // 1%, $10 cap, ON
        assert_eq!(c.quote_profit_fee(100_000_000), 1_000_000); // 1% of $100 = $1
        assert_eq!(c.quote_profit_fee(1_000_000_000), 10_000_000); // 1% of $1000 = $10 (at cap)
        assert_eq!(c.quote_profit_fee(2_000_000_000), 10_000_000); // capped from $20 to $10
        assert_eq!(c.quote_profit_fee(0), 0);
    }

    #[test]
    fn day_1105_forward_withdraw_opens_only_for_native_owner_bound_kamino() {
        // A payout ATA alone does not bind router-held receipts, so Jupiter
        // remains closed. KLend's native obligation owner is an independent,
        // protocol-enforced binding and may use the direct-owner path.
        assert_eq!(
            assert_forward_withdraw_owner_binding(&pad_adapter_id("jupiter-lend")),
            Err(ProgramError::Custom(
                DayError::ForwardWithdrawOwnerBindingNotWired as u32
            ))
        );
        assert_eq!(
            assert_forward_withdraw_owner_binding(&pad_adapter_id("kamino")),
            Ok(())
        );
    }

    #[test]
    fn protocol_authority_is_treasury() {
        assert_eq!(
            PROTOCOL_AUTHORITY.to_string(),
            "A975vAJtcEB3saDWXwa3YQmM18qe3DCg83T41KWb9eg6"
        );
    }

    #[test]
    fn pda_seeds_stable() {
        assert_eq!(REGISTRY_SEED, b"adapter_registry");
        assert_eq!(REGISTRY_V2_SEED, b"adapter_registry_v2");
        assert_eq!(ROUTER_SEED, b"yield_router");
        let (reg, reg_bump) = Pubkey::find_program_address(&[REGISTRY_SEED], &crate::id());
        let (rtr, rtr_bump) = Pubkey::find_program_address(&[ROUTER_SEED], &crate::id());
        assert_eq!(
            reg.to_string(),
            "HYv3GFyfYBiz3SPTkPodKghzccARc66pQMnaWpj9uxn6"
        );
        assert_eq!(
            rtr.to_string(),
            "5baGJsjUWLfTTrADAakHHES4grTn7P6vf4NqZyWtocV"
        );
        assert_eq!(reg_bump, 255);
        assert_eq!(rtr_bump, 254);
    }

    // ── DAY-962/980 peer-custody receiver scaffold (Sui executor analog) ─────
    #[test]
    fn day_962_origin_record_fail_closed() {
        let owner = [7u8; 32];
        let chain = *b"base\0\0\0\0\0\0\0\0\0\0\0\0";
        let asset = *b"USDC\0\0\0\0\0\0\0\0\0\0\0\0";
        // Valid record accepted.
        assert_eq!(assert_origin_record_valid(&owner, &chain, &asset), Ok(()));
        // Zero owner rejected (unattributable/unrecoverable).
        assert_eq!(
            assert_origin_record_valid(&[0u8; 32], &chain, &asset),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Empty chain label rejected.
        assert_eq!(
            assert_origin_record_valid(&owner, &[0u8; ORIGIN_CHAIN_LEN], &asset),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
        // Empty asset label rejected.
        assert_eq!(
            assert_origin_record_valid(&owner, &chain, &[0u8; ORIGIN_ASSET_LEN]),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32))
        );
    }

    #[test]
    fn day_962_handoff_pdas_distinct_and_deterministic() {
        let tx1 = [1u8; 32];
        let tx2 = [2u8; 32];
        let (pos1, _) = handoff_position_pda(&crate::id(), &tx1);
        let (cus1, _) = handoff_custody_pda(&crate::id(), &tx1);
        let (pos1b, _) = handoff_position_pda(&crate::id(), &tx1);
        let (pos2, _) = handoff_position_pda(&crate::id(), &tx2);
        // Deterministic per day_tx_id.
        assert_eq!(pos1, pos1b);
        // Position and custody PDAs are different accounts (isolated custody).
        assert_ne!(pos1, cus1);
        // Distinct day_tx_id → distinct position (no cross-position aliasing).
        assert_ne!(pos1, pos2);
    }

    #[test]
    fn day_962_handoff_position_len_frozen() {
        // Layout must stay frozen once any position exists on-chain.
        assert_eq!(
            HandoffPosition::LEN,
            8 + 4 + 32 + ORIGIN_CHAIN_LEN + 32 + ORIGIN_ASSET_LEN + ADAPTER_ID_LEN + 32 + 24
        );
        assert_eq!(HandoffPosition::STATE_UNINIT, 0);
        assert_eq!(HandoffPosition::STATE_ACTIVE, 1);
        assert_eq!(HandoffPosition::STATE_EXITED, 2);
        assert_eq!(HANDOFF_POSITION_DISCRIMINATOR, 0x4441595f484e4450u64);
        assert_eq!(HANDOFF_POSITION_SEED, b"handoff_position");
        assert_eq!(HANDOFF_CUSTODY_SEED, b"handoff_custody");
    }

    #[test]
    fn day_962_handoff_receive_params_roundtrip() {
        let p = HandoffReceiveParams {
            day_tx_id: [9u8; 32],
            origin_chain: *b"base\0\0\0\0\0\0\0\0\0\0\0\0",
            origin_owner: [3u8; 32],
            origin_asset: *b"USDC\0\0\0\0\0\0\0\0\0\0\0\0",
            adapter_id: pad_adapter_id("jupiter-lend"),
            claimed_principal_micros: 1_000_000,
            min_return_micros: 990_000,
        };
        let bytes = borsh::to_vec(&p).unwrap();
        let back = HandoffReceiveParams::try_from_slice(&bytes).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn day_962_handoff_position_serialize_fits_len_and_roundtrips() {
        let pos = HandoffPosition {
            discriminator: HANDOFF_POSITION_DISCRIMINATOR,
            version: HANDOFF_POSITION_VERSION,
            bump: 251,
            custody_bump: 250,
            state: HandoffPosition::STATE_ACTIVE,
            day_tx_id: [5u8; 32],
            origin_chain: *b"base\0\0\0\0\0\0\0\0\0\0\0\0",
            origin_owner: [6u8; 32],
            origin_asset: *b"USDC\0\0\0\0\0\0\0\0\0\0\0\0",
            adapter_id: pad_adapter_id("jupiter-lend"),
            adapter_program: JUPITER_LEND_EARN_PROGRAM_ID,
            principal_micros: 1_000_000,
            remaining_principal_micros: 1_000_000,
            min_return_micros: 995_000,
        };
        let bytes = borsh::to_vec(&pos).unwrap();
        // Serialized length must fit the allocated account (frozen layout).
        assert!(bytes.len() <= HandoffPosition::LEN, "serialized {} > LEN {}", bytes.len(), HandoffPosition::LEN);
        let back = HandoffPosition::try_from_slice(&bytes).unwrap();
        assert_eq!(pos, back);
        // A wrong discriminator must be rejectable by load path logic.
        let mut bad = pos.clone();
        bad.discriminator = 0;
        assert_ne!(bad.discriminator, HANDOFF_POSITION_DISCRIMINATOR);
    }

    #[test]
    fn day_962_origin_owner_pubkey_from_position_is_deterministic() {
        // The exit destination pubkey is derived ONLY from stored origin_owner
        // bytes — never a caller argument. A Solana-origin owner round-trips.
        let owner = Pubkey::new_unique();
        let mut arr = [0u8; 32];
        arr.copy_from_slice(owner.as_ref());
        assert_eq!(Pubkey::new_from_array(arr), owner);
    }

    #[test]
    fn day_962_origin_owner_zero_rejected_any_chain_accepted() {
        let base_chain = *b"base\0\0\0\0\0\0\0\0\0\0\0\0";
        // All-zero owner is rejected (unattributable/unpayable).
        assert_eq!(
            assert_solana_origin_owner(&[0u8; 32], &base_chain),
            Err(ProgramError::Custom(DayError::InvalidAccount as u32)),
            "zero owner must be rejected"
        );
        // Owner-direct model: origin_chain is audit metadata (e.g. "base"); a real
        // Solana wallet owner is accepted for a base-origin arrival. Exit-payability
        // is enforced at exit by assert_spl_token_owner (not curve math here — that
        // links curve25519 and overflows the SBF stack).
        let mut owner = [0u8; 32];
        owner.copy_from_slice(PROTOCOL_AUTHORITY.as_ref());
        assert_eq!(assert_solana_origin_owner(&owner, &base_chain), Ok(()));
        assert_eq!(assert_solana_origin_owner(&owner, &ORIGIN_CHAIN_SOLANA), Ok(()));
    }
}
