import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/auth_repository.dart';
import 'auth/refresh_tokens.dart';
import 'auth/token_issuer.dart';
import 'config.dart';
import 'database.dart';
import 'errors.dart';
import 'http/json.dart';
import 'http/middleware.dart';
import 'log.dart';
import 'routes/auth_routes.dart';
import 'routes/firm_routes.dart';
import 'routes/health_routes.dart';
import 'routes/scan_routes.dart';
import 'routes/sync_routes.dart';
import 'sync/sync_repository.dart';

/// Assembles the whole HTTP surface.
///
/// Takes its dependencies rather than reaching for globals, so tests can build a
/// handler with a fake database and no network, and so the composition is
/// readable in one screen.
///
/// Every route is registered directly on one [Router]. Deliberately no
/// `Router.mount`: a mount takes ownership of its whole prefix, so a mounted
/// sub-router that answers 404 does *not* fall through to later routes — it
/// silently swallows every route registered after it.
Handler buildHandler({
  required Config config,
  required Database database,
  required Logger logger,
  DateTime? startedAt,
}) {
  final issuer = TokenIssuer(
    secret: config.jwtSecret,
    issuer: config.jwtIssuer,
    ttl: config.accessTokenTtl,
  );
  final repository = AuthRepository(database);
  final syncRepository = SyncRepository(database);
  final refreshTokens = RefreshTokenFactory();

  final router = Router();

  addHealthRoutes(
    router,
    check: database.check,
    startedAt: startedAt ?? DateTime.now(),
    version: config.version,
  );

  addAuthRoutes(
    router,
    repository: repository,
    issuer: issuer,
    refreshTokens: refreshTokens,
    config: config,
  );

  addProtectedRoutes(
    router,
    repository: repository,
    config: config,
    guard: authenticate(issuer),
  );

  addSyncRoutes(
    router,
    repository: syncRepository,
    config: config,
    guard: authenticate(issuer),
  );

  addScanRoutes(
    router,
    config: config,
    guard: authenticate(issuer),
    logger: logger,
  );

  router.get(
    '/',
    (Request request) => jsonResponse({
      'service': 'atria-api',
      'version': config.version,
      'issuer': config.jwtIssuer,
    }),
  );

  // Anything else, on any method, is our JSON 404 rather than shelf's default
  // plain-text body.
  router.all(
    '/<ignored|.*>',
    (Request request, String ignored) => errorResponse(
      const ApiException.notFound('No such endpoint.'),
    ),
  );

  return Pipeline()
      // Order matters. requestId is outermost so that even a failure inside the
      // error mapper has an id to log against; jsonErrors sits outside the logger
      // and the routes so nothing can escape as a stack trace.
      .addMiddleware(requestId())
      .addMiddleware(jsonErrors(logger))
      .addMiddleware(requestLogger(logger))
      .addHandler(router.call);
}
