/**
 * DAY Form adapter — Aave V3 USDC on Arbitrum.
 *
 * Liquid blue-chip USDC lend. Prefer Aave V3 when listed (it is on Arb).
 * read_apy: mock for CI; live path null-not-fake.
 * Cage actions: ROUTE / EXIT / HARVEST prepare (owner-sign).
 */

import { createMockFormAdapter, truthyEnvFlag } from "./shared.mjs";
import { withArbitrumUnsignedTx, AAVE_V3_POOL_ARBITRUM } from "./arbitrum-evm.mjs";

/** Deterministic CI mock gross supply APY (bps). Not live truth. */
export const AAVE_V3_ARB_MOCK_APY_BPS = 340;

/** Circle native USDC on Arbitrum One. */
export const AAVE_V3_ARB_USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

/**
 * Aave V3 Pool on Arbitrum One (canonical).
 * @see https://docs.aave.com/developers/deployed-contracts/v3-mainnet/arbitrum
 */
export const AAVE_V3_ARB_POOL = "0x794a61358D6845594F94dc1DB02A252b5b4814aD";

export const AAVE_V3_ARB_META = Object.freeze({
  venueId: "aave-v3-arb",
  formId: "form-aave-v3-arb",
  chain: "arbitrum",
  protocol: "Aave V3",
  asset: "USDC",
  assetAddress: AAVE_V3_ARB_USDC,
  pool: AAVE_V3_ARB_POOL,
  ticket: "DAY-240",
  cageActions: Object.freeze(["ROUTE", "EXIT", "HARVEST", "COMPOUND"]),
  decimals: 6,
});

/**
 * Optional live APY reader — fail-closed; never invents.
 * @param {object} [ctx]
 * @returns {Promise<{ grossApyBps: number, source: string }|null>}
 */
export async function liveAaveV3ArbReadApy(ctx = {}) {
  if (typeof ctx.liveReadApy === "function") {
    try {
      const r = await ctx.liveReadApy({
        venue: "aave-v3-arb",
        chain: "arbitrum",
        coinType: ctx.coinType || AAVE_V3_ARB_USDC,
        asset: "USDC",
      });
      if (r && r.grossApyBps != null && Number.isFinite(Number(r.grossApyBps))) {
        return {
          grossApyBps: Number(r.grossApyBps),
          source: r.source || "aave-v3-arb:live",
        };
      }
    } catch {
      return null;
    }
  }
  if (truthyEnvFlag("OPEN_YIELD_LIVE_APY") || truthyEnvFlag("OPEN_YIELD_LIVE_CLAIM")) {
    return null;
  }
  return null;
}

/**
 * Live claim reader — never invents micros from APY.
 * @param {object} [ctx]
 */
export async function liveAaveV3ArbReadClaimYield(ctx = {}) {
  if (typeof ctx.liveReadClaimYield === "function") {
    try {
      const r = await ctx.liveReadClaimYield({
        venue: "aave-v3-arb",
        chain: "arbitrum",
        coinType: ctx.coinType || AAVE_V3_ARB_USDC,
      });
      if (r && typeof r === "object") return r;
    } catch {
      return null;
    }
  }
  const apy = await liveAaveV3ArbReadApy(ctx);
  if (apy) {
    return {
      grossYieldMicros: null,
      liveApyBps: apy.grossApyBps,
      source: apy.source,
      reason: "claim_amount_requires_adapter",
    };
  }
  return null;
}

const _aaveV3ArbBase = createMockFormAdapter({
  venueId: "aave-v3-arb",
  formId: "form-aave-v3-arb",
  chain: "arbitrum",
  mockApyBps: AAVE_V3_ARB_MOCK_APY_BPS,
  ticket: "DAY-240",
  wave: "day-1",
  notes: `Aave V3 USDC on Arbitrum pool ${AAVE_V3_POOL_ARBITRUM}; prepare unsigned_tx; chain WRITE_GO + residual for depositableLive`,
  liveReader: async (ctx) => liveAaveV3ArbReadApy(ctx),
  liveClaimReader: async (ctx) => liveAaveV3ArbReadClaimYield(ctx),
});

/** Prepare writeReady via unsigned_tx; chain live money still WRITE_GO + residual. */
export const aaveV3ArbFormAdapter = withArbitrumUnsignedTx(_aaveV3ArbBase, "aave-v3-arb");

export default aaveV3ArbFormAdapter;
