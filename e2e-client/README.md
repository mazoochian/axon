# Axon E2E client tests

Real-client end-to-end tests: [Element Web](https://github.com/element-hq/element-web)
(matrix-js-sdk) driven by [Playwright](https://playwright.dev/) against a real
Axon server, two browser contexts at once (Alice + Bob) so they can actually
message each other.

This is a different kind of test from `apps/axon_web/test/e2e/*.exs` and
`../complement/`, which are both black-box but drive raw HTTP requests
against the Matrix API. This suite drives a real client's UI instead, to
catch the class of bug that only shows up when the server is used in
practice by an actual client — sync-loop timing, room-creation/invite flows,
encryption defaults, and so on.

## Running locally

Two pieces: Axon itself (run directly on the host, in dev mode, for fast
iteration — no image rebuild per code change) and Element Web (run via
Docker, pointed at the host).

```bash
# 1. One-time setup, if you haven't already (see main README.md):
#    mix deps.get && mix ecto.setup

# 2. From e2e-client/:
docker compose --profile local up -d      # starts Element Web only
./start-axon.sh                            # boots Axon (mix phx.server), separate terminal

# 3. Install test deps once, then run:
npm install
npx playwright install chromium
npm test
```

`start-axon.sh` reuses your normal local dev Postgres/`axon_dev` database (the
same one `mix ecto.setup` sets up) rather than spinning up a dedicated one —
this harness is meant to run standalone, so stop anything else already
bound to ports 8008/8448/8080 first.

Debug a failure interactively with `npm run test:ui`, or inspect the last
report with `npm run report`.

## Running in CI

`docker compose --profile ci up -d` instead starts a fully isolated stack:
a dedicated Postgres, Axon built from the repo's root `Dockerfile` (the
same prod image from the main README's Docker section), and Element Web
wired to that `axon` service over the compose network — no host processes
involved, for hermeticity. See `.github/workflows/e2e-client.yml`, which
runs this nightly and via manual dispatch (not on every PR — a real browser
plus a real Element Web image pull plus a real server boot is too slow for
the fast inner-loop CI in `.github/workflows/ci.yml`).

## Notes

- Element Web's image tag is pinned in `docker-compose.yml`
  (`vectorim/element-web:v1.11.86`) for reproducibility — bump deliberately,
  not via `latest`.
- Element Web's UI selectors can shift between versions. If a bump breaks
  `tests/dm-message-roundtrip.spec.ts`, `npm run test:ui` is the fastest way
  to see exactly where the flow diverges.
- The DM in the first scenario runs through Element Web's default
  encrypted-DM flow rather than forcing plaintext — that's deliberate, since
  it's real E2EE-in-practice coverage distinct from the protocol-level E2EE
  tests in `apps/axon_web/test/e2e/`. If that proves too flaky, disabling
  encryption via `element-config.*.json` is a documented fallback, not the
  starting assumption.
