import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_repository.dart';
import '../auth/credentials.dart';
import '../auth/refresh_tokens.dart';
import '../auth/token_issuer.dart';
import '../config.dart';
import '../errors.dart';
import '../http/json.dart';

void addAuthRoutes(
  Router router, {
  required AuthRepository repository,
  required TokenIssuer issuer,
  required RefreshTokenFactory refreshTokens,
  required Config config,
}) {
  /// Issues an access token and a *new* refresh token for a device.
  ///
  /// Every session is device-scoped, so "sign out my old phone" is a real
  /// operation rather than a password change that kicks everything.
  Future<Map<String, Object?>> issueSession({
    required String userId,
    required String email,
    required String deviceId,
    String? deviceName,
    String? platform,
  }) async {
    await repository.recordDevice(
      userId: userId,
      deviceId: deviceId,
      name: deviceName,
      platform: platform,
    );

    final refreshToken = refreshTokens.generate();
    await repository.storeRefreshToken(
      userId: userId,
      deviceId: deviceId,
      token: refreshToken,
      expiresAt: DateTime.now().toUtc().add(config.refreshTokenTtl),
    );

    return {
      'accessToken': issuer.issue(userId: userId, deviceId: deviceId),
      'refreshToken': refreshToken,
      'tokenType': 'Bearer',
      'expiresIn': config.accessTokenTtl.inSeconds,
      'user': {'id': userId, 'email': email},
    };
  }

  router.post('/v1/auth/signup', (Request request) async {
    final body = await readJsonObject(
      request,
      maxBytes: config.maxRequestBodyBytes,
    );
    final email = requiredString(body, 'email', maxLength: 254);
    final password = requiredString(body, 'password', maxLength: 128);
    final deviceId = requiredString(body, 'deviceId', maxLength: 64);

    validateEmail(email);
    validatePassword(password);

    final account = await repository.createAccount(
      email: email,
      password: password,
    );

    return jsonResponse(
      await issueSession(
        userId: account.id,
        email: account.email,
        deviceId: deviceId,
        deviceName: optionalString(body, 'deviceName', maxLength: 120),
        platform: optionalString(body, 'platform', maxLength: 40),
      ),
      status: 201,
    );
  });

  router.post('/v1/auth/login', (Request request) async {
    final body = await readJsonObject(
      request,
      maxBytes: config.maxRequestBodyBytes,
    );
    final email = requiredString(body, 'email', maxLength: 254);
    final password = requiredString(body, 'password', maxLength: 128);
    final deviceId = requiredString(body, 'deviceId', maxLength: 64);

    // Note: signup's email/password *rules* are deliberately not re-applied
    // here. Rejecting a login with "that password is too short" would confirm
    // the account exists, and would also lock out any account created under an
    // older rule.
    final account = await repository.verifyCredentials(
      email: email,
      password: password,
    );
    if (account == null) {
      // One message for both causes. "No such account" versus "wrong password"
      // is a customer-list disclosure.
      throw const ApiException.unauthorized('Email or password is incorrect.');
    }

    return jsonResponse(
      await issueSession(
        userId: account.id,
        email: account.email,
        deviceId: deviceId,
        deviceName: optionalString(body, 'deviceName', maxLength: 120),
        platform: optionalString(body, 'platform', maxLength: 40),
      ),
    );
  });

  router.post('/v1/auth/refresh', (Request request) async {
    final body = await readJsonObject(
      request,
      maxBytes: config.maxRequestBodyBytes,
    );
    final presented = requiredString(body, 'refreshToken', maxLength: 200);

    final replacement = refreshTokens.generate();
    final rotated = await repository.rotateRefreshToken(
      presented: presented,
      replacement: replacement,
      replacementExpiresAt: DateTime.now().toUtc().add(config.refreshTokenTtl),
    );

    return jsonResponse({
      'accessToken': issuer.issue(
        userId: rotated.userId,
        deviceId: rotated.deviceId,
      ),
      'refreshToken': replacement,
      'tokenType': 'Bearer',
      'expiresIn': config.accessTokenTtl.inSeconds,
    });
  });

  router.post('/v1/auth/logout', (Request request) async {
    final body = await readJsonObject(
      request,
      maxBytes: config.maxRequestBodyBytes,
    );
    final token = requiredString(body, 'refreshToken', maxLength: 200);
    await repository.revokeRefreshToken(token);
    return jsonResponse({'revoked': true});
  });
}
