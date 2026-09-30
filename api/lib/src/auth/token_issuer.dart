import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import '../errors.dart';

/// The authenticated caller, reconstructed from a verified access token.
class AuthPrincipal {
  const AuthPrincipal({required this.userId, this.deviceId});

  final String userId;
  final String? deviceId;

  Map<String, Object?> toJson() => {
        'userId': userId,
        if (deviceId != null) 'deviceId': deviceId,
      };
}

/// Issues and verifies short-lived HS256 access tokens.
///
/// HS256 (a shared secret) rather than RS256 + a JWKS endpoint because nothing
/// outside this process verifies our tokens today. If PowerSync is added later
/// it needs to verify our JWTs itself, and it can be pointed straight at this
/// secret (`client_auth.supabase_jwt_secret` in its config) without changing
/// the issuer at all. Moving to RS256 is then a contained change to this file
/// plus a JWKS route.
class TokenIssuer {
  const TokenIssuer({
    required this.secret,
    required this.issuer,
    required this.ttl,
  });

  final String secret;
  final String issuer;
  final Duration ttl;

  String issue({required String userId, String? deviceId}) {
    final token = JWT(
      {
        'sub': userId,
        if (deviceId != null) 'dev': deviceId,
      },
      issuer: issuer,
    );
    return token.sign(SecretKey(secret), expiresIn: ttl);
  }

  /// Verifies signature, expiry and issuer. Throws [ApiException] 401 for
  /// anything that cannot be trusted — never returns a partial principal.
  AuthPrincipal verify(String token) {
    final JWT jwt;
    try {
      jwt = JWT.verify(token, SecretKey(secret));
    } on JWTExpiredException {
      throw const ApiException.unauthorized('Access token has expired.');
    } on JWTException catch (error) {
      throw ApiException.unauthorized(
        'Access token is not valid: ${error.message}',
      );
    } on FormatException {
      // A string that is not three dot-separated base64url segments at all.
      throw const ApiException.unauthorized('Access token is not valid.');
    }

    final Object? rawPayload = jwt.payload;
    if (rawPayload is! Map) {
      throw const ApiException.unauthorized('Access token payload is malformed.');
    }
    final Map<Object?, Object?> payload = rawPayload.cast<Object?, Object?>();

    if (payload['iss'] != issuer) {
      throw const ApiException.unauthorized(
        'Access token was issued for a different service.',
      );
    }

    final Object? subject = payload['sub'];
    if (subject is! String || subject.isEmpty) {
      throw const ApiException.unauthorized('Access token has no subject.');
    }

    final Object? device = payload['dev'];
    return AuthPrincipal(
      userId: subject,
      deviceId: device is String && device.isNotEmpty ? device : null,
    );
  }
}
