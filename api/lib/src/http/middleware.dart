import 'dart:math';

import 'package:shelf/shelf.dart';

import '../auth/token_issuer.dart';
import '../errors.dart';
import '../log.dart';
import 'json.dart';

const String _principalKey = 'atria.principal';
const String _requestIdKey = 'atria.requestId';

/// The authenticated caller, or null on a public route.
AuthPrincipal? principalOf(Request request) =>
    request.context[_principalKey] as AuthPrincipal?;

String requestIdOf(Request request) =>
    request.context[_requestIdKey] as String? ?? '-';

/// The authenticated principal, or a 401.
///
/// Reaching the null branch means a protected handler was registered without
/// the `authenticate` middleware — a wiring bug. Failing closed there is the
/// difference between a missing guard and an open endpoint.
AuthPrincipal requirePrincipal(Request request) {
  final principal = principalOf(request);
  if (principal == null) {
    throw const ApiException.unauthorized('Authentication is required.');
  }
  return principal;
}

/// Stamps every request and response with an id, so a user reporting a problem
/// and a line in the log can be connected. A client-supplied id is honoured
/// (useful for tracing a retry) but length-capped, because it ends up in logs.
Middleware requestId({Random? random}) {
  final source = random ?? Random();
  return (inner) => (request) async {
    final provided = request.headers['x-request-id']?.trim();
    final id = (provided != null && provided.isNotEmpty && provided.length <= 64)
        ? provided
        : _newId(source);
    final response = await inner(request.change(context: {_requestIdKey: id}));
    return response.change(headers: {'x-request-id': id});
  };
}

Middleware requestLogger(Logger logger) => (inner) => (request) async {
      final stopwatch = Stopwatch()..start();
      final response = await inner(request);
      stopwatch.stop();

      final fields = <String, Object?>{
        'requestId': requestIdOf(request),
        'method': request.method,
        'path': '/${request.url.path}',
        'status': response.statusCode,
        'durationMs': stopwatch.elapsedMilliseconds,
        // nginx sets X-Forwarded-For; the first entry is the real client.
        // This is personal data under the DPDP Act — see the retention note in
        // server/README.md, and keep the log rotation in docker-compose.yml.
        'ip': _clientIp(request),
      };

      // Log 5xx as errors and 4xx as warnings: a burst of 401s is a real signal
      // (expired tokens, or someone guessing passwords) and should be findable
      // without also matching every successful request.
      if (response.statusCode >= 500) {
        logger.error('request', fields);
      } else if (response.statusCode >= 400) {
        logger.warn('request', fields);
      } else {
        logger.info('request', fields);
      }
      return response;
    };

/// Turns exceptions into the one client-visible error shape.
///
/// This must sit *outside* everything that can throw — including the
/// authentication middleware, whose whole job is to throw — or the default
/// shelf behaviour leaks a stack trace into the response.
Middleware jsonErrors(Logger logger) => (inner) => (request) async {
      try {
        return await inner(request);
      } on ApiException catch (error) {
        return errorResponse(error);
      } catch (error, stackTrace) {
        logger.error('unhandled_exception', {
          'requestId': requestIdOf(request),
          'method': request.method,
          'path': '/${request.url.path}',
          'error': error.toString(),
          // Logged, never returned. A client that receives `error.toString()`
          // is being told about our schema.
          'stack': stackTrace.toString(),
        });
        return errorResponse(
          const ApiException(
            500,
            'internal_error',
            'Something went wrong on our side.',
          ),
        );
      }
    };

/// Requires `Authorization: Bearer <access token>` and puts the verified
/// principal in the request context.
Middleware authenticate(TokenIssuer issuer) => (inner) => (request) {
      final header = request.headers['authorization'];
      if (header == null || header.trim().isEmpty) {
        throw const ApiException.unauthorized(
          'An `Authorization: Bearer <token>` header is required.',
        );
      }
      final parts = header.split(' ');
      if (parts.length != 2 || parts.first.toLowerCase() != 'bearer') {
        throw const ApiException.unauthorized(
          'Authorization header must be `Bearer <token>`.',
        );
      }
      final principal = issuer.verify(parts[1].trim());
      return inner(request.change(context: {_principalKey: principal}));
    };

String _clientIp(Request request) {
  final forwarded = request.headers['x-forwarded-for'];
  if (forwarded != null && forwarded.isNotEmpty) {
    return forwarded.split(',').first.trim();
  }
  return '-';
}

String _newId(Random random) {
  final suffix = List<int>.generate(6, (_) => random.nextInt(256))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$suffix';
}
