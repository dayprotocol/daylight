import { DayError } from "./errors.mjs";

// Strict decimal-integer (optionally signed). No dot, no exponent, no inner whitespace.
const INT_RE = /^-?\d+$/;

// Normalize a micros value to a BigInt-safe decimal string.
// Accepts: bigint | integer-string | safe-integer number.
// Rejects: floats, exponent notation, NaN/Infinity, unsafe-integer numbers,
//          empty / non-numeric strings, objects. Enforces "no float money".
export function toMicrosString(value, field = "amountMicros", opts = {}) {
  const { allowZero = false } = opts;
  let str;

  if (typeof value === "bigint") {
    str = value.toString();
  } else if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new DayError("INVALID_AMOUNT", `${field} must be a finite integer`);
    }
    if (!Number.isInteger(value)) {
      throw new DayError(
        "INVALID_AMOUNT",
        `${field} must be an integer number of micros, not a float (${value}); no float money`,
      );
    }
    if (!Number.isSafeInteger(value)) {
      throw new DayError(
        "INVALID_AMOUNT",
        `${field} exceeds MAX_SAFE_INTEGER; pass a string or BigInt to stay BigInt-safe`,
      );
    }
    str = String(value);
  } else if (typeof value === "string") {
    const trimmed = value.trim();
    if (!INT_RE.test(trimmed)) {
      throw new DayError(
        "INVALID_AMOUNT",
        `${field} must be a decimal-integer micros string; no floats, no exponent, no units`,
      );
    }
    str = trimmed;
  } else {
    throw new DayError(
      "INVALID_AMOUNT",
      `${field} is required as a micros string / BigInt-safe integer`,
    );
  }

  let n;
  try {
    n = BigInt(str);
  } catch {
    throw new DayError("INVALID_AMOUNT", `${field} is not a valid integer`);
  }
  if (n < 0n) {
    throw new DayError("INVALID_AMOUNT", `${field} must not be negative`);
  }
  if (!allowZero && n === 0n) {
    throw new DayError("INVALID_AMOUNT", `${field} must be greater than zero`);
  }
  return n.toString();
}

// True if the value is an acceptable micros representation.
export function isMicros(value, opts = {}) {
  try {
    toMicrosString(value, "value", opts);
    return true;
  } catch {
    return false;
  }
}
