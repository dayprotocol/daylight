/**
 * Basis-point helpers — fee only applies to yield / rails, never principal.
 *
 * Numeric defaults + public schedule SSOT: runtime/config/fee-config.mjs
 * (docs/critical/FEE-STRUCTURE.md). This module owns pure math; FeeConfig owns rates.
 *
 * Flat protocol_yield_skim is SUPERSEDED — prefer applyStrategyPerformanceWaterfall.
 */

import {
  BASIS_POINTS as FEE_BASIS_POINTS,
  DEFAULT_PROTOCOL_YIELD_SKIM_BPS as FEE_YIELD_SKIM,
  DEFAULT_PROTOCOL_SWAP_FEE_BPS as FEE_SWAP,
  DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS as FEE_GAS,
  DEFAULT_PROTOCOL_BRIDGE_FEE_BPS as FEE_BRIDGE,
  DEFAULT_ROUTING_FEE_USD_MICROS as FEE_ROUTING_USD,
  DEFAULT_KEEPER_REWARD_BPS as FEE_KEEPER,
  DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS as FEE_DEPOSIT_WITHDRAW,
  DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS as FEE_AUTO_PAY,
  DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS as FEE_STRAT_PERF,
  DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS as FEE_PROTO_PERF,
  dayFeeSchedule as feeConfigDaySchedule,
  getYieldSkimBps,
  getAutoPayFeeBps,
  getSwapFeeBps,
  getGasSponsorFeeBps,
  getBridgeFeeBps,
  getRoutingFeeUsdMicros,
  getKeeperRewardBps,
  getStrategyPerformanceFeeBps,
  getProtocolPerformanceFeeBps,
  applyStrategyPerformanceWaterfall,
  assertFeeConfigLocked,
} from "../config/fee-config.mjs";

export const BASIS_POINTS = FEE_BASIS_POINTS;
/** @deprecated Flat skim of user residual superseded (default 0). */
export const DEFAULT_PROTOCOL_YIELD_SKIM_BPS = FEE_YIELD_SKIM;
/** Protocol fee on DAY-composed swap notional. Third-party DEX fees still apply on top. */
export const DEFAULT_PROTOCOL_SWAP_FEE_BPS = FEE_SWAP;
/** Markup on gas-sponsor cost (typical 10% = 1000 bps). */
export const DEFAULT_PROTOCOL_GAS_SPONSOR_FEE_BPS = FEE_GAS;
/** Protocol bridge fee on bridge notional. */
export const DEFAULT_PROTOCOL_BRIDGE_FEE_BPS = FEE_BRIDGE;
/** Routing / x402 fixed fee in USD micros ($0.001 = 1000). */
export const DEFAULT_ROUTING_FEE_USD_MICROS = FEE_ROUTING_USD;
/** Keeper tip from realized yield only. Never principal. */
export const DEFAULT_KEEPER_REWARD_BPS = FEE_KEEPER;
/** Deposit / withdraw principal — always 0. */
export const DEFAULT_DEPOSIT_WITHDRAW_FEE_BPS = FEE_DEPOSIT_WITHDRAW;
/** Auto Pay transfer fee on residual yield routed to approved payees. 0 live (DAY-818 retired; historical 100). */
export const DEFAULT_AUTO_PAY_TRANSFER_FEE_BPS = FEE_AUTO_PAY;
export const DEFAULT_STRATEGY_PERFORMANCE_FEE_BPS = FEE_STRAT_PERF;
export const DEFAULT_PROTOCOL_PERFORMANCE_FEE_BPS = FEE_PROTO_PERF;

export {
  getYieldSkimBps,
  getAutoPayFeeBps,
  getSwapFeeBps,
  getGasSponsorFeeBps,
  getBridgeFeeBps,
  getRoutingFeeUsdMicros,
  getKeeperRewardBps,
  getStrategyPerformanceFeeBps,
  getProtocolPerformanceFeeBps,
  applyStrategyPerformanceWaterfall,
  assertFeeConfigLocked,
};

/**
 * @param {number|string|bigint} grossBps
 * @param {number|string|bigint} skimBps
 * @returns {number}
 */
export function netApyBps(grossBps, skimBps = 0) {
  const gross = Number(grossBps);
  const skim = Number(skimBps);
  if (!Number.isFinite(gross) || gross < 0) {
    throw new Error("grossApyBps must be a non-negative number");
  }
  if (!Number.isSafeInteger(skim) || skim < 0 || skim > BASIS_POINTS) {
    throw new Error("skimBps must be integer 0..10000");
  }
  return Math.floor((gross * (BASIS_POINTS - skim)) / BASIS_POINTS);
}

/**
 * Fee skim on harvested yield only.
 * @param {bigint|number|string} grossYieldMicros
 * @param {number} skimBps
 */
export function skimYieldMicros(grossYieldMicros, skimBps = 0) {
  const gross = BigInt(grossYieldMicros);
  if (gross < 0n) throw new Error("grossYieldMicros must be non-negative");
  const skim = BigInt(skimBps);
  if (skim < 0n || skim > BigInt(BASIS_POINTS)) {
    throw new Error("skimBps must be 0..10000");
  }
  const protocolSkim = (gross * skim) / BigInt(BASIS_POINTS);
  const net = gross - protocolSkim;
  return {
    grossYieldMicros: gross.toString(),
    protocolSkimMicros: protocolSkim.toString(),
    netYieldMicros: net.toString(),
    feeBps: Number(skim),
  };
}

/**
 * @param {unknown} value
 * @param {string} field
 * @returns {bigint}
 */
export function asNonNegativeBigInt(value, field) {
  if (typeof value === "bigint") {
    if (value < 0n) throw new Error(`${field} must be non-negative`);
    return value;
  }
  if (value === undefined || value === null || value === "") {
    throw new Error(`${field} is required`);
  }
  const s = String(value);
  if (!/^\d+$/.test(s)) throw new Error(`${field} must be a non-negative integer`);
  return BigInt(s);
}

/**
 * Protocol fee on a notional amount (swap or gas-sponsor repayment).
 * @param {bigint|number|string} notionalMicros
 * @param {number} feeBps
 */
export function protocolNotionalFeeMicros(
  notionalMicros,
  feeBps = DEFAULT_PROTOCOL_SWAP_FEE_BPS,
) {
  const n = BigInt(notionalMicros);
  if (n < 0n) throw new Error("notional must be non-negative");
  const bps = BigInt(feeBps);
  if (bps < 0n || bps > BigInt(BASIS_POINTS)) throw new Error("feeBps must be 0..10000");
  const fee = (n * bps) / BigInt(BASIS_POINTS);
  return {
    notionalMicros: n.toString(),
    protocolFeeMicros: fee.toString(),
    netMicros: (n - fee).toString(),
    feeBps: Number(bps),
  };
}

/** Public fee schedule for status / plans / docs — FeeConfig SSOT. */
export function dayFeeSchedule(ctx = {}) {
  return feeConfigDaySchedule(ctx);
}
