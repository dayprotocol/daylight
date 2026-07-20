# @dayprotocol/mcp

**DAY GUIDE** remote [MCP](https://modelcontextprotocol.io) server implementation — **Streamable HTTP** transport.

> **Hosted-only client path — do not install from npm/npx.** This package remains in the
> monorepo as the server implementation and registry package, but the only documented DAY MCP
> client endpoint is **`https://mcp.dayprotocol.com/mcp`** using `streamable-http` and
> `Authorization: Bearer <DAY_PAT>`. In-repo it is imported by relative path
> (`../packages/mcp/src/http-server.mjs`), so it deliberately reaches into repo-root
> `agents/skills.mjs` and is **not a user-installed client package**.

Tools are a **1:1 mirror** of `agents/skills.mjs` / `site/skill.md` (DAY-214 · DAY-215).

| | |
|---|---|
| **Product** | [DAY](https://dayprotocol.com) |
| **Identity** | **Wallet address only** — no characters/accounts |
| **Client URL** | `https://mcp.dayprotocol.com/mcp` |
| **Transport** | `streamable-http` (JSON response mode) · single `POST /mcp` |
| **Auth** | `Authorization: Bearer <DAY_PAT>` |
| **Open-core** | This package is **open**; proprietary decide internals are **not** shipped here |

## Client config

```json
{
  "mcpServers": {
    "day": {
      "transport": "streamable-http",
      "url": "https://mcp.dayprotocol.com/mcp",
      "headers": {
        "Authorization": "Bearer ${DAY_PAT}"
      }
    }
  }
}
```

## Hosted server env

| Variable | Default | Meaning |
|---|---|---|
| `DAY_MCP_PORT` | `8790` | Listen port |
| `DAY_MCP_HOST` | `127.0.0.1` | Bind address for hosted process |
| `DAY_MCP_PATH` | `/mcp` | MCP endpoint path |
| `DAY_API_BASE` | `https://dayprotocol.com` | DAY API origin (or `…/api/v1`) |
| `DAY_API_KEY` | — | Internal hosted fallback only; clients use Bearer/PAT auth |
| `DAY_MCP_ALLOWED_ORIGINS` | — | Comma list; when set, validates `Origin` |

## Tools

Every MVP skill becomes an MCP tool. Examples:

| Tool | DAY path | Auth |
|---|---|---|
| `routeYield` | `POST /api/v1/wallets/{address}/route` | owner |
| `harvest` | `POST /api/v1/wallets/{address}/harvest` | permissionless |
| `getPosition` | `GET /api/v1/wallets/{address}/position` | owner_or_agent |
| `packages` | `GET /api/v1/day/packages` | public |
| `bridgePlan` | `POST /api/v1/day/bridge/plan` | public |

Full table: `site/skill.md` § MCP + § MVP skill registry. Parity check: `checkSkillMcpParity()`.

Wallet-scoped tools take:

```json
{
  "walletAddress": "0x…",
  "body": { "amountMicros": "1000000", "token": "USDC" },
  "idempotencyKey": "day_route_…"
}
```

## Maintainer implementation use

```js
import {
  startMcpServer,
  listMcpTools,
  checkSkillMcpParity,
} from "../packages/mcp/src/index.mjs";

const parity = checkSkillMcpParity();
console.log(parity.ok, listMcpTools({ mvpOnly: true }).names);
```

## Open vs proprietary

| Surface | Open (this package) | Proprietary |
|---|---|---|
| MCP tools + Streamable HTTP | **Yes** (`packages/mcp`) | Hosted PAT issuance, rate limits |
| Vault action vocabulary | **Yes** | Live signer wiring |
| Reference `decide()` / scorer | **Yes** (public rules) | Multi-goal ranking weights, proprietary models |
| SDK | **Yes** (`packages/sdk`) | — |



## Tests

```bash
node --test packages/mcp/tests/**/*.test.mjs
# or monorepo
npm run test:mcp
```

## Hard rules

1. Never custody principal / never accept private keys as tool args.  
2. Fee on yield only (5% harvest skim).  
3. Stake OFF by default.  
4. No invented APY.  
5. Map ≠ Executable.  
6. No prod deploy from this package without explicit go.
