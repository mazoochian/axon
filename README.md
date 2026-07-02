# Axon

A Matrix homeserver written in Elixir/Erlang, targeting spec [v1.18](https://spec.matrix.org/v1.18/).

Named after the neurological structure — fitting for a highly-connected, distributed message-passing system. Axon is designed to fix the fundamental runtime limitations of [Synapse](https://github.com/element-hq/synapse) (Python GIL, OS-level worker processes, Redis dependency) by using the BEAM runtime, where each Matrix room maps naturally to a GenServer process that owns its state in memory, serializes event application, and can be restarted from persistent storage on crash.

## Status

| Phase | Scope | Status |
|---|---|---|
| **Phase 1** — CS API | Auth, rooms, events, sync, filters, directory, E2EE keys | **Complete** — 37/50 Complement CS API tests pass (all 13 failures are Phase 3/4 scope: media, push, presence, search) |
| **Phase 2** — Federation | State res v2, S2S API, room join, PDU fan-out | **In progress** — foundation built (key cache, HTTP client, all endpoints, outbound fan-out) |
| **Phase 3** — Full E2EE | Cross-signing, key backup, SSSS, device list sync, to-device delivery | **Complete** — user-scoped key backup, cross-signing UIA, device list change tracking, OTK counts in sync |
| **Phase 4** — Media/Push | Upload/download, thumbnails, push notifications, App Services | **Complete** — local filesystem media, Sygnal-compatible push delivery, AS skeleton with PubSub fanout |
| **Phase 5** — Advanced | Spaces, threads, reactions, room upgrades | Not started |
| **Phase 6** — OIDC | OAuth2/OIDC login (MSC3861) for Fractal and modern clients | Not started |

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

### Supervision tree

```
AxonWeb.Application
├── AxonCrypto.KeyServer          # Ed25519 signing keypair for this server
├── Finch (Axon.Finch)            # HTTP client pool for outbound federation
├── Task.Supervisor               # Async tasks (fan-out, snapshots)
├── AxonWeb.FederationFanout      # Sends PDUs to remote servers on PubSub event
├── AxonCore.Repo                 # PostgreSQL via Ecto
├── AxonRoom.Registry             # Horde.Registry: room_id → pid
├── AxonRoom.Supervisor           # Horde.DynamicSupervisor: per-room GenServers
├── AxonRoom.TaskSupervisor       # Async room tasks (snapshots)
├── AxonFederation.KeyCache       # ETS-backed cache of remote server signing keys
├── AxonSync.Manager              # Long-poll sync connections
├── Cluster.Supervisor            # libcluster node auto-discovery
├── AxonWeb.Endpoint              # CS API — port 8008
└── AxonWeb.FederationEndpoint    # S2S API — port 8448
```

### Key design decisions

**PostgreSQL over Cassandra**: Matrix state resolution requires recursive auth chain traversal (a single recursive CTE in Postgres; N serial round-trips in Cassandra). Atomic event + state updates also require cross-partition ACID, which Cassandra cannot provide. Postgres handles all Matrix query patterns natively and Ecto integration is first-class.

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
| `DB_PASS` | `axon` | PostgreSQL password |
| `DB_NAME` | `axon_prod` | PostgreSQL database name |
| `POOL_SIZE` | `20` | Ecto connection pool size |
| `SECRET_KEY_BASE` | *(generated)* | 64-byte Phoenix secret key — **set this in production** |

## Deploying with Docker

### Build the image

```bash
docker build -f complement/Dockerfile -t axon:latest .
```

### Run

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

**37/50 CS API tests passing.** All 13 failures are out-of-scope for Phase 1:

```
PASS: Auth, registration, login, logout, whoami, password change
PASS: Rooms — create, join, leave, invite, kick, ban, unban, forget
PASS: Events — send, state, redact, messages, history visibility
PASS: Sync — initial, incremental, filters, account data, ignored users, unsigned.membership
PASS: Directory — public rooms, aliases, canonical alias, room visibility
PASS: E2EE — keys upload/query/claim, to-device messages
PASS: Profile, receipts, read markers, device management

FAIL: Media (5 tests) — Phase 4
FAIL: E2EE device list updates (3 tests) — Phase 3
FAIL: Push (2 tests) — Phase 4
FAIL: Presence (1 test) — Phase 3
FAIL: Search (1 test) — Phase 4
FAIL: Server notices (1 test) — Phase 4
```

## Media storage

Media files are stored on the local filesystem (default: `/tmp/axon_media`). Configure a custom path:

```elixir
# config/dev.exs
config :axon_media, :storage_path, "/var/lib/axon/media"
```

Each upload generates a random 24-character base64url ID (`mxc://server/ID`). Remote media is proxied on download.

## Application Services

Drop a JSON registration file in the project directory and point to it:

```elixir
config :axon_web, :appservice_config_path, "appservices.json"
```

Registration format matches Synapse's schema. The manager subscribes to all room events via Phoenix.PubSub and fans out to matching ASes.

## Room versions

Supported room versions: **2–11** (default: **11**).

Room version 12 (state resolution v2.1 per MSC4297) is planned for Phase 2 completion.

## Federation

Federation is implemented per the [Matrix S2S spec v1.18](https://spec.matrix.org/v1.18/server-server-api/). All events are signed with the server's Ed25519 key; signatures are verified on all inbound PDUs.

Implemented endpoints:
- `GET /_matrix/key/v2/server` — server signing key document
- `GET /_matrix/federation/v1/make_join/:roomId/:userId`
- `PUT /_matrix/federation/v2/send_join/:roomId/:eventId`
- `GET /_matrix/federation/v1/make_leave/:roomId/:userId`
- `PUT /_matrix/federation/v2/send_leave/:roomId/:eventId`
- `PUT /_matrix/federation/v1/send/:txnId` — inbound PDU transactions
- `GET /_matrix/federation/v1/event/:eventId`
- `GET /_matrix/federation/v1/state/:roomId`
- `GET /_matrix/federation/v1/state_ids/:roomId`
- `GET /_matrix/federation/v1/backfill/:roomId`
- `POST /_matrix/federation/v1/get_missing_events/:roomId`
- `GET /_matrix/federation/v1/query/directory`
- `GET /_matrix/federation/v1/query/profile`

## License

MIT
