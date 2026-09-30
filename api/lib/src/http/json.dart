import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../errors.dart';

const Map<String, String> jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

Response jsonResponse(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body), headers: jsonHeaders);

/// Every error the client sees has the same shape, so the app has exactly one
/// failure path to write:
/// `{"error": {"code": "...", "message": "..."}}`.
Response errorResponse(ApiException error) => jsonResponse(
      {
        'error': {'code': error.code, 'message': error.message},
      },
      status: error.status,
    );

/// Reads a JSON object body, refusing an oversized one *before* buffering it.
///
/// `Content-Length` is checked first so a 50 MB body is rejected without being
/// read into memory; the limit is a config value
/// (`ATRIA_MAX_BODY_BYTES`) because a document push is a legitimate large body
/// whereas an auth request never is.
Future<Map<String, Object?>> readJsonObject(
  Request request, {
  required int maxBytes,
}) async {
  final declaredLength = request.contentLength;
  if (declaredLength != null && declaredLength > maxBytes) {
    throw ApiException.badRequest(
      'Request body must not exceed ${maxBytes ~/ 1024} KB.',
    );
  }

  final raw = await request.readAsString();
  if (raw.trim().isEmpty) {
    throw const ApiException.badRequest('A JSON body is required.');
  }

  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const ApiException.badRequest('Request body is not valid JSON.');
  }

  if (decoded is! Map) {
    throw const ApiException.badRequest('Request body must be a JSON object.');
  }
  return decoded.cast<String, Object?>();
}

/// Reads a required non-empty string field.
String requiredString(
  Map<String, Object?> body,
  String field, {
  int maxLength = 320,
}) {
  final value = body[field];
  if (value is! String || value.trim().isEmpty) {
    throw ApiException.badRequest('"$field" is required.');
  }
  final trimmed = value.trim();
  if (trimmed.length > maxLength) {
    throw ApiException.badRequest(
      '"$field" must be at most $maxLength characters.',
    );
  }
  return trimmed;
}

String? optionalString(
  Map<String, Object?> body,
  String field, {
  int maxLength = 320,
}) {
  final value = body[field];
  if (value == null) return null;
  if (value is! String) {
    throw ApiException.badRequest('"$field" must be a string.');
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > maxLength) {
    throw ApiException.badRequest(
      '"$field" must be at most $maxLength characters.',
    );
  }
  return trimmed;
}
