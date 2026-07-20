/**
 * DAY-214 — Streamable HTTP smoke: initialize → tools/list → tools/call (mocked)
 */
import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { startMcpServer } from "../src/http-server.mjs";
import { createDayProxy } from "../src/proxy.mjs";
import { createMcpHandler } from "../src/protocol.mjs";
import { MCP_PROTOCOL_VERSION } from "../src/tools.mjs";

describe("Streamable HTTP MCP smoke", () => {
  /** @type {Awaited<ReturnType<typeof startMcpServer>>} */
  let app;

  before(async () => {
    const proxy = createDayProxy({
      baseUrl: "https://dayprotocol.com",
      fetchImpl: async (url, init) => {
        return new Response(
          JSON.stringify({
            ok: true,
            mocked: true,
            url: String(url),
            method: init?.method || "GET",
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    });
    app = await startMcpServer({
      host: "127.0.0.1",
      port: 0, // ephemeral
      proxy,
      allowedOrigins: null,
    });
    // Node assigns ephemeral port
    const addr = app.server.address();
    app.port = typeof addr === "object" && addr ? addr.port : app.port;
    app.url = `http://127.0.0.1:${app.port}${app.path}`;
  });

  after(async () => {
    await app.close();
  });

  async function post(body, sessionId) {
    const headers = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
    };
    if (sessionId) headers["mcp-session-id"] = sessionId;
    const res = await fetch(app.url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { raw: text };
    }
    return {
      status: res.status,
      sessionId: res.headers.get("mcp-session-id"),
      json,
      text,
    };
  }

  it("initialize returns serverInfo + session", async () => {
    const r = await post({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "day-smoke", version: "0.0.1" },
      },
    });
    assert.equal(r.status, 200);
    assert.ok(r.sessionId, "Mcp-Session-Id header");
    assert.equal(r.json.result.serverInfo.name, "day-guide");
    assert.equal(r.json.result.protocolVersion, MCP_PROTOCOL_VERSION);
    assert.ok(r.json.result.capabilities.tools);
  });

  it("tools/list returns skill-mirrored tools", async () => {
    const init = await post({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "day-smoke", version: "0.0.1" },
      },
    });
    const sid = init.sessionId;
    assert.ok(sid);

    // initialized notification → 202
    const note = await post(
      {
        jsonrpc: "2.0",
        method: "notifications/initialized",
      },
      sid,
    );
    assert.equal(note.status, 202);

    const list = await post(
      {
        jsonrpc: "2.0",
        id: 2,
        method: "tools/list",
        params: {},
      },
      sid,
    );
    assert.equal(list.status, 200);
    const tools = list.json.result.tools;
    assert.ok(Array.isArray(tools));
    assert.ok(tools.length >= 10);
    const names = tools.map((t) => t.name);
    assert.ok(names.includes("routeYield"));
    assert.ok(names.includes("packages"));
    assert.ok(names.includes("harvest"));
    // no walletAddress on public tool schema required list
    const packages = tools.find((t) => t.name === "packages");
    assert.ok(packages.inputSchema);
  });

  it("tools/call proxies to DAY API (mocked fetch)", async () => {
    const init = await post({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: "day-smoke", version: "0.0.1" },
      },
    });
    const call = await post(
      {
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: {
          name: "packages",
          arguments: {},
        },
      },
      init.sessionId,
    );
    assert.equal(call.status, 200);
    assert.equal(call.json.result.isError, false);
    const text = call.json.result.content[0].text;
    const payload = JSON.parse(text);
    assert.equal(payload.ok, true);
    assert.equal(payload.skill, "packages");
    assert.ok(String(payload.path).includes("/packages"));
  });

  it("GET /mcp returns 405 (JSON response mode)", async () => {
    const res = await fetch(app.url, {
      method: "GET",
      headers: { accept: "text/event-stream" },
    });
    assert.equal(res.status, 405);
  });

  it("health endpoint", async () => {
    const res = await fetch(`http://127.0.0.1:${app.port}/health`);
    assert.equal(res.status, 200);
    const j = await res.json();
    assert.equal(j.ok, true);
  });
});

describe("createMcpHandler unit", () => {
  it("unknown method → -32601", async () => {
    const h = createMcpHandler({
      proxy: createDayProxy({
        fetchImpl: async () => new Response("{}", { status: 200 }),
      }),
    });
    const init = await h.handleMessage({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {},
    });
    const bad = await h.handleMessage(
      { jsonrpc: "2.0", id: 2, method: "resources/list", params: {} },
      { sessionId: init.sessionId },
    );
    assert.equal(bad.response.error.code, -32601);
  });
});
