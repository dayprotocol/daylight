/**
 * DAY-214 / DAY-215 — MCP tools/list smoke + skill parity
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  listMcpTools,
  listToolNames,
  checkSkillMcpParity,
  MCP_PROTOCOL_VERSION,
  MCP_SERVER_INFO,
  getSkillByName,
  skillToInputSchema,
} from "../src/tools.mjs";
import { listMvpSkills, SKILL_REGISTRY, planSkillCall } from "../../../agents/skills.mjs";

describe("DAY MCP tools list", () => {
  it("lists MVP tools with JSON Schema input", () => {
    const { tools, names } = listMcpTools({ mvpOnly: true });
    assert.ok(tools.length >= 10, `expected >=10 tools, got ${tools.length}`);
    assert.equal(tools.length, names.length);

    for (const t of tools) {
      assert.equal(typeof t.name, "string");
      assert.ok(t.name.length > 0);
      assert.equal(typeof t.description, "string");
      assert.equal(t.inputSchema.type, "object");
      assert.ok(t.inputSchema.properties);
      assert.ok(t._day?.http, `${t.name} missing _day.http`);
      assert.ok(t._day?.auth, `${t.name} missing _day.auth`);
    }
  });

  it("includes core wallet + public skills", () => {
    const names = listToolNames({ mvpOnly: true });
    for (const required of [
      "routeYield",
      "harvest",
      "withdraw",
      "getPosition",
      "previewRoute",
      "listOpportunities",
      "enableAutoYield",
      "packages",
      "enablement",
      "bridgePlan",
      "listWalletStrategies",
      "createWalletStrategy",
      "updateWalletStrategy",
      "deleteWalletStrategy",
    ]) {
      assert.ok(names.includes(required), `missing tool ${required}`);
    }
  });

  it("wallet tools require walletAddress; public packages does not", () => {
    const route = getSkillByName("routeYield");
    const schema = skillToInputSchema(route);
    assert.ok(schema.required.includes("walletAddress"));

    const packages = getSkillByName("packages");
    const pub = skillToInputSchema(packages);
    assert.ok(!pub.required?.includes("walletAddress"));

    const updateStrategy = getSkillByName("updateWalletStrategy");
    const updateSchema = skillToInputSchema(updateStrategy);
    assert.ok(updateSchema.required.includes("walletAddress"));
    assert.ok(updateSchema.required.includes("id"));
    const planned = planSkillCall("updateWalletStrategy", {
      walletAddress: "0xw",
      id: "strat_s1",
      body: { name: "New" },
    });
    assert.equal(planned.method, "PATCH");
    assert.equal(planned.path, "/api/v1/wallets/0xw/strategies/strat_s1");
  });

  it("server info + protocol version set", () => {
    assert.equal(MCP_SERVER_INFO.name, "day-guide");
    assert.match(MCP_PROTOCOL_VERSION, /^2025-/);
  });
});

describe("DAY-215 skill ↔ MCP parity", () => {
  it("MCP tool names match listMvpSkills (unique)", () => {
    const parity = checkSkillMcpParity();
    assert.deepEqual(parity.missingInMcp, [], `missing in MCP: ${parity.missingInMcp}`);
    assert.deepEqual(parity.extraInMcp, [], `extra in MCP: ${parity.extraInMcp}`);
    assert.equal(parity.ok, true);
  });

  it("every registry skill is addressable by name", () => {
    for (const s of SKILL_REGISTRY) {
      assert.ok(getSkillByName(s.name), s.name);
    }
    const mvp = listMvpSkills();
    assert.ok(mvp.includes("routeYield"));
  });
});
