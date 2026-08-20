# Security Policy

## Reporting a vulnerability

**Do not open public issues for active exploits.**

Prefer one of:

1. **GitHub Security Advisories** — private report on the relevant `dayprotocol/*` repository (Security → Report a vulnerability), when available.
2. **Email** — `mav@gen.pro` until a dedicated `security@` address is published.

Please include: affected package/version or package id, chain, impact, and a minimal reproduction if possible.

## Scope (when core is public)

- **In-scope:** Move / Solana / EVM packages listed on docs.dayprotocol.com; published `@dayprotocol/sdk` versions; fee math and non-custodial invariants.
- **Out of scope:** third-party venues (Suilend, NAVI, bridges), phishing, social engineering, issues that only apply after a private key is already leaked.

## Known product rules (not bugs)

- Stake defaults **OFF**
- Fee applies only to harvested yield
- Agents cannot withdraw principal
- Adapter `read_apy` may be null (must not invent APY)

## Versioning

Fixes that preserve invariants ship as patches on the same major.
Invariant changes require a new major package version (see docs/22-versioning-strategy.md).
