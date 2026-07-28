# DAY

**Non-custodial capital infrastructure for autonomous agents.** DAY lets an
agent's capital earn yield, use that yield to cover its own running costs, and —
in time — pay for services and other agents, without a human handing over the
funds or the keys.

The owner holds the funds and the keys. DAY never does. It holds only a scoped,
revocable, destination-locked permission to route capital into venues the owner
has allowed, and to return it to the owner — nothing else. That guarantee is
enforced on-chain, not by policy.

- **Whitepaper** — [WHITEPAPER.md](WHITEPAPER.md)
- **Docs & API** — [dayprotocol.com/docs](https://dayprotocol.com/docs)
- **Site** — [dayprotocol.com](https://dayprotocol.com)
- **License** — Apache 2.0 (code) · [BRAND_LICENSE.md](BRAND_LICENSE.md) (name/wordmark)
- **Security** — [SECURITY.md](SECURITY.md)

| | |
|---|---|
| **Chains** | Sui, Solana, Base, Arbitrum |
| **Access** | HTTPS API · [`@dayprotocol/sdk`](packages/sdk) · hosted remote MCP (`https://mcp.dayprotocol.com/mcp`) · x402 |
| **Fees** | Profit fee 1% (cap $10, currently off) · swap/bridge 0.10% · deposits & withdrawals free |
| **Custody** | None — the owner always holds funds and keys, and can exit at any time |

## What it does

- **Earn** — route idle capital into yield venues across the supported chains.
- **Route** — move capital to the best allowed strategy and rebalance within the owner's limits.
- **Harvest** — claim rewards and compound them back into the owner's vault.
- **Persist** — keep running non-custodially, independent of the operator.

## Open core

The parts that touch money are open and auditable; the strategy intelligence is
not. You can verify DAY's safety without seeing the intelligence behind it.

- **Open (Apache 2.0):** vault, authorization, policy, and routing contracts; the
  adapter interface; the SDK and hosted MCP implementation; fee math; plan schemas.
- **Proprietary:** the Autopilot strategy intelligence and its supporting data —
  constrained by the open contracts, so it never needs to be trusted with funds.

## Quick start

```bash
# public reads need no key
curl -s https://dayprotocol.com/api/v1/day/status | jq

# install the client
npm install @dayprotocol/sdk
```

```js
import { DayClient } from "@dayprotocol/sdk";

const day = new DayClient({ baseUrl: "https://dayprotocol.com/api/v1" });
const { strategies } = await day.listStrategies();
```

See [dayprotocol.com/docs](https://dayprotocol.com/docs) for the full API,
authentication (x402), and the deposit → sign → settle flow.

## Layout

```
day/
  contracts/   # Move (Sui) · Rust (Solana) · Solidity (EVM)
  packages/
    sdk/       # @dayprotocol/sdk  — TypeScript client (Apache 2.0)
    mcp/       # hosted remote MCP implementation; clients use https://mcp.dayprotocol.com/mcp
  runtime/     # routing, adapters, fee math, keepers
  api/         # HTTP surface
  schemas/     # versioned request/response contracts
  site/        # dayprotocol.com
```
