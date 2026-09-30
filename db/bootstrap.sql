-- Runs once, as the superuser, on an empty data directory (see init/01-init.sh).
-- Creates the extensions and the application role. It deliberately creates no
-- tables: those belong to migrations, so there is exactly one place where the
-- schema is defined.
--
-- Variables supplied by psql -v: app_user, app_password, db_name.

-- crypt()/gen_salt() hash passwords and digest() hashes refresh tokens. Both
-- happen in Postgres on purpose, so no password or token is ever hashed by our
-- own code and no plaintext reaches a table, a query log or a pg_dump.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- The application role.
--
-- Deliberately NOT the owner of any table. A table's owner bypasses row-level
-- security, so an app role that owned the tables would make every policy in
-- migrations/0001_identity.sql decorative. Migrations run as the superuser and
-- grant this role only what it needs.
-- ---------------------------------------------------------------------------
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_password')
\gexec

SELECT format(
  'ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT', :'app_user'
)
\gexec

-- Bound the damage a bug in the API can do to the whole server. Without these,
-- one missing WHERE clause holds a transaction open indefinitely and fills the
-- disk with WAL.
SELECT format('ALTER ROLE %I SET statement_timeout = %L', :'app_user', '15s')
\gexec
SELECT format(
  'ALTER ROLE %I SET idle_in_transaction_session_timeout = %L', :'app_user', '30s'
)
\gexec

GRANT CONNECT ON DATABASE :"db_name" TO :"app_user";
GRANT USAGE ON SCHEMA public TO :"app_user";

-- Privileges for objects created later by the migrations. Migrations also grant
-- explicitly, so this is a safety net rather than the mechanism.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_user";
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO :"app_user";
