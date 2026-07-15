# Axon

A Matrix homeserver written in Elixir/Erlang, targeting spec [v1.18](https://spec.matrix.org/v1.18/).

> Disclaimer: This is an educational project for me. I am using this project as a chance to: 
> - Learn the Matrix protocol 
> - Learn to work with AI optimally for my normal worflows
> - Learn Erlang/Elixir. 
>
> This is in no way a production-ready server. USE AT YOUR OWN RISK.

Named after the neurological structure, Axon is designed to fix the fundamental runtime limitations of [Synapse](https://github.com/element-hq/synapse) (Python GIL, OS-level worker processes, Redis dependency) by using the BEAM runtime, where each Matrix room maps naturally to a GenServer process that owns its state in memory, serializes event application, and can be restarted from persistent storage on crash.

### Known gaps

- Presence is in-memory only (ETS) and does not persist across a restart — by design (presence is ephemeral), but worth knowing if you're expecting it to survive a deploy.
- URL preview SSRF protection blocks literal/resolved private IP ranges but doesn't pin the HTTP connection to the address it validated, so it isn't immune to DNS rebinding — see `AxonMedia.UrlPreview`'s moduledoc.

See [ROADMAP.md](ROADMAP.md) for the phase history (Phase 8 through 14 — the full roadmap as originally scoped is now complete).

## Why BEAM?

Synapse's worker model solves concurrency by spawning separate OS processes — each carrying a full Python interpreter (~200–500 MB). A moderately busy Synapse deployment with workers can consume 2–10 GB RAM.

The BEAM runtime inverts all of these problems:

- **Lightweight processes**: ~2 KB base overhead each vs. ~200 MB for a Python worker
- **Per-process GC**: no global GC pauses that block all rooms simultaneously
- **Built-in distribution**: Horde + libcluster give transparent multi-node clustering without Redis
- **Natural mapping**: one `RoomProcess` GenServer per active room, one `Sender` GenServer per remote federation server

## Architecture

```
axon/                              # Mix umbrella
├── apps/
│   ├── axon_crypto/               # Ed25519, SHA256, canonical JSON, event hashing/signing
│   ├── axon_core/                 # Ecto repo, migrations, event store, schemas
│   ├── axon_room/                 # Per-room GenServers, auth rules, state resolution v2
│   ├── axon_federation/           # Key cache, HTTP client, room join flow
│   ├── axon_sync/                 # Long-poll sync manager, PubSub fanout
│   ├── axon_web/                  # Phoenix router, CS API + federation controllers
│   ├── axon_media/                # (Phase 4) Media upload/download
│   └── axon_push/                 # (Phase 4) Push rule evaluation, delivery
```

### Dependency graph

```
axon_crypto  (no deps on other apps)
      │
axon_core    (crypto)
      │
  ┌───┴──────────────────┐
axon_room  axon_federation  axon_sync
  └──────────────────────┴──────────┘
                │
          axon_web          (depends on all above)
```

### Key design decisions

**Event store is append-only**: `events` rows are never updated or deleted. `current_room_state` is a materialized view. `room_state_snapshots` are taken every 100 events to bound replay time on process restart.

**State resolution v2**: Implemented as a pure Elixir function in `AxonRoom.StateResV2`. Inputs are a list of state sets and a `get_event_fn`. The algorithm computes auth difference, sorts the full conflicted set by reverse topological power ordering (mainline-based), then runs the iterative auth check.

**Federation fan-out via PubSub**: `RoomProcess` (in `axon_room`) cannot depend on `AxonFederation.HttpClient` (in `axon_federation`) — they're at the same supervision level. Instead, `RoomProcess` broadcasts `{:federate_event, event_map, remote_servers}` on `Axon.PubSub`, and `AxonWeb.FederationFanout` (which can see both apps) handles the outbound HTTP.

## Database schema

Core tables:

| Table | Purpose |
|---|---|
| `events` | Append-only PDU store with `auth_event_ids`, `prev_event_ids`, `hashes`, `signatures`, `depth`, `stream_ordering` |
| `current_room_state` | Materialized current state: `(room_id, type, state_key) → event_id` |
| `room_memberships` | Denormalized membership for fast "which rooms is this user in?" queries |
| `room_state_snapshots` | Periodic snapshots of `{type\0state_key → event_id}` to bound replay time |
| `access_tokens` | Bearer token → user_id + device_id |
| `devices` | Device key storage for E2EE |
| `one_time_keys` / `fallback_keys` | OTK pool with atomic `FOR UPDATE SKIP LOCKED` claiming |
| `account_data` / `room_account_data` | Per-user and per-room account data (JSONB) |
| `federation_inbound_txns` | Deduplication of inbound `PUT /send/:txnId` transactions |
| `remote_server_keys` | Persisted cache of remote server Ed25519 keys |
| `cross_signing_keys` | Master, self-signing, user-signing cross-signing keys per user |
| `cross_signing_signatures` | Uploaded cross-signing signature records |
| `room_key_backup_versions` | Key backup version metadata, user-scoped |
| `room_key_backups` | Megolm session key backups |
| `device_list_updates` | Log of key upload events used to compute `/keys/changes` cursor |
| `media` | Media file metadata (origin server, content-type, storage path) |
| `pushers` | Registered push gateways per user/device |

## Getting started

### Prerequisites

- Elixir 1.18+, Erlang/OTP 27+
- PostgreSQL 15+
- ImageMagick (`convert`) — for media thumbnailing; not required to run the server, only to generate resized thumbnails (non-image thumbnail requests fall back to the original file)

### Development

```bash
# Clone and install dependencies
git clone https://github.com/mazoochian/axon.git
cd axon
mix deps.get

# Create and migrate the database (defaults to localhost:5432, user/pass: axon/axon)
mix ecto.setup

# Start the server (CS API on :8008, federation on :8448)
AXON_SERVER_NAME=localhost iex -S mix
```

The server is now listening at `http://localhost:8008`. You can point any Matrix client at it and register a new account.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `AXON_SERVER_NAME` | `localhost` | The Matrix server name (e.g. `matrix.example.com`) |
| `DB_HOST` | `localhost` | PostgreSQL host |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_USER` | `axon` | PostgreSQL user |
| `DB_PASS` | `axon` (dev/test only) | PostgreSQL password. **Required in production** — the release refuses to boot without it |
| `DB_NAME` | `axon_prod` | PostgreSQL database name |
| `POOL_SIZE` | `20` | Ecto connection pool size |
| `SECRET_KEY_BASE` | *none* | 64-byte Phoenix secret key. **Required in production** — the release refuses to boot without it (generate with `openssl rand -hex 32`) |
| `SENTRY_DSN` | *unset* | Optional. Enables crash reporting via [Sentry](https://sentry.io) when set; the app runs normally without it |

## Deploying with Docker

The repo has two Dockerfiles for two different purposes: `complement/Dockerfile` bundles its own throwaway Postgres and mints an ephemeral secret at boot, purpose-built for the [Complement](#compliance-testing) test harness — don't use it for a real deployment. The root `Dockerfile` is the production-oriented one: it runs as a non-root user, ships a `HEALTHCHECK`, expects Postgres and all secrets from the environment, and never auto-runs migrations on boot.

### Quick start with Docker Compose

```bash
cp .env.example .env
# edit .env: set DB_PASS and SECRET_KEY_BASE (openssl rand -hex 32), etc.

docker compose run --rm migrate   # run once, and again after every deploy that adds migrations
docker compose up -d axon
```

This builds the root `Dockerfile`, starts a `postgres` service with a persistent volume, and starts `axon` on ports 8008 (CS API) and 8448 (federation) once Postgres is healthy.

### Build the image manually

```bash
docker build -t axon:latest .
```

### Run manually (external Postgres)

```bash
docker run -d \
  --name axon \
  -e AXON_SERVER_NAME=matrix.example.com \
  -e DB_HOST=your-postgres-host \
  -e DB_USER=axon \
  -e DB_PASS=yourpassword \
  -e DB_NAME=axon \
  -e SECRET_KEY_BASE=$(openssl rand -hex 32) \
  -p 8008:8008 \
  -p 8448:8448 \
  axon:latest
```

Run migrations once before starting traffic: `docker run --rm <same -e flags> axon:latest /axon/bin/axon eval "AxonCore.Release.migrate()"`.

### Building a production release

```bash
MIX_ENV=prod mix release
# Binary at _build/prod/rel/axon/bin/axon

# Run migrations
_build/prod/rel/axon/bin/axon eval "AxonCore.Release.migrate()"

# Start
_build/prod/rel/axon/bin/axon start
```

## Production deployment

### Reverse proxy (nginx)

Axon listens on port 8008 (CS API) and 8448 (federation). A TLS-terminating reverse proxy is required for production use.

```nginx
# Client-Server API
server {
    listen 443 ssl;
    server_name matrix.example.com;

    ssl_certificate     /etc/letsencrypt/live/matrix.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/matrix.example.com/privkey.pem;

    location / {
        proxy_pass http://localhost:8008;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
}

# Federation API (Matrix S2S)
server {
    listen 8448 ssl;
    server_name matrix.example.com;

    ssl_certificate     /etc/letsencrypt/live/matrix.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/matrix.example.com/privkey.pem;

    location / {
        proxy_pass http://localhost:8448;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
}
```

### Well-known delegation

If you want the Matrix server name to be `example.com` but host at `matrix.example.com`, add these well-known files:

**`https://example.com/.well-known/matrix/server`**
```json
{ "m.server": "matrix.example.com:443" }
```

**`https://example.com/.well-known/matrix/client`**
```json
{
  "m.homeserver": { "base_url": "https://matrix.example.com" },
  "m.identity_server": { "base_url": "https://vector.im" }
}
```

### DNS (for federation without well-known)

Alternatively, add an SRV record:

```
_matrix-fed._tcp.example.com. 3600 IN SRV 10 5 8448 matrix.example.com.
```

### TLS certificate

```bash
certbot certonly --nginx -d matrix.example.com
```

## Observability

- `GET /health` — liveness probe, always 200 while the process is up. Used by the Docker image's `HEALTHCHECK`.
- `GET /ready` — readiness probe, 503 if the database is unreachable.
- `/_synapse/admin/dashboard` — [Phoenix LiveDashboard](https://github.com/phoenixframework/phoenix_live_dashboard) (Phoenix/Ecto/VM metrics, live process/ETS inspection). Gated by the same admin auth as the rest of `/_synapse/admin` — visit with `?access_token=<an admin user's token>`.
- Set `SENTRY_DSN` to enable crash reporting; unset, the app runs normally with no error tracking.
- Structured `Logger` metadata (`request_id`, `user_id`, `room_id`) is attached automatically once a request is authenticated/scoped to a room.

## Testing with Matrix clients

Any Matrix client can connect to Axon today:

- **[Element Web](https://app.element.io)** — open settings, change homeserver to `https://matrix.example.com`
- **[Element Desktop](https://element.io/download)** — same as above
- **[Cinny](https://cinny.in)** — enter your homeserver URL on the login screen
- **[Nheko](https://nheko.im)** — Settings → Account → Homeserver

For local development without TLS, use a client that allows custom insecure homeservers, or add `http://localhost:8008` directly (Element allows this for custom homeservers).

## Compliance testing

Axon uses [Complement](https://github.com/matrix-org/complement) as its acceptance test suite.

### Building the Complement image

```bash
# Full build (takes ~5 minutes)
docker build -f complement/Dockerfile -t axon-complement:latest .

# Fast incremental rebuild (patch existing image with new release)
MIX_ENV=prod mix release --overwrite
docker build -f - -t axon-complement:latest . <<'EOF'
FROM axon-complement:latest
COPY _build/prod/rel/axon /axon
EOF
```

### Running tests

```bash
# Clone Complement
git clone https://github.com/matrix-org/complement.git

# Run all CS API tests
cd complement
COMPLEMENT_BASE_IMAGE=axon-complement:latest \
  go test -timeout 600s ./tests/csapi/...

# Run a specific test
COMPLEMENT_BASE_IMAGE=axon-complement:latest \
  go test -run TestRoomCreate -timeout 120s ./tests/csapi/...
```

### Current results

The last full Complement run (37/50 CS API tests) predates Phases 3–7 and is stale — most of its 13 failures (media, presence, search) are in areas that have since been built out. Re-run the suite above for current numbers.

### Real-client end-to-end tests

Complement and `apps/axon_web/test/e2e/*.exs` are both black-box but drive raw HTTP against the Matrix API, not an actual client. `e2e-client/` instead drives real [Element Web](https://github.com/element-hq/element-web) instances with [Playwright](https://playwright.dev/) — two at once, so they can message each other — to catch the kind of bug that only shows up when the server is used in practice. See `e2e-client/README.md`. Runs nightly/on-demand in CI (`.github/workflows/e2e-client.yml`), not on every PR, since it's much slower than the rest of the suite.

## Media storage

Media files are stored on the local filesystem (default: `/tmp/axon_media`). Configure a custom path:

```elixir
# config/dev.exs
config :axon_media, :storage_path, "/var/lib/axon/media"
```

Each upload generates a random 24-character base64url ID (`mxc://server/ID`). Remote media is proxied on download.

### Thumbnails

`GET /_matrix/media/v3/thumbnail/...` generates real thumbnails via ImageMagick (`crop` or `scale`, any `width`/`height` up to 1600px), cached on disk next to the original so repeat requests for the same size don't re-encode. Non-image content (or a missing `convert` binary) falls back to serving the original file untouched. Remote thumbnail requests are proxied straight to the origin server's own thumbnail endpoint rather than re-encoded locally.

## Application Services

Drop a JSON registration file in the project directory and point to it:

```elixir
config :axon_web, :appservice_config_path, "appservices.json"
```

Registration format matches Synapse's schema. The manager subscribes to all room events via Phoenix.PubSub and fans out to matching ASes.

## Room versions

Supported room versions: **2–12** (default for new rooms: **11** — pass `room_version` to `/createRoom` for v12). Restricted joins (`join_rule: restricted`/`knock_restricted`, MSC3083) work on any version that supports them. Note: v12 is accepted and validated, but state resolution doesn't yet implement the MSC4297 v2.1 auth-difference changes specific to that version — v12 rooms currently resolve state with the same algorithm as v6–v11.

## Federation

Federation is implemented per the [Matrix S2S spec v1.18](https://spec.matrix.org/v1.18/server-server-api/). All events are signed with the server's Ed25519 key; signatures are verified on all inbound PDUs.

Implemented endpoints:
- `GET /_matrix/key/v2/server` — server signing key document
- `GET /_matrix/federation/v1/make_join/:roomId/:userId` — includes MSC3083 restricted-join authorisation
- `PUT /_matrix/federation/v2/send_join/:roomId/:eventId`
- `GET /_matrix/federation/v1/make_leave/:roomId/:userId`
- `PUT /_matrix/federation/v2/send_leave/:roomId/:eventId`
- `GET /_matrix/federation/v1/make_knock/:roomId/:userId`
- `PUT /_matrix/federation/v1/send_knock/:roomId/:eventId`
- `PUT /_matrix/federation/v1/send/:txnId` — inbound PDU transactions
- `GET /_matrix/federation/v1/event/:eventId`
- `GET /_matrix/federation/v1/state/:roomId`
- `GET /_matrix/federation/v1/state_ids/:roomId`
- `GET /_matrix/federation/v1/backfill/:roomId`
- `POST /_matrix/federation/v1/get_missing_events/:roomId`
- `GET /_matrix/federation/v1/query/directory`
- `GET /_matrix/federation/v1/query/profile`
- `POST /_matrix/federation/v1/user/keys/query` / `claim`, `GET /_matrix/federation/v1/user/devices/:userId` — cross-server E2EE key exchange

## Presence

Presence (`GET`/`PUT /_matrix/client/v3/presence/:userId/status`) is tracked in-memory (ETS) per server — no DB persistence, since presence is ephemeral by spec. Using the API at all marks a user "online"; a background sweep drops idle users to "unavailable" after 5 minutes and "offline" after 30. `/sync` reports presence for the syncing user plus anyone sharing a joined room with them.

## Search

`POST /_matrix/client/v3/search` runs a Postgres full-text search (`tsvector`/`tsquery`, English config) over `m.room.message` bodies in rooms the requester has joined, with `rank` or `recent` ordering and per-result timeline context.

## License

MIT
