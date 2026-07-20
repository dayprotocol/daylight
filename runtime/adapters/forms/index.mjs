/**
 * DAY Form adapter modules index.
 * All registered strategies are mock-ready (read_apy + prepare write paths).
 * Base/Arbitrum expansion venues included (DAY-CHAIN).
 */

import { scallopFormAdapter, SCALLOP_MOCK_APY_BPS, liveScallopReadApy } from "./scallop.mjs";
import { jitoFormAdapter, JITO_MOCK_APY_BPS, liveJitoReadApy } from "./jito.mjs";
import { jupsolFormAdapter, JUPSOL_MOCK_APY_BPS, liveJupsolReadApy } from "./jupsol.mjs";
import {
  kaminoFormAdapter,
  KAMINO_MOCK_APY_BPS,
  liveKaminoReadApy,
  liveKaminoReadClaimYield,
} from "./kamino.mjs";
import {
  suilendFormAdapter,
  SUILEND_MOCK_APY_BPS,
  liveSuilendReadApy,
  liveSuilendReadClaimYield,
} from "./suilend.mjs";
import {
  naviFormAdapter,
  NAVI_MOCK_APY_BPS,
  liveNaviReadApy,
  liveNaviReadClaimYield,
} from "./navi.mjs";
import { marginfiFormAdapter, MARGINFI_MOCK_APY_BPS, liveMarginfiReadApy } from "./marginfi.mjs";
import { haedalFormAdapter, HAEDAL_MOCK_APY_BPS } from "./haedal.mjs";
import { kaiFormAdapter, KAI_MOCK_APY_BPS } from "./kai.mjs";
import { sanctumFormAdapter, SANCTUM_MOCK_APY_BPS } from "./sanctum.mjs";
import { marinadeFormAdapter, MARINADE_MOCK_APY_BPS } from "./marinade.mjs";
import { raydiumAmmFormAdapter, RAYDIUM_AMM_MOCK_APY_BPS } from "./raydium-amm.mjs";
import { driftStakedSolFormAdapter, DRIFT_STAKED_SOL_MOCK_APY_BPS } from "./drift-staked-sol.mjs";
import { binanceStakedSolFormAdapter, BINANCE_STAKED_SOL_MOCK_APY_BPS } from "./binance-staked-sol.mjs";
import { jupiterLendFormAdapter, JUPITER_LEND_MOCK_APY_BPS } from "./jupiter-lend.mjs";
import { ondoYieldAssetsFormAdapter, ONDO_YIELD_ASSETS_MOCK_APY_BPS } from "./ondo-yield-assets.mjs";
import { DAY904_LST_FORM_ADAPTERS } from "./day904-lst.mjs";
import {
  aaveV3BaseFormAdapter,
  AAVE_V3_MOCK_APY_BPS,
  liveAaveV3ReadApy,
} from "./aave-v3.mjs";
import {
  morphoBlueBaseFormAdapter,
  MORPHO_BLUE_MOCK_APY_BPS,
  liveMorphoBlueReadApy,
} from "./morpho-blue.mjs";
import {
  sparkSavingsBaseFormAdapter,
  SPARK_SAVINGS_MOCK_APY_BPS,
  liveSparkSavingsReadApy,
} from "./spark-savings.mjs";
import {
  moonwellBaseFormAdapter,
  MOONWELL_MOCK_APY_BPS,
  liveMoonwellReadApy,
} from "./moonwell.mjs";
import {
  morphoArbFormAdapter,
  MORPHO_MOCK_APY_BPS,
  liveMorphoArbReadApy,
  liveMorphoArbReadClaimYield,
  MORPHO_ARB_META,
} from "./morpho.mjs";
import {
  aaveV3ArbFormAdapter,
  AAVE_V3_ARB_MOCK_APY_BPS,
  liveAaveV3ArbReadApy,
  liveAaveV3ArbReadClaimYield,
  AAVE_V3_ARB_META,
} from "./aave-v3-arb.mjs";
import { fluidLendingArbFormAdapter, FLUID_LENDING_ARB_MOCK_APY_BPS } from "./fluid-lending-arb.mjs";
import { dolomiteArbFormAdapter, DOLOMITE_MOCK_APY_BPS } from "./dolomite.mjs";
import {
  lidoEthFormAdapter,
  ethenaUsdeEthFormAdapter,
  ETHEREUM_SECOND_WAVE_VENUES,
  ethereumSecondWaveBlockers,
  isEthereumSecondWaveVenue,
} from "./ethereum-second-wave.mjs";
import { liveBaseDefillamaReadApy, BASE_READY_VENUE_IDS, buildBaseUnsignedTx } from "./base-evm.mjs";
import {
  buildArbitrumUnsignedTx,
  isArbitrumUnsignedTxVenue,
} from "./arbitrum-evm.mjs";
import {
  DAY_925_927_FORM_ADAPTERS,
  MAP_ONLY_EXPANSION_ADAPTERS_BY_CHAIN,
  materializeVenusCorePoolDeposit,
  materializeVenusCorePoolWithdraw,
  materializeEulerV2Deposit,
  materializeEulerV2Withdraw,
  materializeListaLendingBscDeposit,
  materializeListaLendingBscWithdraw,
  venusCorePoolBscFormAdapter,
  eulerV2MonadFormAdapter,
  listaLendingBscFormAdapter,
} from "./day-925-927-expansion-scaffolds.mjs";

// DAY-4364 — re-export the per-chain unsigned_tx builders so the deposit
// composer can materialize a signable leg through the single forms barrel.
export {
  buildBaseUnsignedTx,
  buildArbitrumUnsignedTx,
  isArbitrumUnsignedTxVenue,
  ETHEREUM_SECOND_WAVE_VENUES,
  ethereumSecondWaveBlockers,
  isEthereumSecondWaveVenue,
  lidoEthFormAdapter,
  ethenaUsdeEthFormAdapter,
};

/** @type {Readonly<Record<string, object>>} */
export const FORM_ADAPTERS = Object.freeze({
  suilend: suilendFormAdapter,
  navi: naviFormAdapter,
  scallop: scallopFormAdapter,
  jito: jitoFormAdapter,
  jupsol: jupsolFormAdapter,
  kamino: kaminoFormAdapter,
  marginfi: marginfiFormAdapter,
  haedal: haedalFormAdapter,
  kai: kaiFormAdapter,
  sanctum: sanctumFormAdapter,
  marinade: marinadeFormAdapter,
  "raydium-amm": raydiumAmmFormAdapter,
  "drift-staked-sol": driftStakedSolFormAdapter,
  "binance-staked-sol": binanceStakedSolFormAdapter,
  "jupiter-lend": jupiterLendFormAdapter,
  "ondo-yield-assets": ondoYieldAssetsFormAdapter,
  ...DAY904_LST_FORM_ADAPTERS,
  "aave-v3": aaveV3BaseFormAdapter,
  "morpho-blue": morphoBlueBaseFormAdapter,
  "spark-savings": sparkSavingsBaseFormAdapter,
  moonwell: moonwellBaseFormAdapter,
  morpho: morphoArbFormAdapter,
  "aave-v3-arb": aaveV3ArbFormAdapter,
  "fluid-lending-arb": fluidLendingArbFormAdapter,
  dolomite: dolomiteArbFormAdapter,
  // DAY-923/924 ethereum second-wave — registered, money path fail-closed
  lido: lidoEthFormAdapter,
  "ethena-usde": ethenaUsdeEthFormAdapter,
  // DAY-925/926/927 expansion map-only stubs (ready=false; deposit fail-closed)
  ...DAY_925_927_FORM_ADAPTERS,
});

export const FORM_MODULE_MOCK_APY_BPS = Object.freeze({
  suilend: SUILEND_MOCK_APY_BPS,
  navi: NAVI_MOCK_APY_BPS,
  scallop: SCALLOP_MOCK_APY_BPS,
  jito: JITO_MOCK_APY_BPS,
  jupsol: JUPSOL_MOCK_APY_BPS,
  kamino: KAMINO_MOCK_APY_BPS,
  marginfi: MARGINFI_MOCK_APY_BPS,
  haedal: HAEDAL_MOCK_APY_BPS,
  kai: KAI_MOCK_APY_BPS,
  sanctum: SANCTUM_MOCK_APY_BPS,
  marinade: MARINADE_MOCK_APY_BPS,
  "raydium-amm": RAYDIUM_AMM_MOCK_APY_BPS,
  "drift-staked-sol": DRIFT_STAKED_SOL_MOCK_APY_BPS,
  "binance-staked-sol": BINANCE_STAKED_SOL_MOCK_APY_BPS,
  "jupiter-lend": JUPITER_LEND_MOCK_APY_BPS,
  "ondo-yield-assets": ONDO_YIELD_ASSETS_MOCK_APY_BPS,
  "aave-v3": AAVE_V3_MOCK_APY_BPS,
  "morpho-blue": MORPHO_BLUE_MOCK_APY_BPS,
  "spark-savings": SPARK_SAVINGS_MOCK_APY_BPS,
  moonwell: MOONWELL_MOCK_APY_BPS,
  morpho: MORPHO_MOCK_APY_BPS,
  "aave-v3-arb": AAVE_V3_ARB_MOCK_APY_BPS,
  "fluid-lending-arb": FLUID_LENDING_ARB_MOCK_APY_BPS,
  dolomite: DOLOMITE_MOCK_APY_BPS,
});

export const FORM_MODULE_VENUE_IDS = Object.freeze(Object.keys(FORM_ADAPTERS));

export function getFormAdapter(venueId) {
  const id = String(venueId || "").toLowerCase();
  return FORM_ADAPTERS[id] || null;
}

export async function executeFormAdapter(payload = {}, opts = {}) {
  const venue = String(payload.venue || "").toLowerCase();
  const adapter = getFormAdapter(venue);
  if (!adapter) return null;
  return adapter.execute({ ...payload, venue }, opts);
}

export function composeLiveReadApy(outer) {
  return async (ctx) => {
    if (typeof outer === "function") {
      try {
        const r = await outer(ctx);
        if (r && r.grossApyBps != null && Number.isFinite(Number(r.grossApyBps))) return r;
      } catch {
        /* fall through */
      }
    }
    const venue = String(ctx?.venue || "").toLowerCase();
    if (venue === "suilend") return liveSuilendReadApy(ctx);
    if (venue === "navi") return liveNaviReadApy(ctx);
    if (venue === "scallop") return liveScallopReadApy(ctx);
    if (venue === "jito") return liveJitoReadApy(ctx);
    if (venue === "jupsol") return liveJupsolReadApy(ctx);
    if (venue === "kamino") return liveKaminoReadApy(ctx);
    if (venue === "marginfi") return liveMarginfiReadApy(ctx);
// DAY-232..234 Base venues (DefiLlama opt-in / inject)
    if (venue === "aave-v3") return liveAaveV3ReadApy(ctx);
    if (venue === "morpho-blue") return liveMorphoBlueReadApy(ctx);
    if (venue === "spark-savings") return liveSparkSavingsReadApy(ctx);
    if (venue === "moonwell") return liveMoonwellReadApy(ctx);
    // DAY-239/240 Arbitrum primary
    if (venue === "morpho") return liveMorphoArbReadApy(ctx);
    if (venue === "aave-v3-arb") return liveAaveV3ArbReadApy(ctx);
    return null;
  };
}

/**
 * Composite live claim reader for phase-1 homes.
 * Injected outer wins; else module hooks. Never invents claim micros.
 *
 * @param {((ctx: object) => Promise<object|null>)|null|undefined} outer
 */
export function composeLiveReadClaimYield(outer) {
  return async (ctx) => {
    if (typeof outer === "function") {
      try {
        const r = await outer(ctx);
        if (r && typeof r === "object") return r;
      } catch {
        // fall through
      }
    }
    const venue = String(ctx?.venue || "").toLowerCase();
    if (venue === "suilend") return liveSuilendReadClaimYield(ctx);
    if (venue === "navi") return liveNaviReadClaimYield(ctx);
    if (venue === "kamino") return liveKaminoReadClaimYield(ctx);
    return null;
  };
}

export {
  scallopFormAdapter,
  SCALLOP_MOCK_APY_BPS,
  liveScallopReadApy,
  jitoFormAdapter,
  JITO_MOCK_APY_BPS,
  liveJitoReadApy,
  jupsolFormAdapter,
  JUPSOL_MOCK_APY_BPS,
  liveJupsolReadApy,
  kaminoFormAdapter,
  KAMINO_MOCK_APY_BPS,
  liveKaminoReadApy,
  liveKaminoReadClaimYield,
  suilendFormAdapter,
  SUILEND_MOCK_APY_BPS,
  liveSuilendReadApy,
  liveSuilendReadClaimYield,
  naviFormAdapter,
  NAVI_MOCK_APY_BPS,
  liveNaviReadApy,
  liveNaviReadClaimYield,
  marginfiFormAdapter,
  MARGINFI_MOCK_APY_BPS,
  liveMarginfiReadApy,
  haedalFormAdapter,
  HAEDAL_MOCK_APY_BPS,
  kaiFormAdapter,
  KAI_MOCK_APY_BPS,
  sanctumFormAdapter,
  SANCTUM_MOCK_APY_BPS,
  marinadeFormAdapter,
  MARINADE_MOCK_APY_BPS,
  raydiumAmmFormAdapter,
  RAYDIUM_AMM_MOCK_APY_BPS,
  driftStakedSolFormAdapter,
  DRIFT_STAKED_SOL_MOCK_APY_BPS,
  binanceStakedSolFormAdapter,
  BINANCE_STAKED_SOL_MOCK_APY_BPS,
  jupiterLendFormAdapter,
  JUPITER_LEND_MOCK_APY_BPS,
  ondoYieldAssetsFormAdapter,
  ONDO_YIELD_ASSETS_MOCK_APY_BPS,
  aaveV3BaseFormAdapter,
  AAVE_V3_MOCK_APY_BPS,
  liveAaveV3ReadApy,
  morphoBlueBaseFormAdapter,
  MORPHO_BLUE_MOCK_APY_BPS,
  liveMorphoBlueReadApy,
  sparkSavingsBaseFormAdapter,
  SPARK_SAVINGS_MOCK_APY_BPS,
  liveSparkSavingsReadApy,
  moonwellBaseFormAdapter,
  MOONWELL_MOCK_APY_BPS,
  liveMoonwellReadApy,
  liveBaseDefillamaReadApy,
  BASE_READY_VENUE_IDS,
  morphoArbFormAdapter,
  MORPHO_MOCK_APY_BPS,
  liveMorphoArbReadApy,
  liveMorphoArbReadClaimYield,
  MORPHO_ARB_META,
  aaveV3ArbFormAdapter,
  AAVE_V3_ARB_MOCK_APY_BPS,
  liveAaveV3ArbReadApy,
  liveAaveV3ArbReadClaimYield,
  AAVE_V3_ARB_META,
  fluidLendingArbFormAdapter,
  FLUID_LENDING_ARB_MOCK_APY_BPS,
  dolomiteArbFormAdapter,
  DOLOMITE_MOCK_APY_BPS,
  // DAY-925/926/927 expansion map-only scaffolds
  DAY_925_927_FORM_ADAPTERS,
  MAP_ONLY_EXPANSION_ADAPTERS_BY_CHAIN,
  materializeVenusCorePoolDeposit,
  materializeVenusCorePoolWithdraw,
  materializeEulerV2Deposit,
  materializeEulerV2Withdraw,
  materializeListaLendingBscDeposit,
  materializeListaLendingBscWithdraw,
  venusCorePoolBscFormAdapter,
  eulerV2MonadFormAdapter,
  listaLendingBscFormAdapter,
};

export {
  failClosed,
  okResult,
  prepareWrite,
  createStubFormAdapter,
  createMockFormAdapter,
  isLiveClaimEnabled,
  liveYieldReaderStatus,
  tryLiveReadClaimYield,
  tryLiveReadApy,
  LIVE_CLAIM_VENUE_IDS,
  truthyEnvFlag,
} from "./shared.mjs";

export {
  REFERENCE_PREPARE_VENUES,
  isReferencePrepareVenue,
  buildReferenceUnsignedTx,
  withReferencePrepare,
  attachReferencePrepare,
} from "./reference-prepare.mjs";

export {
  SUI_WRITE_VENUES,
  SUI_USDC_COIN_TYPE,
  SUI_COIN_TYPE,
  isSuiWritePrepareVenue,
  listSuiWritePrepareVenues,
  buildSuiWriteUnsignedTx,
  buildSuiVenueBuilderPlan,
  withSuiWritePrepare,
  attachSuiWritePrepare,
} from "./sui-write-prepare.mjs";

export {
  SOLANA_WRITE_VENUES,
  SOLANA_WRITE_VENUE_IDS,
  SOLANA_PROTOCOL_IDS,
  SOLANA_LIVE_PREPARE_PRIORITY,
  SOLANA_LIVE_PREPARE_SECONDARY,
  isSolanaWriteVenue,
  isSolanaLivePrepareVenue,
  solanaVenueBaseReadiness,
  solanaVenuePreparePath,
  buildSolanaUnsignedTx,
  buildSolanaVenueBuilderPlan,
  withSolanaPrepare,
  attachSolanaPrepare,
  SOLANA_USDC_MINT,
  SPL_STAKE_POOL_PROGRAM_ID,
} from "./solana-prepare.mjs";

export {
  materializeSolanaDeposit,
  materializeSolanaWithdraw,
  mergeSolMaterialization,
  materializeJupiterLendDeposit,
  materializeJupiterLendWithdraw,
  materializeJupiterLstAcquire,
  materializeJupiterLstExit,
  materializeKaminoDeposit,
  materializeKaminoDepositViaSdk,
  materializeKaminoDepositKtx,
  materializeMarginfiDeposit,
  materializeMarginfiWithdraw,
  materializeOndoUsdyAcquire,
  materializeOndoUsdyExit,
  materializeRaydiumAmmLpDeposit,
  materializeRaydiumAmmLpWithdraw,
  raydiumAmmV4WithdrawLayout,
  encodeRaydiumAmmV4WithdrawData,
  baseUnitsToDecimal,
  isLiveSerializedMaterialize,
  isSolLendLiveEnabled,
  isRaydiumLpLiveEnabled,
  isSolLstAcquireVenue,
  isSolYieldTokenAcquireVenue,
  loadKlendSdk,
  loadMarginfiSdk,
} from "./solana-materialize.mjs";

export {
  KAMINO_LEND_MARKETS,
  MARGINFI_LEND_MARKETS,
  KAMINO_LEND_MARKET_IDS,
  MARGINFI_LEND_MARKET_IDS,
  KAMINO_LEND_DEFAULT_MARKET_ID,
  MARGINFI_LEND_DEFAULT_MARKET_ID,
  resolveKaminoLendMarket,
  resolveMarginfiLendMarket,
  listLendMarkets,
} from "./solana-lend-markets.mjs";

export {
  isKlendSdkPresent,
  kaminoPreparePath,
  klendSdkCandidateRoots,
} from "./klend-availability.mjs";

export {
  ADAPTER_ACTIONS,
  ADAPTER_WRITE_ACTIONS,
  FORM_ACTIONS,
  normalizeAdapterAction,
  toFormAction,
  toPlanKind,
  listAdapterInterface,
  assertAdapterConforms,
  assertAllAdaptersConform,
  ADAPTER_INTERFACE_SCHEMA,
} from "../adapter-interface.mjs";
