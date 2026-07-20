#!/usr/bin/env node
/**
 * day-mcp — start Streamable HTTP MCP server
 *
 * Env:
 *   DAY_MCP_PORT=8790
 *   DAY_MCP_HOST=127.0.0.1
 *   DAY_MCP_PATH=/mcp
 *   DAY_API_BASE=https://dayprotocol.com
 *   DAY_API_KEY=…          (optional default for owner/agent tools)
 *   DAY_MCP_ALLOWED_ORIGINS=https://claude.ai,https://dayprotocol.com
 */

import { startMcpServer } from "./http-server.mjs";
import { listToolNames, MCP_SERVER_INFO } from "./tools.mjs";

const port = Number(process.env.DAY_MCP_PORT || 8790);
const host = process.env.DAY_MCP_HOST || "127.0.0.1";

const app = await startMcpServer({ port, host });
const names = listToolNames({ mvpOnly: true });

console.error(
  JSON.stringify({
    service: MCP_SERVER_INFO.name,
    version: MCP_SERVER_INFO.version,
    transport: "streamable-http",
    url: app.url,
    tools: names.length,
    toolNames: names,
  }),
);

const shutdown = async () => {
  await app.close();
  process.exit(0);
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
