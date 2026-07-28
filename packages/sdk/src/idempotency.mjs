import { DayError } from "./errors.mjs";

// Header the server reads to dedupe a mutating money call.
export const IDEMPOTENCY_HEADER = "Idempotency-Key";

// Canonical idempotency-key SHAPE for DAY money operations:
//   oy_<op>_<walletAddress>_<nonce>
// - op:      route | withdraw | harvest | auto-pay | auto-yield (the money action)
// - walletAddress: scopes the key to one wallet
// - nonce:   caller-chosen unique token (a client request id, ULID, hash, ...)
// The permissionless-harvest rule still holds: the key only dedupes a poke, it
// cannot encode amounts, fees, or waterfall behavior.
const OP_RE = /^[a-z][a-z0-9-]*$/;
const KEY_RE = /^oy_[a-z][a-z0-9-]*_[^_]+_.+$/;

// Build a canonical idempotency key. Sanitizes walletAddress so the underscore
// delimiters stay unambiguous.
export function buildIdempotencyKey(op, walletAddress, nonce) {
  if (typeof op !== "string" || !OP_RE.test(op)) {
    throw new DayError("INVALID_CONFIG", "idempotency op must be a lowercase slug");
  }
  if (typeof walletAddress !== "string" || walletAddress.length === 0) {
    throw new DayError("INVALID_CONFIG", "idempotency walletAddress is required");
  }
  if (nonce == null || String(nonce).length === 0) {
    throw new DayError("INVALID_CONFIG", "idempotency nonce is required");
  }
  const safeChar = String(walletAddress).replace(/_/g, "-");
  const safeNonce = String(nonce).replace(/\s+/g, "-");
  return `oy_${op}_${safeChar}_${safeNonce}`;
}

// Validate an externally-supplied idempotency key against the canonical shape.
export function isIdempotencyKey(key) {
  return typeof key === "string" && KEY_RE.test(key) && key.length <= 255;
}

// Assert + return a usable key (accepts a pre-built canonical key only).
export function assertIdempotencyKey(key) {
  if (!isIdempotencyKey(key)) {
    throw new DayError(
      "INVALID_CONFIG",
      "idempotencyKey must match shape oy_<op>_<walletAddress>_<nonce>",
    );
  }
  return key;
}
