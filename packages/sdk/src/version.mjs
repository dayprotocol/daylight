/**
 * SDK version + update check helpers.
 * Source of truth for "what am I running" is package.json (inlined at release).
 */

/** Installed client version — bump with package.json on every release. */
export const SDK_VERSION = "0.2.4";

export const SDK_PACKAGE_NAME = "@dayprotocol/sdk";

/**
 * API version this SDK was built against / documents.
 * DAY API **v1** starts at 1.0.0 (formal OpenAPI contract).
 * Compare to server X-DAY-API-Version-Latest via DayClient.checkApiVersion().
 */
export const SDK_API_VERSION = "1.0.0";

/**
 * Compare semver strings (major.minor.patch only; pre-release ignored).
 * @param {string} a
 * @param {string} b
 * @returns {number} -1 if a<b, 0 if equal, 1 if a>b
 */
export function compareSemver(a, b) {
  const pa = String(a || "0")
    .replace(/^v/i, "")
    .split("-")[0]
    .split(".")
    .map((x) => parseInt(x, 10) || 0);
  const pb = String(b || "0")
    .replace(/^v/i, "")
    .split("-")[0]
    .split(".")
    .map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < 3; i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d < 0) return -1;
    if (d > 0) return 1;
  }
  return 0;
}

/**
 * @param {string} current
 * @param {string} latest
 * @returns {boolean}
 */
export function isUpdateAvailable(current, latest) {
  if (!latest) return false;
  return compareSemver(current, latest) < 0;
}

/**
 * Normalize API or GitHub release payload into a check result.
 * @param {object} input
 * @param {string} [input.currentVersion]
 * @param {string} [input.latestVersion]
 * @param {string} [input.minSupportedVersion]
 * @param {object} [input.install]
 * @param {string} [input.releaseUrl]
 * @param {string} [input.repoUrl]
 */
export function buildUpdateResult(input = {}) {
  const currentVersion = String(input.currentVersion || SDK_VERSION);
  const latestVersion = input.latestVersion != null ? String(input.latestVersion) : null;
  const minSupportedVersion =
    input.minSupportedVersion != null ? String(input.minSupportedVersion) : null;
  const updateAvailable =
    latestVersion != null ? isUpdateAvailable(currentVersion, latestVersion) : false;
  const belowMinimum =
    minSupportedVersion != null
      ? compareSemver(currentVersion, minSupportedVersion) < 0
      : false;

  let message = null;
  if (belowMinimum) {
    message = `${SDK_PACKAGE_NAME} ${currentVersion} is below the minimum supported ${minSupportedVersion}. Upgrade: ${input.install?.gitTag || input.install?.git || `npm install github:dayprotocol/sdk#v${latestVersion}`}`;
  } else if (updateAvailable) {
    message = `${SDK_PACKAGE_NAME} update available: ${currentVersion} → ${latestVersion}. Upgrade: ${input.install?.gitTag || `npm install github:dayprotocol/sdk#v${latestVersion}`}`;
  }

  return {
    schemaVersion: "day-sdk-update.v1",
    package: SDK_PACKAGE_NAME,
    currentVersion,
    latestVersion,
    minSupportedVersion,
    updateAvailable,
    belowMinimum,
    upToDate: latestVersion != null ? !updateAvailable && !belowMinimum : null,
    install: input.install || null,
    releaseUrl: input.releaseUrl || "https://github.com/dayprotocol/sdk/releases",
    repoUrl: input.repoUrl || "https://github.com/dayprotocol/sdk",
    message,
  };
}

/**
 * Compare client-targeted API version vs server GET /api/day/version payload.
 * @param {object} input
 */
export function buildApiVersionCheckResult(input = {}) {
  const clientApiVersion = String(input.clientApiVersion || SDK_API_VERSION);
  const serverVersion = input.version != null ? String(input.version) : null;
  const latestVersion =
    input.latestVersion != null ? String(input.latestVersion) : serverVersion;
  const minSupportedVersion =
    input.minSupportedVersion != null ? String(input.minSupportedVersion) : null;

  const updateAvailable =
    latestVersion != null ? compareSemver(clientApiVersion, latestVersion) < 0 : false;
  const belowMinimum =
    minSupportedVersion != null
      ? compareSemver(clientApiVersion, minSupportedVersion) < 0
      : false;

  let message = null;
  if (belowMinimum) {
    message = `DAY API ${clientApiVersion} is below minimum ${minSupportedVersion}. Upgrade your client/integration (server latest ${latestVersion}). See GET /api/day/version.`;
  } else if (updateAvailable) {
    message = `DAY API update available: client targets ${clientApiVersion}, latest is ${latestVersion}. Read response headers X-DAY-API-Version-Latest or GET /api/day/version.`;
  }

  return {
    schemaVersion: "day-api-update.v1",
    clientApiVersion,
    serverVersion,
    latestVersion,
    minSupportedVersion,
    updateAvailable,
    belowMinimum,
    upToDate: latestVersion != null ? !updateAvailable && !belowMinimum : null,
    message,
    versionPath: "/api/day/version",
    docsUrl: input.docsUrl || "https://docs.dayprotocol.com",
    headers: input.headers || {
      version: "X-DAY-API-Version",
      latest: "X-DAY-API-Version-Latest",
      min: "X-DAY-API-Version-Min",
    },
  };
}
