-- 0001_identity — identity, tenancy and sessions.
--
-- Table and column names deliberately mirror the drift tables in the Flutter app
-- (`lib/core/database/tables/`), which already use snake_case: `firm_id`,
-- `created_at`, `is_deleted`. Two reasons that matters:
--
--   1. The eventual sync engine moves rows between these two schemas by name.
--   2. If PowerSync is adopted later, it copies rows *verbatim* into the
--      client's SQLite file (audit/06 §3.1), so a name that differs here is
--      silent data loss there.
--
-- Scope: only the identity and tenancy slice. The books tables (invoices,
-- payments, stock movements) are deliberately NOT here yet. Which of their
-- columns are client-owned, server-owned, or derived-and-never-synced is the
-- open decision in audit/06 §5 step 1, and guessing it now would bake the wrong
-- answer into a migration that devices will already have applied.
--
-- psql variable supplied by apply-migrations.sh: app_user.

-- ---------------------------------------------------------------------------
-- Server-side identity. Never synced to devices.
-- ---------------------------------------------------------------------------
CREATE TABLE app_users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text NOT NULL,
  password_hash text NOT NULL,
  is_disabled   boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT app_users_email_key UNIQUE (email),
  -- Explicitly enforced rather than relying on every caller remembering to
  -- lower() the address: two rows differing only in case would be two accounts
  -- for one person.
  CONSTRAINT app_users_email_lowercase CHECK (email = lower(email))
);

COMMENT ON TABLE app_users IS
  'Sign-in identities. Server-only: no client ever reads another user''s row.';

CREATE TABLE devices (
  user_id      uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  device_id    text NOT NULL,
  name         text,
  platform     text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id)
);

COMMENT ON TABLE devices IS
  'One row per signed-in install, so a lost phone can be revoked on its own.';

CREATE TABLE refresh_tokens (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  device_id  text NOT NULL,
  -- SHA-256 of the token, computed by Postgres. The plaintext is never stored,
  -- so a dump of this table cannot be replayed as a session.
  token_hash text NOT NULL,
  issued_at  timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  CONSTRAINT refresh_tokens_hash_key UNIQUE (token_hash)
);

CREATE INDEX refresh_tokens_live_idx
  ON refresh_tokens (user_id)
  WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- Tenancy. These two ARE synced, and their shape matches the app's
-- firms / firm_members tables.
--
-- `id` is text rather than uuid because the client mints these ids itself
-- (`IdUtils.newId()` → UUID v7) and the client column is text. Requiring a
-- different type here would mean a conversion on every sync, which is exactly
-- the kind of impedance the client-generated-key design exists to avoid.
-- ---------------------------------------------------------------------------
CREATE TABLE firms (
  id         text PRIMARY KEY,
  name       text NOT NULL,
  gstin      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE firm_members (
  id         text PRIMARY KEY,
  firm_id    text NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
  name       text NOT NULL,
  email      text,
  role       text NOT NULL DEFAULT 'admin',
  -- `app_users.id` rendered as a uuid. Nullable for the same reason the app's
  -- column is: a local-only member exists before they have an account.
  user_id    uuid REFERENCES app_users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT firm_members_role_check
    CHECK (role IN ('admin', 'staff', 'accountant'))
);

CREATE INDEX firm_members_firm_idx ON firm_members (firm_id);
CREATE INDEX firm_members_user_idx ON firm_members (user_id);

-- ---------------------------------------------------------------------------
-- Row-level security.
--
-- Policies are attached to PUBLIC rather than to a named role, so changing
-- ATTRIA_DB_USER does not require rewriting every policy. The table owner (the
-- migrations role) still bypasses RLS — which is what lets the SECURITY DEFINER
-- function below establish a tenant in the first place.
-- ---------------------------------------------------------------------------
ALTER TABLE firms ENABLE ROW LEVEL SECURITY;
ALTER TABLE firm_members ENABLE ROW LEVEL SECURITY;

-- `current_setting(..., true)` returns NULL when unset, and any comparison with
-- NULL is NULL — which is not true — so a request that forgets to set
-- app.user_id is denied everything rather than allowed everything. Fail-closed
-- is the only acceptable default here.
CREATE FUNCTION app_current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

COMMENT ON FUNCTION app_current_user_id() IS
  'The caller identity for this transaction, set by the API with set_config(..., true).';

-- SECURITY DEFINER on purpose: the membership check has to read firm_members,
-- and a policy on firm_members that itself queries firm_members would recurse.
-- Postgres refuses that ("infinite recursion detected in policy"), so the check
-- lives in a definer function which reads the table as its owner and therefore
-- bypasses RLS. This is the standard fix, and the alternative — a permissive
-- policy — is how tenant isolation quietly stops existing.
CREATE FUNCTION app_is_firm_member(p_firm_id text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM firm_members m
    WHERE m.firm_id = p_firm_id
      AND m.user_id = app_current_user_id()
  )
$$;

CREATE FUNCTION app_is_firm_admin(p_firm_id text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM firm_members m
    WHERE m.firm_id = p_firm_id
      AND m.user_id = app_current_user_id()
      AND m.role = 'admin'
  )
$$;

CREATE POLICY firms_select_member ON firms
  FOR SELECT USING (app_is_firm_member(id));

CREATE POLICY firms_update_admin ON firms
  FOR UPDATE USING (app_is_firm_admin(id))
  WITH CHECK (app_is_firm_admin(id));

CREATE POLICY firms_delete_admin ON firms
  FOR DELETE USING (app_is_firm_admin(id));

CREATE POLICY firm_members_select_member ON firm_members
  FOR SELECT USING (app_is_firm_member(firm_id));

CREATE POLICY firm_members_write_admin ON firm_members
  FOR ALL USING (app_is_firm_admin(firm_id))
  WITH CHECK (app_is_firm_admin(firm_id));

-- Note there is deliberately no INSERT policy on `firms`, and no way for a user
-- to insert themselves into an arbitrary firm: a brand-new firm has no members,
-- so no membership-based policy could authorise creating it. Tenancy is
-- established only through app_create_firm below, which is the single
-- controlled entry point.

CREATE FUNCTION app_create_firm(
  p_user_id     uuid,
  p_firm_id     text,
  p_name        text,
  p_gstin       text,
  p_member_name text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Bind the action to the identity the request actually authenticated as, so
  -- the app role cannot create a firm *on behalf of* somebody else by passing a
  -- different parameter. If the API forgot to set app.user_id this fails closed.
  IF p_user_id IS DISTINCT FROM app_current_user_id() THEN
    RAISE EXCEPTION 'firm creation must be performed as the authenticated user'
      USING ERRCODE = '42501';
  END IF;

  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'firm name is required' USING ERRCODE = '22023';
  END IF;

  IF p_gstin IS NOT NULL AND p_gstin <> '' AND length(p_gstin) <> 15 THEN
    RAISE EXCEPTION 'GSTIN must be 15 characters' USING ERRCODE = '22023';
  END IF;

  INSERT INTO firms (id, name, gstin)
  VALUES (p_firm_id, btrim(p_name), NULLIF(btrim(p_gstin), ''));

  INSERT INTO firm_members (id, firm_id, name, role, user_id)
  VALUES (
    gen_random_uuid()::text,
    p_firm_id,
    btrim(p_member_name),
    'admin',
    p_user_id
  );
END;
$$;

COMMENT ON FUNCTION app_create_firm IS
  'The only way to create a tenant: creates the firm and the creator''s admin membership atomically.';

-- ---------------------------------------------------------------------------
-- Privileges. Explicit rather than relying on ALTER DEFAULT PRIVILEGES, so the
-- grant and the table are always read together.
-- ---------------------------------------------------------------------------
SELECT format(
  'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I TO %I', t, :'app_user'
)
FROM unnest(ARRAY['firms', 'firm_members']) AS t
\gexec

-- The identity tables have no RLS: no client ever touches them directly, the
-- API is the only reader and writer, and the queries it runs are the access
-- control. They still need explicit grants, because the app role is not their
-- owner.
SELECT format(
  'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I TO %I', t, :'app_user'
)
FROM unnest(ARRAY['app_users', 'devices', 'refresh_tokens']) AS t
\gexec

REVOKE ALL ON FUNCTION app_create_firm(uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app_is_firm_member(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app_is_firm_admin(text) FROM PUBLIC;

SELECT format('GRANT EXECUTE ON FUNCTION app_create_firm(uuid, text, text, text, text) TO %I', :'app_user')
\gexec
SELECT format('GRANT EXECUTE ON FUNCTION app_is_firm_member(text) TO %I', :'app_user')
\gexec
SELECT format('GRANT EXECUTE ON FUNCTION app_is_firm_admin(text) TO %I', :'app_user')
\gexec
