import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { toMicrosString, isMicros } from "../src/money.mjs";
import { DayError } from "../src/errors.mjs";

describe("toMicrosString", () => {
  it("accepts integer strings, safe-int numbers, bigints", () => {
    assert.equal(toMicrosString("10000000000"), "10000000000");
    assert.equal(toMicrosString(5000000), "5000000");
    assert.equal(toMicrosString(123n), "123");
    assert.equal(toMicrosString("  42  "), "42"); // trims
  });

  it("stays lossless well beyond 2^53", () => {
    const big = "9007199254740993000000"; // > MAX_SAFE_INTEGER
    assert.equal(toMicrosString(big), big);
    assert.equal(toMicrosString(10n ** 30n), (10n ** 30n).toString());
  });

  it("rejects floats, exponent, NaN/Infinity", () => {
    for (const bad of [1.5, "1.0", "1e6", NaN, Infinity, -Infinity]) {
      assert.throws(() => toMicrosString(bad), (e) => e instanceof DayError && e.code === "INVALID_AMOUNT");
    }
  });

  it("rejects unsafe-integer numbers but accepts them as strings", () => {
    assert.throws(() => toMicrosString(Number.MAX_SAFE_INTEGER + 2), (e) => e.code === "INVALID_AMOUNT");
    assert.equal(toMicrosString(`${Number.MAX_SAFE_INTEGER}0`), `${Number.MAX_SAFE_INTEGER}0`);
  });

  it("rejects zero unless allowZero", () => {
    assert.throws(() => toMicrosString("0"), (e) => e.code === "INVALID_AMOUNT");
    assert.equal(toMicrosString("0", "x", { allowZero: true }), "0");
  });

  it("rejects negatives and junk", () => {
    assert.throws(() => toMicrosString("-1"), (e) => e.code === "INVALID_AMOUNT");
    assert.throws(() => toMicrosString("abc"), (e) => e.code === "INVALID_AMOUNT");
    assert.throws(() => toMicrosString(null), (e) => e.code === "INVALID_AMOUNT");
    assert.throws(() => toMicrosString({}), (e) => e.code === "INVALID_AMOUNT");
  });

  it("isMicros mirrors validity", () => {
    assert.equal(isMicros("100"), true);
    assert.equal(isMicros(1.5), false);
    assert.equal(isMicros("0"), false);
    assert.equal(isMicros("0", { allowZero: true }), true);
  });
});
