import 'dart:convert';

import 'package:atria_api/src/app.dart';
import 'package:atria_api/src/auth/token_issuer.dart';
import 'package:atria_api/src/database.dart';
import 'package:atria_api/src/errors.dart';
import 'package:atria_api/src/http/middleware.dart';
import 'package:atria_api/src/log.dart';
import 'package:atria_api/src/routes/health_routes.dart';
import 'package:atria_api/src/routes/sync_routes.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Handler handler;

  setUpAll(() {
    final config = testConfig();
    // Constructing a Pool does not connect; `testConfig` points at port 1 on
    // loopback, so any test that does reach for the database fails instantly
    // instead of hanging. That is what makes the database-down tests below
    // meaningful rather than slow.
    handler = buildHandler(
      config: config,
      database: Database(Pool.withUrl(config.databaseUrl)),
      logger: silentLogger(),
    );
  });

  Future<Response> send(
    String method,
    String path, {
    Map<String, String>? headers,
    String? body,
  }) async {
    return await handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: headers,
        body: body,
      ),
    );
  }

  Future<Map<String, Object?>> bodyOf(Response response) async =>
      (jsonDecode(await response.readAsString()) as Map).cast<String, Object?>();

  group('public routes', () {
    test('GET / identifies the service', () async {
      final response = await send('GET', '/');
      expect(response.statusCode, 200);
      expect((await bodyOf(response))['service'], 'atria-api');
    });

    test('GET /health answers without the database', () async {
      // The whole point: liveness must not depend on Postgres, or an outage
      // would make Docker restart a healthy container.
      final response = await send('GET', '/health');
      expect(response.statusCode, 200);
      final body = await bodyOf(response);
      expect(body['status'], 'ok');
      expect(body['uptimeSeconds'], isA<int>());
    });

    test('GET /ready reports 503 when the database is unreachable', () async {
      final response = await send('GET', '/ready');
      expect(response.statusCode, 503);
      final body = await bodyOf(response);
      expect(body['status'], 'degraded');
      expect(
        (body['checks'] as Map)['database'],
        'unreachable',
      );
    });

    test('an unknown path is a JSON 404, not shelf plain text', () async {
      final response = await send('GET', '/nope');
      expect(response.statusCode, 404);
      expect(response.headers['content-type'], contains('application/json'));
      final body = await bodyOf(response);
      expect((body['error'] as Map)['code'], 'not_found');
    });
  });

  group('request ids', () {
    test('echoes a client-supplied request id', () async {
      final response = await send(
        'GET',
        '/health',
        headers: {'x-request-id': 'trace-abc'},
      );
      expect(response.headers['x-request-id'], 'trace-abc');
    });

    test('generates one when the client does not supply it', () async {
      final response = await send('GET', '/health');
      expect(response.headers['x-request-id'], isNotEmpty);
    });
  });

  group('authentication', () {
    test('GET /v1/me without a token is a 401 in our error shape', () async {
      final response = await send('GET', '/v1/me');
      expect(response.statusCode, 401);
      final body = await bodyOf(response);
      expect((body['error'] as Map)['code'], 'unauthorized');
    });

    test('rejects a non-Bearer Authorization header', () async {
      final response = await send(
        'GET',
        '/v1/me',
        headers: {'authorization': 'Basic dXNlcjpwYXNz'},
      );
      expect(response.statusCode, 401);
    });

    test('rejects a token that we did not sign', () async {
      final forged = const TokenIssuer(
        secret: 'some-other-secret-value-that-is-long-enough',
        issuer: 'api.apexbooks.in',
        ttl: Duration(minutes: 15),
      ).issue(userId: 'attacker');

      final response = await send(
        'GET',
        '/v1/me',
        headers: {'authorization': 'Bearer $forged'},
      );
      expect(response.statusCode, 401);
    });

    test('a protected route with a valid token reaches the database', () async {
      // The database is unreachable in this test, so the assertion is that it
      // got past authentication and failed *there* — a 500, not a 401.
      final token = TokenIssuer(
        secret: testConfig().jwtSecret,
        issuer: 'api.apexbooks.in',
        ttl: const Duration(minutes: 15),
      ).issue(userId: 'user-1');

      final response = await send(
        'GET',
        '/v1/me',
        headers: {'authorization': 'Bearer $token'},
      );
      expect(response.statusCode, 500);
    });
  });

  group('firm erasure', () {
    const firmId = '018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b';
    late String token;

    setUpAll(() {
      token = TokenIssuer(
        secret: testConfig().jwtSecret,
        issuer: 'api.apexbooks.in',
        ttl: const Duration(minutes: 15),
      ).issue(userId: 'user-1');
    });

    Map<String, String> auth() => {'authorization': 'Bearer $token'};

    test('erasing without a token is a JSON 401', () async {
      final response = await send('DELETE', '/v1/firms/$firmId');
      expect(response.statusCode, 401);
      expect(
        ((await bodyOf(response))['error'] as Map)['code'],
        'unauthorized',
      );
    });

    test('a token we did not sign cannot erase anything', () async {
      final forged = const TokenIssuer(
        secret: 'some-other-secret-value-that-is-long-enough',
        issuer: 'api.apexbooks.in',
        ttl: Duration(minutes: 15),
      ).issue(userId: 'attacker');

      final response = await send(
        'DELETE',
        '/v1/firms/$firmId',
        headers: {'authorization': 'Bearer $forged'},
      );
      expect(response.statusCode, 401);
    });

    test('a malformed firm id is a 400 before any database work', () async {
      final response = await send(
        'DELETE',
        '/v1/firms/not-a-uuid',
        headers: auth(),
      );
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('firmId'),
      );
    });

    test('a valid erase request reaches the database', () async {
      // The database is unreachable here, so a 500 is the assertion that
      // matters: the request got past authentication *and* id validation and
      // failed where the real work happens. A 200 would mean the route
      // claimed to have erased something without a database.
      final response = await send(
        'DELETE',
        '/v1/firms/$firmId',
        headers: auth(),
      );
      expect(response.statusCode, 500);
    });

    test('an id with a trailing segment is a plain 404', () async {
      final response = await send(
        'DELETE',
        '/v1/firms/$firmId/extra',
        headers: auth(),
      );
      expect(response.statusCode, 404);
    });
  });

  group('change push', () {
    const firmId = '018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b';
    late String token;

    setUpAll(() {
      token = TokenIssuer(
        secret: testConfig().jwtSecret,
        issuer: 'api.apexbooks.in',
        ttl: const Duration(minutes: 15),
      ).issue(userId: 'user-1', deviceId: 'device-1');
    });

    Map<String, String> auth() => {'authorization': 'Bearer $token'};

    Future<Response> push(Object? changes) => send(
          'POST',
          '/v1/firms/$firmId/changes',
          headers: auth(),
          body: jsonEncode({'changes': changes}),
        );

    test('pushing without a token is a JSON 401', () async {
      final response = await send(
        'POST',
        '/v1/firms/$firmId/changes',
        body: jsonEncode({'changes': []}),
      );
      expect(response.statusCode, 401);
    });

    test('a malformed firm id is a 400 before any database work', () async {
      final response = await send(
        'POST',
        '/v1/firms/not-a-uuid/changes',
        headers: auth(),
        body: jsonEncode({'changes': []}),
      );
      expect(response.statusCode, 400);
    });

    test('an empty push is a success, not an error', () async {
      // A device with nothing queued. Answering 400 here would make an idle
      // client look broken, and it needs no database to know that.
      final response = await push(const []);
      expect(response.statusCode, 200);
      final body = await bodyOf(response);
      expect(body['received'], 0);
      expect(body['duplicates'], 0);
    });

    test('changes must be a list', () async {
      final response = await send(
        'POST',
        '/v1/firms/$firmId/changes',
        headers: auth(),
        body: jsonEncode({'changes': 'everything'}),
      );
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('must be a list'),
      );
    });

    test('an unknown operation is refused, naming the entry', () async {
      final response = await push([
        {
          'id': 'change-1',
          'entity': 'sales_invoices',
          'entityId': 'inv-1',
          'operation': 'upsert',
        },
      ]);
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('changes[0].operation'),
      );
    });

    test('an entity that is not a table name is refused', () async {
      final response = await push([
        {
          'id': 'change-1',
          'entity': 'sales_invoices; DROP TABLE firms',
          'entityId': 'inv-1',
          'operation': 'insert',
        },
      ]);
      expect(response.statusCode, 400);
    });

    test('a batch bigger than the cap is refused with the count', () async {
      final many = List.generate(
        maxChangesPerPush + 1,
        (i) => {
          'id': 'change-$i',
          'entity': 'sales_invoices',
          'entityId': 'inv-$i',
          'operation': 'insert',
        },
      );
      final response = await push(many);
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('${maxChangesPerPush + 1}'),
      );
    });

    test('a well-formed change reaches the database', () async {
      // The database is unreachable in this test, so a 500 is the assertion
      // that matters: the batch got past authentication and validation and
      // failed where the write happens. A 200 would mean the route claimed to
      // have journalled something with nothing behind it.
      final response = await push([
        {
          'id': 'change-1',
          'entity': 'sales_invoices',
          'entityId': 'inv-1',
          'operation': 'insert',
          'payload': {'id': 'inv-1', 'grandTotal': 1332.22},
          'createdAt': '2026-09-30T10:00:00Z',
        },
      ]);
      expect(response.statusCode, 500);
    });
  });

  group('request validation', () {
    test('a missing body is rejected before any database work', () async {
      final response = await send('POST', '/v1/auth/login');
      expect(response.statusCode, 400);
      final body = await bodyOf(response);
      expect((body['error'] as Map)['code'], 'bad_request');
    });

    test('invalid JSON is rejected with a readable message', () async {
      final response = await send(
        'POST',
        '/v1/auth/login',
        body: '{"email": ',
      );
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('not valid JSON'),
      );
    });

    test('a JSON array body is rejected', () async {
      final response = await send('POST', '/v1/auth/login', body: '[]');
      expect(response.statusCode, 400);
    });

    test('names the missing field', () async {
      final response = await send(
        'POST',
        '/v1/auth/login',
        body: jsonEncode({'email': 'owner@apexbooks.in'}),
      );
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('password'),
      );
    });

    test('rejects a bad email before touching the database', () async {
      final response = await send(
        'POST',
        '/v1/auth/signup',
        body: jsonEncode({
          'email': 'owner',
          'password': 'longenough',
          'deviceId': 'device-1',
        }),
      );
      expect(response.statusCode, 400);
      expect(
        ((await bodyOf(response))['error'] as Map)['message'],
        contains('valid email'),
      );
    });

    test('rejects an oversized body without buffering it', () async {
      final response = await send(
        'POST',
        '/v1/auth/login',
        body: jsonEncode({'email': 'a' * 300000}),
      );
      expect(response.statusCode, 400);
    });
  });

  group('readiness states', () {
    // Driven directly, so all three states are deterministic and instant — the
    // real database is only ever reachable in one of them from a test.
    Future<Map<String, Object?>> readyWith(DatabaseHealth health) async {
      final router = Router();
      addHealthRoutes(
        router,
        check: () async => health,
        startedAt: DateTime.now(),
        version: 'test',
      );
      final response = await router.call(
        Request('GET', Uri.parse('http://localhost/ready')),
      );
      expect(
        response.statusCode,
        health == DatabaseHealth.ready ? 200 : 503,
      );
      return (jsonDecode(await response.readAsString()) as Map)
          .cast<String, Object?>();
    }

    test('a healthy, migrated database is ready', () async {
      expect((await readyWith(DatabaseHealth.ready))['status'], 'ready');
    });

    test('an unreachable database is degraded', () async {
      final body = await readyWith(DatabaseHealth.unreachable);
      expect(body['status'], 'degraded');
      expect((body['checks'] as Map)['database'], 'unreachable');
    });

    test('a reachable but un-migrated database says so specifically', () async {
      // Regression: a connectivity-only probe reported this state as healthy,
      // so a container whose migrations never ran looked fine while every
      // request it served would fail.
      final body = await readyWith(DatabaseHealth.schemaMissing);
      expect(body['status'], 'degraded');
      expect((body['checks'] as Map)['database'], 'schema_missing');
    });
  });

  group('error containment', () {
    test('an unhandled exception becomes a generic 500 with no internals',
        () async {
      final logged = <String>[];
      final logger = Logger(level: LogLevel.error, sink: logged.add);

      const connectionString = 'postgresql://atria:hunter2@db:5432/atria';
      final leaky = Pipeline()
          .addMiddleware(jsonErrors(logger))
          .addHandler((request) => throw StateError('connect to $connectionString'));

      final response = await leaky(Request('GET', Uri.parse('http://localhost/x')));
      expect(response.statusCode, 500);

      final raw = await response.readAsString();
      expect(raw, isNot(contains('hunter2')));
      expect(raw, isNot(contains('postgresql')));
      expect(raw, contains('internal_error'));

      // But it *is* in the log, where an operator needs it.
      expect(logged.single, contains(connectionString));
    });

    test('an ApiException keeps its own status and message', () async {
      final pipeline = Pipeline()
          .addMiddleware(jsonErrors(silentLogger()))
          .addHandler(
            (request) => throw const ApiException.conflict('Already exists.'),
          );

      final response =
          await pipeline(Request('GET', Uri.parse('http://localhost/x')));
      expect(response.statusCode, 409);
      expect(
        ((await bodyOf(response))['error'] as Map)['code'],
        'conflict',
      );
    });
  });
}
