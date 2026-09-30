-- 0002_firm_purges — the erasure ledger.
--
-- Deleting a firm has to be a deletion, not a flag. DPDP Rule 8 requires
-- erasure to actually erase, and a tombstone is not an erasure (audit/07 §9).
-- So `DELETE /v1/firms/{id}` removes the `firms` row and, through
-- `ON DELETE CASCADE`, its `firm_members` rows — outright.
--
-- What survives is this table, and only this: that a firm id was erased, when,
-- and by which account. It holds no name, no GSTIN, no customer, no books.
-- It exists for two reasons, and both of them are about correctness rather
-- than bookkeeping:
--
--   1. **A stale device must not undo the erase.** A device that was offline
--      when the deletion happened still holds the firm locally and will push
--      it back on its next sync. `app_firm_purges` is what lets
--      `POST /v1/firms` refuse that push. Firm ids are UUID v7 minted by the
--      client, so an id is never legitimately reused — refusing one costs
--      nothing and is the only thing that makes the erasure stick.
--   2. **Accountability for a deletion request.** "We removed it on <date> for
--      <account>" is answerable from one row, without keeping any of the data
--      the deletion was about.
--
-- Scope: identity/tenancy only. This is deliberately NOT a books tombstone —
-- the books tables do not exist yet (see 0001's header).
--
-- psql variable supplied by apply-migrations.sh: app_user.

CREATE TABLE app_firm_purges (
  firm_id   text PRIMARY KEY,
  -- Who asked for the erasure. Nullable because the account may itself be
  -- deleted later; the purged firm id is what must survive, not the actor.
  purged_by uuid REFERENCES app_users(id) ON DELETE SET NULL,
  purged_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE app_firm_purges IS
  'Append-only ledger of erased firm ids: that a firm was deleted, when, and by whom. Never any firm data — see the 0002 header.';

-- No row-level security here, for the same reason the identity tables have
-- none (0001): no client reads this table, the API is its only reader and
-- writer, and the two queries it runs are a lookup by the exact id being
-- created and an insert on erase. The app role still needs explicit grants,
-- because it is not the owner.
--
-- Written with `format`/`\gexec` exactly as 0001 does, rather than psql's
-- `:"app_user"` identifier interpolation, so both files are exercised through
-- the same quoting path the runner has already been proven with.
SELECT format(
  'GRANT SELECT, INSERT ON TABLE %I TO %I', t, :'app_user'
)
FROM unnest(ARRAY['app_firm_purges']) AS t
\gexec

-- The lookup in `createFirm` is by primary key, so no extra index is needed.
