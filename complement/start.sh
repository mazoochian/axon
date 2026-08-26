#!/bin/bash
set -e

# Complement passes SERVER_NAME env var
SERVER_NAME="${SERVER_NAME:-localhost}"

# Resolve whatever PostgreSQL major version Debian's "postgresql" apt
# package actually pulled in at image-build time, rather than hardcoding
# one — bookworm's default has drifted between major versions across
# rebuilds of this image (observed both 15 and 17), and a hardcoded path
# that no longer matches makes every container immediately exit on a
# bare "pg_ctl: No such file or directory", which is a confusing failure
# mode with no obvious connection to a package-version bump.
PG_VERSION="$(ls /usr/lib/postgresql/ | sort -V | tail -1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
export PGDATA="/var/lib/postgresql/${PG_VERSION}/data"
PG_LOG=/var/log/postgresql/complement.log

mkdir -p "$PGDATA" /var/log/postgresql /run/postgresql
chown -R postgres:postgres "$PGDATA" /var/log/postgresql /run/postgresql

# Init and start postgres
su -s /bin/bash postgres -c "$PG_BIN/pg_ctl initdb -D $PGDATA -o '--auth=trust --encoding=UTF8' 2>&1" || true
su -s /bin/bash postgres -c "$PG_BIN/pg_ctl start -D $PGDATA -l $PG_LOG -w -o '-h 127.0.0.1 -p 5432 -k /run/postgresql'"

# Wait for postgres
for i in $(seq 1 30); do
  su -s /bin/bash postgres -c "$PG_BIN/pg_isready -q -h 127.0.0.1 -p 5432" && break
  sleep 0.5
done

# Create DB and user
su -s /bin/bash postgres -c "$PG_BIN/psql -h 127.0.0.1 -c \"CREATE USER axon WITH PASSWORD 'axon';\" 2>/dev/null || true"
su -s /bin/bash postgres -c "$PG_BIN/psql -h 127.0.0.1 -c \"CREATE DATABASE axon_prod OWNER axon;\" 2>/dev/null || true"

# Runtime env for Axon
export AXON_SERVER_NAME="$SERVER_NAME"
export ELIXIR_ERL_OPTIONS="+fnu"
export DB_USER=axon
export DB_PASS=axon
export DB_HOST=127.0.0.1
export DB_NAME=axon_prod
export SECRET_KEY_BASE=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
# Complement's own test traffic (many rapid registrations/sends from one
# client against one homeserver) trips the production anti-abuse rate
# limits by design — see config/runtime.exs.
export RELAXED_RATE_LIMITS=true

# Complement creates every test user via plain POST /register, which prod
# now rejects by default (see config/runtime.exs) — open it back up here or
# the whole suite fails at user creation.
export REGISTRATION_ENABLED=true

# Complement's TestUrlPreview webserver is only reachable via the Docker
# host gateway (host.docker.internal), a private address axon's SSRF
# defense otherwise always blocks — see config/runtime.exs.
export URL_PREVIEW_ALLOW_PRIVATE_ADDRESSES=true

# Same reasoning for remote *media* federation: every Complement homeserver
# is reachable only at a private Docker network address, which axon's media
# SSRF guard otherwise always blocks — see config/runtime.exs and
# AxonFederation.AddressGuard.
export FEDERATION_ALLOW_PRIVATE_ADDRESSES=true

# Complement's Synapse-compat harness mints its admin/test accounts through
# POST /_synapse/admin/v1/register, MACed with the shared secret its own
# homeserver config hardcodes to "complement". That value used to be a
# compiled-in literal in axon itself; it now comes from the environment and
# the endpoint is simply absent when unset, so Complement has to set it here.
export REGISTRATION_SHARED_SECRET=complement

# Fixed path Complement copies one Synapse-style registration YAML into
# per application service configured on this homeserver in the blueprint
# (present even if the blueprint defines none — the directory just won't
# exist then, which AxonWeb.AppService.Manager tolerates the same way it
# tolerates a missing appservices.json).
export AXON_APPSERVICE_DIR=/complement/appservice

# Complement talks to the federation port over real TLS (accepting any
# self-signed cert, so this alone would be enough for Complement's own
# federation.Server client — see config/runtime.exs). But server-to-server
# federation *between two Complement-spawned homeservers* (e.g. hs1 calling
# out to hs2) goes through axon's own outbound Finch client, which validates
# certs against a normal trust store and would reject a bare self-signed
# cert. Complement mounts a shared CA at /complement/ca/{ca.crt,ca.key} into
# every homeserver container for exactly this: sign this server's cert with
# it, and (via FEDERATION_TLS_CA_FILE below) tell axon's outbound client to
# trust that same CA, so any two Complement homeservers — both signed by it
# — validate each other normally instead of needing to skip verification.
mkdir -p /tmp/federation-tls
openssl req -newkey rsa:2048 -nodes \
  -keyout /tmp/federation-tls/key.pem -out /tmp/federation-tls/csr.pem \
  -subj "/CN=${SERVER_NAME}" \
  -addext "subjectAltName=DNS:${SERVER_NAME}" 2>/dev/null
openssl x509 -req -in /tmp/federation-tls/csr.pem -days 1 \
  -CA /complement/ca/ca.crt -CAkey /complement/ca/ca.key -CAcreateserial \
  -out /tmp/federation-tls/cert.pem \
  -copy_extensions copy 2>/dev/null
export FEDERATION_TLS_CERT_FILE=/tmp/federation-tls/cert.pem
export FEDERATION_TLS_KEY_FILE=/tmp/federation-tls/key.pem
export FEDERATION_TLS_CA_FILE=/complement/ca/ca.crt

# Run DB migrations
/axon/bin/axon eval "AxonCore.Release.migrate()"

# Start Axon
exec /axon/bin/axon start
