import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  SDK_VERSION,
  SDK_API_VERSION,
  compareSemver,
  isUpdateAvailable,
  buildUpdateResult,
  buildApiVersionCheckResult,
} from "../src/version.mjs";
import { DayClient } from "../src/index.mjs";

describe("SDK version helpers", () => {
  it("exports a semver SDK_VERSION", () => {
    assert.match(SDK_VERSION, /^\d+\.\d+\.\d+$/);
  });

  it("compareSemver orders correctly", () => {
    assert.equal(compareSemver("0.2.0", "0.2.1"), -1);
    assert.equal(compareSemver("0.2.1", "0.2.1"), 0);
    assert.equal(compareSemver("0.3.0", "0.2.9"), 1);
    assert.equal(compareSemver("v1.0.0", "1.0.0"), 0);
  });

  it("isUpdateAvailable", () => {
    assert.equal(isUpdateAvailable("0.2.0", "0.2.1"), true);
    assert.equal(isUpdateAvailable("0.2.1", "0.2.1"), false);
    assert.equal(isUpdateAvailable("0.3.0", "0.2.1"), false);
  });

  it("buildUpdateResult message when outdated", () => {
    const r = buildUpdateResult({
      currentVersion: "0.1.0",
      latestVersion: "0.2.1",
      minSupportedVersion: "0.1.0",
      install: { gitTag: "npm install github:dayprotocol/sdk#v0.2.1" },
    });
    assert.equal(r.updateAvailable, true);
    assert.equal(r.upToDate, false);
    assert.match(r.message, /0\.1\.0 → 0\.2\.1/);
  });
});

describe("DayClient.checkForUpdate", () => {
  it("reports updateAvailable against remote latest", async () => {
    const fetchImpl = async (url) => {
      assert.match(String(url), /\/api\/v1\/day\/sdk$/);
      return {
        ok: true,
        status: 200,
        statusText: "OK",
        text: async () =>
          JSON.stringify({
            schemaVersion: "day-sdk-release.v1",
            package: "@dayprotocol/sdk",
            latestVersion: "9.9.9",
            minSupportedVersion: "0.1.0",
            install: {
              git: "npm install github:dayprotocol/sdk",
              gitTag: "npm install github:dayprotocol/sdk#v9.9.9",
            },
            releaseUrl: "https://github.com/dayprotocol/sdk/releases",
          }),
      };
    };
    const warnings = [];
    const orig = console.warn;
    console.warn = (...a) => warnings.push(a.join(" "));
    try {
      const day = new DayClient({
        baseUrl: "https://dayprotocol.com",
        fetchImpl,
        checkUpdate: false, // manual only
        warnOnUpdate: true,
      });
      const r = await day.checkForUpdate();
      assert.equal(r.updateAvailable, true);
      assert.equal(r.latestVersion, "9.9.9");
      assert.equal(r.currentVersion, SDK_VERSION);
      assert.ok(warnings.some((w) => w.includes("update available")));
    } finally {
      console.warn = orig;
    }
  });

  it("schedules update check after first successful non-sdk request", async () => {
    let sdkHits = 0;
    let versionHits = 0;
    const fetchImpl = async (url) => {
      const u = String(url);
      if (u.includes("/api/v1/day/sdk")) {
        sdkHits += 1;
        return {
          ok: true,
          status: 200,
          statusText: "OK",
          headers: {
            get: (n) =>
              String(n).toLowerCase() === "x-day-api-version-latest" ? SDK_API_VERSION : null,
          },
          text: async () =>
            JSON.stringify({
              latestVersion: SDK_VERSION,
              minSupportedVersion: "0.1.0",
              install: {},
            }),
        };
      }
      if (u.includes("/api/v1/day/version")) {
        versionHits += 1;
        return {
          ok: true,
          status: 200,
          statusText: "OK",
          headers: {
            get: (n) =>
              String(n).toLowerCase() === "x-day-api-version-latest" ? SDK_API_VERSION : null,
          },
          text: async () =>
            JSON.stringify({
              version: SDK_API_VERSION,
              latestVersion: SDK_API_VERSION,
              minSupportedVersion: "1.0",
              client: {
                version: SDK_API_VERSION,
                updateAvailable: false,
                belowMinimum: false,
                upToDate: true,
                message: null,
              },
            }),
        };
      }
      return {
        ok: true,
        status: 200,
        statusText: "OK",
        headers: {
          get: (n) => {
            const k = String(n).toLowerCase();
            if (k === "x-day-api-version") return SDK_API_VERSION;
            if (k === "x-day-api-version-latest") return SDK_API_VERSION;
            if (k === "x-day-api-version-min") return "1.0";
            return null;
          },
        },
        text: async () => JSON.stringify({ schemaVersion: "day-readiness.v1", ok: true }),
      };
    };
    const day = new DayClient({
      baseUrl: "https://example.test",
      fetchImpl,
      checkUpdate: true,
      warnOnUpdate: false,
    });
    await day.readiness();
    await new Promise((r) => setTimeout(r, 30));
    assert.ok(sdkHits >= 1, "expected /api/v1/day/sdk hit");
    assert.ok(versionHits >= 1, "expected /api/v1/day/version hit");
    assert.ok(day.lastUpdateCheck);
    assert.equal(day.lastUpdateCheck.upToDate, true);
  });

  it("checkApiVersion reports when server latest is newer", async () => {
    const fetchImpl = async (url) => {
      assert.match(String(url), /\/api\/v1\/day\/version/);
      return {
        ok: true,
        status: 200,
        statusText: "OK",
        headers: { get: () => null },
        text: async () =>
          JSON.stringify({
            version: "9.0",
            latestVersion: "9.0",
            minSupportedVersion: "1.0",
            client: {
              version: SDK_API_VERSION,
              updateAvailable: true,
              belowMinimum: false,
              upToDate: false,
              message: "DAY API update available",
            },
          }),
      };
    };
    const day = new DayClient({
      baseUrl: "https://example.test",
      fetchImpl,
      checkUpdate: false,
      warnOnUpdate: false,
    });
    const r = await day.checkApiVersion();
    assert.equal(r.updateAvailable, true);
    assert.equal(r.latestVersion, "9.0");
  });

  it("buildApiVersionCheckResult works", () => {
    const r = buildApiVersionCheckResult({
      clientApiVersion: "0.9.0",
      version: "1.0.0",
      latestVersion: "1.0.0",
      minSupportedVersion: "1.0.0",
    });
    assert.equal(r.updateAvailable, true);
    assert.equal(r.belowMinimum, true);
    const same = buildApiVersionCheckResult({
      clientApiVersion: "1.0.0",
      version: "1.0.0",
      latestVersion: "1.0.0",
      minSupportedVersion: "1.0.0",
    });
    assert.equal(same.updateAvailable, false);
    assert.equal(same.upToDate, true);
  });
});

