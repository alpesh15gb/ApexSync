-- 0003_firm_changes — the server-side journal of device changes.
--
-- Scope: the *push* half of sync. A device drains its local outbox
-- (`sync_queue` in the app) into this table and nothing more. There is
-- deliberately no merge or conflict resolution here yet: what a device's change
-- means for a row that another device also changed is the open question in
-- audit/06 §5, and answering it with a `last write wins` update today would bake
-- a wrong answer into rows that devices have already pushed.
--
-- Three properties make this safe to add before that question is answered:
--
--   1. It is append-only. No row is ever updated, so no device's data is
--      destroyed by a push, and any later merge can be computed from this
--      journal rather than guessed.
--   2. `change_id` is the client's own outbox id, so a retry after a timeout is
--      idempotent: the same change arriving twice is stored once.
--   3. `payload` is the row as the device had it (drift's `toJson` shape), so
--      the journal holds what was true at the time, not what the table says
--      now.
--
-- psql variable supplied by apply-migrations.sh: app_user.

CREATE TABLE firm_changes (
  -- The client mints this (`SyncQueue.id`), which is what makes a re-sent batch
  -- a no-op instead of a duplicate.
  change_id   text PRIMARY KEY,
  firm_id     text NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
  -- Table name in the app's schema: sales_invoices, payments, items, ...
  entity      text NOT NULL,
  entity_id   text NOT NULL,
  -- insert | update | delete. A delete is a tombstone in the journal, never a
  -- DELETE of the journal: a device that was offline still has to be told.
  operation   text NOT NULL,
  -- The row as the device had it, or NULL when the row is already gone.
  payload     jsonb,
  -- Which install pushed it, from the access token's `dev` claim. Nullable
  -- because a token issued without a device claim is still a valid session.
  device_id   text,
  -- The device's own timestamp, kept apart from received_at because a device
  -- with a wrong clock must not be able to reorder history.
  created_at  timestamptz,
  received_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT firm_changes_entity_check
    CHECK (entity ~ '^[a-z][a-z0-9_]{0,39}$'),
  CONSTRAINT firm_changes_operation_check
    CHECK (operation IN ('insert', 'update', 'delete'))
);

COMMENT ON TABLE firm_changes IS
  'Append-only journal of device changes. The push half of sync; merge is not implemented.';

-- The read pattern a future pull will have: everything for one firm, in the
-- order it arrived (a sequence would be more precise than a timestamp, and is
-- the obvious upgrade if two changes land in the same millisecond).
CREATE INDEX firm_changes_firm_received_idx
  ON firm_changes (firm_id, received_at);

CREATE INDEX firm_changes_entity_idx
  ON firm_changes (firm_id, entity, entity_id);

-- ---------------------------------------------------------------------------
-- Row-level security. Same shape as firms: a member of the firm may read and
-- write its rows, and nobody else can see that they exist.
--
-- There is no UPDATE or DELETE policy on purpose — an append-only journal with
-- an update policy is just a table. Erasure still works: the firm's cascade
-- takes its journal with it, which is what DPDP Rule 8 wants.
-- ---------------------------------------------------------------------------
ALTER TABLE firm_changes ENABLE ROW LEVEL SECURITY;

CREATE POLICY firm_changes_select_member ON firm_changes
  FOR SELECT USING (app_is_firm_member(firm_id));

CREATE POLICY firm_changes_insert_member ON firm_changes
  FOR INSERT WITH CHECK (app_is_firm_member(firm_id));

SELECT format(
  'GRANT SELECT, INSERT ON TABLE %I TO %I', 'firm_changes', :'app_user'
)
\gexec
