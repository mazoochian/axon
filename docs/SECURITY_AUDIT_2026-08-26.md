# Axon Security Audit — 2026-08-26

Authorized pre-launch security review of Axon (Elixir/Phoenix Matrix homeserver).
Scope: static code review of the `master` worktree at `/home/armin/claude/axon-master-worktree`
plus light authenticated/unauthenticated probing of the live dev instance
(client API `http://localhost:8008`, federation `http://localhost:8448`).

**Reviewer note on live testing:** The live dev instance was reachable at the
start of the audit and the two highest-impact findings (C1 admin-mint, H1 SSRF)
were confirmed live against it. Partway through, the instance went down
(the whole environment appears to have restarted; no listener remained on
8008/8448, no `beam.smp` running). I deliberately did **not** restart it —
sibling worktrees/agents share this repo and a restart could disrupt them —
so findings discovered after that point are marked **code-review-only** with
the reason stated. Nothing destructive was run; no DoS, no mass account
creation, no data exfiltration.

File:line references are into `/home/armin/claude/axon-master-worktree`.

---

## Severity summary

| Sev | # | Findings |
|-----|---|----------|
| Critical | 1 | C1 hardcoded shared-secret admin registration |
| High | 3 | H1 unauthenticated media SSRF · H2 federation event forgery via `origin` override · H3 predictable `secret_key_base` fallback in prod |
| Medium | 2 | M1 inbound PDU content-hash never verified · M2 cross-user presence leak |
| Low | 4 | L1 rate-limiting gaps · L2 access tokens accepted in query string · L3 media_id injected into outbound federation URL · L4 OIDC `username` claim trusted unsanitized |
| Informational | 4 | I1 no `filter_parameters` · I2 ephemeral signing key by default · I3 `.env.example` ships blank secrets · I4 signing-key file write TOCTOU |

Injection surface (raw SQL / Ecto `fragment` / full-text search / atom/eval) was
reviewed and found **clean** — see "Injection review" at the end.

---

## Critical

### C1 — Hardcoded shared-secret admin registration (confirmed, already known)
**What:** `/_synapse/admin/v1/register` (Synapse-compatible shared-secret admin
bootstrap) authenticates the request with an HMAC-SHA1 MAC keyed by a **literal
compiled-in secret**, `@synapse_shared_secret "complement"`, with no
environment-variable override anywhere in the repo.

**Where:**
- `apps/axon_web/lib/axon_web/controllers/auth_controller.ex:236` — `@synapse_shared_secret "complement"`
- `apps/axon_web/lib/axon_web/controllers/auth_controller.ex:491-495` — `compute_synapse_mac/4` uses it as the HMAC key
- Router `apps/axon_web/lib/axon_web/router.ex:158-163` — the endpoint is unauthenticated (MAC *is* the auth) and **not** rate limited
- Repo-wide grep confirms only these two references and no `System.get_env` override.

**How verified:** **LIVE.** Fetched a nonce from `GET /_synapse/admin/v1/register`,
computed `HMAC-SHA1("complement", nonce\0user\0pass\0"admin")`, POSTed to
`/_synapse/admin/v1/register` with `"admin": true`, and received a working
access token for a brand-new `@audittest_*:localhost` account. Using that
token against `GET /_synapse/admin/v1/users` returned the full user list
(all 36 users) — i.e. the minted account has **real admin authority**, not just
a flag.

**Impact:** Anyone who has read the (public) source — the secret is a constant in
the repo — can mint a full-admin account on **any** Axon deployment, with no
prior credentials. Complete server takeover: list/deactivate/shadow-ban users,
purge rooms, quarantine media, send server notices, reach LiveDashboard.

**Fix direction:** Require a per-deployment secret from the environment
(e.g. `REGISTRATION_SHARED_SECRET`); if unset, **disable** the endpoint entirely
rather than falling back to any default. Never ship a usable literal. Add
rate limiting to the nonce + register endpoints regardless.

---

## High

### H1 — Unauthenticated SSRF via media download/thumbnail proxying
**What:** The remote-media download and thumbnail endpoints take the
`:server_name` segment straight from the URL and use it as the host Axon
connects to when proxying media from "another homeserver." An attacker picks
the host:port. The legacy download path requires no authentication at all.

**Where:**
- `apps/axon_web/lib/axon_web/controllers/media_controller.ex:159-166` (`download/2` → `proxy_remote/4` when `origin_server != local_server`)
- `apps/axon_web/lib/axon_web/controllers/media_controller.ex:287-311` (`proxy_remote`) and `:314-337` (`proxy_remote_thumbnail`)
- `apps/axon_federation/lib/axon_federation/media_fetch.ex:42-63` builds the outbound request to `server_name`
- Router: legacy `GET /_matrix/media/v3/download/:server_name/:media_id` is under `pipe_through(:api)` (unauthenticated) — `apps/axon_web/lib/axon_web/router.ex:214-226`

**How verified:** **LIVE.** Started a TCP listener on `127.0.0.1:9098`, then
requested `GET /_matrix/media/v3/download/127.0.0.1:9098/AAA...` **with no auth
header**. The listener captured an inbound connection from the Axon process
carrying a TLS ClientHello with SNI `127.0.0.1` — proving Axon initiates an
outbound connection to an arbitrary attacker-chosen host:port pre-auth. The
authenticated MSC3916 path (`/_matrix/client/v1/media/download/...`) behaves
identically (also confirmed live against a listener on `127.0.0.1:9099`).

**Impact:** Server-side request forgery reachable **without authentication**.
An external attacker can make the homeserver connect to arbitrary internal
addresses (cloud metadata `169.254.169.254`, internal admin panels, Postgres,
other localhost services), map the internal network via timing/error
differences, and reach services that trust the homeserver's source IP. This is
distinct from — and worse than — the already-known url-preview SSRF because it
needs no auth and no user interaction.

**Fix direction:** Resolve `server_name` through the normal Matrix server
resolution and enforce an allow/deny policy that rejects RFC1918 / loopback /
link-local / ULA addresses (resolve first, then validate the *resolved* IP to
avoid DNS-rebinding), consistent with whatever the url-preview fix does. Also
consider requiring auth on the legacy media download path.

### H2 — Federation event forgery via attacker-controlled `origin` field (code-review-only)
**What:** Inbound PDU signature verification selects *which server's key to
verify against* from the wire event's own `origin` field, falling back to the
sender's domain only if `origin` is absent. Because any federation server's
signing key is public and fetchable, an attacker who runs a homeserver can forge
an event whose `sender` is a **victim on another server** while signing it with
the attacker's own key and setting `origin` to the attacker's server.

**Where:**
- `apps/axon_federation/lib/axon_federation/event_verification.ex:16-17`
  ```elixir
  sender_server = event["sender"] |> to_string() |> AxonCore.MatrixId.server_name()
  origin = event["origin"] || sender_server           # <-- trusts wire "origin"
  key_id = get_in(event, ["signatures", origin]) |> maybe_first_key()
  ```
  then `EventHash.verify_signature(event, origin, key_id, KeyCache.get_key(origin, key_id), rv)`
- `apps/axon_crypto/lib/axon_crypto/event_hash.ex:94-109` — verifies the signature under `signatures[origin][key_id]`; it does not bind `origin` to `sender`'s domain.
- Reached from `process_inbound_pdu/2` (`apps/axon_web/lib/axon_web/controllers/federation_controller.ex:1337-1357`) — the only signature check before an event is applied.

**Attack:** Craft event `E` with `sender=@victim:good.com`, `origin=evil.com`,
`signatures={"evil.com":{...}}` where the signature is a valid ed25519 signature
by evil.com over `redact(E)` (which the attacker controls and can compute).
Verification picks `origin=evil.com`, fetches evil.com's public key, and the
signature checks out — the event is accepted as authentic though good.com never
signed it. In `redaction.ex`, `origin` is a preserved top-level key for room
versions 1-10 and dropped for v11+; the forgery works either way because the
attacker signs consistently and the *key-selection* uses the unredacted,
attacker-supplied field.

**How verified:** Code review only. Not exercised live: the instance was down,
and staging it requires standing up a second signing identity plus a shared
room with a joined victim — out of proportion for this pass and adjacent to the
"don't be destructive" guidance. The reasoning is concrete and the code path is
unambiguous.

**Impact:** Cross-server impersonation. In any room the attacker's server shares
with a victim, the attacker can inject `m.room.message` events attributed to the
victim (chat forgery), and potentially state events attributed to powerful
members (subject to the room's auth rules, which check membership/power but do
**not** re-check the signing domain). Breaks the core federation authenticity
guarantee.

**Fix direction:** Verify the event signature against the **sender's domain**
(`server_name(event["sender"])`), never a wire-supplied `origin`; for
membership/join/leave events additionally require the signature from the
`state_key`/acting server per spec. Do not let `event["origin"]` steer key
selection.

### H3 — Predictable `secret_key_base` fallback in production config
**What:** In prod, if `SECRET_KEY_BASE` is unset the endpoint silently falls back
to a hardcoded, guessable value (`"a"` × 64). `.env.example` ships with
`SECRET_KEY_BASE=` **blank**, so a deployer who follows the example gets the
predictable key.

**Where:**
- `config/prod.exs:12` — `secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("a", 64)`
- `.env.example` — `SECRET_KEY_BASE=` (empty) and `DB_PASS=changeme`; `config/prod.exs:5` also defaults `DB_PASS` to `"axon"`.

**How verified:** Code review (config). Not runtime-tested — the dev instance
uses `config/dev.exs`, and I did not want to assert the running process's env.

**Impact:** `secret_key_base` keys Phoenix's `Plug.Crypto` — signed/encrypted
cookies, CSRF tokens, and any `Phoenix.Token`. A known value lets an attacker
forge/decrypt anything derived from it. A blank-by-default example plus a
silent fallback (rather than a hard failure) makes an insecure production
deployment the default outcome.

**Fix direction:** In prod, require `SECRET_KEY_BASE` (and a real `DB_PASS`) and
**crash on boot** if unset — never fall back to a literal. Remove the
`String.duplicate("a", 64)` default.

---

## Medium

### M1 — Inbound PDU content hash is never verified
**What:** Inbound events are signature-checked but their `hashes.sha256`
content hash is not validated. The event signature is computed over the
**redacted** event, so for event types where redaction strips `content`
(e.g. `m.room.message`, whose body is not preserved under redaction) the
signature does not protect the body. The content hash is what does — and it is
only ever *produced* on outbound events, never *checked* on inbound ones.

**Where:**
- `apps/axon_federation/lib/axon_federation/event_verification.ex` — only calls `EventHash.verify_signature`, no `content_hash` check.
- `EventHash.content_hash/1` (`apps/axon_crypto/lib/axon_crypto/event_hash.ex:28`) is used only in the outbound `room_join.ex:74`, `room_leave.ex:69`, `room_knock.ex:71` paths.

**How verified:** Code review only (server down; also requires a full signed
federation transaction to demonstrate).

**Impact:** A malicious relaying/forwarding server can alter the non-redacted
`content` of an event it passes on (e.g. rewrite a message body) while the
original author's signature still verifies, because the signature only covers
the redacted form. Message-integrity break.

**Fix direction:** On inbound, recompute `content_hash` over the full event and
compare to `hashes.sha256`; on mismatch, redact the event (drop to the
signed/redacted form) rather than trusting the sender's `content`, per the
spec's "check content hash → redact on failure" rule.

### M2 — Cross-user presence leak (confirmed)
**What:** `GET /_matrix/client/v3/presence/:user_id/status` returns any user's
presence with **no authorization check** — it does not verify the requester
shares a room with the target (Matrix's normal presence visibility rule).

**Where:** `apps/axon_web/lib/axon_web/controllers/presence_controller.ex:9-11`
```elixir
def get_status(conn, %{"user_id" => user_id}) do
  json(conn, Presence.get(user_id))   # no relationship check on caller
end
```
(Contrast `put_status/2` at :17-24, which *does* check `user_id != current_user_id`.)

**How verified:** **LIVE.** Registered two unrelated accounts (sharing no room);
the attacker account read the victim's presence via
`GET /presence/@victim...:localhost/status` and received
`{"presence":"online","currently_active":true,"last_active_ago":11575}` (HTTP 200).

**Impact:** Any authenticated user can harvest online/offline status,
last-active timestamps, and status messages of **any** user on the server
without sharing a room — an activity-tracking / privacy leak across the whole
user base.

**Fix direction:** Gate `get_status` on a shared-room check between caller and
target (mirror Synapse's presence visibility), returning 403/empty otherwise.

**Note — the other cross-user reads tested clean:** account-data read *and*
write via a forged `:user_id` in the path both returned **403** (proper IDOR
protection — `apps/axon_web` account-data controller); `GET /profile/:user_id`
returns only displayname (public, expected); `POST /keys/query` for another user
returned empty. So the historical user-directory-search class of bug does not
appear to recur in account-data — presence is the one that leaks.

---

## Low

### L1 — Rate-limiting coverage gaps
**What / Where:** The `RateLimit` plug
(`apps/axon_web/lib/axon_web/plug/rate_limit.ex`) is mounted per-action on
`login`, `register`, `sync`, `media_upload`, `send_event`, `search`. It is
**not** applied to:
- `/_synapse/admin/v1/register` (C1's admin bootstrap) and its nonce endpoint
- `POST /account/password` and `/account/deactivate` (the UIA password-verify path — `Argon2.verify_pass` with no throttle)
- `POST /refresh`

Additional notes:
- `login` is keyed **per-IP only** (`key_by: :ip`), not per-username — no
  per-account lockout, so distributed/rotating-IP credential stuffing against a
  single account is unthrottled (`config/config.exs:104`: 10/60s).
- Good: `conn.remote_ip` is the real TCP peer — there is **no** `RemoteIp`/XFF
  plug in the pipeline, so `X-Forwarded-For` spoofing does **not** bypass the
  per-IP limit (verified by grep — no XFF handling anywhere).
- **Deployment risk:** `config/runtime.exs:98-107` sets every limit to
  1,000,000 when `RELAXED_RATE_LIMITS=true`. The dev instance appears to run
  with this (rapid probing never tripped a 429). If that env var leaks into the
  alpha, rate limiting is effectively off.

**How verified:** Code review of plug mount points + config; live behavior
consistent with relaxed limits on the dev box.

**Fix direction:** Add IP-based limits to the admin register/nonce, password,
deactivate, and refresh endpoints; add a per-username limiter to login; ensure
`RELAXED_RATE_LIMITS` is never set in the alpha deployment.

### L2 — Access tokens accepted in the query string
**What:** `AuthenticateToken` falls back to `?access_token=` for every
authenticated endpoint, and LiveDashboard is documented to be reached that way.
**Where:** `apps/axon_web/lib/axon_web/plug/authenticate_token.ex:88-91`;
LiveDashboard note at `apps/axon_web/lib/axon_web/router.ex:186-203`.
**Impact:** Bearer tokens land in access logs, proxy logs, browser history, and
`Referer` headers. Token disclosure via log exposure.
**How verified:** Code review (this is spec-permitted legacy behavior, but a
hardening gap). **Fix direction:** Prefer the `Authorization` header; if the
query-param fallback must stay, ensure request logging redacts `access_token`.

### L3 — `media_id` interpolated into the outbound federation URL
**What:** `media_id` from the request URL is string-interpolated into the
outbound federation request path when proxying remote media.
**Where:** `apps/axon_federation/lib/axon_federation/media_fetch.ex:45,49,60,63`
(e.g. `"/_matrix/federation/v1/media/download/#{media_id}"`).
**Impact:** A crafted `media_id` containing `../`, `?`, or `#` can manipulate the
path/query of the request Axon makes to the *remote* server (request-path
injection against a third party; combines with H1's host control). Local FS
traversal is **not** reachable this way — local media is served by DB lookup of
a random id (see below), not by building a path from `media_id`.
**How verified:** Code review; live path-traversal probes against the local
media endpoint could not be completed (server went down mid-test).
**Fix direction:** Validate `media_id` against the Matrix media-id charset
(`[A-Za-z0-9_-]+`) at the controller boundary and URL-encode it before
interpolation.

### L4 — OIDC `username` claim trusted as localpart without sanitization
**What:** When delegated OIDC (MSC3861) is enabled, the local Matrix localpart is
taken from `claims["username"]` **verbatim** (only the `sub` fallback is
sanitized).
**Where:** `apps/axon_web/lib/axon_web/oidc.ex:166-168`.
**Impact:** A misbehaving/misconfigured Authorization Server (or one that lets a
user influence their `username` claim) could set an unexpected localpart. Low
because OIDC is disabled in this config and the AS is a trusted component.
**Fix direction:** Run `username` through the same localpart validation/charset
enforcement as registration before using it.

---

## Informational

- **I1 — No `filter_parameters` configured.** No `config :phoenix,
  :filter_parameters` anywhere (grep: none). If Phoenix request-param logging is
  enabled, `password`/`access_token` params would be logged in cleartext.
  Set an explicit filter list.
- **I2 — Ephemeral signing key by default.** `AxonCrypto.KeyServer`
  (`apps/axon_crypto/lib/axon_crypto/key_server.ex:167-170`) generates a fresh
  in-memory ed25519 keypair on every boot when `SIGNING_KEY_PATH` is unset
  (`.env.example` confirms). For a persistent alpha this breaks federation on
  each restart and invalidates cached `/_matrix/key/v2/server` responses.
  Set `SIGNING_KEY_PATH` to a persisted, backed-up file.
- **I3 — `.env.example` ships blank/placeholder secrets.** `SECRET_KEY_BASE=`
  (blank) and `DB_PASS=changeme` — combined with the silent prod fallbacks
  (H3), following the example yields an insecure deploy.
- **I4 — Signing-key file write TOCTOU.** `persist_keypair!`
  (`key_server.ex:203-206`) does `File.write!` then `File.chmod!(0o600)` — a
  brief window where the private-key file exists at the default umask. Write to
  a temp file with `0o600` then rename, or set mode at creation.

---

## Injection review (clean)

- All Ecto `fragment(...)` uses (in `event_store.ex`, `sync_controller.ex`,
  `event_controller.ex`, `federation_controller.ex:1618`) put user data only in
  `?`/`^var` parameter positions; the SQL-string portions are constant. No
  string-interpolated Ecto.
- Full-text search raw SQL (`apps/axon_core/lib/axon_core/event_store.ex:926-946`)
  uses `Ecto.Adapters.SQL.query!` with `$1/$2` **parameters** and the safe
  `plainto_tsquery` (won't throw or inject on special chars).
- Other raw SQL (`key_controller.ex:526`, `health_controller.ex:21`) is constant.
- No `String.to_atom`/`to_existing_atom`, `Code.eval*`, or
  `:erlang.binary_to_term` on user input (grep: none).
- Local media path handling is safe from traversal: stored files are named by a
  random `strong_rand_bytes` id and read via DB lookup
  (`apps/axon_media/lib/axon_media/store.ex:28,57-60`), not by building a path
  from the URL-supplied `media_id`; remote media is streamed, not disk-cached,
  so no cache-path traversal. (Thumbnail `cache_path` at
  `thumbnailer.ex:87-89` uses only DB-validated local ids.)

Thumbnail command-injection / decompression-bomb limits were not fully traced
in this pass (the media subagent's deeper dive was interrupted by the
environment restart) — recommend a follow-up specifically on
`apps/axon_media/lib/axon_media/thumbnailer.ex` to confirm (a) no shell string
interpolation if it shells out, and (b) an input-pixel/size guard before decode.

---

## What was NOT covered / recommended follow-up
- Live confirmation of H2 (event forgery), M1 (content-hash), and media
  path/command-injection — blocked by the instance being down mid-audit;
  re-run once it's back up.
- Thumbnailer resource limits (thumbnail-bomb DoS) — needs a focused pass on
  `thumbnailer.ex` decode limits.
- Deeper OIDC/OAuth2 resource-server edge cases (token audience/`aud` binding,
  introspection response spoofing) beyond the localpart-trust note in L4.
