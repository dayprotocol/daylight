/**
 * @dayprotocol/sdk — public client for DAY HTTP API v1
 * Canonical paths: /api/v1/day/* · /api/v1/wallets/*
 * Spec: docs/02-agent-api.md · Constitution: docs/00-product-constitution.md
 *
 * baseUrl may be either:
 *   - origin only: `https://dayprotocol.com`  (recommended)
 *   - v1 prefix:   `https://dayprotocol.com/api/v1`
 * Paths are never double-prefixed.
 */

/** Prefix all product API paths with /api/v1 (health stays unversioned). */
export function toV1Path(path) {
  const p = String(path || "");
  if (p === "/health" || p === "/") return p;
  if (p.startsWith("/api/v1/") || p === "/api/v1") return p;
  if (p === "/openapi.json" || p === "/openapi") return "/api/v1/openapi.json";
  // Never publish /api/v1/day/openapi.json — openapi is at /api/v1/openapi.json
  if (p === "/api/day/openapi.json") return "/api/v1/openapi.json";
  if (p.startsWith("/api/")) return `/api/v1/${p.slice("/api/".length)}`;
  return p;
}

/**
 * Join baseUrl + path without doubling /api/v1.
 * @param {string} baseUrl
 * @param {string} path
 * @returns {string}
 */
export function resolveApiUrl(baseUrl, path) {
  let base = String(baseUrl || "").replace(/\/+$/, "");
  let p = toV1Path(path);
  // base already ends with /api/v1 → path should be relative under v1 (/day/status)
  if (/\/api\/v1$/i.test(base)) {
    if (p.startsWith("/api/v1/")) p = p.slice("/api/v1".length); // → /day/...
    else if (p === "/api/v1") p = "/";
    // /health is absolute from origin, not under /api/v1
    if (p === "/health" || p === "/") {
      base = base.replace(/\/api\/v1$/i, "");
    }
  }
  if (!p.startsWith("/")) p = `/${p}`;
  return `${base}${p}`;
}

/**
 * @typedef {object} DayClientOptions
 * @property {string} baseUrl Origin (`https://dayprotocol.com`) or v1 base (`https://dayprotocol.com/api/v1`)
 * @property {string} [apiKey]
 * @property {string} [sessionToken]
 * @property {typeof fetch} [fetchImpl]
 * @property {boolean} [checkUpdate] When true (default), check /api/v1/day/sdk once after first successful request
 * @property {boolean} [warnOnUpdate] When true (default), console.warn if a newer SDK is published
 * @property {(info: object) => void} [onUpdate] Optional callback when updateAvailable
 */

export { DayError } from "./errors.mjs";
export { toMicrosString, isMicros } from "./money.mjs";
export {
  IDEMPOTENCY_HEADER,
  buildIdempotencyKey,
  isIdempotencyKey,
  assertIdempotencyKey,
} from "./idempotency.mjs";
export {
  SDK_VERSION,
  SDK_PACKAGE_NAME,
  SDK_API_VERSION,
  compareSemver,
  isUpdateAvailable,
  buildUpdateResult,
  buildApiVersionCheckResult,
} from "./version.mjs";

import { DayError } from "./errors.mjs";
import { toMicrosString } from "./money.mjs";
import { IDEMPOTENCY_HEADER } from "./idempotency.mjs";
import {
  SDK_VERSION,
  SDK_PACKAGE_NAME,
  SDK_API_VERSION,
  buildUpdateResult,
  buildApiVersionCheckResult,
} from "./version.mjs";

/**
 * Canonical strategy id is the bare venueId (strategyId === venueId).
 * Prefer: `"suilend"`, `"kamino"`, `"aave-v3"`.
 * Not: `"chain:venue"` (e.g. `sui:suilend`).
 * Legacy alias accepted: `"form-suilend"` → `"suilend"` (stripped client-side;
 * server getForm/getStrategy also resolve form-* for safety).
 *
 * @param {string} strategyId
 * @returns {string}
 */
export function normalizeStrategyId(strategyId) {
  let id = String(strategyId ?? "")
    .trim()
    .toLowerCase();
  if (id.startsWith("form-")) id = id.slice("form-".length);
  return id;
}

export class DayClient {
  /** Installed package version (same as package.json). */
  static SDK_VERSION = SDK_VERSION;
  static SDK_PACKAGE_NAME = SDK_PACKAGE_NAME;
  /** API contract this client targets. */
  static SDK_API_VERSION = SDK_API_VERSION;

  /** @param {DayClientOptions} opts */
  constructor(opts) {
    if (!opts?.baseUrl) throw new DayError("INVALID_CONFIG", "baseUrl is required");
    this.baseUrl = String(opts.baseUrl).replace(/\/$/, "");
    this.apiKey = opts.apiKey || null;
    this.sessionToken = opts.sessionToken || null;
    this.fetchImpl = opts.fetchImpl || globalThis.fetch;
    if (typeof this.fetchImpl !== "function") {
      throw new DayError("INVALID_CONFIG", "fetch is not available; pass fetchImpl");
    }
    /** @type {boolean} */
    this.checkUpdate = opts.checkUpdate !== false;
    /** @type {boolean} */
    this.warnOnUpdate = opts.warnOnUpdate !== false;
    /** @type {((info: object) => void)|null} */
    this.onUpdate = typeof opts.onUpdate === "function" ? opts.onUpdate : null;
    /** @type {((info: object) => void)|null} */
    this.onApiUpdate = typeof opts.onApiUpdate === "function" ? opts.onApiUpdate : null;
    /** @type {object|null} */
    this.lastUpdateCheck = null;
    /** @type {object|null} */
    this.lastApiVersionCheck = null;
    /** @type {object|null} */
    this.lastApiVersionHeaders = null;
    this._updateCheckStarted = false;
    this._apiHeaderWarned = false;
  }

  /**
   * Compare this install to the server's published latest (`GET /api/day/sdk`).
   * Safe to call anytime; never throws on network errors (returns status: "error").
   * @param {{ force?: boolean }} [opts]
   */
  async checkForUpdate(opts = {}) {
    if (this.lastUpdateCheck && !opts.force) {
      return this.lastUpdateCheck;
    }
    try {
      const remote = await this.request("/api/day/sdk");
      const result = buildUpdateResult({
        currentVersion: SDK_VERSION,
        latestVersion: remote.latestVersion,
        minSupportedVersion: remote.minSupportedVersion,
        install: remote.install,
        releaseUrl: remote.releaseUrl,
        repoUrl: remote.repoUrl,
      });
      this.lastUpdateCheck = result;
      if (result.updateAvailable || result.belowMinimum) {
        if (this.warnOnUpdate && typeof console !== "undefined" && console.warn) {
          console.warn(`[${SDK_PACKAGE_NAME}] ${result.message}`);
        }
        if (this.onUpdate) {
          try {
            this.onUpdate(result);
          } catch {
            // never break caller
          }
        }
      }
      return result;
    } catch (err) {
      const result = {
        schemaVersion: "day-sdk-update.v1",
        package: SDK_PACKAGE_NAME,
        currentVersion: SDK_VERSION,
        latestVersion: null,
        updateAvailable: false,
        belowMinimum: false,
        upToDate: null,
        status: "error",
        error: err instanceof DayError ? err.message : String(err?.message || err),
        message: null,
      };
      this.lastUpdateCheck = result;
      return result;
    }
  }

  /** Fire-and-forget SDK + API update checks (after first successful API call). */
  _maybeScheduleUpdateCheck() {
    if (!this.checkUpdate || this._updateCheckStarted) return;
    this._updateCheckStarted = true;
    const run = () => {
      void this.checkForUpdate().catch(() => {});
      void this.checkApiVersion().catch(() => {});
    };
    if (typeof queueMicrotask === "function") queueMicrotask(run);
    else setTimeout(run, 0);
  }

  /** @param {string} path @param {RequestInit & { json?: unknown, idempotencyKey?: string }} [init] */
  async request(path, init = {}) {
    // All product API calls go through /api/v1/* (never double-prefix if baseUrl ends with /api/v1).
    const url = resolveApiUrl(this.baseUrl, path);
    const headers = new Headers(init.headers || {});
    headers.set("Accept", "application/json");
    if (init.json !== undefined) {
      headers.set("Content-Type", "application/json");
    }
    if (this.apiKey) headers.set("X-API-Key", this.apiKey);
    if (this.sessionToken) headers.set("Authorization", `Bearer ${this.sessionToken}`);
    // Tell the server which API contract this client targets
    if (!headers.has("X-DAY-API-Client-Version")) {
      headers.set("X-DAY-API-Client-Version", SDK_API_VERSION);
    }
    // DAY-625: put the idempotency key on the wire as the documented header so
    // the server can dedupe a mutating money call. Accept it from init, from the
    // JSON body's idempotencyKey field, or an explicit header already set by the
    // caller — whichever is present. Body field is left intact (server reads either).
    if (!headers.has(IDEMPOTENCY_HEADER)) {
      const idem =
        init.idempotencyKey != null
          ? init.idempotencyKey
          : init.json && typeof init.json === "object"
            ? init.json.idempotencyKey
            : undefined;
      if (idem != null && String(idem).length > 0) {
        headers.set(IDEMPOTENCY_HEADER, String(idem));
      }
    }

    const res = await this.fetchImpl(url, {
      ...init,
      headers,
      body: init.json !== undefined ? JSON.stringify(init.json) : init.body,
    });

    const text = await res.text();
    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = { raw: text };
      }
    }

    // Capture version headers from every response (works even without body parse)
    this._noteApiVersionHeaders(res);

    if (!res.ok) {
      const code = data?.code || data?.error || `HTTP_${res.status}`;
      const message = data?.message || data?.detail || res.statusText || "request failed";
      throw new DayError(String(code), String(message), res.status, data);
    }
    // After a successful call, optionally check for newer SDK + API (non-blocking)
    if (!url.includes("/day/sdk") && !url.includes("/day/version")) {
      this._maybeScheduleUpdateCheck();
    }
    return data;
  }

  /**
   * @param {Response} res
   */
  _noteApiVersionHeaders(res) {
    try {
      const get = (name) => {
        if (typeof res.headers?.get === "function") return res.headers.get(name);
        const h = res.headers || {};
        return h[name] || h[name.toLowerCase()] || null;
      };
      const latest = get("x-day-api-version-latest") || get("X-DAY-API-Version-Latest");
      const version = get("x-day-api-version") || get("X-DAY-API-Version");
      const min = get("x-day-api-version-min") || get("X-DAY-API-Version-Min");
      if (latest || version) {
        this.lastApiVersionHeaders = {
          version: version || null,
          latestVersion: latest || version || null,
          minSupportedVersion: min || null,
        };
        // Immediate header-based notify (no extra round trip)
        if (this.checkUpdate && latest) {
          const hdr = buildApiVersionCheckResult({
            clientApiVersion: SDK_API_VERSION,
            version: version || latest,
            latestVersion: latest,
            minSupportedVersion: min,
          });
          if ((hdr.updateAvailable || hdr.belowMinimum) && !this._apiHeaderWarned) {
            this._apiHeaderWarned = true;
            this.lastApiVersionCheck = hdr;
            if (this.warnOnUpdate && typeof console !== "undefined" && console.warn) {
              console.warn(`[day-api] ${hdr.message}`);
            }
            if (this.onApiUpdate) {
              try {
                this.onApiUpdate(hdr);
              } catch {
                /* ignore */
              }
            }
          }
        }
      }
    } catch {
      // ignore header parse issues
    }
  }

  /** Server-published latest SDK metadata. */
  sdkRelease() {
    return this.request("/api/day/sdk");
  }

  /** Server API version document. */
  apiVersion(opts = {}) {
    const q = new URLSearchParams();
    const client = opts.client || opts.clientVersion || SDK_API_VERSION;
    if (client) q.set("client", String(client));
    const qs = q.toString();
    return this.request(`/api/day/version${qs ? `?${qs}` : ""}`);
  }

  /**
   * Compare this client's SDK_API_VERSION to server latest API version.
   * @param {{ force?: boolean }} [opts]
   */
  async checkApiVersion(opts = {}) {
    if (this.lastApiVersionCheck && !opts.force) {
      return this.lastApiVersionCheck;
    }
    try {
      const remote = await this.apiVersion({ client: SDK_API_VERSION });
      const result = buildApiVersionCheckResult({
        clientApiVersion: SDK_API_VERSION,
        version: remote.version,
        latestVersion: remote.latestVersion,
        minSupportedVersion: remote.minSupportedVersion,
        docsUrl: remote.docsUrl,
        headers: remote.headers,
      });
      // Prefer explicit server client evaluation when present
      if (remote.client && remote.client.message) {
        result.message = remote.client.message;
        result.updateAvailable = remote.client.updateAvailable;
        result.belowMinimum = remote.client.belowMinimum;
        result.upToDate = remote.client.upToDate;
      }
      this.lastApiVersionCheck = result;
      if (result.updateAvailable || result.belowMinimum) {
        if (this.warnOnUpdate && typeof console !== "undefined" && console.warn) {
          console.warn(`[day-api] ${result.message}`);
        }
        if (this.onApiUpdate) {
          try {
            this.onApiUpdate(result);
          } catch {
            /* ignore */
          }
        }
      }
      return result;
    } catch (err) {
      const result = {
        schemaVersion: "day-api-update.v1",
        clientApiVersion: SDK_API_VERSION,
        serverVersion: null,
        latestVersion: null,
        updateAvailable: false,
        belowMinimum: false,
        upToDate: null,
        status: "error",
        error: err instanceof DayError ? err.message : String(err?.message || err),
        message: null,
        versionPath: "/api/day/version",
      };
      this.lastApiVersionCheck = result;
      return result;
    }
  }

  listVenues() {
    return this.request("/api/day/venues");
  }

  /**
   * Form registry (L1 venue bindings). DAY-20..26 + primary homes.
   * @param {{ chain?: string, wave?: string, ready?: boolean }} [opts]
   */
  listForms(opts = {}) {
    const q = new URLSearchParams();
    if (opts.chain) q.set("chain", opts.chain);
    if (opts.wave) q.set("wave", opts.wave);
    if (opts.ready === true) q.set("ready", "1");
    const qs = q.toString();
    return this.request(`/api/day/forms${qs ? `?${qs}` : ""}`);
  }

  /** Priority matrix for Auto Yield routing (lower priority number preferred). */
  formPriority() {
    return this.request("/api/day/forms/priority");
  }

  /** @param {string} formId e.g. form-suilend or suilend */
  getForm(formId) {
    return this.request(`/api/day/forms/${encodeURIComponent(formId)}`);
  }

  /**
   * DAY-56 public strategies (AdapterRegistry mirror). Prefer over forms for product UI.
   * @param {{ chain?: string, wave?: string, ready?: boolean, live?: boolean }} [opts]
   */
  listStrategies(opts = {}) {
    const q = new URLSearchParams();
    if (opts.chain) q.set("chain", opts.chain);
    if (opts.wave) q.set("wave", opts.wave);
    if (opts.ready === true) q.set("ready", "1");
    if (opts.live === true) q.set("live", "1");
    const qs = q.toString();
    return this.request(`/api/day/strategies${qs ? `?${qs}` : ""}`);
  }

  /**
   * GET one strategy by id.
   * **strategyId === venueId** — use bare venue keys only, e.g. `"suilend"`, `"kamino"`, `"aave-v3"`.
   * Not `form-*` (normalized client-side) and not `chain:venue` (unsupported).
   * @param {string} strategyId venue id (or legacy `form-<venue>` alias)
   */
  getStrategy(strategyId) {
    const id = normalizeStrategyId(strategyId);
    return this.request(`/api/day/strategies/${encodeURIComponent(id)}`);
  }

  strategyPriority() {
    return this.request("/api/day/strategies/priority");
  }

  /**
   * DAY-572: wallet profile metadata used for Strategy Lead display.
   * @param {string} walletAddress
   * @param {{ displayName?: string|null }} body
   */
  updateWalletProfile(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/profile`, {
      method: "PUT",
      json: body,
    });
  }

  /**
   * DAY-572: list wallet-created Strategies from the off-chain registry.
   * @param {string} walletAddress
   * @param {{ includeDeleted?: boolean }} [opts]
   */
  listWalletStrategies(walletAddress, opts = {}) {
    const q = new URLSearchParams();
    if (opts.includeDeleted === true) q.set("includeDeleted", "1");
    const qs = q.toString();
    return this.request(
      `/api/wallets/${encodeURIComponent(walletAddress)}/strategies${qs ? `?${qs}` : ""}`,
    );
  }

  /**
   * DAY-572: create a wallet-bound Strategy. Returns unsigned_tx + AgentCap contract.
   * @param {string} walletAddress
   * @param {{ strategyId?: string, name?: string, description?: string, displayName?: string, isPublic?: boolean, performanceFeeBps?: number, fees?: object, guardrails: object, idempotencyKey?: string, agentGrantee?: string, agentScopes?: string[] }} body
   */
  createWalletStrategy(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/strategies`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * DAY-572: get one wallet-bound Strategy.
   * @param {string} walletAddress
   * @param {string} strategyId
   */
  getWalletStrategy(walletAddress, strategyId) {
    return this.request(
      `/api/wallets/${encodeURIComponent(walletAddress)}/strategies/${encodeURIComponent(strategyId)}`,
    );
  }

  /**
   * DAY-572: update editable Strategy metadata. Guardrails are immutable.
   * @param {string} walletAddress
   * @param {string} strategyId
   * @param {{ name?: string, description?: string|null, displayName?: string|null, isPublic?: boolean, guardrails?: object }} body
   */
  updateWalletStrategy(walletAddress, strategyId, body = {}) {
    return this.request(
      `/api/wallets/${encodeURIComponent(walletAddress)}/strategies/${encodeURIComponent(strategyId)}`,
      {
        method: "PATCH",
        json: body,
      },
    );
  }

  /**
   * DAY-572: tombstone a wallet-bound Strategy. Returns revoke-capability unsigned_tx.
   * @param {string} walletAddress
   * @param {string} strategyId
   */
  deleteWalletStrategy(walletAddress, strategyId) {
    return this.request(
      `/api/wallets/${encodeURIComponent(walletAddress)}/strategies/${encodeURIComponent(strategyId)}`,
      { method: "DELETE" },
    );
  }

  /**
   * Prepare-only deposit plan (fee 0 on principal). Never broadcasts from client alone.
   * **strategyId === venueId** (e.g. `"suilend"`). Legacy `form-suilend` is normalized to `suilend`.
   * @param {{ strategyId: string, amountMicros: string|number, owner?: string, autoYieldEnabled?: boolean }} body
   */
  prepareStrategyDeposit(body = {}) {
    const { strategyId, ...rest } = body;
    const json = {
      ...rest,
      strategyId: normalizeStrategyId(strategyId),
    };
    return this.request("/api/day/strategies/deposit/plan", {
      method: "POST",
      json,
    });
  }

  /**
   * Prepare-only withdraw plan (fee 0 on principal).
   * **strategyId === venueId** (e.g. `"suilend"`). Legacy `form-suilend` is normalized to `suilend`.
   * @param {{ strategyId: string, amountMicros: string|number, owner?: string }} body
   */
  prepareStrategyWithdraw(body = {}) {
    const { strategyId, ...rest } = body;
    const json = {
      ...rest,
      strategyId: normalizeStrategyId(strategyId),
    };
    return this.request("/api/day/strategies/withdraw/plan", {
      method: "POST",
      json,
    });
  }

  /**
   * DAY-307: owner-signed deposit execute (Sui + Solana write venues).
   * Pass `signedTx` after the owner wallet signs the prepare plan's unsigned_tx.
   * Server broadcasts only when OPEN_YIELD_EXECUTION_ENABLED + OPEN_YIELD_ALLOW_BROADCAST.
   * Never send private keys.
   * @param {{ strategyId: string, amountMicros: string|number, owner?: string, signedTx?: string, signatures?: string[] }} body
   */
  executeStrategyDeposit(body = {}) {
    const { strategyId, ...rest } = body;
    const json = {
      ...rest,
      strategyId: normalizeStrategyId(strategyId),
    };
    return this.request("/api/day/strategies/deposit/execute", {
      method: "POST",
      json,
    });
  }

  /**
   * @deprecated Internal/legacy in-memory vault store — not the public product.
   * Prefer {@link DayClient#listStrategies} / prepareStrategy* plans.
   */
  listVaults() {
    return this.request("/api/day/vaults");
  }

  /**
   * @deprecated Internal/legacy vault store — not public product surface.
   * @param {{ name?: string, asset?: string, feeSkimBps?: number, allowedForms?: string[] }} body
   * @param {{ apiKey?: string }} [opts] optional per-call key override
   */
  createVault(body = {}, opts = {}) {
    const headers = {};
    // DAY-140 / Codex: never invent privileged keys from role — only real apiKey.
    if (opts.apiKey) headers["x-api-key"] = opts.apiKey;
    else if (this.apiKey) headers["x-api-key"] = this.apiKey;
    return this.request("/api/day/vaults", {
      method: "POST",
      json: body,
      headers,
    });
  }

  /**
   * @deprecated Internal/legacy vault store.
   * @param {string} vaultId
   */
  getVault(vaultId) {
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}`);
  }

  /**
   * @deprecated Internal/legacy vault store.
   * Liquid deposit — fee 0; strategy/auto_deploy stay OFF by default.
   * @param {string} vaultId
   * @param {{ owner: string, amountMicros: string|number }} body
   * @param {{ apiKey?: string }} [opts]
   */
  vaultDeposit(vaultId, body, opts = {}) {
    const headers = {};
    // DAY-140 / Codex: never invent privileged keys from role — only real apiKey.
    if (opts.apiKey) headers["x-api-key"] = opts.apiKey;
    else if (this.apiKey) headers["x-api-key"] = this.apiKey;
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}/deposit`, {
      method: "POST",
      json: body,
      headers,
    });
  }

  /**
   * @deprecated Internal/legacy vault store.
   * Liquid withdraw by shares — fee 0; owner path.
   * @param {string} vaultId
   * @param {{ owner: string, shares: string|number }} body
   * @param {{ apiKey?: string }} [opts]
   */
  vaultWithdraw(vaultId, body, opts = {}) {
    const headers = {};
    // DAY-140 / Codex: never invent privileged keys from role — only real apiKey.
    if (opts.apiKey) headers["x-api-key"] = opts.apiKey;
    else if (this.apiKey) headers["x-api-key"] = this.apiKey;
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}/withdraw`, {
      method: "POST",
      json: body,
      headers,
    });
  }

  /**
   * @deprecated Internal/legacy vault store.
   * Owner arm/disarm strategy (default OFF). Does not broadcast.
   * @param {string} vaultId
   * @param {{ enabled: boolean }} body
   * @param {{ apiKey?: string }} [opts]
   */
  vaultSetStrategy(vaultId, body, opts = {}) {
    const headers = {};
    // DAY-140 / Codex: never invent privileged keys from role — only real apiKey.
    if (opts.apiKey) headers["x-api-key"] = opts.apiKey;
    else if (this.apiKey) headers["x-api-key"] = this.apiKey;
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}/strategy`, {
      method: "POST",
      json: body,
      headers,
    });
  }

  /**
   * @deprecated Internal/legacy vault store.
   * Apply harvest skim to vault NAV (yield only). Permissionless poke path.
   * @param {string} vaultId
   * @param {{ grossYieldMicros: string|number, feeSkimBps?: number }} body
   */
  vaultHarvest(vaultId, body) {
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}/harvest`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * @deprecated Internal/legacy vault store.
   * Liquid→Form deploy accounting (strategy must be ON). Owner-only.
   * In-store plan/apply — no on-chain broadcast until package IDs ship.
   * @param {string} vaultId
   * @param {{ formId: string, amountMicros: string|number, dryRun?: boolean }} body
   * @param {{ apiKey?: string }} [opts]
   */
  vaultDeploy(vaultId, body, opts = {}) {
    const headers = {};
    // DAY-140 / Codex: never invent privileged keys from role — only real apiKey.
    if (opts.apiKey) headers["x-api-key"] = opts.apiKey;
    else if (this.apiKey) headers["x-api-key"] = this.apiKey;
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}/deploy`, {
      method: "POST",
      json: body,
      headers,
    });
  }

  /**
   * @deprecated Internal/legacy vault store.
   * Form→liquid undeploy accounting. Owner-only; allowed with strategy OFF.
   * @param {string} vaultId
   * @param {{ formId: string, amountMicros: string|number, dryRun?: boolean }} body
   * @param {{ apiKey?: string }} [opts]
   */
  vaultUndeploy(vaultId, body, opts = {}) {
    const headers = {};
    // DAY-140 / Codex: never invent privileged keys from role — only real apiKey.
    if (opts.apiKey) headers["x-api-key"] = opts.apiKey;
    else if (this.apiKey) headers["x-api-key"] = this.apiKey;
    return this.request(`/api/day/vaults/${encodeURIComponent(vaultId)}/undeploy`, {
      method: "POST",
      json: body,
      headers,
    });
  }

  /**
   * Failed bridge **rescue** plan (POST `/api/day/bridge/rescue`).
   * Use only when a prior bridge delivery failed/refunded/mismatched — funds
   * always return to the **owner** destination. Not for ordinary cross-chain
   * fund moves; use {@link DayClient#bridgePlan} for prepare-only Mayan lanes.
   *
   * @param {Record<string, unknown>} body
   * @param {string} [body.ownerAddress] owner destination (required)
   * @param {string} [body.asset]
   * @param {string|number} [body.amountMicros]
   */
  bridgeRescuePlan(body) {
    return this.request("/api/day/bridge/rescue", { method: "POST", json: body });
  }

  /** @param {{ minTvlUsd?: number, chain?: string, status?: string }} [opts] */
  listOpportunities(opts = {}) {
    const q = new URLSearchParams();
    if (opts.minTvlUsd != null) q.set("min_tvl_usd", String(opts.minTvlUsd));
    if (opts.chain) q.set("chain", opts.chain);
    if (opts.status) q.set("status", opts.status);
    const qs = q.toString();
    return this.request(`/api/day/opportunities${qs ? `?${qs}` : ""}`);
  }

  /** @param {string} walletAddress */
  getPosition(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/position`);
  }

  getPortfolio(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/portfolio`);
  }

  getPerformance(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/performance`);
  }

  batchPositions(wallets) {
    return this.request(`/api/wallets/batch/positions`, {
      method: "POST",
      body: JSON.stringify({ wallets }),
    });
  }

  venueApyTable(query = {}) {
    const q = new URLSearchParams(query).toString();
    return this.request(`/api/day/venues/apy${q ? `?${q}` : ""}`);
  }

  errorCatalog() {
    return this.request(`/api/day/errors`);
  }

  listWebhookEventTypes() {
    return this.request(`/api/day/webhooks/events/types`);
  }

  subscribeWebhook(body) {
    return this.request(`/api/day/webhooks`, { method: "POST", body: JSON.stringify(body || {}) });
  }

  listWebhookEvents(query = {}) {
    const q = new URLSearchParams(query).toString();
    return this.request(`/api/day/webhooks/events${q ? `?${q}` : ""}`);
  }

  /** @param {string} walletAddress */
  getAutoYield(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-yield`);
  }

  /**
   * DAY-173 / DAY-177: Autopilot status for a wallet.
   * @param {string} walletAddress
   */
  getAutopilot(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/autopilot`);
  }

  /**
   * DAY-173 / DAY-177: Decision history.
   * @param {string} walletAddress
   * @param {{ limit?: number, id?: string }} [opts]
   */
  getAutopilotHistory(walletAddress, opts = {}) {
    if (opts.id) {
      return this.request(
        `/api/wallets/${encodeURIComponent(walletAddress)}/autopilot/history/${encodeURIComponent(opts.id)}`,
      );
    }
    const q = new URLSearchParams();
    if (opts.limit != null) q.set("limit", String(opts.limit));
    const qs = q.toString();
    return this.request(
      `/api/wallets/${encodeURIComponent(walletAddress)}/autopilot/history${qs ? `?${qs}` : ""}`,
    );
  }

  /**
   * DAY-175 / DAY-177: Enable Autopilot (+ optional policy arming).
   * @param {string} walletAddress
   * @param {{ goal?: string, capabilities?: string[], armAutoYield?: boolean, targetVenue?: string, targetChain?: string, maxStakeMicros?: string|number, autoPay?: object }} [body]
   */
  enableAutopilot(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/autopilot/enable`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * DAY-175 / DAY-177: Disable Autopilot (positions unchanged).
   * @param {string} walletAddress
   * @param {Record<string, unknown>} [body]
   */
  disableAutopilot(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/autopilot/disable`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * DAY-172 / DAY-177: Dry-run Autopilot proposals.
   * @param {string} walletAddress
   * @param {Record<string, unknown>} [body]
   */
  previewAutopilot(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/autopilot/preview`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * DAY-172 / DAY-177: One Autopilot decision cycle.
   * @param {string} walletAddress
   * @param {{ execute?: boolean, force?: boolean, chain?: string, fixtureGrossYieldMicros?: string, compound?: boolean, idempotencyKey?: string }} [body]
   */
  tickAutopilot(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/autopilot/tick`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * @param {string} walletAddress
   * @param {{ enabled: boolean, targetVenue?: string, maxStakeMicros?: string|number }} body
   */
  setAutoYield(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-yield`, {
      method: "PUT",
      json: body,
    });
  }

  /**
   * Prepare-only route plan. **owner|agent** auth (`X-API-Key`).
   * @param {string} walletAddress
   * @param {Record<string, unknown>} body
   */
  previewRoute(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/preview`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * Credit/route funds for a wallet. **Owner-only** auth (`X-API-Key`).
   * Agent keys receive 403. Prefer {@link DayClient#previewRoute} for dry-run.
   * @param {string} walletAddress
   * @param {Record<string, unknown>} body
   */
  routeYield(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/route`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * @param {string} walletAddress
   * @param {{ compound?: boolean, execute?: boolean, payPercentage?: number }} [body]
   */
  harvest(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/harvest`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * Owner only — agent keys should receive UNAUTHORIZED.
   * @param {string} walletAddress
   * @param {{ amountMicros: string|number, token?: string, unstakeFirst?: boolean }} body
   */
  withdraw(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/withdraw`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * GET Auto Pay config + allowlist (day-auto-pay.v2).
   * @param {string} walletAddress
   */
  getAutoPay(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-pay`);
  }

  /**
   * Configure Auto Pay (owner). Tier1 self-funding; Tier2 blocked without legal go.
   * @param {string} walletAddress
   * @param {object} body
   */
  enableAutoPay(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-pay`, {
      method: "POST",
      json: body,
    });
  }

  /** @param {string} walletAddress */
  getAutoPayPayees(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-pay/payees`);
  }

  /**
   * @param {string} walletAddress
   * @param {{ payees: object[] }} body
   */
  setAutoPayPayees(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-pay/payees`, {
      method: "PUT",
      json: body,
    });
  }

  /**
   * @param {string} walletAddress
   * @param {object} [body]
   */
  previewAutoPay(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-pay/preview`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * Manual Auto Pay trigger (owner) — prepare-only plans.
   * @param {string} walletAddress
   * @param {object} [body]
   */
  triggerAutoPay(walletAddress, body = {}) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-pay/trigger`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * Public Auto Pay residual plan.
   * @param {object} body
   */
  autoPayPlan(body = {}) {
    return this.request(`/api/day/auto-pay/plan`, { method: "POST", json: body });
  }

  /** Phase 1 readiness (launchHomes: sui + solana) */
  readiness() {
    return this.request("/api/day/readiness");
  }

  /**
   * Public protocol treasury addresses (Sui / Solana / EVM).
   * Public addresses only — private keys are never exposed by the API.
   */
  treasury() {
    return this.request("/api/day/treasury");
  }

  /** Active network profile (mainnet | testnet). */
  network() {
    return this.request("/api/day/network");
  }

  /**
   * @param {{ chain?: 'sui'|'solana' }} [opts]
   */
  listVenuesByChain(opts = {}) {
    const q = opts.chain ? `?chain=${encodeURIComponent(opts.chain)}` : "";
    return this.request(`/api/day/venues${q}`);
  }

  solanaApys() {
    return this.request("/api/day/solana/apys");
  }

  /**
   * @param {Record<string, unknown>} body
   */
  solanaStakePlan(body) {
    return this.request("/api/day/solana/stake/plan", { method: "POST", json: body });
  }

  /**
   * @param {string} walletAddress
   * @param {{ amountMicros: string|number, chain?: string, venue?: string, idempotencyKey?: string }} body
   */
  stake(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-yield/stake`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * @param {string} walletAddress
   * @param {{ amountMicros: string|number, chain?: string, venue?: string }} body
   */
  unstake(walletAddress, body) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/auto-yield/unstake`, {
      method: "POST",
      json: body,
    });
  }

  /**
   * Prepare a Mayan cross-chain **bridge plan** (POST `/api/day/bridge/plan`).
   * Prepare-only unless server execution is enabled and `execute: true`.
   *
   * Required fields: `sourceChain`, `destChain`, `amountMicros`, `sourceAddress`,
   * `destinationAddress`. Aliases: `srcChain`/`fromChain`, `dstChain`/`toChain`,
   * `amount`, `from`, `to`. Supported lanes include Sui↔Solana and Base/Eth→Sui|Sol.
   *
   * Blocked responses echo normalized fields plus `blockers`, `blockerDetails`,
   * `requiredFields`, and `supportedLanes`. Distinct from {@link DayClient#bridgeRescuePlan}
   * (failed-delivery rescue to owner).
   *
   * @param {Record<string, unknown>} body
   * @param {string} [body.sourceChain] aliases: srcChain, fromChain
   * @param {string} [body.destChain] aliases: dstChain, toChain
   * @param {string|number} [body.amountMicros] aliases: amount (micros integer string)
   * @param {string} [body.sourceAddress] aliases: from
   * @param {string} [body.destinationAddress] aliases: to
   * @param {boolean} [body.execute]
   */
  bridgePlan(body) {
    return this.request("/api/day/bridge/plan", { method: "POST", json: body });
  }

  /** Dual-home funding snapshot (honest null APYs). */
  getFunding(walletAddress) {
    return this.request(`/api/wallets/${encodeURIComponent(walletAddress)}/funding`);
  }

  /** Redacted audit trail. */
  listAudits(opts = {}) {
    const q = new URLSearchParams();
    if (opts.walletAddress) q.set("wallet_address", opts.walletAddress);
    if (opts.action) q.set("action", opts.action);
    if (opts.limit != null) q.set("limit", String(opts.limit));
    const qs = q.toString();
    return this.request(`/api/day/audits${qs ? `?${qs}` : ""}`);
  }

  /** Solana public wallet balances (read-only). */
  solanaWalletBalance(address) {
    return this.request(`/api/day/solana/wallet-balance?address=${encodeURIComponent(address)}`);
  }

  /** Sui public wallet balances (read-only). */
  suiWalletBalance(address) {
    return this.request(`/api/day/sui/wallet-balance?address=${encodeURIComponent(address)}`);
  }

  /** Base public wallet balances ETH + USDC (read-only, DAY-235). */
  baseWalletBalance(address) {
    return this.request(`/api/day/base/wallet-balance?address=${encodeURIComponent(address)}`);
  }

  /** Arbitrum public wallet balances ETH + USDC (read-only; N/A on RPC fail). */
  arbitrumWalletBalance(address) {
    return this.request(
      `/api/day/arbitrum/wallet-balance?address=${encodeURIComponent(address)}`,
    );
  }

  /** DAY-STATS market snapshot (TVL map + adapter APY). */
  marketStats() {
    return this.request("/api/day/markets/stats");
  }

  /**
   * DAY-MAP DefiLlama ≥$10M venue map (map only — not execution truth).
   * @param {{ minTvlUsd?: number, chain?: string }} [opts]
   */
  listMapVenues(opts = {}) {
    const q = new URLSearchParams();
    if (opts.minTvlUsd != null) q.set("minTvlUsd", String(opts.minTvlUsd));
    if (opts.chain) q.set("chain", opts.chain);
    const qs = q.toString();
    return this.request(`/api/day/map/venues${qs ? `?${qs}` : ""}`);
  }

  /** Alias for {@link DayClient#listMapVenues}. */
  mapVenues(opts = {}) {
    return this.listMapVenues(opts);
  }

  /**
   * Multi-chain package IDs (day-packages.v1).
   * Dual-writes Sui top-level packageId / upgradeCapStatus for legacy clients.
   */
  packages() {
    return this.request("/api/day/packages");
  }

  /** Agent decision surface — prepare_only until broadcast go. */
  whatPossible() {
    return this.request("/api/day/possible");
  }

  /**
   * Arbitrum expansion profile.
   * Registry may be live; writeReady/liveMoneyPath false while adapters stub.
   */
  arbitrumProfile() {
    return this.request("/api/day/arbitrum");
  }

  /**
   * Arbitrum enablement / write gate.
   * PREPARE_OK_STUBS = prepare only; broadcast hard-gated until writeReady + write go.
   */
  arbitrumEnablement() {
    return this.request("/api/day/arbitrum/enablement");
  }

  /** Base expansion profile (stubs until enablement). */
  baseProfile() {
    return this.request("/api/day/base");
  }

  /** Base enablement gate (NO_GO until OPEN_YIELD_BASE_EXECUTION). */
  baseEnablement() {
    return this.request("/api/day/base/enablement");
  }
}


/**
 * Wallet-scoped yield routing helper (owner-only).
 *
 * Calls `/api/wallets/{address}/preview` (owner|agent) or falls back to
 * `/api/wallets/{address}/route` (owner). **Not a public endpoint** — requires
 * an explicit owner/agent `apiKey` and `walletAddress`. Never defaults walletAddress
 * to `"default"`.
 *
 * Prefer public prepare-only surfaces when you do not own a wallet:
 * `DayClient.prepareStrategyDeposit` / `listStrategies` / `listMapVenues`.
 *
 * @param {{
 *   amount: number|string,
 *   walletAddress: string,
 *   apiKey: string,
 *   token?: string,
 *   goal?: string,
 *   baseUrl?: string,
 *   execute?: boolean,
 *   fetchImpl?: typeof fetch,
 * }} input
 */
export async function routeYield(input = {}) {
  const amount = input.amount;
  if (amount == null || amount === "") {
    throw new DayError("INVALID_AMOUNT", "amount is required");
  }
  const apiKey = input.apiKey != null ? String(input.apiKey).trim() : "";
  if (!apiKey) {
    throw new DayError(
      "INVALID_CONFIG",
      "routeYield requires apiKey (owner or agent key). Wallet preview/route are owner-scoped — not public. Use prepareStrategyDeposit / listStrategies for public prepare paths.",
    );
  }
  const walletAddress =
    input.walletAddress != null ? String(input.walletAddress).trim() : "";
  if (!walletAddress) {
    throw new DayError(
      "INVALID_CONFIG",
      'routeYield requires walletAddress. Wallet preview/route are owner-scoped — do not omit or default to "default".',
    );
  }
  const client = new DayClient({
    baseUrl: input.baseUrl || "https://dayprotocol.com",
    apiKey,
    fetchImpl: input.fetchImpl,
  });
  const body = {
    amountMicros: toMicrosString(amount, input.token || "USDC"),
    token: input.token || "USDC",
    goal: input.goal || "stable_yield_for_agent",
    execute: input.execute === true,
  };
  // Prefer prepare/preview surface; fall back to owner route
  try {
    return await client.previewRoute(walletAddress, body);
  } catch (err) {
    if (err instanceof DayError && (err.status === 404 || err.status === 405)) {
      return client.routeYield(walletAddress, body);
    }
    throw err;
  }
}

export default DayClient;
