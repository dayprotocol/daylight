/**
 * DAY Form adapter — JitoSOL (Solana LST) · DAY-22 + DAY-197 + DAY-304.
 *
 * Public interface: deposit / withdraw / harvest / read_apy.
 * Primary path: SPL Stake Pool depositSol/withdrawSol (NOT jito-ts block engine).
 * npm: @solana/spl-stake-pool · interceptor optional.
 *
 * Live path opt-in via OPEN_YIELD_JITO_LIVE + injected reader. Fail-closed default.
 * ROUTE/EXIT/HARVEST prepare-only (owner sign); never broadcasts by default.
 */

import { createMockFormAdapter } from "./shared.mjs";
import { withSolanaPrepare } from "./solana-prepare.mjs";

/** Deterministic CI mock gross APY (bps) — LST exchange-rate style. */
export const JITO_MOCK_APY_BPS = 410;

/**
 * Optional live reader for JitoSOL stake pool APY / exchange-rate growth.
 * @param {object} [ctx]
 * @returns {Promise<{ grossApyBps: number, source: string }|null>}
 */
export async function liveJitoReadApy(ctx = {}) {
  if (!["1", "true", "yes", "on"].includes(String(process.env.OPEN_YIELD_JITO_LIVE || "").toLowerCase())) {
    return null;
  }
  if (typeof ctx.liveReadApy === "function") {
    try {
      const r = await ctx.liveReadApy({ venue: "jito", chain: "solana", coinType: ctx.coinType });
      if (r && r.grossApyBps != null && Number.isFinite(Number(r.grossApyBps))) {
        return { grossApyBps: Number(r.grossApyBps), source: r.source || "jito_stake_pool:live" };
      }
    } catch {
      return null;
    }
  }
  return null;
}

const jitoFormAdapterBase = createMockFormAdapter({
  venueId: "jito",
  formId: "form-jito",
  chain: "solana",
  mockApyBps: JITO_MOCK_APY_BPS,
  ticket: "DAY-197",
  notes:
    "@solana/spl-stake-pool depositSol/withdrawSol; ROUTE/EXIT/HARVEST prepare",
  liveReader: async (ctx) => liveJitoReadApy(ctx),
});

/** Solana write prepare — same interface as Kamino.
 * Preserve withSolanaPrepare readiness getters (no object-spread).
 */
export const jitoFormAdapter = withSolanaPrepare(
  { ...jitoFormAdapterBase, referencePrepare: true },
  "jito",
);

export default jitoFormAdapter;
