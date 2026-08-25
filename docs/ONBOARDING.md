# Axon onboarding

This is a from-the-code walkthrough for someone who already knows distributed
systems and OTP but hasn't been in this repo for a while. It's organized to
get you oriented fast, then to go deep on the pieces that are architecturally
load-bearing. It is honest about rough edges — this is an internal doc, not
marketing copy. Numbers and status claims below were checked against the
code and against `ROADMAP.md` as it stands today (Phase 28, 2026-08); they
will drift, so re-check ROADMAP.md's tail for anything time-sensitive.

## 1. Mental model, in one paragraph

Axon is a Matrix homeserver (spec v1.18) written as an Elixir umbrella app.
The one idea the whole design hangs off is: **a Matrix room maps onto a BEAM
process.** Synapse gets concurrency by running a fleet of OS-level Python
worker processes (each carrying a full interpreter, ~200-500MB, coordinated
through Redis) because Python's GIL means a single process can't usefully
parallelize CPU-bound work. The BEAM doesn't have that problem — processes
are ~2KB, scheduled preemptively across cores, individually garbage
collected, and can talk to each other for free whether they're on the same
node or a different one via distributed Erlang. So instead of sharding rooms
across a fixed set of heavyweight workers, axon just gives every *active*
room its own lightweight process (`AxonRoom.RoomProcess`) that owns that
room's state in memory and is the single serialization point for every
mutation to it — local sends and inbound federation PDUs alike go through
the same `GenServer.call`. Crash it and it comes back by replaying from
Postgres. This is a completely standard, sound OTP pattern (it's exactly
what you'd reach for to model "N independent state machines, low contention
within each, need serialized mutation") — the rest of this doc is about how
axon actually built that idea out, including where it still has sharp edges.

## 2. The umbrella and its real dependency graph

Eight apps under `apps/`. The README draws `axon_room`, `axon_federation`,
and `axon_sync` as three parallel siblings that all depend only on
`axon_core`, with `axon_web` sitting on top of everything. **That diagram is
wrong** — verified from every `apps/*/mix.exs`:

```
axon_crypto   (no deps)
      │
axon_core     (axon_crypto)
      │
      ├── axon_push    (axon_core)
      ├── axon_media   (axon_core)
      ├── axon_sync    (axon_core)
      │
      axon_room       (axon_core, axon_push)
              │
      axon_federation (axon_core, axon_room)
                          │
                     axon_web (all of the above: axon_crypto, axon_core,
                               axon_room, axon_federation, axon_sync,
                               axon_media, axon_push)
```

The two corrections that matter:

- **`axon_federation` depends directly on `axon_room`** (`apps/axon_federation/mix.exs:26`), not the reverse and not "same level." `AxonFederation.RoomJoin` and `AxonFederation.Backfill` both `alias AxonRoom.RoomProcess` and call it directly (`apps/axon_federation/lib/axon_federation/room_join.ex:15`, `apps/axon_federation/lib/axon_federation/backfill.ex:33`). This is a one-way edge, not a peer relationship — and it's precisely why the reverse direction (`axon_room` calling into `axon_federation`) isn't just discouraged, it would be a literal circular dependency the umbrella wouldn't compile with. See §3.4 for how that constraint shapes the federation fan-out design.
- **`axon_room` depends on `axon_push`**, which the README's diagram doesn't show at all (needed so `RoomProcess` can call `AxonPush.Dispatcher.dispatch_event/2` on every applied event — `apps/axon_room/lib/axon_room/room_process.ex:347,508`). `axon_media` is also absent from the diagram; it only hangs off `axon_core` and is otherwise a leaf, pulled in by `axon_web`.

Each app is a normal OTP application with its own supervision tree
(`AxonCore.Application`, `AxonRoom.Application`, etc.), started together by
the umbrella's release. `Axon.PubSub` — the process-group message bus half
the architecture leans on — is started by `axon_sync`
(`apps/axon_sync/lib/axon_sync/application.ex:7`), not `axon_core`, which
matters if you ever try to run a single sub-app's tests in isolation (a
`cd apps/axon_room && mix test` run starts `axon_room`'s tree but not
`axon_sync`'s, so anything that broadcasts on `Axon.PubSub` blows up looking
like a regression when it's really a missing sibling supervisor —
ROADMAP Phase 20 documents this trap explicitly).

Horde (`horde ~> 0.9`) and libcluster (`libcluster ~> 3.4`) are both real
dependencies, and `AxonWeb.Application` does start a `Cluster.Supervisor`
(`apps/axon_web/lib/axon_web/application.ex:36`) — but `config/dev.exs`,
`config/test.exs`, and `config/runtime.exs` all configure `topologies: []`
(or don't mention libcluster at all, in prod's case). So "Horde + libcluster
give transparent multi-node clustering" is true of the *machinery*, not of
anything currently wired up out of the box: nobody has configured an actual
node-discovery strategy anywhere in this repo. Horde's `members: :auto`
setting means it'll pick up cluster membership *if* libcluster ever
connects nodes together, but as shipped, a deployment runs single-node.
Worth knowing before you assume "just add nodes" is a tested path.

## 3. The per-room GenServer, in detail

`AxonRoom.RoomProcess` (`apps/axon_room/lib/axon_room/room_process.ex`) is
the center of gravity of this codebase. Read the module doc at the top of
that file first — it's dense but accurate.

### 3.1 Lifecycle

There's no room supervisor tree with one child per known room. Instead,
`AxonRoom.Application` (`apps/axon_room/lib/axon_room/application.ex`) starts
exactly three long-lived things: a `Horde.Registry` (`AxonRoom.Registry`), a
`Horde.DynamicSupervisor` (`AxonRoom.Supervisor`), and a `Task.Supervisor`
for snapshot writes. A room process is started lazily, on first access, via
`RoomProcess.get_or_start/1` (`room_process.ex:47`): look it up in the Horde
registry, and if it's not there, ask the Horde dynamic supervisor to start
one, keyed by `room_id` through `via/1` (`{:via, Horde.Registry, {AxonRoom.Registry, room_id}}`).
Every public function on this module (`send_event/5`, `apply_remote_event/3`,
`get_state/1`, etc.) calls `get_or_start/1` first, so "the room process
exists" is an invariant callers never have to think about — you just call
the API and a process materializes if it wasn't already there.

On `init/1` (`room_process.ex:157`), the process loads itself from Postgres:
`load_room/1` fetches the room's version, then `load_from_snapshot/1`
(`room_process.ex:629`) looks for the most recent row in
`room_state_snapshots` for this room. If there's a snapshot, it deserializes
that flattened `{type, state_key} → event_id` map back into full event maps
and then replays only the events *since* that snapshot's
`after_stream_ordering` (`EventStore.get_events_since/3`). If there's no
snapshot yet, it replays the whole room from event 0. Every `@snapshot_interval`
(100) applied events, a snapshot write is kicked off asynchronously via
`Task.Supervisor.start_child(AxonRoom.TaskSupervisor, ...)` (`room_process.ex:700-704`)
so it doesn't block the GenServer's mailbox.

Crash recovery: `use GenServer, restart: :transient` plus the Horde dynamic
supervisor means a crashed room process gets restarted (not restarted if it
exits normally/is explicitly stopped) and goes through exactly the same
`init/1` → snapshot-plus-replay path as a first-time start. There is no
separate "warm restart" path — a crash and a cold start look identical from
the process's own perspective, which is a nice property (one code path to
reason about, one code path to test) at the cost of replay time being
whatever it is (bounded by the 100-event snapshot interval, not by any
smarter incremental checkpoint).

Admin purge is the only thing that explicitly kills a resident process:
`RoomProcess.stop_if_running/1` (`room_process.ex:67`) is called by
`AxonCore.EventStore.purge_room/1` specifically so a just-deleted room's
in-memory process can't keep answering queries with state that no longer
has any backing rows.

### 3.2 One `GenServer.call` for every mutation, local or federated

Both `send_event/5` (a local client posting a message or state change) and
`apply_remote_event/3` (an inbound federation PDU) ultimately reduce to a
single synchronous `GenServer.call` into the room's process — `{:send_event, ...}`
or `{:apply_remote_event, ...}` respectively. That's the actual mechanism
behind "state resolution and auth checking are serialized per room": because
it's one process handling one call at a time, there's no possibility of two
concurrent writers racing on `current_state` for the same room — the BEAM
scheduler does the mutual exclusion for you, for free, without a lock. The
local-send path (`do_send_event/2`, `room_process.ex:311`) does a plain
`AuthRules.check/3` against the room's current in-memory state and inserts.
The federation path (`handle_call({:apply_remote_event, ...})`,
`room_process.ex:359`) is considerably more involved — soft-fail-permanence
checks, transitive auth-event rejection, and (if the PDU's `prev_events`
fork away from this server's known head) a full state-resolution walk before
the auth check even runs. Both paths converge on the same
`commit_persisted_event`/`apply_authorized_event` machinery: persist via
`AxonCore.EventStore`, advance in-memory state via `apply_and_advance/3`,
broadcast to local `/sync` subscribers, and (conditionally) fan out to
federation. See §6 for that last part.

### 3.3 Local sends and federated PDUs share the mutation path, but not the auth path

Worth being precise about what "the same GenServer.call" buys you and what
it doesn't. It buys serialization — nothing about this room's state can be
read-then-written non-atomically by two callers at once. It does *not* mean
local and federated events are auth-checked identically: a local send is
checked once, against `state.current_state`; an inbound federated PDU can
require running `AxonRoom.StateResolver` first (if it forks) to compute the
state its own ancestry actually implies, checking against *that*, and then
optionally a second, "soft-fail" check against the room's live current state
too (see the big comment block starting at `room_process.ex:446`). That
second check exists because a forked PDU can be legitimately authorized
against its own ancestry while having been overtaken by a *different* branch
that actually won — soft-failure is what lets axon apply-but-hide such an
event rather than either rejecting it outright or corrupting current state
with it.

### 3.4 Why `RoomProcess` can't import `axon_federation`, and how PubSub bridges the gap

This is real, not aesthetic. §2 showed `axon_federation` depends on
`axon_room` (for `RoomProcess.apply_remote_event/3` and friends). If
`axon_room` also depended on `axon_federation` (so `RoomProcess` could call
`AxonFederation.HttpClient` directly to push a newly-applied event out to
remote servers), that would be a circular dependency between two umbrella
apps — Mix will not build that. So the actual outbound-federation call has
to happen from somewhere that can see both `axon_room`'s event and
`axon_federation`'s HTTP client, which by the dependency graph can only be
`axon_web` (it depends on everything).

The bridge is `Phoenix.PubSub`. `RoomProcess.broadcast_for_federation/4`
(`room_process.ex:801`) computes the set of remote server names with a
joined member in the room (from `current_state`'s `m.room.member` events),
and if that set is non-empty, publishes `{:federate_event, event_map,
remote_servers}` on the `"federation:fanout"` topic — a plain message, no
function call across the app boundary. `AxonWeb.FederationFanout`
(`apps/axon_web/lib/axon_web/federation_fanout.ex`) is a GenServer that
subscribes to that topic and, on receipt, hands the event off to
`AxonFederation.OutboundQueue.enqueue/2` for durable, retried delivery. It
also relays `:federate_edu` (typing, receipts, to-device) and
`:presence_changed` the same way. The whole thing is a textbook mediator
pattern implemented with a message bus instead of a shared interface — it
works, and it's the *only* option given the dependency direction, but it
does mean the outbound-federation contract is an implicit one (the shape of
the PubSub message), not a compiler-checked function signature. If you ever
rename or restructure that tuple, nothing will fail to compile; it'll just
silently stop delivering.

### 3.5 The idle-eviction gap

This is a real, confirmed architectural gap, not a hypothetical. Read all of
`room_process.ex` end to end and there is **no idle timeout, no
hibernation, and no eviction logic of any kind**. `get_or_start/1` starts a
process on first access; nothing after that ever calls
`GenServer.stop/1`, sets a receive `timeout`, or arranges a `Process.send_after/3`
tick to check for inactivity. The only two things that ever terminate a
resident `RoomProcess` are a node restart (which drops the whole BEAM VM and
therefore every process on it) and the admin-only `RoomProcess.stop_if_running/1`
path invoked by a room purge. There's no periodic sweep, no LRU cache, no
`:hibernate` return anywhere in the module.

The practical consequence: **the number of resident room processes only
grows over a node's uptime.** Every room anyone (local user or remote
federation peer) ever touches stays resident in memory forever, whether or
not anyone is actively using it. On a long-lived, busy, federating server
this is a real capacity-planning concern — it's not bounded by working set,
it's bounded by "every room ever touched since the last restart."

This is *not* a flaw in the process-per-room design itself — process-per-room
is exactly the right OTP pattern here, and the fix is a narrow, well-understood
addition to it, not a redesign. It's also, importantly, a pure cache-eviction
problem and not a durability one: dropping a `RoomProcess`'s in-memory state
is always safe, because `init/1` already knows how to rebuild that exact
state from `room_state_snapshots` + event replay (§3.1) — that's the same
path a crash recovery takes. The natural fix is the standard one: an idle
timeout (`GenServer`'s own `timeout` return value, or a `Process.send_after/3`
self-tick) that calls `stop_if_running/1`-equivalent logic on itself after N
minutes with no `handle_call`/`handle_cast` traffic, trusting the existing
snapshot-and-replay path to rebuild it cheaply on next access. Nothing in
ROADMAP.md currently tracks this as an open item — it's worth adding.

## 4. State resolution v2

Two modules do two different jobs, and the README currently only really
describes one of them.

**`AxonRoom.StateResV2`** (`apps/axon_room/lib/axon_room/state_res_v2.ex`) is
the actual State Resolution v2 algorithm from the spec, as a pure function:
given a list of state sets (each `{type, state_key} → event_map`) and a
`get_event_fn` callback, it (1) splits keys into unconflicted (same value
present in *every* input set — not merely "only one candidate value among
sets that have an opinion," which is a correctness-critical distinction the
module's doc calls out explicitly) and conflicted, (2) computes the auth
difference (the conflicted events' auth chains, minus whatever's already
reachable from the unconflicted state), (3) sorts that full conflicted set
by reverse topological power ordering (mainline-based — depth and
power-level-authority determine event precedence), and (4) iteratively
auth-checks each event in that order, folding accepted ones into the result.
For room v12 it also implements MSC4297's "v2.1" refinements — starting the
iterative fold from an empty map instead of the unconflicted map, and
including the "conflicted state subgraph" (ancestors that lie *between* two
conflicted events but would otherwise look already-settled). This is a
self-contained, well-tested piece of code with no I/O beyond the injected
callback.

**`AxonRoom.StateResolver`** (`apps/axon_room/lib/axon_room/state_resolver.ex`)
is what actually decides *when* to run that algorithm and *what* to feed it,
for a live inbound PDU. `needs_resolution?/2` is the cheap fast path: if a
PDU's `prev_events` is empty (room creation) or is exactly `[our own current
head]` (the overwhelmingly common case — an ordinary `/send` transaction),
no resolution is needed at all and the room's existing `current_state` is
used directly, zero extra queries. Only when a PDU's ancestry actually
diverges from what this server thinks is the head does `resolve_for_auth_check/4`
run: a capped (500-event), batched, cycle-safe two-phase BFS — first
prefetching everything the walk might need in level-by-level round trips,
then a pure in-memory fold that resolves the state at each of the PDU's
`prev_events`, calling `StateResV2.resolve/3` at every branch point it
actually finds along the way, not just a one-hop peek. This is a real,
comparatively recent fix (Phase 15.6) — before it, the resolution only ever
looked one hop into a `prev_event`'s own `auth_events`, so multi-generation
forks and the v12 subgraph refinement were both provably unreachable.

The documented scope limit that still matters: `StateResolver` is bounded to
events already present in *this server's own* database. It does not, itself,
reach out over federation to fetch a missing ancestor mid-walk — that's a
separate concern handled *before* this module ever runs, by
`AxonFederation.Backfill` (§6). If a PDU's `prev_events` are genuinely
unresolvable locally (not found, or beyond the 500-event cap), the resolver
returns `:unresolvable` rather than guessing by falling back to the room's
unrelated current state — `RoomProcess` treats that as an outright rejection
(stored, never applied). That's a deliberate fail-closed choice: silently
auth-checking against the wrong ancestry is worse than refusing.

## 5. Sync path

Two endpoints exist: classic long-poll `/sync` and sliding sync (MSC4186,
`POST /_matrix/client/unstable/org.matrix.msc4186/sync`). They share almost
all of their machinery.

**Delivery mechanism**, common to both: `AxonSync.Manager.wait_for_events/3`
(`apps/axon_sync/lib/axon_sync/manager.ex`) is called directly from the sync
controller's own process (not a separate GenServer doing the waiting — the
"manager" module's server callback is nearly empty; the real work happens in
the calling process via a plain `receive`). It subscribes that process to
`Phoenix.PubSub` topics for every room the user is joined to (`"room:#{room_id}"`)
plus a user-specific topic (`"user:#{user_id}"`), does a race-free check
(query first, "did anything already happen since your token" — subscribe
happens *before* that check, not after, so nothing delivered in the gap is
missed), and then blocks in `receive` for up to `timeout` ms, waking on any
of `{:new_event, ...}`, `{:to_device, ...}`, `{:device_list, ...}`,
`{:account_data, ...}`, or `{:ephemeral, ...}`. Every one of those wake
signals re-queries fresh state rather than trusting the message's own
payload — the message is purely a "something changed, go look" nudge. This
is what `RoomProcess.broadcast/2` (`room_process.ex:778`) publishes on every
applied event, and it's also the mechanism to-device delivery, device-list
changes, account-data changes, and ephemeral (typing/receipts) events wake
through — all bugs found across Phases 8-9 were exactly "X changed but
nothing published to this topic, so a long-poller sat there until its
timeout expired regardless of activity."

**Classic `/sync`** (`AxonWeb.SyncController`) and **sliding sync**
(`AxonWeb.SlidingSyncController`) both delegate their actual
cursor/extension logic (E2EE key counts, device-list diffing, account data,
receipts, typing) to a shared `AxonWeb.SyncHelpers` module specifically so
the two implementations can't drift apart on those semantics — this was an
explicit refactor (Phase 10) after they'd started as independent
implementations. Where they genuinely differ: sliding sync organizes rooms
into client-defined, range-paginated *lists* (sorted by recency) plus
explicit per-room `room_subscriptions`, resolves `required_state` including
`$LAZY`/`$ME` wildcards, and (since Phase 16) does real per-`conn_id`
bandwidth diffing — remembering, in an ETS table, what was last sent for a
given range/room and omitting anything byte-identical to last time. Classic
sync has no such diffing; every incremental response is computed fresh from
the `since` token. Both compute real `notification_count`/`highlight_count`
now (this was a long-standing "always 0" gap, closed in Phase 18) via
`AxonWeb.SyncHelpers`, so they can't diverge there either.

## 6. Federation path

### 6.1 Outbound

The chain is: `RoomProcess` applies an event → `broadcast_for_federation/4`
computes the remote-server fan-out set from current membership and
publishes `{:federate_event, ...}` on `"federation:fanout"` →
`AxonWeb.FederationFanout` picks it up and calls
`AxonFederation.OutboundQueue.enqueue/2` → `OutboundQueue` **persists the
transaction before the first delivery attempt**, then delivers over HTTP
with exponential backoff (30s → 1hr cap, giving up after 7 days) and a
per-destination circuit breaker (trips after 5 consecutive failures, caps
concurrent in-flight attempts per destination) — this replaced an original
fire-and-forget design where a remote server being briefly unreachable
silently dropped whatever was sent during that window (Phase 9/15.4).

### 6.2 Inbound

`AxonWeb.FederationController.send_transaction/2` receives a signed
transaction, verifies signatures, computes/attaches `event_id` for each PDU
(room versions 3+ don't carry one on the wire — a real, previously-latent
bug class that bit multiple call sites independently before being unified,
see ROADMAP Phase 21/22), and if a PDU's `prev_events` reference events this
server has never seen, first tries `AxonFederation.Backfill`'s gap-closing
(`POST get_missing_events` against the origin, falling back to `GET
backfill` if that doesn't fully close it) before calling
`RoomProcess.apply_remote_event/2` for each event, oldest-first, same path
as an ordinary live PDU (signature check, auth check, state resolution as
described in §4).

### 6.3 The relay_exclude bug — a worked example of the design's sharp edges

This is genuinely the best illustration of where the process-per-room +
PubSub-fanout design gets sharp: `RoomProcess.apply_remote_event/2`
originally never re-broadcast an applied PDU to federation at all — correct
for an ordinary `/send` transaction (the origin already pushed it to every
resident server, so relaying further would just duplicate traffic and risk
amplification loops), but silently wrong for `send_join`/`send_leave`/
`send_knock`. In those three cases the *acting user's own server* is
structurally the only party that can relay the new membership event onward:
it just learned the room exists (and who's in it) from this one request, and
it has only ever talked to the one resident server it went through — that
resident server is the only one with the full membership picture. Before
this was understood, **a room with three or more homeservers never
converged on membership**: each newly-joined/knocked/left server's peers
never learned about it unless they happened to hear it some other way. It
was found (Phase 17) via `TestACLs` failing on its own *no-ACL* sentinel
room — charlie couldn't see bob's message because charlie's join had never
been relayed to bob's server.

The fix, `apply_remote_event/3`'s `opts[:relay_exclude]`
(`room_process.ex:97-109`, wired through `apply_authorized_event/5`,
`room_process.ex:493-506`): when set, the just-applied event is *also*
fanned out over the normal `"federation:fanout"` PubSub path, to every
server with a joined member in the room, excluding whichever server just
handed us the event (it already has it). `FederationController` passes the
requesting origin as `relay_exclude` from its three `send_*` handlers only;
every other call site (ordinary `/send`, backfill catch-up, v12 room
creation) keeps the no-relay default. The same shape of bug recurred once
more (Phase 22, federated invites via `federate_invite/4`) and got the same
fix — worth remembering as a pattern if you're adding any new "this server
learned about a room event from exactly one peer and needs to tell the
rest" code path: default to *not* relaying, and think hard about whether
this specific path is one of the exceptions.

## 7. Data model: why event-sourcing

`events` (`apps/axon_core/lib/axon_core/schema/event.ex`) is append-only —
rows are never updated (with one narrow, deliberate exception: redaction,
which overwrites a target event's stored `content` in place per spec, and
the `rejected`/`soft_failed` flag flips discussed in §3.3) or deleted except
via an explicit admin purge. `current_room_state` is a genuine materialized
view — a `(room_id, type, state_key) → event_id` table maintained
incrementally on every `insert_event/2` call (`EventStore.update_current_state/2`),
not derived on read. `room_state_snapshots` periodically captures that
same shape (every 100 applied events per room, `RoomProcess`'s
`@snapshot_interval`) so a process restart doesn't have to replay a room's
entire history from event zero.

The *why*, not just the *what*: this isn't cargo-culted from "event
sourcing is a good pattern" — it's forced by what Matrix actually is. A
Matrix room's true structure *is* a DAG of signed, immutable events
(`prev_events`, `auth_events`); a homeserver's job is fundamentally "compute
and serve views over this DAG," and the append-only events table plus a
derived current-state projection is the most direct possible encoding of
that. It also happens to buy the same properties event-sourcing always
buys — crash recovery (§3.1's replay-from-snapshot is only possible because
nothing before the snapshot point was ever mutated), an audit trail (every
past state is reconstructible, which is exactly what §"known gaps" below
notes axon still can't *query* efficiently for arbitrary points in time),
and no possibility of the materialized view and the source of truth silently
diverging in a way you can't detect, since the view is always rebuildable
from the log by construction.

## 8. Current real status

As of the latest ROADMAP entry (Phase 28), against a real, full-package
Complement run (not a scoped subset or an estimate):

- **`tests/csapi`** (core Client-Server API): **89/106 (84.0%)**. 16
  individually-untriaged failures, plus one near-hang
  (`TestMessagesOverFederation`) that's reproduced twice now across
  different phases under host memory pressure and still isn't confirmed as
  an axon bug.
- **`tests/`** (top-level federation/room package): **65/89 (73.0%)**.
  Dominated by one thing that is **confirmed not an axon bug**: a
  `send_join` signature-verification mismatch against Complement's own
  pinned dev-snapshot `gomatrixserverlib` dependency, independently
  re-verified from scratch five separate times (Phases 19/21/22/25/26,
  including byte-for-byte re-derivation in three different languages/
  libraries) — it alone gates the entire knocking feature family and most
  of the restricted-rooms cluster (14 tests). A second, smaller cluster (3
  tests) is the same dev-dependency's `eventauth` package rejecting v12
  room IDs before axon's own code runs at all. Five more failures are newly
  discovered and untriaged; one (`TestMSC4289PrivilegedRoomCreators`) looks
  like a possible regression from a prior passing state, also untriaged.
- `msc*` packages are skipped by policy — axon has never claimed unstable
  MSCs, and Complement's numbers for those are historically ~0%.

**Known gaps a real client user or operator would actually notice**, in
plain language:

- **No point-in-time history for most of the room's life.** `RoomMembership`
  only tracks *current* membership; `EventStore.get_room_members_at/3` and
  the state-at-a-point helpers cover a departed member's own view and a
  specific `at=` token, but there is no general "show me this room as it
  looked at time T" feature beyond what those narrow, purpose-built queries
  cover.
- **Presence is ephemeral by design and won't survive a restart** — this is
  spec-correct, not a bug, but surprising if you expect it to persist.
- **3pid invites now really deliver** (Phase 27 wired up real
  identity-server integration against Sydent) but only for email; msisdn
  invites can't actually be delivered (no SMS provider anywhere in the
  loop) and fall back to axon's own self-signed proof.
- **`soft_failed` exists but is incompletely exercised** — the write path
  and its "never un-set" invariant are solid (Phase 25), but `AuthRules`
  rule 2 (checking an event's `auth_events` against what the selection
  algorithm would itself have chosen) is still unimplemented, so some
  rejection/soft-failure edge cases in adversarial or corrupted-chain
  scenarios aren't caught.
- **Room processes never get evicted** — see §3.5. Not currently visible to
  a client, but very visible to an operator watching memory over weeks of
  uptime on a busy, federating server.
- **Async media upload (MSC2246)** and a handful of other individually
  small CS API surfaces (`TestUploadKey`, `TestUrlPreview`,
  `TestRelationsPagination`, threaded-receipts pagination, some `Txn*`
  idempotency edge cases) are present in the untriaged Phase 28 failure
  list — worth reading the ROADMAP Phase 28 entry directly before assuming
  any one of these is understood.
- **Multi-node clustering is unconfigured out of the box** — see §2. Horde
  and libcluster are real dependencies and Horde's registry/supervisor are
  cluster-aware, but no topology strategy ships configured anywhere, so a
  fresh deployment is single-node until an operator adds one.

## 9. Where to look next — a short index

- **Per-room state machine, the actual core of the system**:
  `apps/axon_room/lib/axon_room/room_process.ex` — start at the module doc,
  then `handle_call({:apply_remote_event, ...})` for the interesting path.
- **Horde wiring**: `apps/axon_room/lib/axon_room/application.ex` (all of
  20 lines — worth reading in full).
- **State resolution algorithm**:
  `apps/axon_room/lib/axon_room/state_res_v2.ex` (the pure algorithm) and
  `apps/axon_room/lib/axon_room/state_resolver.ex` (when/how it's invoked
  against live DAG data).
- **Auth rules** (the actual Matrix room-version-specific authorization
  logic StateRes and RoomProcess both call into):
  `apps/axon_room/lib/axon_room/auth_rules.ex`.
- **Sync delivery mechanism**: `apps/axon_sync/lib/axon_sync/manager.ex`
  (short — the whole wake-up design is ~120 lines), then
  `apps/axon_web/lib/axon_web/sync_helpers.ex` for what actually gets
  assembled into a response.
- **Federation outbound durability**:
  `apps/axon_federation/lib/axon_federation/outbound_queue.ex`.
- **Federation inbound entry point + backfill/gap-closing**:
  `apps/axon_web/lib/axon_web/controllers/federation_controller.ex` and
  `apps/axon_federation/lib/axon_federation/backfill.ex`.
- **The PubSub bridge that makes the whole cross-app federation fan-out
  work**: `apps/axon_web/lib/axon_web/federation_fanout.ex` (~120 lines,
  worth reading in full — it's the whole bridge).
- **Event store / persistence / materialized state**:
  `apps/axon_core/lib/axon_core/event_store.ex` — long file, but
  `insert_event/2`'s doc comment and the "Snapshots" section
  (`latest_snapshot/1`, `create_snapshot/3`) are the two parts that matter
  most for understanding the crash-recovery story.
- **Room versions / v12 specifics** (domainless room IDs, creator
  privilege): `apps/axon_room/lib/axon_room/create_room.ex` and the v12
  branches inside `event_builder.ex`.
- **CS API vs federation API controller split**: both live under
  `apps/axon_web/lib/axon_web/controllers/`; `federation_controller.ex` is
  the one federation-specific controller (everything else there is CS API),
  and the split is enforced at the router level by two different Plug
  pipelines — `pipeline :authenticated` (bearer token) vs `pipeline
  :federation` (`AxonWeb.Plug.FederationAuth`, X-Matrix request signing) in
  `apps/axon_web/lib/axon_web/router.ex`.
- **Project history and current failure triage**: `ROADMAP.md` — it's long,
  but written phase-by-phase with an honest "where it stands" section at
  the end of nearly every phase; the tail few phases (26-28) are the most
  relevant for current state.
