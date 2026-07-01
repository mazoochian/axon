#!/bin/bash
set -e

# Complement passes SERVER_NAME env var
SERVER_NAME="${SERVER_NAME:-localhost}"

# PostgreSQL 17 binary path on Debian
PG_BIN="/usr/lib/postgresql/17/bin"
export PGDATA=/var/lib/postgresql/17/data
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
