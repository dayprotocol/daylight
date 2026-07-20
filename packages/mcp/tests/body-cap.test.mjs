/**
 * DAY-624 — the standalone MCP HTTP server's readBody must cap request body
 * size to prevent a memory-exhaustion DoS. Mirrors the DAY-261 parseBody guard
 * in api/server.mjs (see tests/audit-codex-dos.test.mjs).
 *
 * Over-cap bodies reject with a 413-tagged error (→ caller returns HTTP 413);
 * under-cap bodies resolve normally.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { EventEmitter } from "node:events";
import { readBody, MAX_BODY_BYTES } from "../src/http-server.mjs";

function fakeReq(body, { destroyable = true } = {}) {
  const r = Readable.from([Buffer.from(body)]);
  if (destroyable) r.destroy = () => {};
  return r;
}

describe("readBody byte cap", () => {
  it("rejects oversized body with a 413-tagged error", async () => {
    const big = "{" + '"a":"' + "x".repeat(4096) + '"}';
    await assert.rejects(
      () => readBody(fakeReq(big), { maxBytes: 1024 }),
      (e) => e.status === 413 && e.code === "PAYLOAD_TOO_LARGE",
    );
  });

  it("accepts an under-cap body (resolves to the raw string)", async () => {
    const out = await readBody(fakeReq('{"ok":true}'), { maxBytes: 1024 });
    assert.equal(out, '{"ok":true}');
  });

  it("defaults to MAX_BODY_BYTES when no maxBytes passed", async () => {
    assert.ok(Number.isFinite(MAX_BODY_BYTES) && MAX_BODY_BYTES > 0);
    const out = await readBody(fakeReq('{"small":1}'));
    assert.equal(out, '{"small":1}');
  });

  it("destroys the request stream once the cap is exceeded", async () => {
    // Minimal EventEmitter req: emit chunks past the cap and assert destroy()
    // is called and the promise rejects (no 'end' resolution, no unbounded buffer).
    const req = new EventEmitter();
    let destroyed = false;
    req.destroy = () => {
      destroyed = true;
    };
    const p = readBody(req, { maxBytes: 8 });
    req.emit("data", Buffer.from("1234"));
    req.emit("data", Buffer.from("56789")); // total 9 > 8 → over cap
    await assert.rejects(p, (e) => e.status === 413);
    assert.equal(destroyed, true, "req.destroy() called on overflow");
  });

  it("propagates a stream 'error' as a rejection", async () => {
    const req = new EventEmitter();
    req.destroy = () => {};
    const p = readBody(req, { maxBytes: 1024 });
    const boom = new Error("socket blew up");
    req.emit("error", boom);
    await assert.rejects(p, (e) => e === boom);
  });
});
