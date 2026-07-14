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

## Phase 10 — Sliding Sync (MSC4186) (done)

`POST /_matrix/client/unstable/org.matrix.msc4186/sync` alongside classic `/sync` (kept for legacy clients). A pragmatic subset of the MSC rather than full conformance:

- **Lists**: `ranges`-paginated, recency-sorted (`sort` is always treated as `by_recency`) room lists over the user's *joined* rooms, with `is_dm`/`is_encrypted` filters. Every response re-sends a full `SYNC` op per range rather than diffing against a remembered window — no `conn_id` session state is kept, so this is spec-valid but less bandwidth-efficient than real add/remove diffing.
- **`room_subscriptions`**: explicit per-room overrides, included regardless of list ranges; merged with any list config referencing the same room (union of `required_state`, max `timeline_limit`).
- **`required_state` resolution**: concrete `[type, state_key]` pairs, `*` wildcards, `$ME` (substitutes the requesting user), and `$LAZY` (member events lazy-loaded to just the current timeline's senders, plus self) — reusing `EventStore.get_current_state/1`.
- **Extensions**: `to_device`, `e2ee` (OTK/fallback-key counts, `device_lists`), `account_data` (global + per visible room), `receipts` (`m.read` only), `typing` — all built from the same `AxonWeb.SyncHelpers` module classic `/sync` now delegates to as well, so the two endpoints can't drift apart on E2EE/device-list/ephemeral semantics (the extraction this required also served as a small refactor: those cursor/extension helpers used to be private duplicates baked into `SyncController`). Extension params aren't sticky across requests — a client must resend `"enabled": true` every time, not just once.
- **Known gaps, deliberately deferred**: invited/knocked/left rooms don't appear in `lists`/`room_subscriptions` yet (exposing them safely means re-deriving the same invite-state-only visibility rules classic sync's `build_invite_state/2` already enforces — deferred rather than done half-safely); `notification_count`/`highlight_count` are always 0 (this codebase doesn't compute per-room unread/highlight counts anywhere yet, including in classic `/sync` or push dispatch, so this isn't a regression).

Long-poll wake-up reuses `AxonSync.Manager.wait_for_events/3` unchanged, so the Phase 8 wake-up fixes (to-device, device-list, ephemeral) apply here too. Regression coverage: `apps/axon_web/test/sliding_sync_test.exs` (13 tests: list sort/ranges/filters, `room_subscriptions`, `required_state` incl. `$LAZY`/`$ME`, the long-poll wake path with a real nonzero timeout, and every extension).

## Phase 11 — E2EE/verification test hardening (done)

Two real bugs found and fixed while expanding coverage of the surface that's seen the most iterative bugfixing:

- **Stale test, not a stale bug**: `e2ee_multi_device_test.exs` asserted a first-time cross-signing `master_key` upload returns 401 requiring a UIA retry. MSC3967's `uia_exempt?/4` (`key_controller.ex`) correctly exempts first-time setup (nothing on file yet to protect) and has for a while — the test just never caught up. Fixed the assertion and added a real UIA-required case alongside it (rotating to an unrelated master key that isn't signed by the one on file), so the branch that *does* still require UIA has coverage too.
- **Key backup consistency**: `PUT /room_keys/keys` never validated its `version` query param against the user's actual current backup version — a client retrying against a stale, deleted, or superseded version would silently insert rows with no error, and `count`/`etag` on `GET /room_keys/version` would never reflect the write. Now returns `403 M_WRONG_ROOM_KEYS_VERSION` (with `current_version` in the body) per spec, covered by `apps/axon_web/test/key_backup_consistency_test.exs`.

New Complement-style scenario coverage in `apps/axon_web/test/e2e/verification_flow_test.exs`:

- A full `m.key.verification.*` SAS exchange (request → ready → start → key ×2 → mac ×2 → done) between two users' devices, with every hop driven through a real nonzero-timeout long-poll on both sides — not a single event checked with a short poll, which is all any prior test did.
- The same shape across two homeservers via `AxonFederation.FakeRemoteMatrixServer`, with a realistic nonzero timeout on the inbound EDU recipient's long-poll — the existing federation EDU test only short-polled after the fact, so it couldn't catch a wake-up regression on the federated path the way it already could locally.
- The wildcard `"*"` to-device target (`KeyStore.expand_wildcard_device/2`, added in Phase 8) had zero test coverage until now — verified against a 3-device account, confirming delivery to all three and non-delivery to an unrelated user.
- A cross-signing trust-chain scenario: bob signs alice's master key after "verifying" her; `/keys/query` shows bob his own signature but not an uninvolved third party, exercising the visibility rule end-to-end over HTTP rather than just at the `KeyStore` unit level.

## Phase 12 — Room version / state-res compliance

Close the known room version 12 gap (MSC4297 auth-difference changes — currently falls back to the v6–v11 state-res algorithm). Third-party invites. Guest access.

## Phase 13 — Operability: admin API & rate limiting

A real admin API beyond the current Synapse-compatible shared-secret registration bootstrap: user management (deactivate, list, shadow-ban), room management (list, delete, purge), media quarantine, and a report-review queue (reports are already collected via `POST /rooms/:room_id/report`, but nothing surfaces them). Rate limiting on login, registration, and message-send — notably more important now that this server federates publicly.

## Phase 14 — Feature completion pass

Persist custom push rules (`PUT`/`DELETE` on `/pushrules/...` currently discard silently — only the server default rule set is actually served). Server notices. SSRF-safe URL previews (currently deliberately 404s — see README "Known gaps").
