-- DAY-510 unified data layer (Postgres dialect; SQLite-compatible with minor edits)
-- Runtime schema: runtime/discovery/unified-db.mjs
-- Critical SSOT: docs/critical/UNIFIED-DATA-LAYER.md
-- Mirror: docs/critical/schema/001_unified_data_layer.sql

CREATE TABLE IF NOT EXISTS strategy_leads (
  wallet TEXT PRIMARY KEY,
  display_name TEXT,
  extra_wallets JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS yield_opportunities (
  id UUID PRIMARY KEY,
  external_id TEXT,
  source TEXT NOT NULL, -- onchain | defillama | fixture | manual
  chain TEXT NOT NULL,
  protocol TEXT NOT NULL,
  name TEXT NOT NULL,
  type TEXT NOT NULL, -- vault | pool | lending_market | staking | perp_vault | lst | other
  category TEXT,
  address TEXT,
  token_symbol TEXT,
  token_address TEXT,
  tvl_usd NUMERIC,
  apy_bps INT,
  net_apy_bps INT,
  fee_json JSONB,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_curated BOOLEAN NOT NULL DEFAULT FALSE,
  is_mock BOOLEAN NOT NULL DEFAULT FALSE,
  metadata JSONB NOT NULL DEFAULT '{}',
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_updated TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_yield_opp_identity
  ON yield_opportunities (
    chain,
    protocol,
    COALESCE(address, external_id, id::text)
  );

CREATE INDEX IF NOT EXISTS idx_yield_opp_chain ON yield_opportunities (chain);
CREATE INDEX IF NOT EXISTS idx_yield_opp_protocol ON yield_opportunities (protocol);
CREATE INDEX IF NOT EXISTS idx_yield_opp_active_tvl ON yield_opportunities (is_active, is_curated, tvl_usd DESC);
CREATE INDEX IF NOT EXISTS idx_yield_opp_updated ON yield_opportunities (last_updated);

CREATE TABLE IF NOT EXISTS strategies (
  id UUID PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  -- Who created / manages (on-chain identity) — required
  strategy_lead_wallet TEXT NOT NULL,
  strategy_lead_name TEXT,
  -- Immutable rules after create
  guardrails JSONB NOT NULL,
  guardrails_hash TEXT NOT NULL,
  -- Fees: Lead performance % (e.g. 15.0); optional management % annual
  performance_fee NUMERIC NOT NULL CHECK (performance_fee >= 0 AND performance_fee <= 100),
  management_fee NUMERIC NOT NULL DEFAULT 0 CHECK (management_fee >= 0 AND management_fee <= 100),
  -- DAY share of Lead performance fee (bps of the Lead fee amount)
  protocol_performance_fee_bps INT NOT NULL DEFAULT 0 CHECK (protocol_performance_fee_bps >= 0 AND protocol_performance_fee_bps <= 10000),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  is_public BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  metadata JSONB NOT NULL DEFAULT '{}',
  CONSTRAINT strategies_guardrails_nonempty CHECK (guardrails <> '{}'::jsonb)
);

CREATE INDEX IF NOT EXISTS idx_strategies_lead_wallet ON strategies (strategy_lead_wallet);
CREATE INDEX IF NOT EXISTS idx_strategies_active_public ON strategies (is_active, is_public);
CREATE INDEX IF NOT EXISTS idx_strategies_guardrails_hash ON strategies (guardrails_hash);

-- Optional FK-style link to enrichment table (wallet must exist or be upserted on create)
-- ALTER TABLE strategies ADD CONSTRAINT fk_lead
--   FOREIGN KEY (strategy_lead_wallet) REFERENCES strategy_leads(wallet);

CREATE TABLE IF NOT EXISTS strategy_allocations (
  strategy_id UUID NOT NULL REFERENCES strategies(id) ON DELETE CASCADE,
  opportunity_id UUID NOT NULL REFERENCES yield_opportunities(id),
  weight_bps INT NOT NULL CHECK (weight_bps >= 0 AND weight_bps <= 10000),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (strategy_id, opportunity_id)
);

CREATE TABLE IF NOT EXISTS performance_history (
  id UUID PRIMARY KEY,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('opportunity', 'strategy')),
  entity_id UUID NOT NULL,
  date DATE NOT NULL,
  tvl_usd NUMERIC,
  apy_bps INT,
  net_apy_bps INT,
  volume_usd NUMERIC,
  source TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (entity_type, entity_id, date)
);

CREATE INDEX IF NOT EXISTS idx_perf_entity_date
  ON performance_history (entity_type, entity_id, date DESC);

CREATE TABLE IF NOT EXISTS protocol_registry (
  protocol TEXT PRIMARY KEY,
  display_name TEXT,
  chains JSONB NOT NULL DEFAULT '[]',
  parser_module TEXT,
  homepage_url TEXT,
  is_enabled BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS parser_runs (
  id UUID PRIMARY KEY,
  protocol TEXT NOT NULL,
  chain TEXT,
  status TEXT NOT NULL, -- ok | partial | error
  rows_upserted INT NOT NULL DEFAULT 0,
  error TEXT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at TIMESTAMPTZ
);

-- DAY-4331: official website + Twitter/X handle per protocol slug.
-- Filled at crawl time from DefiLlama /protocols (verified source). A row with
-- source='missing' is a deliberate gap placeholder for a protocol we could not
-- resolve — never a guessed value. verified_at is set only for trusted values.
CREATE TABLE IF NOT EXISTS protocol_metadata (
  protocol_slug TEXT PRIMARY KEY,
  website TEXT,
  twitter_handle TEXT,
  source TEXT NOT NULL DEFAULT 'missing', -- defillama | manual | grok | scrape | missing
  verified_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_protocol_metadata_source
  ON protocol_metadata (source);
