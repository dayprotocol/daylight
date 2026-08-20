import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  buildIdempotencyKey,
  isIdempotencyKey,
  assertIdempotencyKey,
  IDEMPOTENCY_HEADER,
  DayError,
} from "../src/index.mjs";

describe("idempotency key shapes (salvage)", () => {
  it("builds canonical oy_<op>_<walletAddress>_<nonce>", () => {
    const k = buildIdempotencyKey("harvest", "char_1", "req-42");
    assert.equal(k, "oy_harvest_char-1_req-42");
    assert.ok(isIdempotencyKey(k));
    assert.equal(assertIdempotencyKey(k), k);
  });

  it("rejects malformed keys", () => {
    assert.equal(isIdempotencyKey("nope"), false);
    assert.equal(isIdempotencyKey("oy_harvest"), false);
    assert.equal(isIdempotencyKey(""), false);
    assert.throws(() => assertIdempotencyKey("garbage"), (e) => e instanceof DayError);
  });

  it("build validates inputs", () => {
    assert.throws(() => buildIdempotencyKey("BAD OP", "c", "n"), (e) => e instanceof DayError);
    assert.throws(() => buildIdempotencyKey("harvest", "", "n"), (e) => e.code === "INVALID_CONFIG");
    assert.throws(() => buildIdempotencyKey("harvest", "c", ""), (e) => e.code === "INVALID_CONFIG");
  });

  it("exports Idempotency-Key header name", () => {
    assert.equal(IDEMPOTENCY_HEADER, "Idempotency-Key");
  });
});
