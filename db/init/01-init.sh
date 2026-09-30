#!/bin/sh
# Runs once, by the official Postgres image, on an *empty* data directory.
#
# Everything here is idempotent-ish by design, but it will not run again on an
# existing volume — that is what db/apply-migrations.sh is for. This is the
# reason a new migration must never be tested by recreating the container
# without also recreating the volume: you would silently get the old schema.
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${ATRIA_DB_USER:?ATRIA_DB_USER is required}"
: "${ATRIA_DB_PASSWORD:?ATRIA_DB_PASSWORD is required}"

echo 'atria-init: creating extensions and the application role'
psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  -v app_user="$ATRIA_DB_USER" \
  -v app_password="$ATRIA_DB_PASSWORD" \
  -v db_name="$POSTGRES_DB" \
  -f /db/bootstrap.sql

echo 'atria-init: applying migrations'

# The Postgres image does not export the libpq variables, and during init it
# starts the server with `listen_addresses=''` — so a TCP connection to
# localhost would fail and the unix socket is the only route. apply-migrations.sh
# reads PGHOST/PGDATABASE/PGUSER, so set them explicitly rather than relying on
# psql's defaults, which differ between Debian and Alpine images.
export PGHOST=/var/run/postgresql
export PGDATABASE="$POSTGRES_DB"
export PGUSER="$POSTGRES_USER"
export PGPASSWORD="$POSTGRES_PASSWORD"

# Invoked through `sh` rather than executed directly: a bind mount from Windows
# does not preserve the execute bit, and a permission error at first boot is a
# miserable way to find that out.
sh /db/apply-migrations.sh
