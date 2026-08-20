> The DAY whitepaper. Also on the site at [dayprotocol.com](https://dayprotocol.com/docs).

# DAY

### The open routing layer for onchain yield

**A non-custodial protocol that routes capital into Yield Opportunities — never custody. Owners always exit.**

Version 1.0 · [dayprotocol.com](https://dayprotocol.com)

---

## Abstract

Onchain yield is fragmented: lending markets, liquid staking, pools, and third-party vaults sit on different chains with different interfaces. Putting capital to work safely means more than a dashboard — it means open rails that can discover, route, and harvest, without taking custody.

DAY is building the open routing layer for onchain yield. Idle assets earn in allowlisted Yield Opportunities, and realized yield compounds back into the owner's vault. Funds stay under owner control. DAY never holds the funds or the keys; it holds only a narrow, revocable permission to route capital into strategies the owner has allowed, and nowhere else. Owners, treasuries, Strategy Leads, and agents use the same rails.

This document describes what DAY does, the trust model that makes it safe, and the architecture that keeps it non-custodial. The shipped core is yield routing across the supported chains. The specific chains and strategies DAY supports at any given time are listed in Appendix A, kept separate from the body because they evolve continuously and are not the point of the protocol.

---

## 1. The problem

Onchain yield is fragmented and unsafe to chase by hand.

Lending markets, liquid staking, pools, and third-party vaults sit on different chains behind different interfaces. Finding the best risk-adjusted yield means watching many venues at once; capturing it means moving capital between them continuously. Doing that manually is slow and error-prone. Automating it usually means handing your funds to a service that can lose, freeze, or take them.

This leaves owners with a bad trade:

- **Do it yourself and fall behind.** Yield moves faster than a human can track across chains. Idle capital or a stale position is money left on the table.
- **Automate and give up custody.** Almost every tool that automates yield takes custody of funds to do it, recreating the exact counterparty risk onchain was meant to remove.
- **No open, non-custodial middle.** There has been no shared rail that can discover, route, and harvest yield across chains while the owner keeps the funds and the keys.

The tools that exist today do not solve this. Yield aggregators, lending front-ends, and treasury dashboards are built for humans making manual decisions, and most take custody of funds to do it. None of them route capital continuously and safely while leaving ownership fully in the owner's hands.

## 2. What DAY is

DAY is the open routing layer for onchain yield. It gives owners three abilities, built on one non-custodial foundation:

- **Earn.** Put idle capital to work in Yield Opportunities across the supported chains (Appendix A).
- **Route.** Move capital to the best allowed strategy and rebalance as conditions change — always within the owner's limits.
- **Persist.** Keep capital productive without a custodian, and without depending on the company that deployed the rails.

What makes DAY different is not access to markets, which is becoming a commodity. It is *safe, non-custodial routing* under owner Guardrails: open rails rather than a closed vault farm. Access is easy. Letting capital move into yield venues without handing over keys, and without the process being able to lose or steal that money, is the hard part. That is what DAY is built to do.

## 3. The trust model (read this first)

Everything else in DAY depends on one principle, so it comes first.

**DAY is non-custodial. The owner holds the funds and the keys. DAY never does.**

Concretely:

- Capital lives in a **vault the owner controls**, an on-chain object owned by the owner's own wallet. Depositing into DAY does not transfer funds to DAY.
- DAY holds only a **scoped, revocable capability**: permission to route the vault's capital into strategies on an allowlist the owner sets, and to return it to the owner. Nothing more.
- The capability is **destination-locked.** DAY can move funds into an approved yield strategy and back to the owner's vault. It cannot send funds to an arbitrary address, cannot withdraw to DAY, and cannot extract capital under any path. This is enforced by the contract, not by policy or promise.
- The owner can **revoke at any time.** Revocation is immediate and total. Because DAY never held the funds or the keys, revoking costs the owner nothing but the convenience of automation.
- The owner can **self-provision.** An owner who wants to run their own routing pays DAY nothing and grants no capability. DAY is optional infrastructure, not a gatekeeper.

The distinction that matters: DAY can *operate* an agent's capital (route it to earn, within limits) but can never *extract* it. This is what separates a genuine non-custodial protocol from a custodial service wearing the word. If a protocol can send your funds anywhere, it has custody, whatever it calls itself. DAY cannot, by construction.

**The human is not removed from the loop; the human sets the loop's boundaries.** The owner defines the goals, the strategy allowlist, and the caps. Within those boundaries the agent and the protocol act autonomously. Outside them, nothing can happen. This is what makes non-custodial routing safe: automation has freedom inside a fence the owner builds, and the fence is enforced on-chain.

## 4. How it works

DAY has three tiers. An **on-chain vault** holds the rules, the funds, and the limits, and can never be crossed. A set of **mechanical actions** (route, harvest, pay) carry out moves the vault permits. And **Autopilot**, an off-chain intelligence, decides which of those moves to make, toward the owner's goal and within the owner's limits. The shorthand: Autopilot flies, the actions are the controls, the vault is the airspace. The intelligence proposes; the contract disposes.

### 4.1 On-chain execution layer

Deployed on each supported chain (Appendix A). This layer is the source of truth and the safety boundary. It holds:

- The **owner-controlled vault** and its balance.
- The **strategy allowlist and caps** the owner has set (which protocols, maximum exposure per strategy, risk limits).
- The **routing logic** that deposits into and withdraws from approved strategies through per-strategy adapters.
- The **capability grant** that lets the off-chain layer trigger routing, bounded by everything above.

Critically, this layer *constrains* the off-chain intelligence. Even a compromised, buggy, or hallucinating orchestrator cannot move funds outside the allowlist, exceed the caps, or extract capital, because the contract rejects any action that violates the owner's boundaries. Safety does not depend on the intelligence being correct. It depends on the contract refusing anything out of bounds.

### 4.2 Autopilot: intelligent management

Autopilot is the intelligence that manages an owner's capital: the umbrella over everything DAY does on the owner's behalf. The owner sets a destination and the limits — a goal like "stable yield on my idle stablecoins," a strategy allowlist, and caps — and Autopilot handles the flying. Within those limits it orchestrates two capabilities:

- **Routing:** moving idle capital into the allowed strategy with the best risk-adjusted yield, and rebalancing as conditions change.
- **Harvesting:** claiming rewards and compounding them back into the vault, automatically, to keep capital working.

Autopilot reads live market conditions and manages the strategy toward the owner's goal, adapting rather than following a fixed rule. This is goal-driven management, not mere automation, and it is the part an owner pays for. Routing and harvesting are the mechanical work; the intelligence that decides what to do, when, and how much is the value.

Autopilot is deliberately not authoritative. Because the on-chain layer enforces every limit, it is *untrusted by design*: it can only propose actions the contract will independently check and can reject. It flies the plane, but the contract is the airspace it cannot leave. Autopilot is also replaceable. The owner is never locked to DAY's: the interface is open, so a third party can run their own, and an owner who wants to can self-provision and manage their own capital. DAY's Autopilot is one implementation — the one you pay a yield fee to use — not the only one the protocol permits. Intelligence is the value; it is never a point of control.

**Fee principle (locked):** DAY takes a **performance fee on realized yield** — 1% of harvested yield, capped at $10 per harvest, on non-managed strategies. It never charges to hold capital, to deposit, or to withdraw principal. Current fee parameters are in Appendix A and on the [Fees](https://dayprotocol.com/fees/) page.

### 4.3 Programmatic access

DAY is callable programmatically, so it can be driven by a script, a treasury system, or an autonomous agent as easily as by a person. It is reachable over standard interfaces, including x402 for pay-per-use access with no accounts and MCP for integration into agent frameworks and language models. A caller can request a routing decision or trigger an action and pay for it in the same motion, without a human signing up for anything.

### 4.4 The loop

Put together, the layers form a self-sustaining cycle:

1. Capital sits in the owner's vault.
2. Autopilot routes idle capital into the best allowed strategy.
3. Yield accrues and is harvested back into the vault.
4. Surplus compounds, and the position keeps working toward the owner's goal.

The loop runs continuously and non-custodially: capital stays productive with no manual intervention, while the owner retains full control and can withdraw or revoke at any time.

## 5. Architecture and what is open

DAY is layered so that the parts that touch money are open and verifiable, and the part that is DAY's own advantage stays private, without the private part ever being something you have to trust with your funds. The design goal is simple: you should be able to verify the safety of DAY without seeing the intelligence of DAY.

### 5.1 The layers

From the bottom up:

- **Vault layer.** The owner-controlled object that holds capital, one per owner, on each chain. Depositing does not move funds to DAY; it moves them into an object the owner owns. This is the root of the non-custodial guarantee.
- **Authorization layer.** The scoped, revocable, destination-locked capability that lets an orchestrator act on a vault. It defines precisely what any operator may do (route to allowlisted strategies, return to the owner) and, by omission, everything it may never do (send anywhere else, extract, withdraw to a third party). Revoking it is immediate.
- **Policy layer.** The owner's rules held on-chain: the strategy allowlist, per-strategy and total caps, and risk limits. The contract checks every proposed action against this policy and rejects anything outside it.
- **Adapter layer.** One adapter per strategy, implementing a common interface (deposit, withdraw, harvest, price). This is the extensibility surface: new strategies are new adapters against a shared interface, not changes to the core.
- **Routing / execution layer.** The on-chain logic that carries out approved moves through adapters and accounts for balances, yield, and fees.
- **Autopilot layer (off-chain).** The intelligence (the orchestrator, in architectural terms) that decides what to do within the policy: goal-driven strategy management. Untrusted by design and replaceable, as described above.
- **Access layer.** The interfaces agents call: x402 for autonomous pay-per-use, MCP for framework and model integration.

The load-bearing idea is the boundary between the on-chain layers (vault, authorization, policy, adapters, routing) and the off-chain orchestration layer. Everything that can move or hold money is on-chain and rule-bound. The off-chain layer can only ever *ask*; the on-chain layers *decide* whether the ask is permitted.

### 5.2 The open vault and the closed brain

Two properties, held together, are what make DAY both trustworthy and a business.

**The vault is open.** The contracts that hold and move capital — vaults, authorization, policy, routing, and the adapter interface that defines the standard — are open source and audited. For a non-custodial protocol this is not a nicety; it is the proof. You do not have to take DAY's word that funds are safe. You can read the contracts that guarantee it, and so can an auditor. Openness here is the trust.

**The brain is closed.** DAY's Autopilot — its strategy intelligence, how it selects strategies, times harvests, weighs risk, and allocates surplus — along with the data that feeds it, is proprietary. This is the service. It is what an owner pays a yield fee to use rather than managing capital themselves.

These do not conflict, and that is the point. You never have to trust the closed brain, because the open vault constrains it. A proprietary, even a malicious, Autopilot still cannot move funds outside the owner's on-chain limits or extract a cent, because the open, audited contract independently rejects anything out of bounds. The closed brain is safe to use *precisely because* the vault around it is open. DAY can keep its advantage private without asking anyone to trust a black box with their money.

### 5.3 What is open, and why

- **Open source, audited:** the vault, authorization, policy, and routing contracts; the adapter interface; and the access interfaces (x402, MCP). These are the money-handling core and the extensibility standard. They are open because non-custodial trust demands verifiable contracts, and because an open adapter standard lets others extend DAY's strategy coverage rather than waiting on DAY to do it.
- **Open interface, so DAY is never a lock-in:** the orchestration interface is public, so a third party can run their own orchestrator and an owner can self-provision. "Non-custodial and not locked in" is therefore literally true, not a slogan.
- **Proprietary:** DAY's Autopilot (its strategy intelligence) and its supporting data. This is the value DAY sells and the reason the yield fee exists. Keeping it private costs nothing in trust, because it lives outside the money-handling boundary and is constrained by the open contracts.

The result is a protocol whose safety anyone can verify, whose strategy coverage anyone can extend, which no one is locked into, and which still has a real business at its center. Open where openness creates trust; private only where privacy costs no trust.

## 6. Design decisions

Several of DAY's choices only make sense against the alternatives that were considered and rejected. Stating them makes the reasoning legible.

**Non-custodial, not a managed wallet.** The simplest way to give an agent autonomous capital is to hold the funds for it in a service-controlled wallet and let the agent instruct the service. Almost every comparable tool does this. It was rejected because it recreates exactly the fragility DAY exists to remove: the agent's money now depends on a company that can fail, freeze it, or be compelled to. It also turns the operator into a money custodian, with the trust and regulatory burden that implies. A non-custodial vault with a revocable, destination-locked capability is harder to build, but it is the only version where the agent's capital genuinely survives the operator.

**The orchestrator proposes; the contract disposes.** An alternative is to let the off-chain intelligence execute directly, holding keys or broad permissions for speed and flexibility. Rejected: it would make the safety of the whole system depend on the intelligence being correct and uncompromised, which is not a property you can guarantee about an autonomous, evolving decision-maker. Putting the enforcement on-chain and leaving the orchestrator untrusted means safety holds even when the intelligence is wrong.

**Strategy allowlists, not open-ended routing.** It is tempting to let an orchestrator move funds wherever a goal implies. Rejected because open-ended destinations are indistinguishable, at the contract level, from theft: if the system can send anywhere, "non-custodial" is a fiction. Confining every movement to owner-approved, on-chain strategies (and back to the owner) is what keeps the guarantee real, at the cost of requiring owners to define their boundaries up front.

**Multi-chain by requirement, within-chain first.** DAY is multi-chain on purpose: Yield Opportunities and capital do not live on one chain, so an open routing layer cannot either. Being tied to a single chain was rejected as too narrow. What was deferred is *cross-chain movement of a single position*: routing to the best yield anywhere, including across chains, is the more complete product, but bridging introduces custody and trust assumptions (bridge contracts, relayers, wrapped assets) that would silently reintroduce the very risk DAY removes. So DAY supports many chains from the start, routes within each chain first, and adds cross-chain movement only if it can be done without weakening the non-custodial trust base. The specific chains live in the documentation, not here, because that set is fluid; the requirement to be multi-chain is not.

**Fee on yield, never on movement.** DAY could charge for deposits, withdrawals, or for routing payments to third parties. Each was rejected: charging to fund or defund an agent taxes the wrong thing, and charging to move a payment to another party is both bad economics and the clearest form of the regulated activity DAY means to avoid. A fee only on realized yield means DAY earns when the agent's capital earns, and never for merely holding or moving money.

**Open contracts, private intelligence.** The two extremes are open-source everything (no defensible business) or a closed black box (no verifiable trust). Both were rejected in favor of the split in the previous section: open the parts that must be trusted with money, keep private only the intelligence that never touches money directly and is constrained by the open parts regardless.

## 7. Chains and strategies: an adapter model

DAY is not tied to any one chain or protocol. It is built as a **chain-agnostic routing layer** over a set of **per-strategy adapters**, and this abstraction is the durable design; the specific chains and strategies are deliberately not.

- DAY launches on chains chosen for two properties: an ownership model that supports owner-controlled vaults and clean capability scoping, and execution fast and cheap enough for frequent automated routing and harvesting. It is designed to add chains that meet those criteria over time.
- Each supported strategy is **one adapter** implementing a common interface (deposit, withdraw, harvest, price). Adding a strategy is writing an adapter, not changing the protocol. Removing one (a deprecation, a downgraded risk profile) is retiring an adapter.
- DAY opens with a small set of blue-chip strategies per chain and expands the adapter set continuously. Which strategies are live, and their status, is operational information that changes constantly.
- **Within-chain routing ships first.** Moving capital across chains introduces custody and security risk (bridging) that would compromise the non-custodial guarantee, so it is deferred and added only if it can preserve that guarantee.

Because the strategy set is always changing, the current list of supported chains, live adapters, and their status is maintained in **Appendix A**, not in the body of this document. Treat the body as the stable design and Appendix A as the current snapshot.

## 8. Fees

DAY never charges to hold capital, and never charges to deposit or withdraw principal. Principal is never touched. The fees DAY charges are:

| Fee | Value | Status |
|---|---|---|
| **Profit / performance** | 1% of profit, capped $10 per harvest | Currently **not charged** (owner-settable; may be enabled later) |
| **Routing (x402)** | $0.001 per API call | Active |
| **Swap** | 0.10% of swap notional | Active |
| **Bridge** | 0.10% of bridge notional | Active |
| **Deposit / withdraw principal** | 0 | Locked off |

The swap and bridge fees apply only when DAY swaps or bridges an asset for you as part of routing; a deposit that needs no conversion pays neither. All fees are taken on-chain and are transparent and verifiable. An owner who routes their own capital through their own orchestrator pays no DAY fee at all.

Separately, **managed strategies** carry a **Strategy Lead fee** that **varies depending on the creator** — it is set by the Strategy Lead and disclosed up front, paid to the Lead, not to DAY.

Current parameters: [Fees](https://dayprotocol.com/fees/).

## 9. What DAY is not

- **Not a custodian.** DAY never holds funds or keys. If that ever ceased to be true, the core guarantee would be broken; it is enforced on-chain precisely so it cannot quietly erode.
- **Not "access to financial markets."** Broad market access is commoditizing and will be near-universal. DAY's value is the safe, non-custodial *routing and management* of capital, which becomes more necessary, not less, as access spreads.
- **Not a yield aggregator with an AI label.** Yield is the first primitive. The product is safe, non-custodial routing under owner Guardrails.
- **Not autonomous without limits.** The agent acts freely only inside boundaries the owner sets and the contract enforces. "Autonomous" here means self-directing within a fence, not unbounded control of money.

## 10. Roadmap and honest status

DAY is early. This section states plainly what is built, what is designed, and what is aspiration, so the vision is not mistaken for the current state.

- **Shipped / core:** non-custodial vault and capability model; within-chain yield routing on the supported chains through blue-chip adapters; harvest and compound; fee-on-yield at harvest; x402 and MCP access.
- **Designed, building:** goal-driven treasury management (allocation, rebalancing across allowed strategies); a deeper Autopilot; the orchestrator interface that keeps DAY replaceable.
- **Aspiration / vision:** a broad strategy set; and, only if it can be done without compromising non-custody, cross-chain capital movement.

Where a capability is not yet live, DAY says so. The non-custodial guarantee, by contrast, is not a roadmap item: it is the foundation, enforced from the first deployment, because a yield protocol that could lose or take an owner's funds would defeat its own purpose.

## 11. Why this matters

Onchain capital should be able to work — safely, continuously, and across chains — without its owner handing control to anyone. Today that means choosing between doing it by hand and giving up custody to a service. DAY removes the choice: an open routing layer that puts capital to work while the owner keeps the funds and the keys.

That is the space DAY occupies: safe, non-custodial management of onchain capital, for anyone who holds it. A person managing a treasury, a protocol putting reserves to work, or an autonomous agent that needs to manage capital on its own behalf all use the same rails, and all keep ultimate control. Not access, which will be everywhere. Not custody, which defeats the point. The safe middle.

## 12. Conclusion

Onchain yield outran the tools for capturing it safely. The best risk-adjusted returns move between venues and across chains faster than anyone can track by hand, and the tools that automate the chase almost all take custody to do it. That gap — yield everywhere, no safe non-custodial way to route into it — is what DAY is built to close.

DAY closes it with a single, disciplined idea: capital should work for its owner, and no one should have to surrender ownership for that to happen. Autopilot supplies the intelligence, routing and harvesting toward the owner's goal. The non-custodial vault makes all of it safe: the contracts hold the funds and enforce the limits, the intelligence only ever proposes, the owner always holds the keys and can exit at any moment. Intelligence and automation, never custody.

This is deliberately not a claim to have built market access, which is becoming a commodity, nor a bid to hold anyone's money, which would defeat the purpose. It is the narrow, hard, valuable middle: safe, sovereign management of onchain capital for everyone who will increasingly need it — people, treasuries, and the autonomous agents coming after them.

The next generation of onchain activity will hold assets, make financial decisions, and participate in digital economies. It will need rails built for that from the ground up — open where trust demands it, private only where privacy costs no trust, and sovereign to the owner throughout. DAY is building them.

---

## Appendix A: Current chains, strategies, and parameters (snapshot)

*This appendix is the part of the document that changes. It is a point-in-time snapshot of what DAY supports today. Chains and strategies are added and retired continuously; treat the body of this whitepaper as the stable design and this appendix as current operational detail. Nothing here is a commitment to support any specific strategy indefinitely, and inclusion is not an endorsement of a third-party protocol's safety.*

### Chains

DAY is multi-chain by requirement, not tied to any single chain. It supports chains that meet two criteria: an ownership model that supports owner-controlled vaults with clean, revocable capability scoping, and execution fast and cheap enough for frequent automated routing and harvesting. DAY supports four chains today: **Sui, Solana, Base, and Arbitrum**. Which specific chains are live at any time changes as the protocol expands — see the [docs](https://dayprotocol.com/docs) and the open-source contracts on [GitHub](https://github.com/dayprotocol/daylight).

### Strategies

DAY opens on each chain with a small set of blue-chip liquid-staking and lending strategies and expands the set continuously. The current live strategies, per chain, and their status are operational details maintained on [dayprotocol.com/strategies](https://dayprotocol.com/strategies) and in the developer docs. Each strategy is integrated as an adapter (deposit, withdraw, harvest, price).

### Access interfaces

- **x402** for autonomous, pay-per-use access with no accounts.
- **MCP** for integration into agent frameworks and language models.

### Fee parameters (current)

- **Profit / performance fee:** 1% of profit, capped $10 per harvest. Currently not charged (owner-settable; may be enabled later).
- **Routing fee:** $0.001 per API call (x402). Active.
- **Swap fee:** 0.10% of swap notional. Active.
- **Bridge fee:** 0.10% of bridge notional. Active.
- **Deposit / withdraw principal:** 0, locked off.
- **Strategy Lead fee (managed strategies):** varies depending on the creator; set by the Strategy Lead, paid to the Lead, not DAY.
- Zero for an owner who self-provisions.

Fee levels are parameters, not protocol invariants. Live values: [Fees](https://dayprotocol.com/fees/).
