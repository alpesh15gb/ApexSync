import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../database.dart';

/// One change as a device sent it.
class PushedChange {
  const PushedChange({
    required this.changeId,
    required this.entity,
    required this.entityId,
    required this.operation,
    this.payload,
    this.createdAt,
  });

  /// The device's own outbox id — the idempotency key.
  final String changeId;

  /// App table name: `sales_invoices`, `payments`, `items`, ...
  final String entity;

  final String entityId;

  /// insert | update | delete.
  final String operation;

  /// The row as the device had it, or null when the row is gone.
  final Map<String, Object?>? payload;

  /// The device's timestamp. Null when the device did not record one.
  final DateTime? createdAt;
}

/// One change as a device should apply it.
class JournaledChange {
  const JournaledChange({
    required this.seq,
    required this.changeId,
    required this.entity,
    required this.entityId,
    required this.operation,
    this.payload,
    this.createdAt,
  });

  /// Position in the firm's journal. The pull cursor: a device stores the
  /// highest [seq] it has applied and asks for everything after it.
  final int seq;

  /// The origin device's outbox id — also how a device recognises its own
  /// change coming back to it.
  final String changeId;

  /// App table name: `sales_invoices`, `payments`, `items`, ...
  final String entity;

  final String entityId;

  /// insert | update | delete.
  final String operation;

  /// The row as the origin device had it, or null when the row was gone.
  final Map<String, Object?>? payload;

  /// The origin device's timestamp. Null when it did not record one.
  final DateTime? createdAt;

  Map<String, Object?> toJson() => {
        'seq': seq,
        'id': changeId,
        'entity': entity,
        'entityId': entityId,
        'operation': operation,
        'payload': payload,
        'createdAt': createdAt?.toIso8601String(),
      };
}

/// The answer to one pull page.
class PullResult {
  const PullResult({required this.changes, required this.hasMore});

  /// The page, ordered by [JournaledChange.seq] ascending.
  final List<JournaledChange> changes;

  /// True when [changes] filled the page, so another pull should follow.
  /// Decided by fetching limit+1 and dropping the extra, so a change landing
  /// between the page and the check cannot flip this wrongly.
  final bool hasMore;

  Map<String, Object?> toJson() => {
        'changes': [for (final c in changes) c.toJson()],
        'hasMore': hasMore,
      };
}

/// What happened to a batch.
class PushResult {
  const PushResult({required this.received, required this.duplicates});

  /// Changes newly journalled by this push.
  final int received;

  /// Changes already in the journal. Not an error: a device that retried a
  /// batch after a timeout is doing exactly the right thing, and telling it
  /// otherwise would make it retry for ever.
  final int duplicates;

  Map<String, Object?> toJson() => {
        'received': received,
        'duplicates': duplicates,
      };
}

/// Writes pushed changes into `firm_changes`.
///
/// The table is append-only by design (see `db/migrations/0003_firm_changes.sql`):
/// nothing here updates or deletes a row, so a push can never destroy data on
/// the server, and a later merge can be computed from the journal instead of
/// guessed from the current state. That is what makes it safe to ship the push
/// half before the merge half exists.
class SyncRepository {
  SyncRepository(this._db);

  final Database _db;

  /// Journals [changes] for [firmId] as [userId].
  ///
  /// Runs inside [Database.asUser], so `app_is_firm_member(firm_id)` decides
  /// whether this lands: a caller who is not a member of the firm inserts
  /// nothing and gets zero rows back. That is the same answer as an empty
  /// batch, which is deliberate — a push must not become a way to discover
  /// whether somebody else's firm id exists.
  Future<PushResult> pushChanges({
    required String userId,
    required String firmId,
    required List<PushedChange> changes,
    String? deviceId,
  }) async {
    if (changes.isEmpty) {
      return const PushResult(received: 0, duplicates: 0);
    }

    return _db.asUser(userId, (session) async {
      // One statement for the whole batch. A per-change round trip would make a
      // 200-change push 200 network waits, and the batch is already capped by
      // the request body limit.
      //
      // `unnest` of five parallel arrays rather than `jsonb_to_recordset`:
      // the payload is the only structured column, and keeping it as a
      // parameter per row means Postgres stores exactly the JSON the device
      // sent, with no second parse that could disagree with Dart's.
      final result = await session.execute(
        Sql.named('''
          INSERT INTO firm_changes (
            change_id, firm_id, entity, entity_id, operation, payload,
            device_id, created_at
          )
          SELECT
            c.change_id,
            @firmId::text,
            c.entity,
            c.entity_id,
            c.operation,
            c.payload,
            @deviceId::text,
            c.created_at
          FROM unnest(
            @changeIds::text[],
            @entities::text[],
            @entityIds::text[],
            @operations::text[],
            @payloads::jsonb[],
            @createdAts::timestamptz[]
          ) AS c(change_id, entity, entity_id, operation, payload, created_at)
          ON CONFLICT (change_id) DO NOTHING
          RETURNING change_id
        '''),
        parameters: {
          'firmId': firmId,
          'deviceId': deviceId,
          'changeIds': [for (final c in changes) c.changeId],
          'entities': [for (final c in changes) c.entity],
          'entityIds': [for (final c in changes) c.entityId],
          'operations': [for (final c in changes) c.operation],
          'payloads': [
            for (final c in changes)
              c.payload == null ? null : jsonEncode(c.payload),
          ],
          'createdAts': [for (final c in changes) c.createdAt],
        },
      );

      final received = result.length;
      return PushResult(
        received: received,
        duplicates: changes.length - received,
      );
    });
  }

  /// Reads the firm's journal from [afterSeq], oldest first, at most [limit]
  /// rows plus one so the caller learns whether more exist.
  ///
  /// Runs inside [Database.asUser] like the push: row-level security decides
  /// what this caller may read, so a non-member's pull is indistinguishable
  /// from a firm with an empty journal — the same no-enumeration rule the push
  /// and the firm routes follow.
  ///
  /// [afterSeq] is validated as a non-negative integer before this method, so
  /// the comparison stays an integer comparison rather than a cast the planner
  /// could get wrong.
  Future<PullResult> pullChanges({
    required String userId,
    required String firmId,
    required int afterSeq,
    int limit = maxChangesPerPull,
  }) async {
    if (limit < 1 || limit > maxChangesPerPull) {
      throw RangeError.range(limit, 1, maxChangesPerPull, 'limit');
    }

    return _db.asUser(userId, (session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT seq, change_id, entity, entity_id, operation, payload,
                 created_at
          FROM firm_changes
          WHERE firm_id = @firmId AND seq > @afterSeq
          ORDER BY seq ASC
          LIMIT @limit
        '''),
        parameters: {
          'firmId': firmId,
          'afterSeq': afterSeq,
          // One extra row tells us hasMore without a second query.
          'limit': limit + 1,
        },
      );

      final rows = result.map((r) => r.toColumnMap()).toList();
      final hasMore = rows.length > limit;
      if (hasMore) rows.removeLast();

      return PullResult(
        changes: [
          for (final row in rows)
            JournaledChange(
              seq: (row['seq'] as int).toInt(),
              changeId: row['change_id'] as String,
              entity: row['entity'] as String,
              entityId: row['entity_id'] as String,
              operation: row['operation'] as String,
              payload: row['payload'] == null
                  ? null
                  : (row['payload'] as Map).cast<String, Object?>(),
              createdAt: row['created_at'] is DateTime
                  ? (row['created_at'] as DateTime).toUtc()
                  : null,
            ),
        ],
        hasMore: hasMore,
      );
    });
  }
}

/// The largest batch one pull may return. Matches the push cap: one round trip
/// moves the same amount of data either way.
const int maxChangesPerPull = 500;
