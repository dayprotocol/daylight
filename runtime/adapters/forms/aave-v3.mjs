/**
 * DAY Form adapter — Aave V3 USDC on Base.
 *
 * read_apy: mock table (CI) + optional DefiLlama live (OPEN_YIELD_LIVE_APY / OPEN_YIELD_BASE_LIVE).
 * Write path: prepare-only unsigned_tx (approve + Pool.supply / withdraw). Never broadcasts.
 * Base GO stays off unless OPEN_YIELD_BASE_EXECUTION=1.
 */

import { createBaseFormAdapter, liveBaseDefillamaReadApy, AAVE_V3_POOL_BASE, BASE_USDC } from "./base-evm.mjs";

/** Deterministic CI mock gross supply APY (bps). */
export const AAVE_V3_MOCK_APY_BPS = 350;

/**
 * Optional live reader for Aave V3 USDC on Base.
 * @param {object} [ctx]
 */
export async function liveAaveV3ReadApy(ctx = {}) {
  return liveBaseDefillamaReadApy({ ...ctx, venue: "aave-v3" });
}

export const aaveV3BaseFormAdapter = createBaseFormAdapter({
  venueId: "aave-v3",
  formId: "form-aave-v3-base",
  mockApyBps: AAVE_V3_MOCK_APY_BPS,
  ticket: "DAY-232",
  // Literal addresses avoid TDZ on the base-evm ↔ forms ESM cycle.
  notes:
    "Aave V3 USDC Base pool 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5; asset 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; prepare-only until OPEN_YIELD_BASE_EXECUTION",
});

export default aaveV3BaseFormAdapter;
