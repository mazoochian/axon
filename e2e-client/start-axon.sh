#!/bin/bash
set -e

# Local-dev counterpart to the "ci" docker-compose profile: boots Axon
# directly on the host in dev mode, reusing your normal local dev
# Postgres/axon_dev database (the one `mix ecto.setup` sets up per the main
# README) instead of a dedicated e2e Postgres — no image rebuild needed on
# every code change while iterating on this test suite. Pair with
# `docker compose --profile local up -d` (starts only Element Web, pointed
# at host.docker.internal:8008) — see README.md.

cd "$(dirname "$0")/.."
AXON_SERVER_NAME=localhost exec mix phx.server
