/**
 * DAY MCP tool surface — 1:1 with agents/skills.mjs.
 *
 * Identity is wallet address only. Tools proxy to /api/v1/* paths.
 * No character or account ids.
 */

import {
  SKILL_REGISTRY,
  planSkillCall,
  listMvpSkills,
} from "../../../agents/skills.mjs";

export { SKILL_REGISTRY, planSkillCall, listMvpSkills };

/** MCP protocol version we advertise (Streamable HTTP / 2025-03-26 family). */
export const MCP_PROTOCOL_VERSION = "2025-03-26";

export const MCP_SERVER_INFO = Object.freeze({
  name: "day-guide",
  version: "0.1.0",
  title: "DAY GUIDE",
});

/**
 * JSON Schema for a skill tool.
 * Wallet-scoped skills require walletAddress; public day/* tools do not.
 * @param {typeof SKILL_REGISTRY[number]} skill
 */
export function skillToInputSchema(skill) {
  const needsWallet = skill.http.includes("{address}");
  const needsId = skill.http.includes("{id}");
  const properties = {
    // Free-form JSON body for POST/PUT (passed through to DAY API)
    body: {
      type: "object",
      description:
        "Optional JSON body for POST/PUT. Amounts as integer micros strings. No private keys.",
      additionalProperties: true,
    },
    apiKey: {
      type: "string",
      description:
        "Optional X-API-Key override for this call (owner / agent / keeper). Prefer server env DAY_API_KEY.",
    },
    idempotencyKey: {
      type: "string",
      description: "Optional Idempotency-Key for money mutations (oy_* / day_*).",
    },
  };
  const required = [];
  if (needsWallet) {
    properties.walletAddress = {
      type: "string",
      description:
        "Owner wallet address (Sui / Solana / EVM). DAY identity is wallet-only — no characters.",
    };
    required.push("walletAddress");
  } else if (skill.name.startsWith("walletBalance")) {
    properties.address = {
      type: "string",
      description: "Wallet address query param for balance reads.",
    };
    required.push("address");
  }
  if (needsId) {
    properties.id = {
      type: "string",
      description: "Path id, for Strategy tools this is the wallet-bound strategyId.",
    };
    required.push("id");
  }

  return {
    type: "object",
    properties,
    required,
    additionalProperties: false,
  };
}

/**
 * Build full MCP tools/list payload from the skill registry.
 * @param {{ mvpOnly?: boolean }} [opts]
 * @returns {{ tools: Array<object>, names: string[] }}
 */
export function listMcpTools(opts = {}) {
  const skills = opts.mvpOnly
    ? SKILL_REGISTRY.filter((s) => s.mvp)
    : [...SKILL_REGISTRY];

  // De-dupe by name (registry has alias entries e.g. jupiterPlan / jupiterSwapPlan)
  const seen = new Set();
  const tools = [];
  for (const skill of skills) {
    if (seen.has(skill.name)) continue;
    seen.add(skill.name);
    tools.push({
      name: skill.name,
      description: buildToolDescription(skill),
      inputSchema: skillToInputSchema(skill),
      // DAY extensions (not required by MCP; useful for clients / parity docs)
      _day: {
        http: skill.http,
        auth: skill.auth,
        mvp: Boolean(skill.mvp),
        notes: skill.notes || null,
      },
    });
  }
  return { tools, names: tools.map((t) => t.name) };
}

/**
 * @param {typeof SKILL_REGISTRY[number]} skill
 */
function buildToolDescription(skill) {
  const parts = [
    `DAY skill \`${skill.name}\` → ${skill.http}`,
    `auth: ${skill.auth}`,
  ];
  if (skill.notes) parts.push(skill.notes);
  parts.push(
    "Wallet-only identity. Never custody principal. Fees: GET /api/v1/day/fees is the source of truth — never hard-code a rate.",
  );
  return parts.join(". ");
}

/**
 * Resolve skill by MCP tool name.
 * @param {string} name
 */
export function getSkillByName(name) {
  return SKILL_REGISTRY.find((s) => s.name === name) || null;
}

/**
 * Names of all unique tools (for smoke / parity tests).
 * @param {{ mvpOnly?: boolean }} [opts]
 */
export function listToolNames(opts = {}) {
  return listMcpTools(opts).names;
}

/**
 * Assert MCP tool names match MVP skill registry (DAY-215 parity).
 * @returns {{ ok: boolean, missingInMcp: string[], extraInMcp: string[], skillNames: string[], mcpNames: string[] }}
 */
export function checkSkillMcpParity() {
  const skillNames = [...new Set(listMvpSkills())].sort();
  const mcpNames = [...listToolNames({ mvpOnly: true })].sort();
  const skillSet = new Set(skillNames);
  const mcpSet = new Set(mcpNames);
  const missingInMcp = skillNames.filter((n) => !mcpSet.has(n));
  const extraInMcp = mcpNames.filter((n) => !skillSet.has(n));
  return {
    ok: missingInMcp.length === 0 && extraInMcp.length === 0,
    missingInMcp,
    extraInMcp,
    skillNames,
    mcpNames,
  };
}
