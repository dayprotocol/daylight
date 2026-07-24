/**
 * @dayprotocol/sdk — TypeScript declarations for DayClient public API.
 * Runtime is ESM (src/index.mjs). Amounts are integer micros (no float money).
 */

export type DayClientOptions = {
  baseUrl: string;
  apiKey?: string;
  sessionToken?: string;
  fetchImpl?: typeof fetch;
  /** When true (default), check GET /api/day/sdk once after first successful request */
  checkUpdate?: boolean;
  /** When true (default), console.warn if a newer SDK is published */
  warnOnUpdate?: boolean;
  /** Called when updateAvailable or belowMinimum (SDK package) */
  onUpdate?: (info: SdkUpdateResult) => void;
  /** Called when API contract updateAvailable or belowMinimum */
  onApiUpdate?: (info: ApiVersionCheckResult) => void;
};

export type SdkUpdateResult = {
  schemaVersion: "day-sdk-update.v1";
  package: string;
  currentVersion: string;
  latestVersion: string | null;
  minSupportedVersion?: string | null;
  updateAvailable: boolean;
  belowMinimum: boolean;
  upToDate: boolean | null;
  install?: Record<string, string> | null;
  releaseUrl?: string;
  repoUrl?: string;
  message: string | null;
  status?: string;
  error?: string;
};

export type ApiVersionCheckResult = {
  schemaVersion: "day-api-update.v1";
  clientApiVersion: string;
  serverVersion: string | null;
  latestVersion: string | null;
  minSupportedVersion?: string | null;
  updateAvailable: boolean;
  belowMinimum: boolean;
  upToDate: boolean | null;
  message: string | null;
  versionPath?: string;
  docsUrl?: string;
  headers?: Record<string, string>;
  status?: string;
  error?: string;
};

/** Optional per-call API key override for owner-scoped mutators. */
export type DayAuthOpts = {
  apiKey?: string;
};

export declare const SDK_VERSION: string;
export declare const SDK_API_VERSION: string;
export declare const SDK_PACKAGE_NAME: "@dayprotocol/sdk";
export declare function compareSemver(a: string, b: string): number;
export declare function isUpdateAvailable(current: string, latest: string): boolean;

/**
 * Canonical strategy id is the bare venueId (strategyId === venueId).
 * Prefer: "suilend", "kamino", "aave-v3". Not "chain:venue".
 * Legacy alias: "form-suilend" → "suilend".
 */
export declare function normalizeStrategyId(strategyId: string): string;
export declare function buildUpdateResult(input?: {
  currentVersion?: string;
  latestVersion?: string;
  minSupportedVersion?: string;
  install?: Record<string, string>;
  releaseUrl?: string;
  repoUrl?: string;
}): SdkUpdateResult;

export declare function buildApiVersionCheckResult(input?: {
  clientApiVersion?: string;
  version?: string;
  latestVersion?: string;
  minSupportedVersion?: string;
  docsUrl?: string;
  headers?: Record<string, string>;
}): ApiVersionCheckResult;

export declare class DayError extends Error {
  name: "DayError";
  code: string;
  status?: number;
  body?: unknown;
  constructor(code: string, message: string, status?: number, body?: unknown);
}

export declare function toMicrosString(
  value: string | number | bigint,
  field?: string,
  opts?: { allowZero?: boolean },
): string;

export declare function isMicros(
  value: unknown,
  opts?: { allowZero?: boolean },
): boolean;

export declare const IDEMPOTENCY_HEADER: "Idempotency-Key";

export declare function buildIdempotencyKey(
  op: string,
  walletAddress: string,
  nonce: string,
): string;

export declare function isIdempotencyKey(key: string): boolean;

export declare function assertIdempotencyKey(key: string): string;

export declare class DayClient {
  static SDK_VERSION: string;
  static SDK_PACKAGE_NAME: string;
  static SDK_API_VERSION: string;

  baseUrl: string;
  apiKey: string | null;
  sessionToken: string | null;
  fetchImpl: typeof fetch;
  checkUpdate: boolean;
  warnOnUpdate: boolean;
  onUpdate: ((info: SdkUpdateResult) => void) | null;
  onApiUpdate: ((info: ApiVersionCheckResult) => void) | null;
  lastUpdateCheck: SdkUpdateResult | null;
  lastApiVersionCheck: ApiVersionCheckResult | null;
  lastApiVersionHeaders: {
    version: string | null;
    latestVersion: string | null;
    minSupportedVersion: string | null;
  } | null;

  constructor(opts: DayClientOptions);

  request(path: string, init?: RequestInit & { json?: unknown }): Promise<unknown>;

  /** GET /api/day/sdk — server latest version metadata */
  sdkRelease(): Promise<unknown>;

  /**
   * Compare this install to the server's published latest.
   * Network errors return { status: "error" } instead of throwing.
   */
  checkForUpdate(opts?: { force?: boolean }): Promise<SdkUpdateResult>;
  apiVersion(opts?: { client?: string; clientVersion?: string }): Promise<unknown>;
  checkApiVersion(opts?: { force?: boolean }): Promise<ApiVersionCheckResult>;

  /** GET /api/day/venues */
  listVenues(): Promise<unknown>;

  /** GET /api/day/forms */
  listForms(opts?: {
    chain?: string;
    wave?: string;
    ready?: boolean;
  }): Promise<unknown>;

  formPriority(): Promise<unknown>;
  getForm(formId: string): Promise<unknown>;

  /** GET /api/day/strategies — prefer over forms for product UI */
  listStrategies(opts?: {
    chain?: string;
    wave?: string;
    ready?: boolean;
    live?: boolean;
  }): Promise<unknown>;

  /**
   * GET /api/day/strategies/:id
   * strategyId === venueId (e.g. "suilend", "kamino", "aave-v3").
   * Not "form-*" (client strips form- alias) and not "chain:venue".
   */
  getStrategy(strategyId: string): Promise<unknown>;
  strategyPriority(): Promise<unknown>;

  /** PUT /api/v1/wallets/:address/profile — editable wallet display name */
  updateWalletProfile(
    walletAddress: string,
    body?: { displayName?: string | null },
  ): Promise<unknown>;

  /** GET /api/v1/wallets/:address/strategies — wallet-created Strategies */
  listWalletStrategies(
    walletAddress: string,
    opts?: { includeDeleted?: boolean },
  ): Promise<unknown>;

  /** POST /api/v1/wallets/:address/strategies — returns unsigned_tx + AgentCap contract */
  createWalletStrategy(
    walletAddress: string,
    body?: {
      strategyId?: string;
      name?: string;
      description?: string;
      displayName?: string;
      isPublic?: boolean;
      performanceFeeBps?: number;
      fees?: {
        strategyPerformanceFeeBps?: number;
        performanceFeeBps?: number;
      };
      guardrails: Record<string, unknown>;
      idempotencyKey?: string;
      agentGrantee?: string;
      agentScopes?: string[];
    },
  ): Promise<unknown>;

  /** GET /api/v1/wallets/:address/strategies/:strategyId */
  getWalletStrategy(walletAddress: string, strategyId: string): Promise<unknown>;

  /** PATCH /api/v1/wallets/:address/strategies/:strategyId — metadata only; Guardrails immutable */
  updateWalletStrategy(
    walletAddress: string,
    strategyId: string,
    body?: {
      name?: string;
      description?: string | null;
      displayName?: string | null;
      isPublic?: boolean;
      guardrails?: Record<string, unknown>;
    },
  ): Promise<unknown>;

  /** DELETE /api/v1/wallets/:address/strategies/:strategyId */
  deleteWalletStrategy(walletAddress: string, strategyId: string): Promise<unknown>;

  /**
   * POST /api/day/strategies/deposit/plan — prepare-only; fee 0 on principal.
   * strategyId === venueId (e.g. "suilend"). Legacy form-* aliases normalized client-side.
   */
  prepareStrategyDeposit(body?: {
    strategyId: string;
    amountMicros: string | number;
    owner?: string;
    autoYieldEnabled?: boolean;
  }): Promise<unknown>;

  /**
   * POST /api/day/strategies/withdraw/plan — prepare-only; fee 0 on principal.
   * strategyId === venueId (e.g. "suilend"). Legacy form-* aliases normalized client-side.
   */
  prepareStrategyWithdraw(body?: {
    strategyId: string;
    amountMicros: string | number;
    owner?: string;
  }): Promise<unknown>;

  /**
   * @deprecated Internal/legacy in-memory vault store — not the public product.
   * Prefer listStrategies / prepareStrategyDeposit.
   */
  listVaults(): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  createVault(
    body?: Record<string, unknown>,
    opts?: DayAuthOpts,
  ): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  getVault(vaultId: string): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  vaultDeposit(
    vaultId: string,
    body: { owner: string; amountMicros: string | number },
    opts?: DayAuthOpts,
  ): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  vaultWithdraw(
    vaultId: string,
    body: { owner: string; shares: string | number },
    opts?: DayAuthOpts,
  ): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  vaultSetStrategy(
    vaultId: string,
    body: { enabled: boolean },
    opts?: DayAuthOpts,
  ): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  vaultHarvest(
    vaultId: string,
    body: { grossYieldMicros: string | number; feeSkimBps?: number },
  ): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  vaultDeploy(
    vaultId: string,
    body: { formId: string; amountMicros: string | number; dryRun?: boolean },
    opts?: DayAuthOpts,
  ): Promise<unknown>;
  /** @deprecated Internal/legacy vault store */
  vaultUndeploy(
    vaultId: string,
    body: { formId: string; amountMicros: string | number; dryRun?: boolean },
    opts?: DayAuthOpts,
  ): Promise<unknown>;

  /**
   * Failed bridge rescue plan — funds return to owner.
   * Not for ordinary bridges; use {@link DayClient.bridgePlan}.
   */
  bridgeRescuePlan(body: Record<string, unknown>): Promise<unknown>;

  listOpportunities(opts?: {
    minTvlUsd?: number;
    chain?: string;
    status?: string;
  }): Promise<unknown>;

  /** owner|agent */
  getPosition(walletAddress: string): Promise<unknown>;
  getPortfolio(walletAddress: string): Promise<unknown>;
  getPerformance(walletAddress: string): Promise<unknown>;
  batchPositions(wallets: string[]): Promise<unknown>;
  venueApyTable(query?: Record<string, string>): Promise<unknown>;
  errorCatalog(): Promise<unknown>;
  listWebhookEventTypes(): Promise<unknown>;
  subscribeWebhook(body: object): Promise<unknown>;
  listWebhookEvents(query?: Record<string, string>): Promise<unknown>;
  /** owner|agent */
  getAutoYield(walletAddress: string): Promise<unknown>;
  /** owner */
  setAutoYield(
    walletAddress: string,
    body: {
      enabled: boolean;
      targetVenue?: string;
      maxStakeMicros?: string | number;
    },
  ): Promise<unknown>;

  /** owner|agent Autopilot status */
  getAutopilot(walletAddress: string): Promise<unknown>;
  /** owner|agent decision history */
  getAutopilotHistory(
    walletAddress: string,
    opts?: { limit?: number; id?: string },
  ): Promise<unknown>;
  /** owner enable + optional policy arming */
  enableAutopilot(
    walletAddress: string,
    body?: {
      goal?: string;
      capabilities?: string[];
      armAutoYield?: boolean;
      targetVenue?: string;
      targetChain?: string;
      maxStakeMicros?: string | number;
      autoPay?: {
        enabled?: boolean;
        percentage?: number;
        targets?: string[];
      };
    },
  ): Promise<unknown>;
  /** owner pause brain */
  disableAutopilot(
    walletAddress: string,
    body?: Record<string, unknown>,
  ): Promise<unknown>;
  /** owner|agent dry-run */
  previewAutopilot(
    walletAddress: string,
    body?: Record<string, unknown>,
  ): Promise<unknown>;
  /** owner|agent one decision cycle */
  tickAutopilot(
    walletAddress: string,
    body?: {
      execute?: boolean;
      force?: boolean;
      chain?: string;
      fixtureGrossYieldMicros?: string;
      compound?: boolean;
      idempotencyKey?: string;
    },
  ): Promise<unknown>;

  /** owner|agent — prepare-only route plan */
  previewRoute(
    walletAddress: string,
    body: Record<string, unknown>,
  ): Promise<unknown>;
  /** owner only — agent keys receive 403 */
  routeYield(
    walletAddress: string,
    body: Record<string, unknown>,
  ): Promise<unknown>;
  harvest(
    walletAddress: string,
    body?: { compound?: boolean; execute?: boolean; payPercentage?: number },
  ): Promise<unknown>;
  /** owner only */
  withdraw(
    walletAddress: string,
    body: {
      amountMicros: string | number;
      token?: string;
      unstakeFirst?: boolean;
    },
  ): Promise<unknown>;
  /** owner|agent — day-auto-pay.v2 config + allowlist */
  getAutoPay(walletAddress: string): Promise<unknown>;
  /** owner only — Tier1 self-funding; Tier2 blocked without legal go */
  enableAutoPay(
    walletAddress: string,
    body: {
      enabled: boolean;
      percentage?: number;
      targets?: string[];
      frequency?: string;
      tier?: "self_funding" | "third_party_transfer";
      allocation?: {
        percentage?: number;
        payees?: Array<{
          payeeId: string;
          class?: string;
          tier?: number;
          weightBps?: number;
          endpoint?: string;
        }>;
      };
      trigger?: {
        mode?: "after_harvest" | "manual" | "scheduled" | "threshold";
        minAmountMicros?: string;
        minAmountUsd?: number;
      };
      safety?: {
        maxPercentagePerHarvest?: number;
        emergencyPause?: boolean;
        dustMicros?: string;
      };
      simulate?: boolean;
      grossYieldMicros?: string;
      netYieldMicros?: string;
    },
  ): Promise<unknown>;
  getAutoPayPayees(walletAddress: string): Promise<unknown>;
  setAutoPayPayees(
    walletAddress: string,
    body: { payees: Array<Record<string, unknown>> },
  ): Promise<unknown>;
  previewAutoPay(walletAddress: string, body?: Record<string, unknown>): Promise<unknown>;
  triggerAutoPay(walletAddress: string, body?: Record<string, unknown>): Promise<unknown>;
  autoPayPlan(body?: Record<string, unknown>): Promise<unknown>;

  readiness(): Promise<unknown>;
  treasury(): Promise<unknown>;
  network(): Promise<unknown>;
  listVenuesByChain(opts?: { chain?: "sui" | "solana" }): Promise<unknown>;
  solanaApys(): Promise<unknown>;
  solanaStakePlan(body: Record<string, unknown>): Promise<unknown>;

  stake(
    walletAddress: string,
    body: {
      amountMicros: string | number;
      chain?: string;
      venue?: string;
      idempotencyKey?: string;
    },
  ): Promise<unknown>;
  unstake(
    walletAddress: string,
    body: {
      amountMicros: string | number;
      chain?: string;
      venue?: string;
    },
  ): Promise<unknown>;

  /**
   * Mayan bridge prepare plan (POST /api/day/bridge/plan).
   * Required: sourceChain, destChain, amountMicros, sourceAddress, destinationAddress.
   * Aliases: srcChain/fromChain, dstChain/toChain, amount, from, to.
   * Distinct from bridgeRescuePlan (failed-delivery rescue).
   */
  bridgePlan(body: Record<string, unknown>): Promise<unknown>;
  getFunding(walletAddress: string): Promise<unknown>;
  listAudits(opts?: {
    walletAddress?: string;
    action?: string;
    limit?: number;
  }): Promise<unknown>;

  /** Read-only public wallet balances */
  solanaWalletBalance(address: string): Promise<unknown>;
  suiWalletBalance(address: string): Promise<unknown>;

  /** DAY-STATS market snapshot */
  marketStats(): Promise<unknown>;

  /** DAY-MAP DefiLlama ≥$10M venue map (map only — not execution truth) */
  listMapVenues(opts?: { minTvlUsd?: number; chain?: string }): Promise<unknown>;
  /** Alias for listMapVenues */
  mapVenues(opts?: { minTvlUsd?: number; chain?: string }): Promise<unknown>;

  /** Multi-chain package IDs (day-packages.v1) */
  packages(): Promise<unknown>;

  /** Agent decision surface — prepare_only until broadcast go */
  whatPossible(): Promise<unknown>;

  arbitrumProfile(): Promise<unknown>;
  arbitrumEnablement(): Promise<unknown>;
  /** Arbitrum ETH + USDC balances (read-only; N/A on RPC fail) */
  arbitrumWalletBalance(address: string): Promise<unknown>;
  baseProfile(): Promise<unknown>;
  baseEnablement(): Promise<unknown>;
  /** Base public wallet balances ETH + USDC (read-only) */
  baseWalletBalance(address: string): Promise<unknown>;
}

/**
 * Wallet-scoped yield routing helper — **owner-only**, not public.
 * Requires explicit `apiKey` + `walletAddress` (no silent defaults).
 * Throws DayError INVALID_CONFIG if either is missing.
 * Prefer DayClient.prepareStrategyDeposit / listStrategies for public prepare paths.
 */
export declare function routeYield(input: {
  amount: number | string;
  /** Required — wallet scope; never defaults to "default" */
  walletAddress: string;
  /** Required — owner or agent API key (X-API-Key) */
  apiKey: string;
  token?: string;
  goal?: string;
  baseUrl?: string;
  execute?: boolean;
  fetchImpl?: typeof fetch;
}): Promise<unknown>;

export default DayClient;
