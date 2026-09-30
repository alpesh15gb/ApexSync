/// An error that is safe to show a client.
///
/// Anything thrown that is *not* an [ApiException] is treated as an internal
/// failure and replaced with a generic 500, so a stack trace or a SQL fragment
/// can never reach a user. Keep every message here free of schema and
/// implementation detail.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  const ApiException.badRequest(this.message)
      : status = 400,
        code = 'bad_request';

  const ApiException.unauthorized(this.message)
      : status = 401,
        code = 'unauthorized';

  const ApiException.forbidden(this.message)
      : status = 403,
        code = 'forbidden';

  const ApiException.notFound(this.message)
      : status = 404,
        code = 'not_found';

  const ApiException.conflict(this.message)
      : status = 409,
        code = 'conflict';

  const ApiException.tooManyRequests(this.message)
      : status = 429,
        code = 'rate_limited';

  @override
  String toString() => 'ApiException($status $code): $message';
}
