import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../database.dart';
import '../http/json.dart';

/// Liveness and readiness, kept deliberately separate.
///
/// [/health] answers "is the process running" and never touches the database: if
/// it did, a database outage would make Docker restart a perfectly healthy API
/// container, turning one problem into two.
///
/// [/ready] answers "can this instance actually serve" and does touch the
/// database — including a check that the schema is present. Monitoring and any
/// future load balancer should use this one.
///
/// The check is a parameter rather than a `Database` so it can be driven
/// directly in tests, with no connection to fake.
void addHealthRoutes(
  Router router, {
  required Future<DatabaseHealth> Function() check,
  required DateTime startedAt,
  required String version,
}) {
  router.get(
    '/health',
    (Request request) => jsonResponse({
      'status': 'ok',
      'version': version,
      'uptimeSeconds': DateTime.now().difference(startedAt).inSeconds,
    }),
  );

  router.get(
    '/ready',
    (Request request) async {
      final health = await check();
      final databaseLabel = switch (health) {
        DatabaseHealth.ready => 'ok',
        DatabaseHealth.unreachable => 'unreachable',
        // Reported distinctly so the alert says "run the migrations" instead of
        // "the database is down", which sends you looking in the wrong place.
        DatabaseHealth.schemaMissing => 'schema_missing',
      };
      return jsonResponse(
        {
          'status': health == DatabaseHealth.ready ? 'ready' : 'degraded',
          'checks': {'database': databaseLabel},
        },
        status: health == DatabaseHealth.ready ? 200 : 503,
      );
    },
  );
}
