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
    /// DAY-795: pass-through forwarder WITHDRAW. Router CPIs the protocol withdraw
    /// so funds return THROUGH the router, then forwards the measured token delta
    /// to the owner. The legacy caller-provided amount/profit fields are retained
    /// for instruction compatibility but must both be zero; neither is truth.
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

pub const FEE_CONFIG_SEED: &[u8] = b"router_fee_config";
pub const FEE_CONFIG_DISCRIMINATOR: u64 = 0x4441_595f_4643_4701; // "DAY_FCG\x01"

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
    let ix = DayInstruction::try_from_slice(instruction_data)
        .map_err(|_| ProgramError::from(DayError::InvalidInstruction))?;

    match ix {
        DayInstruction::Initialize => process_initialize(program_id, accounts),
        DayInstruction::RegisterAdapter { adapter_id, chain } => {
            process_register_adapter(program_id, accounts, adapter_id, chain)
        }
        DayInstruction::SetActive { adapter_id, active } => {
            process_set_active(program_id, accounts, adapter_id, active)
        }
        DayInstruction::PlanDeposit {
            adapter_id,
            amount_micros,
            auto_yield_enabled,
        } => process_plan_deposit(
            program_id,
            accounts,
            adapter_id,
            amount_micros,
            auto_yield_enabled,
        ),
        DayInstruction::PlanWithdraw {
            adapter_id,
            amount_micros,
        } => process_plan_withdraw(program_id, accounts, adapter_id, amount_micros),
        DayInstruction::PlanHarvestSkim {
            adapter_id,
            gross_yield_micros,
        } => process_plan_harvest_skim(program_id, accounts, adapter_id, gross_yield_micros),
        DayInstruction::SetProfitFee {
            profit_fee_bps,
            profit_fee_cap_usd_micros,
            enabled,
        } => process_set_profit_fee(
            program_id,
            accounts,
            profit_fee_bps,
            profit_fee_cap_usd_micros,
            enabled,
        ),
        DayInstruction::ForwardDeposit {
            adapter_id,
            amount_micros,
            protocol_ix_data,
        } => process_forward_deposit(
            program_id,
            accounts,
            adapter_id,
            amount_micros,
            protocol_ix_data,
        ),
        DayInstruction::ForwardWithdraw {
            adapter_id,
            amount_micros,
            realized_profit_usd_micros,
            protocol_ix_data,
        } => process_forward_withdraw(
            program_id,
            accounts,
            adapter_id,
            amount_micros,
            realized_profit_usd_micros,
            protocol_ix_data,
        ),
        DayInstruction::InitFeeConfig => process_init_fee_config(program_id, accounts),
        DayInstruction::InitRegistryV2 => process_init_registry_v2(program_id, accounts),
        DayInstruction::RegisterAdapterV2 {
            adapter_id,
            chain,
            protocol_program,
        } => process_register_adapter_v2(program_id, accounts, adapter_id, chain, protocol_program),
        DayInstruction::SetActiveV2 { adapter_id, active } => {
            process_set_active_v2(program_id, accounts, adapter_id, active)
        }
        DayInstruction::AuthenticatedCommandScaffold => {
            process_authenticated_command_scaffold(program_id, accounts)
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

fn load_router(ai: &AccountInfo, program_id: &Pubkey) -> Result<YieldRouter, ProgramError> {
    if ai.owner != program_id {
        return Err(DayError::InvalidAccount.into());
    }
    let r = YieldRouter::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if r.discriminator != ROUTER_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(r)
}

/// DAY-763: load the SEPARATE RouterFeeConfig PDA (mirrors load_router).
fn load_fee_config(ai: &AccountInfo, program_id: &Pubkey) -> Result<RouterFeeConfig, ProgramError> {
    if ai.owner != program_id {
        return Err(DayError::InvalidAccount.into());
    }
    let c = RouterFeeConfig::try_from_slice(&ai.data.borrow())
        .map_err(|_| ProgramError::from(DayError::InvalidAccount))?;
    if c.discriminator != FEE_CONFIG_DISCRIMINATOR {
        return Err(DayError::InvalidAccount.into());
    }
    Ok(c)
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
/// has `invoke_signed` + DAY-909 pins; kamino/marginfi still placeholders).
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
        | AdapterDispatchArm::Unknown => Err(DayError::AdapterNotWired.into()),
    }
}

/// DAY-915: registry-gated CPI dispatch into a protocol program.
///
/// Callers must load RegistryV2 first. This function re-validates the active
/// adapter → program binding, then matches a per-adapter arm. Every arm fails
/// closed with `AdapterNotWired` until a verified CPI (pinned program ids +
/// DAY-909 market descriptors + account layout) is safe to `invoke_signed`.
///
/// We NEVER fabricate a protocol CPI against an unverified address. Withdraw
/// snapshots the router token account around this call, pays only the positive
/// delta, and rejects legacy caller-provided USD amount/profit surfaces.
fn cpi_protocol_adapter(
    reg: &AdapterRegistryV2,
    adapter_id: &[u8; ADAPTER_ID_LEN],
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    router_signer_seeds: &[&[u8]],
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
            router_signer_seeds,
        ),
        AdapterDispatchArm::Marginfi => cpi_adapter_marginfi(
            protocol_program,
            protocol_accounts,
            protocol_ix_data,
            router_signer_seeds,
        ),
        AdapterDispatchArm::JupiterLend => cpi_adapter_jupiter_lend(
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

/// Kamino Lend placeholder (DAY-915). Registry binding already validated.
/// Residual: exact market/reserve accounts (DAY-909) + invoke_signed.
fn cpi_adapter_kamino(
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    _router_signer_seeds: &[&[u8]],
) -> ProgramResult {
    msg!(
        "DAY CPI arm=kamino program={} accounts={} data_len={} (AdapterNotWired until full CPI)",
        protocol_program.key,
        protocol_accounts.len(),
        protocol_ix_data.len()
    );
    // Refuse to invoke without market-descriptor binding — fail closed.
    let _ = (protocol_program, protocol_accounts, protocol_ix_data);
    Err(DayError::AdapterNotWired.into())
}

/// Marginfi placeholder (DAY-915). Registry binding already validated.
/// Residual: bank/authority metas + invoke_signed.
fn cpi_adapter_marginfi(
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    _router_signer_seeds: &[&[u8]],
) -> ProgramResult {
    msg!(
        "DAY CPI arm=marginfi program={} accounts={} data_len={} (AdapterNotWired until full CPI)",
        protocol_program.key,
        protocol_accounts.len(),
        protocol_ix_data.len()
    );
    let _ = (protocol_program, protocol_accounts, protocol_ix_data);
    Err(DayError::AdapterNotWired.into())
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
    if keys[JUP_LEND_IX_MINT] != JUPITER_LEND_USDC_MINT {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LENDING_ADMIN] != JUPITER_LEND_USDC_LENDING_ADMIN {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LENDING] != JUPITER_LEND_USDC_LENDING {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_FTOKEN_MINT] != JUPITER_LEND_JLUSDC_MINT {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_SUPPLY_RESERVES] != JUPITER_LEND_USDC_SUPPLY_RESERVES {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_SUPPLY_POSITION] != JUPITER_LEND_USDC_SUPPLY_POSITION {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_RATE_MODEL] != JUPITER_LEND_USDC_RATE_MODEL {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_VAULT] != JUPITER_LEND_USDC_VAULT {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LIQUIDITY] != JUPITER_LEND_USDC_LIQUIDITY {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_LIQUIDITY_PROGRAM] != JUPITER_LEND_LIQUIDITY_PROGRAM_ID {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_REWARDS_RATE_MODEL] != JUPITER_LEND_USDC_REWARDS_RATE_MODEL {
        return Err(DayError::InvalidAccount.into());
    }
    if keys[JUP_LEND_IX_TOKEN_PROGRAM] != SPL_TOKEN_PROGRAM_ID {
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

/// Jupiter Lend Earn Deposit CPI (DAY-915). Registry binding already validated
/// by `cpi_protocol_adapter`.
///
/// 1. Assert Earn program pin
/// 2. Bind exact USDC market metas (DAY-909 pins) — reject caller-arbitrary markets
/// 3. Validate deposit disc + amount
/// 4. Require signer slot == yield_router PDA; `invoke_signed` with router seeds
///
/// Residual before money-path GO: SBF upgrade of deployed `7P7PgkV1…`, on-chain
/// InitRegistryV2 + RegisterAdapterV2, mainnet ForwardDeposit simulate.
fn cpi_adapter_jupiter_lend(
    protocol_program: &AccountInfo,
    protocol_accounts: &[AccountInfo],
    protocol_ix_data: &[u8],
    router_signer_seeds: &[&[u8]],
) -> ProgramResult {
    assert_jupiter_lend_program_pin(protocol_program.key, protocol_program.executable)?;

    let keys: Vec<Pubkey> = protocol_accounts.iter().map(|a| *a.key).collect();
    assert_jupiter_lend_deposit_accounts(&keys)?;
    let amount = assert_jupiter_lend_deposit_ix_data(protocol_ix_data)?;

    let router_pda = Pubkey::create_program_address(router_signer_seeds, &id())
        .map_err(|_| ProgramError::InvalidSeeds)?;
    if protocol_accounts[JUP_LEND_IX_SIGNER].key != &router_pda {
        msg!(
            "DAY CPI jupiter-lend signer must be yield_router PDA {} (got {})",
            router_pda,
            protocol_accounts[JUP_LEND_IX_SIGNER].key
        );
        return Err(DayError::InvalidAccount.into());
    }

    let is_writable: Vec<bool> = protocol_accounts.iter().map(|a| a.is_writable).collect();
    let ix = build_jupiter_lend_deposit_instruction(
        &keys,
        &is_writable,
        &router_pda,
        protocol_ix_data,
    )?;

    msg!(
        "DAY CPI arm=jupiter-lend program={} accounts={} amount={} invoke_signed",
        protocol_program.key,
        protocol_accounts.len(),
        amount
    );

    // Router PDA signs the Earn Deposit CPI (DAY money path, not venue-SDK owner path).
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

    // Deposit charges no fee; forward the full principal to the protocol.
    // DAY-915: registry-gated dispatch (re-validates + per-adapter fail-closed arms).
    cpi_protocol_adapter(
        &reg,
        &adapter_id,
        protocol_program,
        &protocol_accounts,
        &protocol_ix_data,
        seeds,
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
        for tag in ["kamino", "marginfi", "jupiter-lend"] {
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
}
