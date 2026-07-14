# Roadmap

Axon's development has proceeded in informal, numbered phases (see git history and inline comments for Phases 1–7: CS API core, federation foundation + state-res v2, E2EE sync, media/push/app-services, spaces/relations/room upgrades, delegated OIDC login, MSC3814 dehydrated devices). This document tracks what's planned from Phase 8 onward.

## Phase 8 — E2EE reliability & cross-server delivery (done)

Despite a substantial existing E2EE surface (key upload/query/claim, cross-signing, key backup, dehydrated devices), three relay-layer bugs made device verification and message delivery unreliable across clients and homeservers:

- `sendToDevice` never woke a long-polling `/sync` — a queued Megolm room-key share or SAS verification message sat undelivered until the recipient's client-chosen timeout happened to elapse on its own, not until the sender actually sent it. Every existing sync test used `timeout=0`, so this was invisible to the suite.
- `device_lists.changed` only fired on key upload/cross-signing, never on newly sharing a room — a client trusting that signal (rather than deriving key-query needs from room membership itself) would never learn to query/verify a fresh room-mate's devices. `device_lists.left` was hardcoded to `[]`.
- `sendToDevice` had no local/remote split, unlike `/keys/query` and `/keys/claim` — any to-device message aimed at a user on another homeserver was silently dropped forever, since there was no federation EDU handling at all (inbound or outbound).

Fixed by: broadcasting a PubSub wake on to-device delivery (mirroring the existing `device_list_updates` pattern); re-touching `device_list_updates` for both parties on room join and a new `device_list_partings` table + cursor for room leave; and adding `m.direct_to_device` EDU support (outbound via `AxonWeb.FederationFanout`, inbound via `FederationController.send_transaction/2`), plus wildcard (`"*"`) device-id expansion. Regression coverage in `apps/axon_web/test/e2ee_delivery_test.exs` exercises the real long-poll path with a nonzero timeout (closing the test-coverage gap that hid bug 1) and the cross-server EDU path via `AxonFederation.FakeRemoteMatrixServer`.

## Phase 9 — Federation EDU & real-time parity (done)

Full bidirectional EDU support (`m.typing`, `m.receipt`, `m.presence`), building on the `m.direct_to_device` scaffolding from Phase 8, plus durable outbound federation delivery.

- **Typing indicators** (`PUT /rooms/:room_id/typing/:user_id`) were a complete no-op stub — acknowledged and discarded. Now backed by `AxonSync.Typing` (in-memory, auto-expiring, mirroring `AxonSync.Presence`'s design), surfaced in `/sync`'s per-room `ephemeral` section, and federated as `m.typing` EDUs both ways.
- **Read receipts** had no PubSub wake at all (unlike to-device/device-lists/account-data, fixed in Phase 8) — a receipt posted to an otherwise-quiet room sat unseen until something else happened in that room, since incremental sync only included a room at all when it had a *new timeline event*. Fixed with a new `ephemeral_updates` log (mirroring `device_list_updates`) that both wakes long-pollers and makes a room eligible for inclusion on ephemeral-only changes; `m.read` receipts (never `m.read.private`) now federate as `m.receipt` EDUs.
- **Presence** now federates as `m.presence` EDUs to every server sharing a room with the user, but only on an actual state transition (online/unavailable/offline or status_msg change) — not on every `bump_activity` touch, which happens on every authenticated request and would otherwise flood federation peers.
- **Durable outbound delivery**: `AxonFederation.OutboundQueue` persists every outbound PDU/EDU transaction before the first attempt and retries with exponential backoff (30s → 1hr cap, giving up after 7 days) on failure, reusing the same row id as the txn_id on every retry so a remote server that already processed an earlier attempt responds idempotently. Replaces the previous fire-and-forget behavior in `AxonWeb.FederationFanout`, where a failed delivery just logged a warning and was dropped — meaning a remote server being briefly unreachable silently lost whatever was sent to it during that window. Matters here specifically because this deployment federates with other servers in production use, not just same-server accounts.

Regression coverage: `apps/axon_federation/test/outbound_queue_test.exs` (failure → persisted → retry → success), `apps/axon_web/test/phase9_ephemeral_test.exs` (typing/receipt local wake-up and room-inclusion, both EDU directions for typing/receipts/presence, permission checks, expiry).

## Phase 10 — Sliding Sync (MSC3575/MSC4186)

A new sync endpoint alongside classic `/sync` (kept for legacy clients): list-based room sorting/filtering, extensions (`e2ee`, `to_device`, `account_data`, `receipts`, `typing`), and room subscriptions. Reuses the `Phoenix.PubSub`/`AxonSync.Manager` wake-up mechanism hardened in Phase 8. Needed for modern clients (Element X and others) that prefer or require sliding sync, and to reduce sync latency generally.

## Phase 11 — E2EE/verification test hardening

Expand integration coverage for multi-client and multi-homeserver verification flows using realistic long-poll timeouts (the exact gap that hid the Phase 8 bugs), wildcard-device sends, and key-backup consistency. Complement-style scenario coverage for cross-signing and device verification specifically, since that surface has seen the most iterative bugfixing (MSC3967 UIA exemptions, orphaned-key cleanup) and the most room for subtle regressions.

## Phase 12 — Room version / state-res compliance

Close the known room version 12 gap (MSC4297 auth-difference changes — currently falls back to the v6–v11 state-res algorithm). Third-party invites. Guest access.

## Phase 13 — Operability: admin API & rate limiting

A real admin API beyond the current Synapse-compatible shared-secret registration bootstrap: user management (deactivate, list, shadow-ban), room management (list, delete, purge), media quarantine, and a report-review queue (reports are already collected via `POST /rooms/:room_id/report`, but nothing surfaces them). Rate limiting on login, registration, and message-send — notably more important now that this server federates publicly.

## Phase 14 — Feature completion pass

Persist custom push rules (`PUT`/`DELETE` on `/pushrules/...` currently discard silently — only the server default rule set is actually served). Server notices. SSRF-safe URL previews (currently deliberately 404s — see README "Known gaps").
