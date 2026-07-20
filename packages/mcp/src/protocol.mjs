/**
 * Minimal MCP JSON-RPC handler (Streamable HTTP JSON response mode).
 * Spec: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
 *
 * Supports: initialize, ping, tools/list, tools/call, notifications/initialized.
 * No resources/prompts in v0.1 (tools-only GUIDE surface).
 */

import { randomUUID } from "node:crypto";
import {
  MCP_PROTOCOL_VERSION,
  MCP_SERVER_INFO,
  listMcpTools,
  getSkillByName,
} from "./tools.mjs";
import { createDayProxy } from "./proxy.mjs";

/**
 * @typedef {object} Session
 * @property {string} id
 * @property {boolean} initialized
 * @property {string} [clientProtocolVersion]
 */

/**
 * @param {{
 *   proxy?: ReturnType<typeof createDayProxy>,
 *   mvpOnly?: boolean,
 *   sessionIdGenerator?: () => string,
 * }} [opts]
 */
export function createMcpHandler(opts = {}) {
  const proxy = opts.proxy || createDayProxy();
  const mvpOnly = opts.mvpOnly !== false; // default: expose MVP skill tools
  const sessionIdGenerator = opts.sessionIdGenerator || (() => randomUUID());
  /** @type {Map<string, Session>} */
  const sessions = new Map();

  /**
   * Handle one JSON-RPC message (request or notification).
   * @param {object} message
   * @param {{ sessionId?: string|null, isInitialize?: boolean }} [ctx]
   * @returns {Promise<{ response: object|null, sessionId?: string|null, httpStatus?: number }>}
   */
  async function handleMessage(message, ctx = {}) {
    if (!message || typeof message !== "object") {
      return {
        response: jsonRpcError(null, -32700, "Parse error"),
        httpStatus: 400,
      };
    }

    // Batch not required for GUIDE v0.1 — reject multi-arrays for simplicity
    if (Array.isArray(message)) {
      return {
        response: jsonRpcError(null, -32600, "Batch not supported in day-guide v0.1"),
        httpStatus: 400,
      };
    }

    const { method, id, params } = message;
    const isNotification = id === undefined;

    // notifications → 202, no body (handled by transport)
    if (isNotification) {
      if (method === "notifications/initialized") {
        const sid = ctx.sessionId;
        if (sid && sessions.has(sid)) {
          sessions.get(sid).initialized = true;
        }
      }
      return { response: null, sessionId: ctx.sessionId, httpStatus: 202 };
    }

    if (method === "initialize") {
      const sid = sessionIdGenerator();
      sessions.set(sid, {
        id: sid,
        initialized: false,
        clientProtocolVersion: params?.protocolVersion,
      });
      const response = {
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: MCP_PROTOCOL_VERSION,
          capabilities: {
            tools: { listChanged: false },
          },
          serverInfo: { ...MCP_SERVER_INFO },
          instructions:
            "DAY GUIDE MCP. Tools mirror site/skill.md and agents/skills.mjs. " +
            "Identity is wallet address only. Stake OFF by default. Fee on yield only (5%). " +
            "Set DAY_API_KEY for owner/agent calls. Never pass private keys.",
        },
      };
      return { response, sessionId: sid, httpStatus: 200 };
    }

    // Session required after initialize (stateful Streamable HTTP)
    let sessionId = ctx.sessionId || null;
    if (sessionId && !sessions.has(sessionId)) {
      return {
        response: jsonRpcError(id, -32001, "Session not found"),
        httpStatus: 404,
        sessionId,
      };
    }

    if (method === "ping") {
      return {
        response: { jsonrpc: "2.0", id, result: {} },
        sessionId,
        httpStatus: 200,
      };
    }

    if (method === "tools/list") {
      const { tools } = listMcpTools({ mvpOnly });
      // Strip _day extension from wire payload? Keep for agent clients — MCP allows extra fields on tools in practice;
      // some strict clients ignore unknown fields. Expose clean schema + annotations.
      const clean = tools.map(({ name, description, inputSchema, _day }) => ({
        name,
        description,
        inputSchema,
        annotations: {
          readOnlyHint:
            _day.auth === "public" ||
            String(_day.http).startsWith("GET "),
          openWorldHint: true,
          // non-standard but harmless
          dayHttp: _day.http,
          dayAuth: _day.auth,
        },
      }));
      return {
        response: { jsonrpc: "2.0", id, result: { tools: clean } },
        sessionId,
        httpStatus: 200,
      };
    }

    if (method === "tools/call") {
      const name = params?.name;
      const args = params?.arguments && typeof params.arguments === "object"
        ? params.arguments
        : {};
      if (!name || typeof name !== "string") {
        return {
          response: jsonRpcError(id, -32602, "tools/call requires params.name"),
          sessionId,
          httpStatus: 200,
        };
      }
      if (!getSkillByName(name)) {
        return {
          response: {
            jsonrpc: "2.0",
            id,
            result: {
              isError: true,
              content: [
                {
                  type: "text",
                  text: JSON.stringify({ error: "unknown_tool", name }),
                },
              ],
            },
          },
          sessionId,
          httpStatus: 200,
        };
      }
      const result = await proxy.callTool(name, args);
      return {
        response: { jsonrpc: "2.0", id, result },
        sessionId,
        httpStatus: 200,
      };
    }

    return {
      response: jsonRpcError(id, -32601, `Method not found: ${method}`),
      sessionId,
      httpStatus: 200,
    };
  }

  function terminateSession(sessionId) {
    if (sessionId) sessions.delete(sessionId);
  }

  function getSession(sessionId) {
    return sessionId ? sessions.get(sessionId) : undefined;
  }

  return {
    handleMessage,
    terminateSession,
    getSession,
    sessions,
    proxy,
  };
}

function jsonRpcError(id, code, message) {
  return {
    jsonrpc: "2.0",
    id: id ?? null,
    error: { code, message },
  };
}
