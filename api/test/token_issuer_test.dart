import 'package:atria_api/src/auth/token_issuer.dart';
import 'package:atria_api/src/errors.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:test/test.dart';

const String _secret = 'test-secret-that-is-long-enough-to-pass-config';

TokenIssuer issuerWith({String secret = _secret, Duration? ttl}) => TokenIssuer(
      secret: secret,
      issuer: 'api.apexbooks.in',
      ttl: ttl ?? const Duration(minutes: 15),
    );

void main() {
  group('TokenIssuer', () {
    test('round-trips the user and device', () {
      final issuer = issuerWith();
      final token = issuer.issue(userId: 'user-1', deviceId: 'phone-1');

      final principal = issuer.verify(token);
      expect(principal.userId, 'user-1');
      expect(principal.deviceId, 'phone-1');
    });

    test('tolerates a token without a device', () {
      final issuer = issuerWith();
      final principal = issuer.verify(issuer.issue(userId: 'user-1'));
      expect(principal.userId, 'user-1');
      expect(principal.deviceId, isNull);
    });

    test('carries the issuer and the subject as claims', () {
      final token = issuerWith().issue(userId: 'user-1');
      final decoded = JWT.decode(token);

      expect(decoded.issuer, 'api.apexbooks.in');
      expect(decoded.payload['sub'], 'user-1');
      expect(decoded.payload['exp'], isNotNull);
    });

    test('rejects a token signed with a different secret', () {
      final forged = issuerWith(secret: 'a-completely-different-secret-value-here')
          .issue(userId: 'attacker');

      expect(
        () => issuerWith().verify(forged),
        throwsA(
          isA<ApiException>().having((error) => error.status, 'status', 401),
        ),
      );
    });

    test('rejects a token issued for another service', () {
      const other = TokenIssuer(
        secret: _secret,
        issuer: 'sync.example.org',
        ttl: Duration(minutes: 15),
      );

      expect(
        () => issuerWith().verify(other.issue(userId: 'user-1')),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('different service'),
          ),
        ),
      );
    });

    test('rejects an expired token with a distinct message', () {
      // A negative lifetime puts `exp` in the past, which is deterministic —
      // unlike sleeping for a millisecond-long TTL and racing the clock.
      final expired = issuerWith(ttl: const Duration(seconds: -5))
          .issue(userId: 'user-1');

      expect(
        () => issuerWith().verify(expired),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('expired'),
          ),
        ),
      );
    });

    test('rejects malformed input without throwing anything else', () {
      final issuer = issuerWith();
      for (final token in ['', 'not-a-token', 'a.b', 'a.b.c', '....']) {
        expect(
          () => issuer.verify(token),
          throwsA(isA<ApiException>().having((error) => error.status, 'status', 401)),
          reason: 'token: "$token"',
        );
      }
    });
  });
}
