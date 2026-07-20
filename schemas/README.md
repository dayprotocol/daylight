# DAY schemas

JSON Schema (draft 2020-12) contracts for BE payloads. Minimal `required` only —
runtime may attach extra fields. APY fields are nullable; never invent numbers.

## Files

| Schema | Producer | Notes |
|--------|----------|--------|
| `day-venues.v1.json` | `runtime/adapters/venue-adapters.mjs` → `listVenueReadiness` | Phase 1 Sui + Solana venues, readiness + mock/live APY |
| `day-estimates.v1.json` | `runtime/estimates/yield-estimates.mjs` → `buildYieldEstimates` | Gross/net APY bps, daily/monthly micros; null when APY missing |
| `day-opportunity.v1.json` | `runtime/opportunity/opportunity-agent.mjs` → `scanOpportunities` | Propose-only; `autoStake` always false |
| `day-enablement.v1.json` | `runtime/enablement/gates.mjs` → `assessEnablement` | Fail-closed flags, kill switch, go/no-go |
| `day-harvest-plan.v1.json` | `runtime/keepers/harvest-plan.mjs` | Fee on yield only (`feeBps`) |
| `auto-yield-discovery.v1.json` | `runtime/discovery/yield-discovery.mjs` | DefiLlama map result |
| `day-map-venues.v1.json` | `runtime/discovery/defillama-10m-map.mjs` | DefiLlama ≥$10M venues (map only) |
| `auto-yield-plan.v1.json` | `runtime/scorer/auto-yield-scorer.mjs` | Scorer output |
| `auto-yield-policy.v1.json` | `runtime/policy/auto-yield-policy.mjs` | Owner opt-in policy |
| `day-vault-screening.v1.json` | `runtime/curated/screening.mjs` | DAY-352 screening rubric result |
| `day-vault-strategy-registry.v1.json` | `runtime/curated/vault-strategy-registry.mjs` | DAY-359/356 curated LIST allowlist |
| `day-vault-factory-policy.v1.json` | `runtime/vaults/vault-factory-policy.mjs` | DAY-386 permissionless vault factory policy (strategy allowlist, 500 bps DAY skim, fail-closed) |
| `day-strategy-guardrails.v1.json` | `runtime/strategy/guardrails.mjs` | DAY-428 Strategy Guardrails (assets, Yield Opportunity allowlist, max allocation; FeeConfig v2 economics on Strategy Lead surface; depositableLive/onChainFactory false) |
| `day-unified-db.v1.sql` | `runtime/discovery/unified-db.mjs` | DAY-510 unified data layer DDL for `yield_opportunities`, `strategies`, `strategy_allocations`, `performance_history`, Strategy Lead identity, and parser/run metadata |

## Assert helper

`runtime/lib/schema-assert.mjs`:

```js
import { assertRequired, assertSchemaRequired } from "../runtime/lib/schema-assert.mjs";

// throws when missing
assertRequired(payload, ["schemaVersion", "status"]);

// soft: { ok, missing }
const r = assertRequired(payload, ["schemaVersion"], { soft: true });

// from schema JSON `required` array
assertSchemaRequired(schema, payload, { soft: true });
```

## Tests

`tests/schemas.test.mjs` loads each schema and asserts required fields against
real runtime sample outputs (venues, estimates, opportunity, enablement).
