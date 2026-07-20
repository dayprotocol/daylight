/**
 * @dayprotocol/mcp — DAY GUIDE remote MCP server (Streamable HTTP)
 *
 * Tickets: DAY-214 (hosted MCP), DAY-215 (skill parity), DAY-226 (open-core layout)
 */

export {
  SKILL_REGISTRY,
  planSkillCall,
  listMvpSkills,
  MCP_PROTOCOL_VERSION,
  MCP_SERVER_INFO,
  skillToInputSchema,
  listMcpTools,
  listToolNames,
  getSkillByName,
  checkSkillMcpParity,
} from "./tools.mjs";

export { createDayProxy, resolveUrl } from "./proxy.mjs";
export { createMcpHandler } from "./protocol.mjs";
export {
  startMcpServer,
  createEmbeddedMcp,
  handleMcpHttpRequest,
  HOSTED_MCP_PATHS,
} from "./http-server.mjs";
