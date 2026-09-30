#!/bin/sh
# Applies db/migrations/*.sql in filename order, each exactly once, recording
# every applied file in schema_migrations.
#
# Runs in two places:
#   * by init/01-init.sh on a brand-new data directory, and
#   * afterwards, via:  docker compose --profile tools run --rm migrate
#
# Connect details come from the standard libpq variables (PGHOST, PGDATABASE,
# PGUSER, PGPASSWORD) so this works both inside the Postgres image and from a
# throwaway container.
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${ATRIA_DB_USER:?ATRIA_DB_USER is required}"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/db/migrations}"

psql -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

applied=0
for file in "$MIGRATIONS_DIR"/*.sql; do
  [ -e "$file" ] || continue
  version=$(basename "$file")

  # Note the interpolated '$version' rather than psql's `:'version'`. psql only
  # performs variable substitution for input it parses itself (here-documents
  # and -f files); a -c string is sent to the server verbatim, so `:'version'`
  # reaches Postgres as a syntax error at the colon. The value is a filename we
  # control, produced by basename, so interpolating it here is safe.
  already=$(psql -tA \
    -c "SELECT 1 FROM schema_migrations WHERE version = '$version'")

  if [ "$already" = "1" ]; then
    echo "  skip   $version"
    continue
  fi

  echo "  apply  $version"
  # The file and the bookkeeping INSERT run in *one* transaction, so it is not
  # possible to end up with a migration that took effect but was never recorded
  # — which would re-run on the next deploy and fail on an already-existing
  # table.
  # The -f file is parsed by psql, so `:'app_user'` inside it substitutes
  # correctly; only the -c bookkeeping statement needs the shell to interpolate.
  psql -v ON_ERROR_STOP=1 \
    -v app_user="$ATRIA_DB_USER" \
    --single-transaction \
    -f "$file" \
    -c "INSERT INTO schema_migrations (version) VALUES ('$version')"

  applied=$((applied + 1))
done

echo "atria-migrate: $applied migration(s) applied"
