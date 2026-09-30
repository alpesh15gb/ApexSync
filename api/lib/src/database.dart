import 'package:postgres/postgres.dart';

import 'config.dart';

/// The three states `/ready` can be in.
///
/// `schemaMissing` exists as its own state rather than collapsing into
/// "unreachable" because the fix is different and the person reading the alert
/// needs to know which one they have: one is `docker compose up`, the other is
/// `docker compose --profile tools run --rm migrate`.
enum DatabaseHealth { ready, unreachable, schemaMissing }

/// The connection pool, plus the request-scoped transaction helper that makes
/// row-level security work.
class Database {
  Database(this.pool);

  /// The type parameter on [Pool] is the optional endpoint-locality hint used
  /// by `Pool.withSelector` (for routing to a replica, say). We use a fixed
  /// single endpoint, so it carries no information here.
  final Pool<Object?> pool;

  factory Database.connect(Config config) =>
      Database(Pool.withUrl(config.databaseUrl));

  /// Readiness probe. Never throws: the caller's only question is which of the
  /// three states we are in.
  ///
  /// It checks the *schema*, not just `SELECT 1`. A connectivity-only probe
  /// reports a perfectly healthy service that cannot serve a single request,
  /// because migrations have not run — which happens on the first deploy of a
  /// new version and after restoring a database from before the new tables
  /// existed. Learning that from `/ready` beats learning it from the first
  /// 500 in production.
  Future<DatabaseHealth> check({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final result = await pool.execute(
        "SELECT to_regclass('public.app_users') IS NOT NULL AS users_table, "
        "to_regclass('public.firms') IS NOT NULL AS firms_table, "
        "to_regclass('public.firm_members') IS NOT NULL AS members_table, "
        // 0002. Probed too, because a database sitting at 0001 serves most of
        // the API perfectly well while failing every firm create and erase
        // with a missing-relation 500 — the worst kind of half-migrated.
        // The trailing comma stays *inside* the literal: these are adjacent
        // string literals, and a real comma between them would end the
        // expression and pass the second one as a positional argument.
        "to_regclass('public.app_firm_purges') IS NOT NULL AS purges_table, "
        // 0003. Same reasoning: without it every device push fails with a
        // missing-relation 500 while the rest of the API looks healthy.
        "to_regclass('public.firm_changes') IS NOT NULL AS changes_table",
      ).timeout(timeout);

      final row = result.first.toColumnMap();
      final migrated = row['users_table'] == true &&
          row['firms_table'] == true &&
          row['members_table'] == true &&
          row['purges_table'] == true &&
          row['changes_table'] == true;
      return migrated ? DatabaseHealth.ready : DatabaseHealth.schemaMissing;
    } catch (_) {
      return DatabaseHealth.unreachable;
    }
  }

  /// Runs [body] inside a transaction with `app.user_id` set for its duration.
  ///
  /// The `true` third argument to `set_config` makes the setting
  /// *transaction-local*. That is what makes this safe on a pooled connection:
  /// the value cannot leak into whichever request picks the connection up next,
  /// which is the classic way a per-request "current user" becomes a
  /// cross-tenant data leak.
  Future<T> asUser<T>(
    String userId,
    Future<T> Function(TxSession session) body,
  ) {
    return pool.runTx((session) async {
      await session.execute(
        Sql.named("SELECT set_config('app.user_id', @userId, true)"),
        parameters: {'userId': userId},
      );
      return body(session);
    });
  }

  Future<void> close() => pool.close();
}
