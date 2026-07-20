/**
 * DAY Form adapter — haedal (Sui LST) · DAY-303 write prepare.
 * read_apy from mock table; supply/withdraw/claim owner-sign prepare.
 * readiness mock until mainnet Move package path verified (do not fake live).
 *
 * Product family (DAY-339 companion residual):
 * - form-haedal = haSUI LST stake prepare (sibling ≠ haeVault).
 * - haeVault managed product (`vault-haedal-*` LIST) is residual — empty.
 * - DAY-339 ticket closes via form-kai YO vault path, not via haeVault/LST digests.
 * - Discovery haedal INDEX crawl is live (map only).
 */
import { createMockFormAdapter } from "./shared.mjs";
import { withSuiWritePrepare } from "./sui-write-prepare.mjs";

export const HAEDAL_MOCK_APY_BPS = 380;

const haedalFormAdapterBase = createMockFormAdapter({
  venueId: "haedal",
  formId: "form-haedal",
  chain: "sui",
  mockApyBps: HAEDAL_MOCK_APY_BPS,
  wave: "day-1",
  ticket: "DAY-303",
  notes:
    "Haedal haSUI LST owner-sign prepare; form sibling ≠ haeVault managed LIST residual; DAY-339 Done via form-kai not haeVault; discovery crawl live",
});

export const haedalFormAdapter = withSuiWritePrepare(haedalFormAdapterBase, "haedal");

export default haedalFormAdapter;
