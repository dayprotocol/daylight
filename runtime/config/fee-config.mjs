/**
 * FeeConfig v2 — SSOT for DAY protocol fee parameters.
 *
 * Spec (product SSOT):
 *   docs/critical/FEE-STRUCTURE.md · docs/FEE-STRUCTURE.md
 *   docs/critical/TERMINOLOGY.md · docs/TERMINOLOGY.md
 *   docs/critical/ARCHITECTURE-fees-strategies-routing.md
 *
 * SUPERSEDED:
 *   - flat "protocol_yield_skim 500 bps on all yield"
 *   - DAY taking 30% of the Strategy Lead's 15% performance fee
 *
 * LIVE charges today (mav 2026-07):
 *   - Swap 0.10% + Bridge 0.10% only
 *   - Profit fee exists but OFF (placeholder)
 *   - Deposit / Withdraw LOCKED at 0
 *
 * Not charged / retired as DAY defaults (still resolvable for future / managed products):
 *   - Strategy Lead performance fee — Lead sets per Strategy (no DAY global default)
 *   - Protocol share of Lead fee — retired (DAY takes none)
 *   - Auto Pay transfer fee — product retired
 *   - Gas sponsorship markup — not in the live model
 *   - Routing / x402 fixed fee — advertise-only, not enforced
 *
 * Terminology: Yield Opportunities (leaf), Strategies (allocation policy), Strategy Lead, Guardrails.
 * Keep "vault" only for third-party protocol vaults that are Opportunities (e.g. Morpho vault).
 *
 * Resolution: strategy override → opportunity override → global → off/zero.
 * Money path: fail-closed on invalid bps; never invent secrets or live rates.
 *
 * Copyright (c) 2026 Limitless Labs.
 */

export const FEE_CONFIG_SCHEMA = "day-fee-config.v2";
export const FEE_SCHEDULE_SCHEMA = "day-fee-schedule.v2";
/** @deprecated use FEE_CONFIG_SCHEMA */
export const FEE_CONFIG_SCHEMA_V1 = "day-fee-config.v1";

export const BASIS_POINTS = 10_000;

// ── Product defaults (FeeConfig v2 / docs/critical/FEE-STRUCTURE.md) ─────────

/** @deprecated Flat protocol skim of user residual is SUPERSEDED. Prefer waterfall. */
export const DEFAULT_PROTOCOL_YIELD_SKIM_BPS = 0;

/**
 * Auto Pay remittance — product retired. Global default is 0 / off.
 * Historical product rate when Auto Pay was active: 1% (100 bps).
 */
export const DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS = 0;
/** @deprecated historical Auto Pay rate; not a live charge. */
export const HISTORICAL_AUTO_PAY_TRANSFER_FEE_BPS = 100;

/**
 * Swap fee typical mid (0.10%); range 5–30 bps. LIVE product charge.
 * DAY-954: on-chain SSOT is the deployed protocol fee registry
 * (owner-settable via setProtocolRailFeeConfig). This constant is the
 * off-chain fallback only when RPC/registry lacks the selector — not a
 * pretend hard pin of live chain state.
 */
export const DEFAULT_PROTOCOL_SWAP_FEE_BPS = 10;
export const DEFAULT_SWAP_FEE_MIN_BPS = 5;
export const DEFAULT_SWAP_FEE_MAX_BPS = 30;

/** Bridge fee typical mid (0.10%); range 5–25 bps. LIVE charge. */
export const DEFAULT_PROTOCOL_BRIDGE_FEE_BPS = 10;
export const DEFAULT_BRIDGE_FEE_MIN_BPS = 5;
export const DEFAULT_BRIDGE_FEE_MAX_BPS = 25;

/**
 * Gas sponsorship markup — not charged today. Bounds retained for a
 * future enable. Historical mid was 10% of gas (1000 bps).
 */
export const DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS = 0;
export const DEFAULT_GAS_SPONSOR_MIN_BPS = 500;
export const DEFAULT_GAS_SPONSOR_MAX_BPS = 1500;
/** @deprecated historical gas-sponsor mid; not a live charge. */
export const HISTORICAL_PROTOCOL_GAS_SPONSOR_FEE_BPS = 1000;

/**
 * Strategy Lead performance fee — NO DAY global default.
 * The Lead sets + discloses their own rate when creating a Strategy.
 * Bounds for when a Lead enables one: 10–25% of realized profit.
 * Example / Fund #3 ROI leg uses EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS.
 */
export const DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS = 0;
export const DEFAULT_STRATEGY_PERFORMANCE_FEE_MAX_BPS = 2500;
export const DEFAULT_STRATEGY_PERFORMANCE_FEE_MIN_BPS = 1000;
/** Example Lead rate (15%) for managed products / docs / Fund #3 ROI leg. */
export const EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS = 1500;

/**
 * DAY share of Strategy Lead fee — RETIRED.
 * DAY takes no share of the Lead fee. Bounds retained only for historical
 * resolve paths; global row is disabled at 0.
 */
export const DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS = 0;
export const DEFAULT_PROTOCOL_PERFORMANCE_FEE_MIN_BPS = 0;
export const DEFAULT_PROTOCOL_PERFORMANCE_FEE_MAX_BPS = 4000;
/** @deprecated retired "30% of Lead fee" model. */
export const HISTORICAL_PROTOCOL_PERFORMANCE_FEE_BPS = 3000;

/** Optional management fee off by default; cap 2% AUM annual. */
export const DEFAULT_MANAGEMENT_FEE_BPS_ANNUAL = 0;
export const DEFAULT_MANAGEMENT_FEE_MAX_BPS_ANNUAL = 200;

/** Keeper reward (ops) — not user product FeeConfig row; off by default. */
export const DEFAULT_KEEPER_REWARD_BPS = 0;

export const DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS = 0;

/**
 * x402-class routing fee — advertise-only / not enforced.
 * Historical advertised rate was $0.001 = 1000 USD micros.
 */
export const DEFAULT_ROUTING_FEE_USD_MICROS = 0;
/** @deprecated historical x402 advertise rate; not charged. */
export const HISTORICAL_ROUTING_FEE_USD_MICROS = 1000;

// ── Non-managed profit fee — PLACEHOLDER, OFF by default ───────────
//
// Product decision (mav, 2026-07-15): for NON-MANAGED yield opportunities DAY
// charges NO profit fee for now — but the mechanism is wired as an owner-settable
// on-chain variable so it can be turned on later without a code change. Preset
// target when enabled: 1% of realized profit, capped $10. `enabled:false` today
// means 0% is charged. Owner flips enabled=true (and may tune bps/cap within the
// hard bounds) to turn it on. Never charges principal; profit only.
/** Preset profit fee when eventually enabled: 1% of realized profit. */
export const DEFAULT_PROFIT_FEE_BPS = 100;
/** Hard cap the owner cannot exceed for the profit fee (2% = 200 bps). */
export const MAX_PROFIT_FEE_BPS = 200;
/** Preset profit fee dollar cap: $10 = 10_000_000 USD micros. */
export const DEFAULT_PROFIT_FEE_CAP_USD_MICROS = 10_000_000;
/** Profit fee is OFF now (placeholder); flip to true to charge it. */
export const DEFAULT_PROFIT_FEE_ENABLED = false;

/**
 * Global FeeConfig v2 rows — activatable, fixed and/or bps.
 */
export const GLOBAL_FEE_DEFAULTS = Object.freeze({
  routing: Object.freeze({
    enabled: false,
    mode: "fixed",
    bps: 0,
    fixed_usd_micros: DEFAULT_ROUTING_FEE_USD_MICROS,
    fixed_micros: 0,
    base: "x402_or_api_call",
    charged_by: "DAY",
    notes: "advertise_only_not_enforced",
  }),
  swap: Object.freeze({
    enabled: true,
    mode: "bps",
    bps: DEFAULT_PROTOCOL_SWAP_FEE_BPS,
    fixed_micros: 0,
    min_bps: DEFAULT_SWAP_FEE_MIN_BPS,
    max_bps: DEFAULT_SWAP_FEE_MAX_BPS,
    base: "swap_notional_in",
    charged_by: "DAY",
    notes: "third_party_dex_fees_extra",
  }),
  bridge: Object.freeze({
    enabled: true,
    mode: "both",
    bps: DEFAULT_PROTOCOL_BRIDGE_FEE_BPS,
    fixed_micros: 0,
    min_bps: DEFAULT_BRIDGE_FEE_MIN_BPS,
    max_bps: DEFAULT_BRIDGE_FEE_MAX_BPS,
    base: "bridge_notional",
    charged_by: "DAY",
    notes: "third_party_bridge_fees_pass_through",
  }),
  gas_sponsor_markup: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS,
    fixed_micros: 0,
    min_bps: DEFAULT_GAS_SPONSOR_MIN_BPS,
    max_bps: DEFAULT_GAS_SPONSOR_MAX_BPS,
    base: "gas_sponsor_cost",
    charged_by: "DAY",
    notes: "not_charged_today",
  }),
  /**
   * Strategy Lead fee on realized Strategy profit.
   * Global default OFF — Lead sets when creating a Strategy.
   */
  strategy_performance: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS,
    fixed_micros: 0,
    min_bps: 0,
    max_bps: DEFAULT_STRATEGY_PERFORMANCE_FEE_MAX_BPS,
    base: "realized_strategy_profit",
    charged_by: "StrategyLead",
    applies_to: "strategy",
    notes: "lead_sets_per_strategy_no_day_global_default",
  }),
  /**
   * DAY share of Strategy Lead performance fee — RETIRED.
   * DAY takes no share of the Lead fee.
   */
  protocol_performance: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS,
    fixed_micros: 0,
    min_bps: 0,
    max_bps: DEFAULT_PROTOCOL_PERFORMANCE_FEE_MAX_BPS,
    base: "strategy_lead_performance_fee_amount",
    charged_by: "DAY",
    applies_to: "strategy",
    superseded: true,
    notes: "retired_day_share_of_lead_fee",
  }),
  management: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_MANAGEMENT_FEE_BPS_ANNUAL,
    bps_annual: DEFAULT_MANAGEMENT_FEE_BPS_ANNUAL,
    fixed_micros: 0,
    max_bps: DEFAULT_MANAGEMENT_FEE_MAX_BPS_ANNUAL,
    base: "strategy_aum_annual",
    charged_by: "StrategyLead",
    applies_to: "strategy",
  }),
  auto_pay: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS,
    fixed_micros: 0,
    base: "auto_pay_payout_notional",
    charged_by: "DAY",
    notes: "product_retired",
  }),
  deposit: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS,
    fixed_micros: 0,
    base: "principal",
    charged_by: "DAY",
    locked_off: true,
  }),
  withdraw: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS,
    fixed_micros: 0,
    base: "principal",
    charged_by: "DAY",
    locked_off: true,
  }),
  /**
   * DAY-763 — NON-MANAGED profit fee. PLACEHOLDER, OFF by default (0% charged).
   * When the owner flips `enabled:true`, DAY charges `bps` of realized profit at
   * withdraw, capped at `cap_usd_micros`. Preset target: 1% capped $10. Applies
   * to raw (non-managed) opportunities where there is no Strategy Lead waterfall.
   * Never charges principal. Owner-settable within [0, MAX_PROFIT_FEE_BPS].
   */
  profit_performance: Object.freeze({
    enabled: DEFAULT_PROFIT_FEE_ENABLED, // false — 0% charged now
    mode: "bps_capped",
    bps: DEFAULT_PROFIT_FEE_BPS, // 100 = 1% (preset, not charged while disabled)
    fixed_micros: 0,
    max_bps: MAX_PROFIT_FEE_BPS, // 200 = 2% hard owner ceiling
    cap_usd_micros: DEFAULT_PROFIT_FEE_CAP_USD_MICROS, // $10
    base: "realized_profit",
    charged_by: "DAY",
    applies_to: "non_managed_opportunity",
    notes: "placeholder_off_flip_enabled_to_turn_on_1pct_cap_10usd",
  }),
  /**
   * SUPERSEDED flat skim of user residual. Kept disabled for API compat.
   * Prefer strategy_performance + protocol_performance waterfall.
   */
  protocol_yield_skim: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_PROTOCOL_YIELD_SKIM_BPS,
    fixed_micros: 0,
    base: "realized_harvest_yield",
    charged_by: "DAY",
    superseded: true,
    notes: "superseded_by_strategy_protocol_performance_waterfall",
  }),
  /** Ops keeper cut — not product FeeConfig catalog row; off by default. */
  keeper_reward: Object.freeze({
    enabled: false,
    mode: "bps",
    bps: DEFAULT_KEEPER_REWARD_BPS,
    fixed_micros: 0,
    base: "realized_harvest_yield",
    charged_by: "keeper",
    max_bps: 100,
    notes: "ops_not_product_catalog",
  }),
});

// ── Fund #3 — day-autopilot-safe-plus-roi differentiated perf fee ──
//
// Fund #3 is a two-leg managed fund (ticket DAY-568):
//   • the SAFE / stablecoin leg — principal parked in the top 30d stablecoin
//     Yield Opportunity (same engine as fund #1), and
//   • the ROI-chasing leg — the fund #2 higher-variance allocation.
//
// Product decision: DAY takes **0%** of the stablecoin-leg yield but
// **15%** of the ROI leg's realized profit. This is expressed purely through
// FeeConfig strategy overrides (NOT a hard-coded skim), so it exercises and
// proves the strategy-override → opportunity-override → global resolution order.
//
// Each leg is its own Strategy context so `resolveFee`/`getStrategyPerformanceFeeBps`
// resolve independently. The fund id maps to the two leg strategy ids below.
export const FUND3_ID = "day-autopilot-safe-plus-roi";
/** Stablecoin ("safe") leg — 0% strategy performance fee. */
export const FUND3_STABLE_LEG_STRATEGY_ID = "day-autopilot-safe-plus-roi-stable";
/** ROI-chasing leg (fund #2 policy) — 15% strategy performance fee. */
export const FUND3_ROI_LEG_STRATEGY_ID = "day-autopilot-safe-plus-roi-roi";

/** Fund #3 leg selectors accepted by resolveFund3LegFee / fund3LegContext. */
export const FUND3_LEGS = Object.freeze({
  stable: FUND3_STABLE_LEG_STRATEGY_ID,
  safe: FUND3_STABLE_LEG_STRATEGY_ID,
  roi: FUND3_ROI_LEG_STRATEGY_ID,
});

/**
 * Optional per-Strategy overrides (sparse).
 * @type {Readonly<Record<string, Readonly<Record<string, object>>>>}
 */
export const STRATEGY_FEE_OVERRIDES = Object.freeze({
  // Fund #3 stable leg: waive the strategy performance fee entirely (0%).
  // enabled/min are pinned to 0 so the resolved row is internally consistent
  // (not a global-min of 1000 leaking through a waived leg).
  [FUND3_STABLE_LEG_STRATEGY_ID]: Object.freeze({
    strategy_performance: Object.freeze({
      enabled: false,
      bps: 0,
      min_bps: 0,
      base: "realized_strategy_profit_stablecoin_leg",
      notes: "fund3_stable_leg_zero_performance_fee",
    }),
  }),
  // Fund #3 ROI leg: 15% (1500 bps) of realized ROI-leg profit — Lead-style fee
  // for this managed product (not a DAY global default; DAY-818).
  [FUND3_ROI_LEG_STRATEGY_ID]: Object.freeze({
    strategy_performance: Object.freeze({
      enabled: true,
      bps: EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS,
      min_bps: DEFAULT_STRATEGY_PERFORMANCE_FEE_MIN_BPS,
      max_bps: DEFAULT_STRATEGY_PERFORMANCE_FEE_MAX_BPS,
      base: "realized_strategy_profit_roi_leg",
      notes: "fund3_roi_leg_fifteen_pct_performance_fee",
    }),
  }),
});

/**
 * Optional per–Yield Opportunity overrides (sparse).
 * @type {Readonly<Record<string, Readonly<Record<string, object>>>>}
 */
export const OPPORTUNITY_FEE_OVERRIDES = Object.freeze({});

/**
 * Validate integer bps in 0..10000. Fail-closed.
 * @param {unknown} raw
 * @param {string} field
 * @returns {number}
 */
export function assertBps(raw, field = "bps") {
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n < 0 || n > BASIS_POINTS) {
    const err = new Error(`${field} must be integer 0..${BASIS_POINTS}; got ${raw}`);
    err.code = "INVALID_FEE_BPS";
    err.status = 400;
    throw err;
  }
  return n;
}

/**
 * Resolve a named fee row with override order:
 *   strategy → opportunity → global → disabled zero
 *
 * @param {string} feeName key of GLOBAL_FEE_DEFAULTS
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 */
export function resolveFee(feeName, ctx = {}) {
  const name = String(feeName || "").trim();
  const global = GLOBAL_FEE_DEFAULTS[name];
  if (!global) {
    const err = new Error(`unknown fee name: ${feeName}`);
    err.code = "UNKNOWN_FEE";
    err.status = 400;
    throw err;
  }

  const strategyId =
    ctx.strategyId != null && String(ctx.strategyId).trim() !== ""
      ? String(ctx.strategyId).trim().toLowerCase()
      : null;
  const opportunityId =
    ctx.opportunityId != null && String(ctx.opportunityId).trim() !== ""
      ? String(ctx.opportunityId).trim().toLowerCase()
      : null;

  let source = "global";
  /** @type {object} */
  let row = { ...global };

  if (opportunityId && OPPORTUNITY_FEE_OVERRIDES[opportunityId]?.[name]) {
    row = { ...row, ...OPPORTUNITY_FEE_OVERRIDES[opportunityId][name] };
    source = "opportunity";
  }
  if (strategyId && STRATEGY_FEE_OVERRIDES[strategyId]?.[name]) {
    row = { ...row, ...STRATEGY_FEE_OVERRIDES[strategyId][name] };
    source = "strategy";
  }

  // Principal rails locked off — never allow override to charge principal.
  if (name === "deposit" || name === "withdraw") {
    row = {
      ...row,
      enabled: false,
      bps: 0,
      fixed_micros: 0,
      locked_off: true,
    };
  }

  // Cap strategy / protocol performance to protocol max.
  if (name === "strategy_performance" && row.max_bps != null && row.bps != null) {
    const maxBps = assertBps(row.max_bps, `${name}.max_bps`);
    const bpsRaw = assertBps(row.bps, `${name}.bps`);
    if (bpsRaw > maxBps) row = { ...row, bps: maxBps };
  }
  if (name === "protocol_performance" && row.max_bps != null && row.bps != null) {
    const maxBps = assertBps(row.max_bps, `${name}.max_bps`);
    const bpsRaw = assertBps(row.bps, `${name}.bps`);
    if (bpsRaw > maxBps) row = { ...row, bps: maxBps };
  }

  const bps = row.bps != null ? assertBps(row.bps, `${name}.bps`) : 0;
  const fixedMicros = Number(row.fixed_micros || 0);
  const fixedUsdMicros = Number(row.fixed_usd_micros || 0);
  const bpsAnnual =
    row.bps_annual != null ? assertBps(row.bps_annual, `${name}.bps_annual`) : bps;

  const effectivelyEnabled =
    row.locked_off === true || row.superseded === true
      ? false
      : row.enabled === false
        ? false
        : bps > 0 || fixedMicros > 0 || fixedUsdMicros > 0 || (name === "management" && bpsAnnual > 0);

  return {
    name,
    enabled: effectivelyEnabled,
    mode: String(row.mode || "bps"),
    bps,
    fixed_micros: fixedMicros,
    ...(row.fixed_usd_micros != null ? { fixed_usd_micros: fixedUsdMicros } : {}),
    ...(name === "management" ? { bps_annual: bpsAnnual } : {}),
    source,
    charged_by: row.charged_by,
    base: row.base,
    ...(row.locked_off != null ? { locked_off: Boolean(row.locked_off) } : {}),
    ...(row.superseded != null ? { superseded: Boolean(row.superseded) } : {}),
    ...(row.notes != null ? { notes: String(row.notes) } : {}),
    ...(row.max_bps != null ? { max_bps: Number(row.max_bps) } : {}),
    ...(row.min_bps != null ? { min_bps: Number(row.min_bps) } : {}),
    ...(row.applies_to != null ? { applies_to: String(row.applies_to) } : {}),
  };
}

/**
 * @deprecated Flat yield skim of user residual is SUPERSEDED (always 0 unless legacy override).
 * Use applyStrategyPerformanceWaterfall for Strategies.
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 * @returns {number}
 */
export function getYieldSkimBps(ctx = {}) {
  const row = resolveFee("protocol_yield_skim", ctx);
  // Superseded: never charge flat residual skim by default.
  if (row.superseded || !row.enabled) return 0;
  return assertBps(row.bps, "protocol_yield_skim.bps");
}

export function getAutoPayFeeBps(ctx = {}) {
  const row = resolveFee("auto_pay", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps, "auto_pay.bps");
}

/**
 * Protocol swap fee bps. Prefer on-chain protocol fee registry reading when
 * callers pass `ctx.onChainSwapFeeBps`. Otherwise FeeConfig table /
 * product default 10.
 * @param {{ onChainSwapFeeBps?: number|null, strategyId?: string, opportunityId?: string }} [ctx]
 */
export function getSwapFeeBps(ctx = {}) {
  if (ctx.onChainSwapFeeBps != null) {
    const n = Number(ctx.onChainSwapFeeBps);
    if (
      Number.isSafeInteger(n) &&
      n >= DEFAULT_SWAP_FEE_MIN_BPS &&
      n <= DEFAULT_SWAP_FEE_MAX_BPS
    ) {
      return n;
    }
    // Invalid on-chain reading → fall through to table/default (fail closed, no invent).
  }
  const row = resolveFee("swap", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps, "swap.bps");
}

export function getBridgeFeeBps(ctx = {}) {
  const row = resolveFee("bridge", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps, "bridge.bps");
}

/**
 * Gas-sponsor markup bps. Prefer on-chain protocolGasSponsorFeeBps when
 * `ctx.onChainGasSponsorFeeBps` is provided. Default OFF (0).
 * @param {{ onChainGasSponsorFeeBps?: number|null, strategyId?: string, opportunityId?: string }} [ctx]
 */
export function getGasSponsorFeeBps(ctx = {}) {
  if (ctx.onChainGasSponsorFeeBps != null) {
    const n = Number(ctx.onChainGasSponsorFeeBps);
    if (Number.isSafeInteger(n) && n >= 0 && n <= DEFAULT_GAS_SPONSOR_MAX_BPS) {
      // Enabled path: on-chain owner may set 0..max even while schedule row is OFF.
      return n;
    }
  }
  const row = resolveFee("gas_sponsor_markup", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps, "gas_sponsor_markup.bps");
}

export function getRoutingFeeUsdMicros(ctx = {}) {
  const row = resolveFee("routing", ctx);
  if (!row.enabled) return 0;
  return Number(row.fixed_usd_micros || 0);
}

export function getStrategyPerformanceFeeBps(ctx = {}) {
  const row = resolveFee("strategy_performance", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps, "strategy_performance.bps");
}

export function getProtocolPerformanceFeeBps(ctx = {}) {
  const row = resolveFee("protocol_performance", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps, "protocol_performance.bps");
}

/**
 * DAY-763 — resolved non-managed profit fee (placeholder). Returns the bps,
 * the $ cap (USD micros), and whether it is currently enabled. While disabled
 * the effective charge is 0 regardless of bps.
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 * @returns {{ enabled: boolean, bps: number, capUsdMicros: number }}
 */
export function getProfitFeeConfig(ctx = {}) {
  const row = resolveFee("profit_performance", ctx);
  const bps = row.bps != null ? assertBps(row.bps, "profit_performance.bps") : 0;
  const maxBps = row.max_bps != null ? assertBps(row.max_bps, "profit_performance.max_bps") : MAX_PROFIT_FEE_BPS;
  return {
    enabled: row.enabled === true,
    bps: Math.min(bps, maxBps),
    capUsdMicros: Number(row.cap_usd_micros ?? DEFAULT_PROFIT_FEE_CAP_USD_MICROS),
  };
}

/**
 * DAY-763 — compute the non-managed profit fee on realized profit, applying the
 * $ cap. Returns 0 while the placeholder is disabled (current product state).
 * Never charges principal — caller passes realized PROFIT only.
 * @param {bigint|number|string} realizedProfitMicros profit (not principal)
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 * @returns {{ feeMicros: string, bps: number, capUsdMicros: number, enabled: boolean, capped: boolean }}
 */
export function computeProfitFee(realizedProfitMicros, ctx = {}) {
  const { enabled, bps, capUsdMicros } = getProfitFeeConfig(ctx);
  const profit = BigInt(realizedProfitMicros || 0);
  if (profit < 0n) {
    throw Object.assign(new Error("realized profit must be non-negative"), {
      code: "INVALID_REALIZED_PROFIT",
      status: 400,
    });
  }
  if (!enabled || bps === 0 || profit === 0n) {
    return { feeMicros: "0", bps, capUsdMicros, enabled, capped: false };
  }
  const raw = (profit * BigInt(bps)) / BigInt(BASIS_POINTS);
  // cap is in USD micros; profit is in asset micros — treat 1:1 for USD-denominated
  // stables (the non-managed default). Non-USD callers must pass USD-normalized profit.
  const cap = BigInt(capUsdMicros || 0);
  const capped = cap > 0n && raw > cap;
  const feeMicros = capped ? cap : raw;
  return { feeMicros: feeMicros.toString(), bps, capUsdMicros, enabled, capped };
}

export function getManagementFeeBpsAnnual(ctx = {}) {
  const row = resolveFee("management", ctx);
  if (!row.enabled) return 0;
  return assertBps(row.bps_annual ?? row.bps, "management.bps_annual");
}

export function getKeeperRewardBps(ctx = {}) {
  const row = resolveFee("keeper_reward", ctx);
  if (!row.enabled) return 0;
  let bps = assertBps(row.bps, "keeper_reward.bps");
  if (row.max_bps != null) bps = Math.min(bps, assertBps(row.max_bps, "keeper_reward.max_bps"));
  return bps;
}

export function getDepositWithdrawFeeBps() {
  return DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS;
}

/**
 * Strategy performance waterfall (docs/critical/FEE-STRUCTURE.md example).
 *
 * gross profit → Lead strategy_performance_bps → DAY protocol_performance_bps of Lead fee
 * → user residual. Never charges deposit/withdraw. Never invents digests.
 *
 * @param {bigint|number|string} grossProfitMicros
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 */
export function applyStrategyPerformanceWaterfall(grossProfitMicros, ctx = {}) {
  const gross = BigInt(grossProfitMicros || 0);
  if (gross < 0n) {
    const err = new Error("gross profit must be non-negative");
    err.code = "INVALID_GROSS_PROFIT";
    err.status = 400;
    throw err;
  }

  const leadBps = getStrategyPerformanceFeeBps(ctx);
  const protocolOfLeadBps = getProtocolPerformanceFeeBps(ctx);

  const leadFee = (gross * BigInt(leadBps)) / BigInt(BASIS_POINTS);
  const protocolFromLead = (leadFee * BigInt(protocolOfLeadBps)) / BigInt(BASIS_POINTS);
  const leadNet = leadFee - protocolFromLead;
  const userResidual = gross - leadFee;

  return {
    schemaVersion: "day-strategy-performance-waterfall.v1",
    grossProfitMicros: gross.toString(),
    strategyPerformanceFeeBps: leadBps,
    protocolPerformanceFeeBps: protocolOfLeadBps,
    strategyLeadFeeMicros: leadFee.toString(),
    protocolShareOfLeadFeeMicros: protocolFromLead.toString(),
    strategyLeadNetMicros: leadNet.toString(),
    userResidualMicros: userResidual.toString(),
    // Effective DAY take of gross (for disclosure only — base is Lead fee)
    effectiveProtocolOfGrossBps:
      gross === 0n
        ? 0
        : Number((protocolFromLead * BigInt(BASIS_POINTS)) / gross),
    notes: [
      "protocol_fee_is_share_of_lead_fee_not_second_user_skim",
      "deposit_withdraw_locked_0",
      "yield_opportunity_leaf_has_no_strategy_performance_unless_strategy_context",
    ],
    principal: "never",
  };
}

// ── Fund #3 per-leg helpers ───────────────────────────────────────

/**
 * Normalize a fund #3 leg selector to its Strategy id.
 * Accepts a leg key ("stable"|"safe"|"roi") or a full leg strategy id.
 * @param {string} leg
 * @returns {string}
 */
export function fund3LegStrategyId(leg) {
  const raw = String(leg || "").trim().toLowerCase();
  if (raw === FUND3_STABLE_LEG_STRATEGY_ID || raw === FUND3_ROI_LEG_STRATEGY_ID) {
    return raw;
  }
  const mapped = FUND3_LEGS[raw];
  if (!mapped) {
    const err = new Error(
      `unknown fund #3 leg: ${leg} (expected stable|safe|roi or a leg strategy id)`,
    );
    err.code = "UNKNOWN_FUND3_LEG";
    err.status = 400;
    throw err;
  }
  return mapped;
}

/**
 * FeeConfig resolution context for a fund #3 leg (feeds resolveFee / waterfall).
 * @param {string} leg "stable" | "safe" | "roi" | a leg strategy id
 * @param {{ opportunityId?: string|null }} [ctx]
 * @returns {{ strategyId: string, opportunityId: string|null }}
 */
export function fund3LegContext(leg, ctx = {}) {
  return {
    strategyId: fund3LegStrategyId(leg),
    opportunityId:
      ctx.opportunityId != null && String(ctx.opportunityId).trim() !== ""
        ? String(ctx.opportunityId).trim()
        : null,
  };
}

/**
 * Resolve the strategy performance fee (bps) for one leg of fund #3.
 * Configured (not hard-coded): 0 bps stable leg, 1500 bps ROI leg, via
 * STRATEGY_FEE_OVERRIDES → strategy override resolution order.
 * @param {string} leg "stable" | "safe" | "roi" | a leg strategy id
 * @param {{ opportunityId?: string|null }} [ctx]
 * @returns {number}
 */
export function getFund3LegPerformanceFeeBps(leg, ctx = {}) {
  return getStrategyPerformanceFeeBps(fund3LegContext(leg, ctx));
}

/**
 * Apply the full performance waterfall to one fund #3 leg's realized profit.
 * @param {bigint|number|string} grossProfitMicros
 * @param {string} leg "stable" | "safe" | "roi" | a leg strategy id
 * @param {{ opportunityId?: string|null }} [ctx]
 */
export function applyFund3LegWaterfall(grossProfitMicros, leg, ctx = {}) {
  return applyStrategyPerformanceWaterfall(
    grossProfitMicros,
    fund3LegContext(leg, ctx),
  );
}

/**
 * Combined disclosure for fund #3 — proves per-leg differentiation
 * (0% stable / 15% ROI) resolves from FeeConfig, plus a blended split for a
 * given stable/ROI gross-profit pair.
 * @param {{ stableProfitMicros?: bigint|number|string, roiProfitMicros?: bigint|number|string, opportunityId?: string|null }} [ctx]
 */
export function fund3FeeDisclosure(ctx = {}) {
  const opportunityId = ctx.opportunityId ?? null;
  const stableBps = getFund3LegPerformanceFeeBps("stable", { opportunityId });
  const roiBps = getFund3LegPerformanceFeeBps("roi", { opportunityId });

  const stableProfit = BigInt(ctx.stableProfitMicros ?? 0);
  const roiProfit = BigInt(ctx.roiProfitMicros ?? 0);
  const stableWaterfall = applyFund3LegWaterfall(stableProfit, "stable", {
    opportunityId,
  });
  const roiWaterfall = applyFund3LegWaterfall(roiProfit, "roi", { opportunityId });

  const totalGross = stableProfit + roiProfit;
  const totalLeadFee =
    BigInt(stableWaterfall.strategyLeadFeeMicros) +
    BigInt(roiWaterfall.strategyLeadFeeMicros);

  return {
    schemaVersion: "day-fund3-fee-disclosure.v1",
    fundId: FUND3_ID,
    legs: {
      stable: {
        strategyId: FUND3_STABLE_LEG_STRATEGY_ID,
        strategyPerformanceFeeBps: stableBps,
        source: resolveFee("strategy_performance", {
          strategyId: FUND3_STABLE_LEG_STRATEGY_ID,
        }).source,
        waterfall: stableWaterfall,
      },
      roi: {
        strategyId: FUND3_ROI_LEG_STRATEGY_ID,
        strategyPerformanceFeeBps: roiBps,
        source: resolveFee("strategy_performance", {
          strategyId: FUND3_ROI_LEG_STRATEGY_ID,
        }).source,
        waterfall: roiWaterfall,
      },
    },
    blendedGrossProfitMicros: totalGross.toString(),
    blendedStrategyLeadFeeMicros: totalLeadFee.toString(),
    blendedEffectiveLeadOfGrossBps:
      totalGross === 0n
        ? 0
        : Number((totalLeadFee * BigInt(BASIS_POINTS)) / totalGross),
    notes: [
      "fund3_stable_leg_zero_performance_fee",
      "fund3_roi_leg_fifteen_pct_performance_fee",
      "resolved_via_feeconfig_strategy_override_not_hardcoded_skim",
      "principal_never_charged",
      "deposit_withdraw_locked_0",
    ],
    principal: "never",
  };
}

/**
 * Fail-closed guard: product-locked FeeConfig v2 defaults must not drift.
 * @throws {Error}
 */
export function assertFeeConfigLocked() {
  if (DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS !== 0) {
    throw Object.assign(new Error("principal deposit/withdraw fee must be 0"), {
      code: "PRINCIPAL_FEE_FORBIDDEN",
      status: 500,
    });
  }
  // DAY-818: only swap + bridge are live DAY charges at the global schedule.
  if (DEFAULT_PROTOCOL_SWAP_FEE_BPS !== 10) {
    throw Object.assign(
      new Error(
        `DEFAULT_PROTOCOL_SWAP_FEE_BPS must be 10 (0.10%); got ${DEFAULT_PROTOCOL_SWAP_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_PROTOCOL_BRIDGE_FEE_BPS !== 10) {
    throw Object.assign(
      new Error(
        `DEFAULT_PROTOCOL_BRIDGE_FEE_BPS must be 10 (0.10%); got ${DEFAULT_PROTOCOL_BRIDGE_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS !== 0) {
    throw Object.assign(
      new Error(
        `DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS must be 0 (product retired); got ${DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS !== 0) {
    throw Object.assign(
      new Error(
        `DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS must be 0 (Lead sets; no DAY global default); got ${DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS !== 0) {
    throw Object.assign(
      new Error(
        `DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS must be 0 (retired DAY share of Lead); got ${DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS !== 0) {
    throw Object.assign(
      new Error(
        `DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS must be 0 (not charged); got ${DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_ROUTING_FEE_USD_MICROS !== 0) {
    throw Object.assign(
      new Error(
        `DEFAULT_ROUTING_FEE_USD_MICROS must be 0 (advertise-only); got ${DEFAULT_ROUTING_FEE_USD_MICROS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_PROTOCOL_YIELD_SKIM_BPS !== 0) {
    throw Object.assign(
      new Error("flat protocol_yield_skim must be 0 (superseded)"),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  // DAY-763: non-managed profit fee is a PLACEHOLDER — must be OFF (0 charged)
  // until the product explicitly turns it on. Preset target 1% / $10 within bounds.
  if (DEFAULT_PROFIT_FEE_ENABLED !== false) {
    throw Object.assign(
      new Error("non-managed profit fee must be disabled (placeholder) by default"),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (DEFAULT_PROFIT_FEE_BPS > MAX_PROFIT_FEE_BPS) {
    throw Object.assign(
      new Error(`profit fee preset ${DEFAULT_PROFIT_FEE_BPS} exceeds cap ${MAX_PROFIT_FEE_BPS}`),
      { code: "FEE_CAP_DRIFT", status: 500 },
    );
  }
  if (getProfitFeeConfig().enabled !== false) {
    throw Object.assign(
      new Error("resolved non-managed profit fee must be disabled now"),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (getDepositWithdrawFeeBps() !== 0) {
    throw Object.assign(new Error("deposit/withdraw must resolve to 0"), {
      code: "PRINCIPAL_FEE_FORBIDDEN",
      status: 500,
    });
  }
  if (getAutoPayFeeBps() !== 0) {
    throw Object.assign(new Error("resolved auto_pay fee must be 0 bps (product retired)"), {
      code: "FEE_CONSTANT_DRIFT",
      status: 500,
    });
  }
  if (getStrategyPerformanceFeeBps() !== 0) {
    throw Object.assign(
      new Error("resolved global strategy performance fee must be 0 (Lead sets per Strategy)"),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (getProtocolPerformanceFeeBps() !== 0) {
    throw Object.assign(
      new Error("resolved protocol performance fee must be 0 (DAY takes no share of Lead)"),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (getGasSponsorFeeBps() !== 0) {
    throw Object.assign(new Error("resolved gas sponsor fee must be 0 (not charged)"), {
      code: "FEE_CONSTANT_DRIFT",
      status: 500,
    });
  }
  if (getRoutingFeeUsdMicros() !== 0) {
    throw Object.assign(new Error("resolved routing fee must be 0 (advertise-only)"), {
      code: "FEE_CONSTANT_DRIFT",
      status: 500,
    });
  }
  if (getSwapFeeBps() !== 10 || getBridgeFeeBps() !== 10) {
    throw Object.assign(
      new Error("swap and bridge must resolve to 10 bps each (only live DAY charges)"),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  if (getYieldSkimBps() !== 0) {
    throw Object.assign(new Error("flat yield skim must resolve to 0 (superseded)"), {
      code: "FEE_CONSTANT_DRIFT",
      status: 500,
    });
  }
  // Cap invariants
  if (DEFAULT_STRATEGY_PERFORMANCE_FEE_MAX_BPS > 2500) {
    throw Object.assign(new Error("strategy performance cap must be ≤ 2500"), {
      code: "FEE_CAP_DRIFT",
      status: 500,
    });
  }
  if (EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS !== 1500) {
    throw Object.assign(
      new Error(
        `EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS must stay 1500 for managed examples; got ${EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS}`,
      ),
      { code: "FEE_CONSTANT_DRIFT", status: 500 },
    );
  }
  // Fund #3 differentiated performance fee must resolve per-leg:
  // 0 bps on the stablecoin/safe leg, 1500 bps (15%) on the ROI leg.
  if (getFund3LegPerformanceFeeBps("stable") !== 0) {
    throw Object.assign(
      new Error("fund #3 stable leg performance fee must resolve to 0 bps"),
      { code: "FUND3_FEE_DRIFT", status: 500 },
    );
  }
  if (getFund3LegPerformanceFeeBps("roi") !== EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS) {
    throw Object.assign(
      new Error(
        `fund #3 ROI leg performance fee must resolve to ${EXAMPLE_STRATEGY_LEAD_PERFORMANCE_FEE_BPS} bps`,
      ),
      { code: "FUND3_FEE_DRIFT", status: 500 },
    );
  }
}

/**
 * Compact schedule map (status / plans / legacy clients).
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 */
export function dayFeeSchedule(ctx = {}) {
  assertFeeConfigLocked();
  const strategyPerf = getStrategyPerformanceFeeBps(ctx);
  const protocolPerf = getProtocolPerformanceFeeBps(ctx);
  const autoPay = getAutoPayFeeBps(ctx);
  const swap = getSwapFeeBps(ctx);
  const gas = getGasSponsorFeeBps(ctx);
  const bridge = getBridgeFeeBps(ctx);
  const keeper = getKeeperRewardBps(ctx);
  const routingUsd = getRoutingFeeUsdMicros(ctx);
  const mgmt = getManagementFeeBpsAnnual(ctx);
  const flatSkim = getYieldSkimBps(ctx);
  const profitFee = getProfitFeeConfig(ctx);

  return {
    // v2 primary rails
    strategy_performance_fee_bps: strategyPerf,
    protocol_performance_fee_bps: protocolPerf,
    management_fee_bps_annual: mgmt,
    auto_pay_transfer_fee_bps: autoPay,
    protocol_swap_fee_bps: swap,
    protocol_bridge_fee_bps: bridge,
    protocol_gas_sponsor_fee_bps: gas,
    routing_fee_usd_micros: routingUsd,
    deposit_fee_bps: 0,
    withdraw_fee_bps: 0,
    // DAY-763 non-managed profit fee (placeholder — enabled:false => 0 charged now)
    profit_fee_enabled: profitFee.enabled,
    profit_fee_bps: profitFee.enabled ? profitFee.bps : 0,
    profit_fee_cap_usd_micros: profitFee.capUsdMicros,
    keeper_reward_bps: keeper,
    // legacy aliases (compat — flat skim superseded)
    protocol_yield_skim_bps: flatSkim,
    performance_fee_bps: strategyPerf,
    day_share_of_leader_fee_bps: protocolPerf,
    notes: [
      "fee_config_v2",
      "flat_protocol_yield_skim_superseded",
      "day818_live_charges_swap_and_bridge_only",
      "strategy_performance_lead_sets_no_day_global_default",
      "protocol_share_of_lead_fee_retired",
      "deposit_withdraw_locked_0",
      "auto_pay_product_retired",
      "routing_advertise_only_not_enforced",
      "ssot_docs_critical_fee_structure",
    ],
  };
}

/**
 * Full public fee schedule for GET /api/day/fees (and FE /fees page).
 * @param {{ strategyId?: string|null, opportunityId?: string|null }} [ctx]
 */
export function publicFeeSchedule(ctx = {}) {
  assertFeeConfigLocked();
  const strategyId =
    ctx.strategyId != null && String(ctx.strategyId).trim() !== ""
      ? String(ctx.strategyId).trim()
      : null;
  const opportunityId =
    ctx.opportunityId != null && String(ctx.opportunityId).trim() !== ""
      ? String(ctx.opportunityId).trim()
      : null;

  const compact = dayFeeSchedule({ strategyId, opportunityId });
  const feeNames = Object.keys(GLOBAL_FEE_DEFAULTS);
  /** @type {Record<string, object>} */
  const fees = {};
  for (const name of feeNames) {
    fees[name] = resolveFee(name, { strategyId, opportunityId });
  }

  // Example waterfall under CURRENT global defaults (Lead fee 0, DAY share 0).
  // Managed Strategies may set a Lead fee per strategy; DAY takes no share.
  const example = applyStrategyPerformanceWaterfall(100_000_000n, {
    strategyId,
    opportunityId,
  });

  return {
    schemaVersion: FEE_SCHEDULE_SCHEMA,
    feeConfigSchema: FEE_CONFIG_SCHEMA,
    product: "DAY",
    surface: "public_fee_schedule",
    ssot: "runtime/config/fee-config.mjs",
    docs: [
      "docs/critical/FEE-STRUCTURE.md",
      "docs/FEE-STRUCTURE.md",
      "docs/critical/TERMINOLOGY.md",
      "docs/TERMINOLOGY.md",
    ],
    terminology: {
      yieldOpportunity: "Leaf yield source (Aave/Suilend/Morpho/Kamino/…)",
      strategy: "Allocation policy by Strategy Lead within Guardrails",
      strategyLead: "Creator/operator of a Strategy",
      guardrails: "Published constraints on Strategy routing",
    },
    strategyId,
    opportunityId,
    // v2 camelCase
    strategyPerformanceFeeBps: compact.strategy_performance_fee_bps,
    protocolPerformanceFeeBps: compact.protocol_performance_fee_bps,
    managementFeeBpsAnnual: compact.management_fee_bps_annual,
    autoPayTransferFeeBps: compact.auto_pay_transfer_fee_bps,
    protocolSwapFeeBps: compact.protocol_swap_fee_bps,
    protocolGasSponsorFeeBps: compact.protocol_gas_sponsor_fee_bps,
    protocolBridgeFeeBps: compact.protocol_bridge_fee_bps,
    routingFeeUsdMicros: compact.routing_fee_usd_micros,
    depositFeeBps: 0,
    withdrawFeeBps: 0,
    // DAY-763 non-managed profit fee (placeholder — OFF now; preset 1% cap $10)
    profitFeeEnabled: compact.profit_fee_enabled,
    profitFeeBps: compact.profit_fee_bps,
    profitFeeCapUsdMicros: compact.profit_fee_cap_usd_micros,
    keeperRewardBps: compact.keeper_reward_bps,
    // legacy (superseded flat skim / retired DAY share of Lead)
    protocolYieldSkimBps: compact.protocol_yield_skim_bps,
    performanceFeeBps: compact.strategy_performance_fee_bps,
    dayShareOfLeaderFeeBps: compact.protocol_performance_fee_bps,
    ...compact,
    fees,
    liveCharges: {
      swapBps: compact.protocol_swap_fee_bps,
      bridgeBps: compact.protocol_bridge_fee_bps,
      notes: "only_live_day_charges_today",
    },
    waterfall: {
      model: "lead_sets_strategy_performance_day_takes_no_share",
      order: [
        "gross_realized_strategy_profit",
        "strategy_performance_fee_to_lead_if_set",
        "user_residual",
        "rails_swap_bridge_on_entry_rebalance",
      ],
      principal: "never",
      depositWithdraw: 0,
      flatProtocolYieldSkim: "superseded",
      dayShareOfLeadFee: "retired",
      exampleMicros: example,
    },
    placeholders: {
      swap: "protocol_swap_fee_bps + third_party_dex_pass_through",
      bridge: "protocol_bridge_fee_bps + third_party_bridge_pass_through",
      routing: "advertise_only_not_enforced",
    },
    notes: [
      "fee_config_v2_ssot",
      "day818_live_charges_swap_and_bridge_only",
      "no_hard_coded_marketing_as_ssot",
      "deposit_withdraw_locked_0",
      "flat_5pct_protocol_skim_superseded",
      "protocol_share_of_lead_fee_retired",
      "strategy_performance_lead_sets_no_day_global_default",
      "auto_pay_product_retired",
      "routing_advertise_only_not_enforced",
      "yield_opportunity_not_strategy",
      "per_strategy_and_opportunity_overrides_sparse",
    ],
    asOf: new Date().toISOString(),
  };
}

/**
 * @param {Record<string, string|undefined>} [query]
 */
export function publicFeeScheduleFromQuery(query = {}) {
  const q = query && typeof query === "object" ? query : {};
  return publicFeeSchedule({
    strategyId: q.strategyId ?? q.strategy_id ?? null,
    opportunityId:
      q.opportunityId ?? q.opportunity_id ?? q.venueId ?? q.venue_id ?? null,
  });
}

/**
 * Snapshot for status / readiness / heartbeat fee surfaces.
 * @param {{ strategyId?: string|null }} [ctx]
 */
export function feeSurfaceForStatus(ctx = {}) {
  const s = dayFeeSchedule(ctx);
  return {
    ...s,
    strategy_performance_fee_bps: s.strategy_performance_fee_bps,
    protocol_performance_fee_bps: s.protocol_performance_fee_bps,
    auto_pay_transfer_fee_bps: s.auto_pay_transfer_fee_bps,
    protocol_yield_skim_bps: s.protocol_yield_skim_bps,
    performance_fee_bps: s.strategy_performance_fee_bps,
    on: "strategy_performance_waterfall_plus_routing_rails",
    deposit_bps: 0,
    withdraw_bps: 0,
    top_up_bps: 0,
    third_party: "dex_bridge_opportunity_fees_pass_through",
    auto_pay: `transfer_fee_${DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS}_self_funding_tier1`,
    ssot: FEE_CONFIG_SCHEMA,
    flat_protocol_skim: "superseded",
  };
}
