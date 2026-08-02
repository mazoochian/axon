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

# Run DB migrations
/axon/bin/axon eval "AxonCore.Release.migrate()"

# Start Axon
exec /axon/bin/axon start
