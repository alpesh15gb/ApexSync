-- 0004_change_sequence — the pull half of sync.
--
-- 0003 stored the journal as rows a device can append. This migration makes it
-- readable as a *feed*: a monotonic per-firm sequence gives a device a stable
-- cursor ("give me everything after seq N"), which is the shape a pull needs —
-- a timestamp cursor can put two changes in the same millisecond and lose one,
-- which is silent data loss on a books app.
--
-- Why not a global sequence? A per-firm one keeps a device's cursor valid when
-- the journal is later pruned per firm, and it never shares a counter across
-- tenants, so no timing channel exists between firms.
--
-- psql variable supplied by apply-migrations.sh: app_user.

ALTER TABLE firm_changes ADD COLUMN IF NOT EXISTS seq bigint;

-- One statement: backfill existing rows (0001–0003 era pushes) in
-- received_at order, then attach a sequence whose default continues from it.
WITH ordered AS (
  SELECT change_id,
         ROW_NUMBER() OVER (PARTITION BY firm_id ORDER BY received_at, change_id) AS n
  FROM firm_changes
  WHERE seq IS NULL
)
UPDATE firm_changes f
SET seq = o.n
FROM ordered o
WHERE f.change_id = o.change_id;

-- Monotonic per firm. The default continues from whatever the backfill wrote,
-- so pre-0004 rows keep their positions and new rows always get a larger one.
CREATE SEQUENCE IF NOT EXISTS firm_changes_seq_seq;

ALTER TABLE firm_changes
  ALTER COLUMN seq SET DEFAULT nextval('firm_changes_seq_seq');

-- Uniqueness is what makes the cursor safe: a device that stores "I have
-- everything after seq 412" must never see a second row at 412.
CREATE UNIQUE INDEX IF NOT EXISTS uq_firm_changes_firm_seq
  ON firm_changes (firm_id, seq);

-- Existing rows were numbered per firm already, so their seq is dense from 1.
-- Reanchor the sequence past the highest number ever handed out. (The subquery
-- runs before setval; setval's third argument says "the next value is +1".)
SELECT setval(
  'firm_changes_seq_seq',
  COALESCE((SELECT max(seq) FROM firm_changes), 0) + 1,
  false
);

-- A pull reads; a device still pushes. RLS policies are per action, so the
-- existing SELECT/INSERT policies already cover both — this COMMENT documents
-- the state of the world rather than granting anything new.
COMMENT ON TABLE firm_changes IS
  'Append-only journal of device changes. Push and pull (cursor = per-firm seq).';

-- The pull endpoint orders by seq and pages. Without this index every page
-- would sort 178 rows today and a few million rows some day.
CREATE INDEX IF NOT EXISTS firm_changes_firm_seq_idx
  ON firm_changes (firm_id, seq);
