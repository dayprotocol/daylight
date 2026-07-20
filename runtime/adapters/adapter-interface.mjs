/**
 * DAY adapter interface (DAY-195 / developer guide §2).
 *
 * Canonical public verbs — only these four:
 *   deposit · withdraw · harvest · read_apy
 *
 * Cage planKinds map 1:1 onto the money moves:
 *   ROUTE ≈ deposit · EXIT ≈ withdraw · HARVEST ≈ harvest
 *
 * Internal form modules historically used supply / claim_yield; those remain
 * accepted as aliases so existing adapters stay conforming without a big bang.
 *
 * Rules:
 * - Never invent APY or claim micros (null / N/A / blocked).
 * - Prepare-only by default; owner must sign; no server custody.
 * - Wallet address is identity (no character/account).
 */

export const ADAPTER_INTERFACE_SCHEMA = "day-adapter-interface.v1";
export const ADAPTER_RESULT_SCHEMA = "day-adapter-result.v1";
export const ADAPTER_PREPARE_SCHEMA = "day-adapter-prepare.v1";

/**
 * Public interface verbs only.
 * @typedef {"deposit"|"withdraw"|"harvest"|"read_apy"} AdapterAction
 */

/** @type {readonly AdapterAction[]} */
export const ADAPTER_ACTIONS = Object.freeze([
  "deposit",
  "withdraw",
  "harvest",
  "read_apy",
]);

/** Money-moving subset (excludes pure read). */
export const ADAPTER_WRITE_ACTIONS = Object.freeze([
  "deposit",
  "withdraw",
  "harvest",
]);

/**
 * Internal form-layer verbs (legacy modules + form-registry).
 * @typedef {"supply"|"withdraw"|"claim_yield"|"read_apy"} FormAction
 */

/** @type {readonly FormAction[]} */
export const FORM_ACTIONS = Object.freeze([
  "read_apy",
  "supply",
  "withdraw",
  "claim_yield",
]);

/**
 * Cage plan kinds for single-leg venue prepares.
 * @typedef {"ROUTE"|"EXIT"|"HARVEST"} AdapterPlanKind
 */

export const ADAPTER_PLAN_KINDS = Object.freeze(["ROUTE", "EXIT", "HARVEST"]);

/**
 * Free-form input → canonical AdapterAction, or null if unsupported.
 * Accepts public verbs, form verbs, and cage planKinds / aliases.
 *
 * @param {unknown} action
 * @returns {AdapterAction|null}
 */
export function normalizeAdapterAction(action) {
  if (action == null || action === "") return null;
  const raw = String(action).trim();
  const lower = raw.toLowerCase().replace(/-/g, "_");
  const upper = raw.toUpperCase().replace(/-/g, "_");

  if (lower === "deposit" || lower === "supply" || lower === "route" || lower === "compound") {
    return "deposit";
  }
  if (lower === "withdraw" || lower === "exit") {
    return "withdraw";
  }
  if (
    lower === "harvest" ||
    lower === "claim_yield" ||
    lower === "claim" ||
    lower === "claimyield"
  ) {
    return "harvest";
  }
  if (lower === "read_apy" || lower === "readapy" || lower === "apy") {
    return "read_apy";
  }

  // Cage planKinds
  if (upper === "ROUTE" || upper === "COMPOUND") return "deposit";
  if (upper === "EXIT") return "withdraw";
  if (upper === "HARVEST") return "harvest";

  return null;
}

/**
 * Canonical adapter action → internal form verb (shared.mjs / form-registry).
 * @param {unknown} action
 * @returns {FormAction|null}
 */
export function toFormAction(action) {
  const a = normalizeAdapterAction(action);
  if (a === "deposit") return "supply";
  if (a === "withdraw") return "withdraw";
  if (a === "harvest") return "claim_yield";
  if (a === "read_apy") return "read_apy";
  return null;
}

/**
 * Canonical adapter action → cage planKind (single-leg money moves only).
 * @param {unknown} action
 * @returns {AdapterPlanKind|null}
 */
export function toPlanKind(action) {
  const a = normalizeAdapterAction(action);
  if (a === "deposit") return "ROUTE";
  if (a === "withdraw") return "EXIT";
  if (a === "harvest") return "HARVEST";
  return null;
}

/**
 * True if action is one of the four public verbs (after normalize).
 * @param {unknown} action
 */
export function isAdapterAction(action) {
  return normalizeAdapterAction(action) != null;
}

/**
 * True if action is a write (deposit/withdraw/harvest).
 * @param {unknown} action
 */
export function isAdapterWriteAction(action) {
  const a = normalizeAdapterAction(action);
  return a != null && a !== "read_apy";
}

/**
 * Public surface description (docs / OpenAPI / agents).
 */
export function listAdapterInterface() {
  return Object.freeze({
    schemaVersion: ADAPTER_INTERFACE_SCHEMA,
    actions: [...ADAPTER_ACTIONS],
    writeActions: [...ADAPTER_WRITE_ACTIONS],
    formAliases: Object.freeze({
      deposit: "supply",
      withdraw: "withdraw",
      harvest: "claim_yield",
      read_apy: "read_apy",
    }),
    planKinds: Object.freeze({
      deposit: "ROUTE",
      withdraw: "EXIT",
      harvest: "HARVEST",
      read_apy: null,
    }),
    notes: Object.freeze([
      "public_verbs_only_deposit_withdraw_harvest_read_apy",
      "form_modules_may_use_supply_claim_yield_aliases",
      "never_invent_apy_or_claim_micros",
      "prepare_only_default_owner_must_sign",
      "wallet_address_is_identity",
    ]),
  });
}

/**
 * Soft check that a venue adapter module conforms to the interface.
 * Does not execute network calls — shape only.
 *
 * @param {object} adapter
 * @param {object} [opts]
 * @param {string} [opts.expectedVenueId]
 * @param {string} [opts.expectedChain]
 * @returns {{ ok: true, venueId: string, chain: string } | { ok: false, reason: string, detail?: object }}
 */
export function assertAdapterConforms(adapter, opts = {}) {
  if (!adapter || typeof adapter !== "object") {
    return { ok: false, reason: "adapter_missing" };
  }
  if (typeof adapter.execute !== "function") {
    return { ok: false, reason: "missing_execute" };
  }
  const venueId = String(adapter.venueId || "").toLowerCase();
  if (!venueId) {
    return { ok: false, reason: "missing_venueId" };
  }
  if (opts.expectedVenueId && venueId !== String(opts.expectedVenueId).toLowerCase()) {
    return {
      ok: false,
      reason: "venueId_mismatch",
      detail: { expected: opts.expectedVenueId, got: venueId },
    };
  }
  const chain = String(adapter.chain || "").toLowerCase();
  if (!chain) {
    return { ok: false, reason: "missing_chain" };
  }
  if (opts.expectedChain && chain !== String(opts.expectedChain).toLowerCase()) {
    return {
      ok: false,
      reason: "chain_mismatch",
      detail: { expected: opts.expectedChain, got: chain },
    };
  }
  const readiness = adapter.readiness != null ? String(adapter.readiness) : null;
  if (readiness && !["live", "mock", "stub", "partial", "map"].includes(readiness)) {
    return { ok: false, reason: "invalid_readiness", detail: { readiness } };
  }
  return { ok: true, venueId, chain, readiness };
}

/**
 * Assert every entry in a map of adapters conforms; collect failures.
 * @param {Record<string, object>} adapters
 * @returns {{ ok: boolean, checked: number, failures: Array<{ venueId: string, reason: string }> }}
 */
export function assertAllAdaptersConform(adapters = {}) {
  const failures = [];
  let checked = 0;
  for (const [key, adapter] of Object.entries(adapters)) {
    checked += 1;
    const r = assertAdapterConforms(adapter, { expectedVenueId: key });
    if (!r.ok) {
      failures.push({ venueId: key, reason: r.reason, detail: r.detail || null });
    }
  }
  return { ok: failures.length === 0, checked, failures };
}

/**
 * Normalize payload.action to form verb before execute, keeping public action in result.
 * @param {object} payload
 * @returns {{ payload: object, publicAction: AdapterAction|null, formAction: FormAction|null }}
 */
export function normalizePayloadAction(payload = {}) {
  const publicAction = normalizeAdapterAction(payload.action);
  const formAction = toFormAction(publicAction);
  if (!formAction) {
    return { payload, publicAction: null, formAction: null };
  }
  return {
    payload: { ...payload, action: formAction },
    publicAction,
    formAction,
  };
}
