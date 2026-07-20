# @dayprotocol/sdk

Public TypeScript/JavaScript client for **DAY** — open protocol for autonomous capital management.

| | |
|---|---|
| **Site** | [dayprotocol.com](https://dayprotocol.com) |
| **Docs** | [docs.dayprotocol.com](https://docs.dayprotocol.com) |
| **Package home** | [github.com/dayprotocol/sdk](https://github.com/dayprotocol/sdk) |
| **Monorepo source** | `packages/sdk` in [dayprotocol/day](https://github.com/dayprotocol/day) |

## Install

### From GitHub (recommended today)

```bash
npm install github:dayprotocol/sdk
```

Or pin a tag/branch:

```bash
npm install github:dayprotocol/sdk#v0.2.0
```

### npmjs.org (public registry)

```bash
npm install @dayprotocol/sdk
```

`publishConfig` targets **https://registry.npmjs.org** with `access: public`. After the package is published to npm, the plain install above is enough.

### GitHub Packages (optional alternate)

```bash
# .npmrc
@dayprotocol:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_TOKEN

npm install @dayprotocol/sdk
```

Requires a GitHub token with `read:packages`. Prefer `npm install github:dayprotocol/sdk` or npmjs when available.

---

## Principles

- **Non-custodial** — the SDK never holds private keys; owners always control principal.
- **Prepare / plan first** — deposit, withdraw, bridge, and route helpers return plans; broadcast is owner- or keeper-driven, not silent client execution.
- **Honest numbers** — missing APY is `null` / N/A; DefiLlama map is discovery only; adapter `read_apy` is execution truth.
- **No float money** — amounts on low-level methods are integer **micros** (e.g. USDC 6 decimals).

---

## Fee model (locked MVP)

| Rail | bps | Rate | When |
|---|---:|---:|---|
| **Yield performance skim** | **500** | 5% | Harvested / waterfall yield only |
| **Protocol swap fee** | **100** | 1% | DAY-composed swap notional |
| **Gas sponsor fee** | **100** | 1% | When gas is sponsored (USDC wallets) |
| **Deposit / withdraw principal** | **0** | 0% | Never on principal |

Constants match onchain + `runtime/lib/bps.mjs` (`500` / `100` / `100` / `0`). Full detail: [docs/09-fee-model.md](https://docs.dayprotocol.com) / monorepo `docs/09-fee-model.md`.

---

## Quick start

```js
import {
  DayClient,
  DayError,
  SDK_VERSION,
  routeYield,
  toMicrosString,
  buildIdempotencyKey,
  IDEMPOTENCY_HEADER,
} from "@dayprotocol/sdk";

// Public discovery (no key)
const day = new DayClient({
  baseUrl: "https://dayprotocol.com",
  // checkUpdate: true,  // default — after first API call, checks GET /api/day/sdk
  // warnOnUpdate: true, // default — console.warn when a newer version is published
  // onUpdate: (info) => console.log(info.message, info.install),
});

console.log("sdk", SDK_VERSION); // e.g. 0.2.4
await day.readiness();
await day.listStrategies({ ready: true });
await day.packages();
await day.mapVenues({ chain: "sui" });
await day.marketStats();
await day.whatPossible();

// Outdated installs get a one-time console.warn with upgrade command.
const update = await day.checkForUpdate();
if (update.updateAvailable) {
  console.log(update.message);
  // e.g. npm install github:dayprotocol/sdk#v0.2.4
}

// API contract version (headers on every response + GET /api/day/version)
const api = await day.checkApiVersion();
if (api.updateAvailable) {
  console.log(api.message);
}

// Wallet-scoped route helper — OWNER-ONLY (not public).
// Requires explicit apiKey + walletAddress; fails clear if either is missing.
const plan = await routeYield({
  amount: 10000,
  token: "USDC",
  goal: "stable_yield_for_agent",
  walletAddress: process.env.DAY_WALLET_ADDRESS,
  apiKey: process.env.DAY_API_KEY,
  baseUrl: "https://dayprotocol.com",
});

// Or use the full client with owner key for wallet routes:
const ownerDay = new DayClient({
  baseUrl: "https://dayprotocol.com",
  apiKey: process.env.DAY_API_KEY,
});
await ownerDay.previewRoute("char_1", {
  amountMicros: "1000000",
  token: "USDC",
  stake: false,
});
```

### Version discovery

| What | How |
|---|---|
| **Latest SDK** | `GET /api/day/sdk` · `day.checkForUpdate()` · status field `sdk` |
| **Latest API** | Headers on **every** JSON response: `X-DAY-API-Version`, `X-DAY-API-Version-Latest`, `X-DAY-API-Version-Min` |
| | `GET /api/day/version` · `?client=1.0` · `day.checkApiVersion()` · status field `api` |

---

## API surface (`DayClient`)

All methods return parsed JSON (or throw `DayError` with `code`, `status`, `body`).

### Protocol / readiness

| Method | HTTP | Notes |
|---|---|---|
| `readiness()` | `GET /api/day/readiness` | Phase 1 homes (Sui + Solana) |
| `network()` | `GET /api/day/network` | mainnet \| testnet |
| `treasury()` | `GET /api/day/treasury` | Public treasury addresses only — **never private keys** |
| `whatPossible()` | `GET /api/day/possible` | Agent decision surface (`prepare_only` until broadcast go) |
| `packages()` | `GET /api/day/packages` | Multi-chain package IDs (`day-packages.v1`) |

### Strategies (prefer for product UI)

| Method | HTTP | Notes |
|---|---|---|
| `listStrategies({ chain?, wave?, ready?, live? })` | `GET /api/day/strategies` | AdapterRegistry mirror |
| `getStrategy(strategyId)` | `GET /api/day/strategies/:id` | **strategyId === venueId** e.g. `suilend` (not `form-*`, not `chain:venue`) |
| `strategyPriority()` | `GET /api/day/strategies/priority` | Auto Yield priority matrix |
| `prepareStrategyDeposit(body)` | `POST /api/day/strategies/deposit/plan` | Prepare-only; **fee 0** on principal |
| `executeStrategyDeposit(body)` | `POST /api/day/strategies/deposit/execute` | DAY-307 owner-signed execute (Sui+Solana write venues); pass `signedTx`; broadcast flag-gated |
| `prepareStrategyWithdraw(body)` | `POST /api/day/strategies/withdraw/plan` | Prepare-only; **fee 0** on principal |

`strategyId` is the bare venue key (`"suilend"`, `"kamino"`, `"aave-v3"`). Legacy `form-suilend` is accepted and normalized to `suilend` client-side (server also resolves form aliases).

```js
const depositPlan = await day.prepareStrategyDeposit({
  strategyId: "suilend", // venueId — not "form-suilend" or "sui:suilend"
  amountMicros: "1000000000", // 1000 USDC
  owner: "0x…",
  autoYieldEnabled: false, // stake OFF by default
});
```

### Map & market stats

| Method | HTTP | Notes |
|---|---|---|
| `listMapVenues({ minTvlUsd?, chain? })` | `GET /api/day/map/venues` | DefiLlama ≥$10M map — **not** execution truth |
| `mapVenues(opts)` | same | Alias for `listMapVenues` |
| `marketStats()` | `GET /api/day/markets/stats` | TVL map + adapter APY snapshot |
| `listVenues()` / `listVenuesByChain({ chain? })` | `GET /api/day/venues` | Venue list |
| `listOpportunities({ minTvlUsd?, chain?, status? })` | `GET /api/day/opportunities` | Filtered opportunities |

### Forms (L1 registry — legacy alias of strategies)

| Method | HTTP |
|---|---|
| `listForms({ chain?, wave?, ready? })` | `GET /api/day/forms` |
| `getForm(formId)` | `GET /api/day/forms/:id` |
| `formPriority()` | `GET /api/day/forms/priority` |

### Wallets (read-only balances)

| Method | HTTP |
|---|---|
| `suiWalletBalance(address)` | `GET /api/day/sui/wallet-balance?address=` |
| `solanaWalletBalance(address)` | `GET /api/day/solana/wallet-balance?address=` |
| `baseWalletBalance(address)` | `GET /api/day/base/wallet-balance?address=` |
| `arbitrumWalletBalance(address)` | `GET /api/day/arbitrum/wallet-balance?address=` (ETH+USDC; N/A on RPC fail) |
| `solanaApys()` | `GET /api/day/solana/apys` |
| `solanaStakePlan(body)` | `POST /api/day/solana/stake/plan` |

### Enablement (expansion gates)

| Method | HTTP | Notes |
|---|---|---|
| `baseProfile()` | `GET /api/day/base` | Base expansion profile |
| `baseEnablement()` | `GET /api/day/base/enablement` | Gate until execution flag |
| `arbitrumProfile()` | `GET /api/day/arbitrum` | Expansion profile — registry live ≠ live write |
| `arbitrumEnablement()` | `GET /api/day/arbitrum/enablement` | PREPARE_OK_STUBS; broadcast hard-gated until writeReady |

### Bridge

| Method | HTTP | Notes |
|---|---|---|
| `bridgePlan(body)` | `POST /api/day/bridge/plan` | Mayan prepare-only. Required: `sourceChain`, `destChain`, `amountMicros`, `sourceAddress`, `destinationAddress` (aliases: `srcChain`/`fromChain`, `dstChain`/`toChain`, `amount`, `from`, `to`). Lanes: Sui↔Sol, Base/Eth→Sui\|Sol. Blocked → `blockers` + `blockerDetails` + `requiredFields` + `supportedLanes`. |
| `bridgeRescuePlan(body)` | `POST /api/day/bridge/rescue` | Failed **delivery rescue only** — funds return to **owner**. Not for ordinary bridge moves (use `bridgePlan`). |

### Wallet / agent routes (authenticated)

These hit `/api/wallets/{address}/…` and require an **owner or agent API key** (`X-API-Key`). They are **not** public discovery endpoints.

| Method | HTTP | Auth |
|---|---|---|
| `getPosition(walletAddress)` | `GET /api/wallets/:address/position` | owner\|agent |
| `getFunding(walletAddress)` | `GET /api/wallets/:address/funding` | owner\|agent |
| `getAutoYield(walletAddress)` | `GET /api/wallets/:address/auto-yield` | owner\|agent |
| `setAutoYield(walletAddress, body)` | `PUT …/auto-yield` | owner (opt-in; default OFF) |
| `stake` / `unstake` | `POST …/auto-yield/stake\|unstake` | owner |
| `enableAutopilot(walletAddress, body?)` | `POST …/autopilot/enable` | **owner** (OFF by default) |
| `disableAutopilot(walletAddress)` | `POST …/autopilot/disable` | **owner** |
| `previewAutopilot(walletAddress, body?)` | `POST …/autopilot/preview` | owner\|agent |
| `tickAutopilot(walletAddress, body?)` | `POST …/autopilot/tick` | owner\|agent |
| `getAutopilot(walletAddress)` | `GET …/autopilot` | owner\|agent |
| `getAutopilotHistory(walletAddress, opts?)` | `GET …/autopilot/history` | owner\|agent |
| `previewRoute(walletAddress, body)` | `POST …/preview` | owner\|agent |
| `routeYield(walletAddress, body)` | `POST …/route` | **owner only** (agent → 403) |
| `harvest(walletAddress, body?)` | `POST …/harvest` | permissionless yield skim path |
| `withdraw(walletAddress, body)` | `POST …/withdraw` | **owner only** |
| `enableAutoPay(walletAddress, body)` | `POST …/auto-pay` | **owner only** |
| `listAudits({ walletAddress?, action?, limit? })` | `GET /api/day/audits` | redacted trail |

### Vault store (**deprecated** — internal / legacy)

**Not the public product.** In-memory planner vaults from an earlier vault-core experiment. Prefer **strategies** (`listStrategies`, `prepareStrategyDeposit`). Vault helpers remain for internal tests and are marked `@deprecated` in types.

`listVaults`, `createVault`, `getVault`, `vaultDeposit`, `vaultWithdraw`, `vaultSetStrategy`, `vaultHarvest`, `vaultDeploy`, `vaultUndeploy`.

Mutators accept optional `{ apiKey }` per-call override (never invent privileged roles from a free-form `role` string).

### Helpers & errors

| Export | Purpose |
|---|---|
| `routeYield({ amount, walletAddress, apiKey, … })` | **Owner-only** wallet preview/route helper — requires `apiKey` + `walletAddress` |
| `toMicrosString(value)` / `isMicros(value)` | Integer micros validation |
| `buildIdempotencyKey` / `assertIdempotencyKey` / `IDEMPOTENCY_HEADER` | Money-call dedupe keys |
| `normalizeStrategyId(id)` | Strip legacy `form-` prefix; bare venueId |
| `buildUpdateResult` / `buildApiVersionCheckResult` | Version check result builders |
| `DayError` | `code`, `status`, `body` on HTTP / config failures |

```js
try {
  await ownerDay.withdraw("char_1", { amountMicros: toMicrosString(1_000_000) });
} catch (e) {
  if (e instanceof DayError) console.error(e.code, e.status, e.message);
}
```

### Types

`index.d.ts` ships with the package (`types` + `exports["."].types`). Public `DayClient` methods and top-level exports match `src/index.mjs`. Response bodies are `unknown` so callers can refine against live API schemas.

---

## Multi-chain packages

`packages()` returns `day-packages.v1` with per-chain status (Sui YieldRouter, Solana `day_router`, Base/Arbitrum DayRegistry, upgrade caps). Dual-writes legacy top-level `packageId` / `upgradeCapStatus` for older clients.

```js
const pkgs = await day.packages();
// pkgs.schemaVersion === "day-packages.v1"
// pkgs.chains.sui | .solana | .base | .arbitrum
```

---

## Auth

| Surface | Auth |
|---|---|
| Discover / map / packages / strategies / readiness / prepare plans | **Public** — no key |
| Wallet reads (`position`, `preview`, …) | **owner\|agent** `apiKey` → `X-API-Key` |
| Wallet mutators (`route`, `withdraw`, `auto-pay`, …) | **owner** `apiKey` → `X-API-Key` |
| Free `routeYield({…})` helper | **Requires** `apiKey` + `walletAddress` (owner-scoped; fails clear if missing) |
| Session (future) | optional `sessionToken` → `Authorization: Bearer …` — not primary today |

Pass a custom `fetchImpl` for tests or polyfills (Node 20+ has global `fetch`).

---

## License

MIT © Limitless Labs Inc
