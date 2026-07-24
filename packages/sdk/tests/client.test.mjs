import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  DayClient,
  DayError,
  normalizeStrategyId,
  routeYield,
  buildIdempotencyKey,
  buildApiVersionCheckResult,
  SDK_VERSION,
  SDK_API_VERSION,
  SDK_PACKAGE_NAME,
} from "../src/index.mjs";

describe("DayClient", () => {
  it("requires baseUrl", () => {
    assert.throws(() => new DayClient({}), (e) => e instanceof DayError);
  });

  it("listVenues hits correct path with api key", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test/",
      apiKey: "test-key",
      fetchImpl: async (url, init) => {
        calls.push(url);
        assert.equal(init.headers.get("X-API-Key"), "test-key");
        return new Response(JSON.stringify({ venues: [] }), { status: 200 });
      },
    });
    const data = await client.listVenues();
    assert.deepEqual(data, { venues: [] });
    assert.equal(calls[0], "https://example.test/api/v1/day/venues");
  });

  it("previewRoute posts json body", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url, init) => {
        assert.equal(url, "https://example.test/api/v1/wallets/char_1/preview");
        assert.equal(init.method, "POST");
        const body = JSON.parse(init.body);
        assert.equal(body.amountMicros, "1000000");
        assert.equal(body.stake, false);
        return new Response(JSON.stringify({ planStatus: "prepared" }), { status: 200 });
      },
    });
    const res = await client.previewRoute("char_1", {
      amountMicros: "1000000",
      token: "USDC",
      goal: "stable_agent_budget",
      stake: false,
    });
    assert.equal(res.planStatus, "prepared");
  });

  it("Autopilot SDK methods", async () => {
    /** @type {{ url: string, method?: string, body?: unknown }[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      apiKey: "owner-key",
      fetchImpl: async (url, init) => {
        calls.push({
          url: String(url),
          method: init?.method || "GET",
          body: init?.body ? JSON.parse(init.body) : null,
        });
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    });
    await client.enableAutopilot("0xw", { armAutoYield: true, goal: "stable_yield" });
    await client.previewAutopilot("0xw", { chain: "sui" });
    await client.tickAutopilot("0xw", { execute: true });
    await client.getAutopilot("0xw");
    await client.getAutopilotHistory("0xw", { limit: 5 });
    await client.getPosition("0xw");
    await client.disableAutopilot("0xw");
    assert.equal(calls[0].url, "https://example.test/api/v1/wallets/0xw/autopilot/enable");
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].body.armAutoYield, true);
    assert.equal(calls[1].url, "https://example.test/api/v1/wallets/0xw/autopilot/preview");
    assert.equal(calls[2].url, "https://example.test/api/v1/wallets/0xw/autopilot/tick");
    assert.equal(calls[3].url, "https://example.test/api/v1/wallets/0xw/autopilot");
    assert.ok(calls[4].url.includes("/autopilot/history?limit=5"));
    assert.equal(calls[5].url, "https://example.test/api/v1/wallets/0xw/position");
    assert.equal(calls[6].url, "https://example.test/api/v1/wallets/0xw/autopilot/disable");
  });

  it("maps http errors to DayError", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async () =>
        new Response(JSON.stringify({ code: "UNAUTHORIZED", message: "nope" }), { status: 403 }),
    });
    await assert.rejects(
      () => client.withdraw("char_1", { amountMicros: "1" }),
      (e) => e instanceof DayError && e.code === "UNAUTHORIZED" && e.status === 403,
    );
  });

  it("DAY-625: sends Idempotency-Key header for mutating calls when key is in body", async () => {
    let seenHeader = null;
    let seenBodyKey = null;
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      apiKey: "owner-key",
      fetchImpl: async (url, init) => {
        seenHeader = init.headers.get("Idempotency-Key");
        seenBodyKey = init.body ? JSON.parse(init.body).idempotencyKey : null;
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    });
    const key = buildIdempotencyKey("withdraw", "0xowner_wallet", "req-123");
    await client.withdraw("0xowner", { amountMicros: "1000000", idempotencyKey: key });
    // Header goes on the wire (the documented dedupe path)…
    assert.equal(seenHeader, key);
    // …and the body field is preserved (server accepts either).
    assert.equal(seenBodyKey, key);
  });

  it("DAY-625: no Idempotency-Key header when caller omits the key", async () => {
    let hasHeader = true;
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      apiKey: "owner-key",
      fetchImpl: async (url, init) => {
        hasHeader = init.headers.has("Idempotency-Key");
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    });
    // Must not error and must not set the header.
    await client.withdraw("0xowner", { amountMicros: "1000000" });
    assert.equal(hasHeader, false);
  });

  it("listOpportunities encodes query", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        assert.ok(url.includes("min_tvl_usd=50000000"));
        assert.ok(url.includes("chain=sui"));
        return new Response(JSON.stringify({ opportunities: [] }), { status: 200 });
      },
    });
    await client.listOpportunities({ minTvlUsd: 50_000_000, chain: "sui" });
  });

  it("listForms and vault paths", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url, init) => {
        calls.push(`${init?.method || "GET"} ${url}`);
        if (String(url).includes("/forms/priority")) {
          return new Response(JSON.stringify({ byChain: {} }), { status: 200 });
        }
        if (String(url).includes("/forms/")) {
          return new Response(JSON.stringify({ formId: "form-suilend" }), { status: 200 });
        }
        if (String(url).includes("/forms")) {
          return new Response(JSON.stringify({ count: 10, forms: [] }), { status: 200 });
        }
        if (String(url).includes("/vaults") && (init?.method || "GET") === "POST") {
          return new Response(JSON.stringify({ success: true, vault: { vault: { id: "v1" } } }), {
            status: 200,
          });
        }
        if (String(url).includes("/deposit")) {
          return new Response(JSON.stringify({ feeMicros: "0", sharesMinted: "1" }), { status: 200 });
        }
        if (String(url).includes("/deploy") || String(url).includes("/undeploy")) {
          return new Response(JSON.stringify({ success: true, applied: true }), { status: 200 });
        }
        return new Response(JSON.stringify({ vaults: [] }), { status: 200 });
      },
    });
    await client.listForms({ chain: "sui" });
    await client.formPriority();
    await client.getForm("form-suilend");
    await client.listVaults();
    await client.createVault({ name: "t" }, { role: "owner" });
    await client.vaultDeposit("v1", { owner: "a", amountMicros: "1" }, { role: "owner" });
    await client.vaultDeploy(
      "v1",
      { formId: "form-suilend", amountMicros: "1" },
      { role: "owner" },
    );
    await client.vaultUndeploy(
      "v1",
      { formId: "form-suilend", amountMicros: "1" },
      { role: "owner" },
    );
    assert.ok(calls.some((c) => c.includes("/api/v1/day/forms")));
    assert.ok(calls.some((c) => c.includes("/api/v1/day/vaults")));
    assert.ok(calls.some((c) => c.includes("/deploy")));
    assert.ok(calls.some((c) => c.includes("/undeploy")));
  });

  it("DAY-572 wallet Strategy CRUD SDK methods hit v1 wallet paths", async () => {
    /** @type {{ url: string, method: string, body: unknown }[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      apiKey: "owner-key",
      fetchImpl: async (url, init) => {
        calls.push({
          url: String(url),
          method: init?.method || "GET",
          body: init?.body ? JSON.parse(init.body) : null,
        });
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    });

    await client.updateWalletProfile("0xw", { displayName: "Lead" });
    await client.listWalletStrategies("0xw", { includeDeleted: true });
    await client.createWalletStrategy("0xw", {
      strategyId: "s1",
      guardrails: { schemaVersion: "day-strategy-guardrails.v1" },
    });
    await client.getWalletStrategy("0xw", "strat_s1");
    await client.updateWalletStrategy("0xw", "strat_s1", { name: "New" });
    await client.deleteWalletStrategy("0xw", "strat_s1");

    assert.deepEqual(
      calls.map((c) => `${c.method} ${c.url}`),
      [
        "PUT https://example.test/api/v1/wallets/0xw/profile",
        "GET https://example.test/api/v1/wallets/0xw/strategies?includeDeleted=1",
        "POST https://example.test/api/v1/wallets/0xw/strategies",
        "GET https://example.test/api/v1/wallets/0xw/strategies/strat_s1",
        "PATCH https://example.test/api/v1/wallets/0xw/strategies/strat_s1",
        "DELETE https://example.test/api/v1/wallets/0xw/strategies/strat_s1",
      ],
    );
    assert.equal(calls[0].body.displayName, "Lead");
    assert.equal(calls[2].body.strategyId, "s1");
    assert.equal(calls[4].body.name, "New");
  });

  it("treasury hits public treasury path", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        assert.equal(url, "https://example.test/api/v1/day/treasury");
        return new Response(
          JSON.stringify({
            schemaVersion: "day-treasury.v1",
            addresses: { sui: "0x1", solana: "So1", evm: "0x2" },
          }),
          { status: 200 },
        );
      },
    });
    const t = await client.treasury();
    assert.equal(t.schemaVersion, "day-treasury.v1");
    assert.equal(t.addresses.sui, "0x1");
  });

  it("bridgeRescuePlan posts to rescue path", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url, init) => {
        assert.equal(url, "https://example.test/api/v1/day/bridge/rescue");
        assert.equal(init.method, "POST");
        return new Response(JSON.stringify({ status: "prepared", destinationAddress: "0xowner" }), {
          status: 200,
        });
      },
    });
    const res = await client.bridgeRescuePlan({
      ownerAddress: "0xowner",
      asset: "USDC",
      amountMicros: "1000",
    });
    assert.equal(res.status, "prepared");
  });

  it("bridgePlan posts to plan path (not rescue)", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url, init) => {
        assert.equal(url, "https://example.test/api/v1/day/bridge/plan");
        assert.equal(init.method, "POST");
        const body = JSON.parse(init.body);
        assert.equal(body.sourceChain, "sui");
        assert.equal(body.destChain, "solana");
        return new Response(
          JSON.stringify({
            status: "prepared",
            sourceChain: "sui",
            destChain: "solana",
            rail: "mayan",
          }),
          { status: 200 },
        );
      },
    });
    const res = await client.bridgePlan({
      sourceChain: "sui",
      destChain: "solana",
      amountMicros: "1000",
      sourceAddress: "0xsui",
      destinationAddress: "So11111111111111111111111111111111111111112",
    });
    assert.equal(res.status, "prepared");
    assert.equal(res.destChain, "solana");
  });

  it("listMapVenues / mapVenues hit GET /api/v1/day/map/venues", async () => {
    /** @type {string[]} */
    const calls = [];
    const payload = {
      schemaVersion: "day-map-venues.v1",
      mapOnly: true,
      notExecutionTruth: true,
      venueCount: 1,
      venues: [{ project: "suilend", chain: "sui", poolCount: 1, maxTvl: 1e8, samplePoolIds: ["p1"] }],
    };
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        calls.push(url);
        return new Response(JSON.stringify(payload), { status: 200 });
      },
    });
    const a = await client.listMapVenues();
    assert.equal(a.schemaVersion, "day-map-venues.v1");
    assert.equal(a.mapOnly, true);
    assert.equal(calls[0], "https://example.test/api/v1/day/map/venues");

    const b = await client.mapVenues({ minTvlUsd: 10_000_000, chain: "sui" });
    assert.equal(b.venueCount, 1);
    assert.ok(calls[1].includes("/api/v1/day/map/venues"));
    assert.ok(calls[1].includes("minTvlUsd=10000000"));
    assert.ok(calls[1].includes("chain=sui"));
  });

  it("packages hits GET /api/v1/day/packages", async () => {
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        assert.equal(url, "https://example.test/api/v1/day/packages");
        return new Response(
          JSON.stringify({
            schemaVersion: "day-packages.v1",
            network: "mainnet",
            packageId: "0x425980cb460145b83397586891239f7d570c8a6897581469486225ad06d0a4ef",
            upgradeCapStatus: "held",
            phase1Homes: ["sui", "solana"],
            upgradeCapsHeld: true,
            chains: {
              sui: {
                status: "live",
                packageId: "0x425980cb460145b83397586891239f7d570c8a6897581469486225ad06d0a4ef",
              },
              solana: { status: "pending", programId: null },
              base: { status: "live", registry: "0x342d57cf" },
              arbitrum: { status: "live", registry: "0x342d57cf" },
            },
          }),
          { status: 200 },
        );
      },
    });
    const p = await client.packages();
    assert.equal(p.schemaVersion, "day-packages.v1");
    assert.equal(p.upgradeCapStatus, "held");
    assert.equal(p.upgradeCapsHeld, true);
    assert.ok(p.packageId.startsWith("0x425980cb"));
    assert.deepEqual(p.phase1Homes, ["sui", "solana"]);
    assert.equal(p.chains.sui.status, "live");
    assert.equal(p.chains.base.status, "live");
  });

  it("listStrategies / getStrategy / strategyPriority encode filters", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        calls.push(url);
        if (String(url).includes("/priority")) {
          return new Response(JSON.stringify({ byChain: { sui: [] } }), { status: 200 });
        }
        if (String(url).includes("/strategies/suilend")) {
          return new Response(JSON.stringify({ strategyId: "suilend", ready: true }), {
            status: 200,
          });
        }
        return new Response(JSON.stringify({ count: 2, strategies: [] }), { status: 200 });
      },
    });
    await client.listStrategies({ chain: "sui", ready: true, live: true });
    assert.ok(calls[0].includes("/api/v1/day/strategies"));
    assert.ok(calls[0].includes("chain=sui"));
    assert.ok(calls[0].includes("ready=1"));
    assert.ok(calls[0].includes("live=1"));

    const one = await client.getStrategy("suilend");
    assert.equal(one.strategyId, "suilend");
    assert.equal(calls[1], "https://example.test/api/v1/day/strategies/suilend");

    // DAY-268: form-* alias normalizes to bare venueId before request
    await client.getStrategy("form-suilend");
    assert.equal(calls[2], "https://example.test/api/v1/day/strategies/suilend");

    const prio = await client.strategyPriority();
    assert.ok(prio.byChain);
    assert.equal(calls[3], "https://example.test/api/v1/day/strategies/priority");
  });

  it("normalizeStrategyId: strategyId === venueId; form- aliases stripped", () => {
    assert.equal(normalizeStrategyId("suilend"), "suilend");
    assert.equal(normalizeStrategyId("form-suilend"), "suilend");
    assert.equal(normalizeStrategyId("Form-Kamino"), "kamino");
    assert.equal(normalizeStrategyId("  aave-v3  "), "aave-v3");
    // chain:venue is not a supported composite — left as-is (document only)
    assert.equal(normalizeStrategyId("sui:suilend"), "sui:suilend");
  });

  it("prepareStrategyDeposit / Withdraw are POST prepare-only plans", async () => {
    /** @type {{ url: string, method: string, body: unknown }[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url, init) => {
        calls.push({
          url: String(url),
          method: init?.method || "GET",
          body: init?.body ? JSON.parse(init.body) : null,
        });
        return new Response(
          JSON.stringify({
            planStatus: "prepared",
            feeBps: 0,
            feeMicros: "0",
          }),
          { status: 200 },
        );
      },
    });
    const dep = await client.prepareStrategyDeposit({
      strategyId: "suilend",
      amountMicros: "1000000",
      owner: "0xowner",
      autoYieldEnabled: false,
    });
    assert.equal(dep.planStatus, "prepared");
    assert.equal(dep.feeBps, 0);
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].url, "https://example.test/api/v1/day/strategies/deposit/plan");
    assert.equal(calls[0].body.strategyId, "suilend");
    assert.equal(calls[0].body.amountMicros, "1000000");

    // DAY-268: form-* alias sent as bare venueId
    await client.prepareStrategyDeposit({
      strategyId: "form-suilend",
      amountMicros: "1",
    });
    assert.equal(calls[1].body.strategyId, "suilend");

    const w = await client.prepareStrategyWithdraw({
      strategyId: "form-kamino",
      amountMicros: "500000",
      owner: "0xowner",
    });
    assert.equal(w.feeMicros, "0");
    assert.equal(calls[2].url, "https://example.test/api/v1/day/strategies/withdraw/plan");
    assert.equal(calls[2].method, "POST");
    assert.equal(calls[2].body.strategyId, "kamino");
  });

  it("marketStats and whatPossible hit public discovery paths", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        calls.push(url);
        if (String(url).includes("/markets/stats")) {
          return new Response(
            JSON.stringify({ schemaVersion: "day-markets-stats.v1", totalTvlUsd: 1 }),
            { status: 200 },
          );
        }
        return new Response(
          JSON.stringify({ schemaVersion: "day-possible.v1", mode: "prepare_only" }),
          { status: 200 },
        );
      },
    });
    const stats = await client.marketStats();
    assert.equal(stats.schemaVersion, "day-markets-stats.v1");
    assert.equal(calls[0], "https://example.test/api/v1/day/markets/stats");

    const possible = await client.whatPossible();
    assert.equal(possible.mode, "prepare_only");
    assert.equal(calls[1], "https://example.test/api/v1/day/possible");
  });

  it("wallet balance helpers encode address query", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        calls.push(url);
        return new Response(JSON.stringify({ balances: [] }), { status: 200 });
      },
    });
    await client.suiWalletBalance("0xabc");
    await client.solanaWalletBalance("So11111111111111111111111111111111111111112");
    await client.baseWalletBalance("0x0000000000000000000000000000000000000001");
    await client.arbitrumWalletBalance("0x6d0C8D799c4e041eA45e02E456a36a360F3bC142");
    assert.equal(
      calls[0],
      "https://example.test/api/v1/day/sui/wallet-balance?address=0xabc",
    );
    assert.ok(calls[1].includes("/api/v1/day/solana/wallet-balance?address="));
    assert.ok(calls[1].includes("So11111111111111111111111111111111111111112"));
    assert.equal(
      calls[2],
      "https://example.test/api/v1/day/base/wallet-balance?address=0x0000000000000000000000000000000000000001",
    );
    assert.ok(calls[3].includes("/api/v1/day/arbitrum/wallet-balance?address="));
    assert.ok(calls[3].includes("0x6d0C8D799c4e041eA45e02E456a36a360F3bC142"));
  });

  it("base and arbitrum enablement / profile paths", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        calls.push(url);
        return new Response(JSON.stringify({ status: "ok" }), { status: 200 });
      },
    });
    await client.baseProfile();
    await client.baseEnablement();
    await client.arbitrumProfile();
    await client.arbitrumEnablement();
    assert.deepEqual(calls, [
      "https://example.test/api/v1/day/base",
      "https://example.test/api/v1/day/base/enablement",
      "https://example.test/api/v1/day/arbitrum",
      "https://example.test/api/v1/day/arbitrum/enablement",
    ]);
  });

  it("readiness and network hit protocol paths", async () => {
    /** @type {string[]} */
    const calls = [];
    const client = new DayClient({
      checkUpdate: false,
      baseUrl: "https://example.test",
      fetchImpl: async (url) => {
        calls.push(url);
        return new Response(JSON.stringify({ ok: true }), { status: 200 });
      },
    });
    await client.readiness();
    await client.network();
    assert.equal(calls[0], "https://example.test/api/v1/day/readiness");
    assert.equal(calls[1], "https://example.test/api/v1/day/network");
  });

  // DAY-274: free routeYield helper is owner-scoped — not public
  it("routeYield helper requires apiKey and walletAddress (no silent defaults)", async () => {
    await assert.rejects(
      () => routeYield({ amount: 1000 }),
      (e) =>
        e instanceof DayError &&
        e.code === "INVALID_CONFIG" &&
        /apiKey/i.test(e.message) &&
        /not public/i.test(e.message),
    );
    await assert.rejects(
      () => routeYield({ amount: 1000, apiKey: "k" }),
      (e) =>
        e instanceof DayError &&
        e.code === "INVALID_CONFIG" &&
        /walletAddress/i.test(e.message),
    );
    await assert.rejects(
      () => routeYield({ amount: 1000, walletAddress: "c1" }),
      (e) => e instanceof DayError && e.code === "INVALID_CONFIG" && /apiKey/i.test(e.message),
    );
    await assert.rejects(
      () => routeYield({ amount: 1000, apiKey: "  ", walletAddress: "c1" }),
      (e) => e instanceof DayError && e.code === "INVALID_CONFIG",
    );
    await assert.rejects(
      () => routeYield({ amount: 1000, apiKey: "k", walletAddress: "" }),
      (e) => e instanceof DayError && e.code === "INVALID_CONFIG",
    );
    await assert.rejects(
      () => routeYield({ apiKey: "k", walletAddress: "c1" }),
      (e) => e instanceof DayError && e.code === "INVALID_AMOUNT",
    );
  });

  it("routeYield helper posts preview with X-API-Key and never uses walletAddress=default", async () => {
    /** @type {{ url: string, method: string, headers: Headers, body: unknown }[]} */
    const calls = [];
    const res = await routeYield({
      amount: 1_000_000,
      token: "USDC",
      walletAddress: "char_owned",
      apiKey: "owner-key",
      baseUrl: "https://example.test",
      goal: "stable_yield_for_agent",
      fetchImpl: async (url, init) => {
        const u = String(url);
        // Ignore fire-and-forget SDK/API version probes after first success
        if (u.includes("/api/v1/day/sdk") || u.includes("/api/v1/day/version")) {
          return new Response(JSON.stringify({ latestVersion: "0.2.4" }), { status: 200 });
        }
        calls.push({
          url: u,
          method: init?.method || "GET",
          headers: init.headers,
          body: init?.body ? JSON.parse(init.body) : null,
        });
        return new Response(JSON.stringify({ planStatus: "prepared" }), { status: 200 });
      },
    });
    assert.equal(res.planStatus, "prepared");
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://example.test/api/v1/wallets/char_owned/preview");
    assert.equal(calls[0].method, "POST");
    assert.equal(calls[0].headers.get("X-API-Key"), "owner-key");
    assert.equal(calls[0].body.amountMicros, "1000000");
    assert.equal(calls[0].body.token, "USDC");
    assert.ok(!String(calls[0].url).includes("/default"));
  });

  it("routeYield helper falls back to owner route on 404 preview", async () => {
    /** @type {string[]} */
    const calls = [];
    const res = await routeYield({
      amount: "500000",
      walletAddress: "char_2",
      apiKey: "owner-key",
      baseUrl: "https://example.test",
      fetchImpl: async (url, init) => {
        calls.push(String(url));
        if (String(url).includes("/preview")) {
          return new Response(JSON.stringify({ code: "NOT_FOUND", message: "nope" }), {
            status: 404,
          });
        }
        assert.equal(init.headers.get("X-API-Key"), "owner-key");
        return new Response(JSON.stringify({ success: true, deposited: true }), { status: 200 });
      },
    });
    assert.equal(res.success, true);
    assert.equal(calls[0], "https://example.test/api/v1/wallets/char_2/preview");
    assert.equal(calls[1], "https://example.test/api/v1/wallets/char_2/route");
  });

  // DAY-278: public exports stay aligned with index.d.ts / index.mjs
  it("exports version + buildApiVersionCheckResult from package entry", () => {
    assert.equal(typeof SDK_VERSION, "string");
    assert.equal(typeof SDK_API_VERSION, "string");
    assert.equal(SDK_PACKAGE_NAME, "@dayprotocol/sdk");
    const r = buildApiVersionCheckResult({
      clientApiVersion: "1.0.0",
      version: "1.0.0",
      latestVersion: "1.0.0",
    });
    assert.equal(r.schemaVersion, "day-api-update.v1");
    assert.equal(r.upToDate, true);
  });
});

import { toV1Path, resolveApiUrl } from "../src/index.mjs";

describe("v1 path join (no double prefix)", () => {
  it("toV1Path prefixes product paths once", () => {
    assert.equal(toV1Path("/api/day/status"), "/api/v1/day/status");
    assert.equal(toV1Path("/api/v1/day/status"), "/api/v1/day/status");
    assert.equal(toV1Path("/api/day/openapi.json"), "/api/v1/openapi.json");
    assert.equal(toV1Path("/health"), "/health");
  });

  it("resolveApiUrl with origin base", () => {
    assert.equal(
      resolveApiUrl("https://dayprotocol.com", "/api/day/status"),
      "https://dayprotocol.com/api/v1/day/status",
    );
  });

  it("resolveApiUrl with /api/v1 base does not double", () => {
    assert.equal(
      resolveApiUrl("https://dayprotocol.com/api/v1", "/api/day/status"),
      "https://dayprotocol.com/api/v1/day/status",
    );
    assert.equal(
      resolveApiUrl("https://dayprotocol.com/api/v1/", "/api/v1/day/strategies"),
      "https://dayprotocol.com/api/v1/day/strategies",
    );
    assert.equal(
      resolveApiUrl("https://dayprotocol.com/api/v1", "/health"),
      "https://dayprotocol.com/health",
    );
  });
});
