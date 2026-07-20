# DAY Hub OApp

This fresh Sui package is the LayerZero V2 transport boundary for DAY's Sui
policy plane. It depends on the official LayerZero repository pinned at
`9c741e7f9790639537b1710a203bcdfd73b0b9ac` and pins Sui mainnet EndpointV2
object `0xd45b...bf91` / EID `30378`.

It is deliberately separate from `contracts/sui`: Sui does not rerun module
initializers during a package upgrade, while LayerZero requires an OTW-derived
package CallCap. Adding this module to the existing DAY upgrade would compile
but could never create its package identity or register a channel.

Security state before governance is named:

- LayerZero CallCap and AdminCap remain sealed inside the shared `HubOApp`.
- no capability is transferred to the publisher/deployer;
- registration, executor metadata, peer configuration, and enforced options
  require the wrapper `GovernanceCap`;
- `GovernanceCap` has no `store` ability, so it cannot be publicly transferred
  after this module sends it to the selected governance recipient;
- governance bootstrap rejects the deployer/treasury EOA and the tx sender;
- registration constructs official versioned `OAppInfoV1` itself and binds it
  to the exact OApp object; callers cannot provide a pre-encoded replacement
  object identity;
- the public outbound start only borrows DAY's linear
  `AuthorizedHubCommand`; the finalizer consumes it only after the exact
  official LayerZero `Call` has completed;
- the outbound codec parses the complete `ManagedReallocateCommandV1`,
  including the exact immutable Guardrails object id, 32-byte route commitment,
  and reserved reallocation state id, and rejects legacy header-only payloads,
  unknown actions, and trailing bytes;
- raw outbound messages are package-only, not a public caller surface;
- reallocation is the only supported LayerZero message type (`1`), and a peer
  without nonempty type-1 enforced options is rejected before any intent is
  committed;
- every outbound command is recorded by a locally derived intent ID and exact
  SHA-256 command hash before the atomic LayerZero call completes, together
  with the exact destination peer configured at send time;
- inbound delivery validates the LayerZero Endpoint CallCap + configured peer,
  strict application bytes, GUID replay, exact contiguous 1-based Endpoint
  nonce per `(source EID, peer)`, source EID, send-time peer, exact
  intent/command binding, bounded outcome code, and deadline reconciliation;
- rotating a peer starts that peer's independent nonce sequence; rotating back
  resumes the original peer's sequence, and a replacement peer can never
  attest an intent committed for its predecessor;
- outcome messages carry no caller-selected EID, payout destination, asset,
  amount, delta, or transaction metadata;
- authenticated outcomes are exactly `EXECUTED` or `FAILED`; `ORDERED` remains
  a local DAY policy event emitted before this OApp consumes the command;
- after a committed expiry, anyone may mark the exact stored intent `FAILED`;
  destination, command hash, expiry, and outcome are derived from OApp state,
  never supplied by the caller. This timeout is provisional: a later exact
  authenticated peer result consumes its ordered nonce and records the real
  `EXECUTED` or `FAILED` status, preventing duplicate execution and channel
  deadlock;
- Exit Mode remains local and cannot be transported;
- Base, Arbitrum, and Solana EIDs are recognized. Every route still fails closed
  until governance pins an exact nonzero 32-byte package/contract/program peer
  and mandatory execution options for that EID;
- expired intents cannot be pruned until both the authenticated return nonce
  has been consumed and 30 days have passed since committed expiry; immutable
  command/outcome events remain in history;
- LayerZero carries authorization only. Mayan remains the asset rail.

This package must not be published until the final combined review and the
single coordinated contract transaction. Governance bootstrap remains a
separate held action until a non-deployer governance recipient is named.

Move cannot distinguish a multisig address from a single-key address. The
deployment procedure, not this module, must verify that the selected recipient
is the confirmed governance multisig before calling `bootstrap_governance`.

## DAY dependency boundary

The package intentionally imports a two-step DAY transport API. The OApp send
takes ownership of the no-abilities authorization, borrows its committed
transport fields, and returns a no-abilities `PendingAuthorizedHubSend` that
contains both the original authorization and the exact official LayerZero
`Call`. The finalizer accepts only that joined proof and consumes the token
after DAY checks the canonical OApp CallCap, destination, receipt, and exact
message:

```move
public fun day::hub_protocol::authorized_transport_message(
    command: &AuthorizedHubCommand,
): (u32, vector<u8>)

public fun day::hub_protocol::consume_after_completed_layerzero_call(
    command: AuthorizedHubCommand,
    call: &Call<SendParam, MessagingReceipt>,
)
```

`AuthorizedHubCommand` and `PendingAuthorizedHubSend` have no abilities. The
OApp does not accept a caller-supplied intent, endpoint, command hash, or raw
payload, and the caller cannot split the command back out from the official
call after send begins. The same PTB must execute the Endpoint call and consume
the joined proof; returning or dropping raw bytes cannot commit a DAY sequence.
When the existing DAY package is upgraded, this fresh package must be compiled
after finality so its local DAY dependency resolves to the upgraded
`published-at` package ID.

The immutable DAY-to-OApp binding must be performed through
`bind_canonical_day_hub_transport`. That typed wrapper derives the CallCap ID
from the OTW-created, Endpoint-registered `HubOApp`; the deployment PTB never
accepts or types a raw address. It also requires the exact OApp
`GovernanceCap`, proving the same transaction controls both governance planes.
DAY still verifies the canonical HubState, StrategyRegistry, AdminCap, and
governance sender before recording the binding.

The fresh OApp package ID does not exist when the router upgrade is compiled,
so this is necessarily one explicit external-package choice by DAY Admin
governance. The underlying DAY boundary accepts only an official package
`CallCap` (never an individual cap or address) and rejects every rebind. The
typed wrapper above is the required production path because it additionally
proves the registered OApp object and its co-held OApp GovernanceCap.

## Verification

```bash
sui move test --path contracts/sui-day-oapp --warnings-are-errors
```

The suite uses official LayerZero `EndpointV2`, `OApp`, `Call`, and
`LzReceiveParam` test surfaces to prove registration, exact peer validation,
EID binding, mandatory type-1 execution options, value rejection, peer-scoped
application nonce ordering across rotations, replay protection, expiry, and
exact send-time peer/intent/command outcome reconciliation.
