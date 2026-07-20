/**
 * Streamable HTTP transport for DAY GUIDE MCP (JSON response mode).
 *
 * Single endpoint (default `/mcp`) — POST for JSON-RPC; GET returns 405
 * (SSE optional stream not required when enableJsonResponse); DELETE ends session.
 *
 * Hosted path: mount on the DAY API via `createEmbeddedMcp` +
 * `handleMcpHttpRequest` at `/api/mcp` (and optional `/mcp`).
 *
 * Security:
 * - validates Origin when DAY_MCP_ALLOWED_ORIGINS is set
 * - defaults bind 127.0.0.1 (override with DAY_MCP_HOST)
 */

import http from "node:http";
import { createMcpHandler } from "./protocol.mjs";
import { createDayProxy } from "./proxy.mjs";

/**
 * DAY-624 / DAY-261: max request body size (bytes) to prevent memory-exhaustion
 * DoS. Mirrors MAX_JSON_BODY_BYTES in api/server.mjs (default 256 KiB).
 */
export const MAX_BODY_BYTES = Number(process.env.DAY_MCP_MAX_BODY_BYTES || 256 * 1024);

/** Canonical hosted paths served by open-yield-api (nginx proxies /api/*). */
export const HOSTED_MCP_PATHS = Object.freeze(["/api/mcp", "/mcp"]);

/**
 * Create an MCP handler + proxy for embedding in the DAY API process.
 * @param {{
 *   proxy?: ReturnType<typeof createDayProxy>,
 *   mvpOnly?: boolean,
 *   baseUrl?: string,
 *   apiKey?: string|null,
 *   allowedOrigins?: string[]|null,
 * }} [opts]
 */
export function createEmbeddedMcp(opts = {}) {
  const proxy =
    opts.proxy ||
    createDayProxy({
      baseUrl: opts.baseUrl,
      apiKey: opts.apiKey,
    });
  const handler = createMcpHandler({
    proxy,
    mvpOnly: opts.mvpOnly,
  });
  const allowedOrigins =
    opts.allowedOrigins !== undefined
      ? opts.allowedOrigins
      : parseOrigins(process.env.DAY_MCP_ALLOWED_ORIGINS);
  return { handler, proxy, allowedOrigins };
}

/**
 * Dispatch one HTTP request to MCP JSON-RPC (embeddable in DAY API).
 * Path must already match a hosted MCP path; callers gate on pathname.
 *
 * @param {import("node:http").IncomingMessage} req
 * @param {import("node:http").ServerResponse} res
 * @param {{
 *   handler: ReturnType<typeof createMcpHandler>,
 *   mcpPath?: string,
 *   allowedOrigins?: string[]|null,
 *   skipPathCheck?: boolean,
 * }} ctx
 */
export async function handleMcpHttpRequest(req, res, ctx) {
  await onRequest(req, res, {
    handler: ctx.handler,
    mcpPath: ctx.mcpPath || "/api/mcp",
    allowedOrigins: ctx.allowedOrigins ?? null,
    skipPathCheck: ctx.skipPathCheck === true,
  });
}

/**
 * @param {{
 *   port?: number,
 *   host?: string,
 *   path?: string,
 *   proxy?: ReturnType<typeof createDayProxy>,
 *   mvpOnly?: boolean,
 *   allowedOrigins?: string[]|null,
 * }} [opts]
 */
export async function startMcpServer(opts = {}) {
  const port = Number(opts.port ?? process.env.DAY_MCP_PORT ?? 8790);
  const host = String(opts.host ?? process.env.DAY_MCP_HOST ?? "127.0.0.1");
  const mcpPath = normalizePath(opts.path ?? process.env.DAY_MCP_PATH ?? "/mcp");
  const allowedOrigins =
    opts.allowedOrigins !== undefined
      ? opts.allowedOrigins
      : parseOrigins(process.env.DAY_MCP_ALLOWED_ORIGINS);

  const handler = createMcpHandler({
    proxy: opts.proxy || createDayProxy(),
    mvpOnly: opts.mvpOnly,
  });

  const server = http.createServer(async (req, res) => {
    try {
      await onRequest(req, res, { handler, mcpPath, allowedOrigins });
    } catch (err) {
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            error: {
              code: -32603,
              message: err instanceof Error ? err.message : "Internal error",
            },
            id: null,
          }),
        );
      }
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => resolve(undefined));
  });

  const baseUrl = `http://${host}:${port}${mcpPath}`;
  return {
    server,
    handler,
    host,
    port,
    path: mcpPath,
    url: baseUrl,
    async close() {
      await new Promise((resolve) => server.close(() => resolve(undefined)));
    },
  };
}

/**
 * @param {import("node:http").IncomingMessage} req
 * @param {import("node:http").ServerResponse} res
 * @param {{
 *   handler: ReturnType<typeof createMcpHandler>,
 *   mcpPath: string,
 *   allowedOrigins: string[]|null,
 *   skipPathCheck?: boolean,
 * }} ctx
 */
async function onRequest(req, res, ctx) {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const mcpPath = ctx.mcpPath.replace(/\/+$/, "") || "/mcp";

  // Health for standalone MCP process load balancers (not used when embedded)
  if (path === "/health" && req.method === "GET" && !ctx.skipPathCheck) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, service: "day-guide-mcp" }));
    return;
  }

  if (!ctx.skipPathCheck && path !== mcpPath) {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not_found", hint: `MCP endpoint is ${mcpPath}` }));
    return;
  }

  // Origin check (DNS rebinding guard when allowlist configured)
  if (ctx.allowedOrigins && ctx.allowedOrigins.length > 0) {
    const origin = req.headers.origin;
    if (origin && !ctx.allowedOrigins.includes(origin) && !ctx.allowedOrigins.includes("*")) {
      res.writeHead(403, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "origin_not_allowed" }));
      return;
    }
  }

  // Discovery / liveness for hosted MCP (GET on MCP path)
  if (req.method === "GET") {
    // JSON-response mode: no standalone SSE stream — return service discovery
    res.writeHead(405, {
      allow: "POST, DELETE",
      "content-type": "application/json",
    });
    res.end(
      JSON.stringify({
        jsonrpc: "2.0",
        error: {
          code: -32000,
          message: "SSE GET not offered; use POST JSON response mode",
        },
        id: null,
        // Non-spec discovery hints for operators (clients ignore unknown fields)
        day: {
          service: "day-guide-mcp",
          transport: "streamable-http-json",
          path: mcpPath,
          hosted: true,
        },
      }),
    );
    return;
  }

  const sessionHeader = header(req, "mcp-session-id");

  if (req.method === "DELETE") {
    if (sessionHeader) ctx.handler.terminateSession(sessionHeader);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  if (req.method !== "POST") {
    res.writeHead(405, { allow: "POST, DELETE", "content-type": "application/json" });
    res.end(JSON.stringify({ error: "method_not_allowed" }));
    return;
  }

  let bodyText;
  try {
    bodyText = await readBody(req);
  } catch (err) {
    if (err && err.status === 413) {
      res.writeHead(413, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          error: { code: -32600, message: "Payload too large" },
          id: null,
        }),
      );
      return;
    }
    throw err;
  }

  let message;
  try {
    message = bodyText ? JSON.parse(bodyText) : null;
  } catch {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        jsonrpc: "2.0",
        error: { code: -32700, message: "Parse error" },
        id: null,
      }),
    );
    return;
  }

  const isInitialize =
    message &&
    !Array.isArray(message) &&
    message.method === "initialize";

  // Stateful: non-init requests should carry session (soft-require after init)
  if (!isInitialize && sessionHeader && !ctx.handler.getSession(sessionHeader)) {
    res.writeHead(404, { "content-type": "application/json" });
    res.end(
      JSON.stringify({
        jsonrpc: "2.0",
        error: { code: -32001, message: "Session not found" },
        id: message?.id ?? null,
      }),
    );
    return;
  }

  const result = await ctx.handler.handleMessage(message, {
    sessionId: sessionHeader,
  });

  if (result.httpStatus === 202 || result.response === null) {
    const headers = { "content-type": "application/json" };
    if (result.sessionId) headers["mcp-session-id"] = result.sessionId;
    res.writeHead(202, headers);
    res.end();
    return;
  }

  const headers = {
    "content-type": "application/json",
    "cache-control": "no-store",
  };
  if (result.sessionId) headers["mcp-session-id"] = result.sessionId;
  res.writeHead(result.httpStatus || 200, headers);
  res.end(JSON.stringify(result.response));
}

function normalizePath(p) {
  let s = String(p || "/mcp");
  if (!s.startsWith("/")) s = `/${s}`;
  return s;
}

function parseOrigins(raw) {
  if (!raw || !String(raw).trim()) return null;
  return String(raw)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

function header(req, name) {
  const v = req.headers[name.toLowerCase()];
  if (Array.isArray(v)) return v[0] || null;
  return v || null;
}

/**
 * Buffer a request body with a hard byte cap. On exceeding `maxBytes` the
 * stream is destroyed and the promise rejects with a 413-tagged error so the
 * caller can return HTTP 413 instead of buffering unbounded memory.
 * @param {import("node:http").IncomingMessage} req
 * @param {{ maxBytes?: number }} [opts]
 */
export function readBody(req, opts = {}) {
  const maxBytes = Number(opts.maxBytes || MAX_BODY_BYTES);
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let rejected = false;
    req.on("data", (c) => {
      if (rejected) return;
      total += c.length;
      if (total > maxBytes) {
        rejected = true;
        try {
          req.destroy();
        } catch {
          /* ignore */
        }
        reject(
          Object.assign(new Error("request body too large"), {
            status: 413,
            code: "PAYLOAD_TOO_LARGE",
          }),
        );
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      if (rejected) return;
      resolve(Buffer.concat(chunks).toString("utf8"));
    });
    req.on("error", (err) => {
      if (rejected) return;
      reject(err);
    });
  });
}
