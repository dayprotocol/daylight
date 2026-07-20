/**
 * Proxy MCP tool calls → DAY HTTP API (/api/v1/*).
 * Wallet-only; never invents amounts or APY.
 */

import { getSkillByName, planSkillCall } from "./tools.mjs";

/**
 * @typedef {object} ProxyOptions
 * @property {string} [baseUrl] DAY API origin or …/api/v1 (default env DAY_API_BASE / dayprotocol.com)
 * @property {string} [apiKey] Default X-API-Key (env DAY_API_KEY)
 * @property {typeof fetch} [fetchImpl]
 */

/**
 * @param {ProxyOptions} [opts]
 */
export function createDayProxy(opts = {}) {
  const baseUrl = String(
    opts.baseUrl ||
      process.env.DAY_API_BASE ||
      process.env.DAY_BASE_URL ||
      "https://dayprotocol.com",
  ).replace(/\/+$/, "");
  const defaultApiKey =
    opts.apiKey || process.env.DAY_API_KEY || process.env.DAY_OWNER_API_KEY || null;
  const fetchImpl = opts.fetchImpl || globalThis.fetch;

  /**
   * @param {string} toolName
   * @param {Record<string, unknown>} args
   */
  async function callTool(toolName, args = {}) {
    const skill = getSkillByName(toolName);
    if (!skill) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              ok: false,
              error: "unknown_tool",
              toolName,
              hint: "Use tools/list; names mirror agents/skills.mjs",
            }),
          },
        ],
      };
    }

    const walletAddress =
      args.walletAddress != null ? String(args.walletAddress) : undefined;
    const plan = planSkillCall(toolName, {
      walletAddress,
      id: args.id != null ? String(args.id) : undefined,
      strategyId: args.strategyId != null ? String(args.strategyId) : undefined,
      body: args.body && typeof args.body === "object" ? args.body : null,
    });
    if (!plan.ok) {
      return {
        isError: true,
        content: [{ type: "text", text: JSON.stringify(plan) }],
      };
    }

    let path = plan.path;
    // Public wallet-balance tools take ?address=
    if (
      (toolName === "walletBalanceSui" || toolName === "walletBalanceSol") &&
      args.address
    ) {
      const q = new URLSearchParams({ address: String(args.address) });
      path = `${path}?${q.toString()}`;
    }

    const url = resolveUrl(baseUrl, path);
    const headers = {
      accept: "application/json",
      "user-agent": "day-guide-mcp/0.1.0",
    };
    const apiKey = args.apiKey != null ? String(args.apiKey) : defaultApiKey;
    if (apiKey) headers["X-API-Key"] = apiKey;
    if (args.idempotencyKey) {
      headers["Idempotency-Key"] = String(args.idempotencyKey);
    }

    const init = { method: plan.method, headers };
    if (plan.method !== "GET" && plan.method !== "HEAD") {
      headers["content-type"] = "application/json";
      init.body = JSON.stringify(plan.body || args.body || {});
    }

    if (typeof fetchImpl !== "function") {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              ok: false,
              error: "fetch_unavailable",
              plan: { method: plan.method, path: plan.path, auth: plan.auth },
            }),
          },
        ],
      };
    }

    try {
      const res = await fetchImpl(url, init);
      const text = await res.text();
      let data;
      try {
        data = text ? JSON.parse(text) : null;
      } catch {
        data = { raw: text };
      }
      const payload = {
        ok: res.ok,
        status: res.status,
        skill: toolName,
        method: plan.method,
        path: plan.path,
        auth: plan.auth,
        data,
      };
      return {
        isError: !res.ok,
        content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
      };
    } catch (err) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: JSON.stringify({
              ok: false,
              error: "proxy_fetch_failed",
              message: err instanceof Error ? err.message : String(err),
              plan: { method: plan.method, path: plan.path },
            }),
          },
        ],
      };
    }
  }

  return { callTool, baseUrl, defaultApiKey: Boolean(defaultApiKey) };
}

/**
 * Join base + path without double /api/v1.
 * @param {string} baseUrl
 * @param {string} path  e.g. /api/v1/day/packages
 */
export function resolveUrl(baseUrl, path) {
  let base = String(baseUrl || "").replace(/\/+$/, "");
  let p = String(path || "");
  if (!p.startsWith("/")) p = `/${p}`;

  // planSkillCall already returns /api/v1/...
  if (/\/api\/v1$/i.test(base)) {
    if (p.startsWith("/api/v1/")) p = p.slice("/api/v1".length);
    else if (p === "/api/v1") p = "/";
  }
  return `${base}${p}`;
}
