import 'package:atria_api/src/config.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('Config', () {
    test('accepts a complete environment and applies defaults', () {
      final config = testConfig();

      expect(config.jwtIssuer, 'api.apexbooks.in');
      expect(config.apiPort, 8080);
      expect(config.accessTokenTtl, const Duration(minutes: 15));
      expect(config.refreshTokenTtl, const Duration(days: 30));
      expect(config.logLevel, 'info');
      expect(config.isDebug, isFalse);
    });

    test('reports every missing variable at once, not one per restart', () {
      expect(
        () => Config.fromMap({'ATRIA_JWT_SECRET': 'a' * 48}),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.problems.join(' '),
            'problems',
            allOf(
              contains('ATRIA_DB_HOST'),
              contains('ATRIA_DB_NAME'),
              contains('ATRIA_DB_USER'),
              contains('ATRIA_DB_PASSWORD'),
            ),
          ),
        ),
      );
    });

    test('rejects a JWT secret that is too short to be worth anything', () {
      expect(
        () => testConfig(overrides: {'ATRIA_JWT_SECRET': 'secret'}),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.problems.single,
            'problem',
            allOf(contains('ATRIA_JWT_SECRET'), contains('32')),
          ),
        ),
      );
    });

    test('rejects a non-numeric and an out-of-range port', () {
      expect(
        () => testConfig(overrides: {'ATRIA_API_PORT': 'http'}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => testConfig(overrides: {'ATRIA_API_PORT': '70000'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects an unknown log level rather than silently defaulting', () {
      expect(
        () => testConfig(overrides: {'ATRIA_LOG_LEVEL': 'chatty'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('parses duration suffixes', () {
      expect(
        testConfig(overrides: {'ATRIA_ACCESS_TOKEN_TTL': '90s'})
            .accessTokenTtl,
        const Duration(seconds: 90),
      );
      expect(
        testConfig(overrides: {'ATRIA_ACCESS_TOKEN_TTL': '45m'})
            .accessTokenTtl,
        const Duration(minutes: 45),
      );
      expect(
        testConfig(overrides: {'ATRIA_REFRESH_TOKEN_TTL': '90d'})
            .refreshTokenTtl,
        const Duration(days: 90),
      );
      expect(
        testConfig(overrides: {'ATRIA_ACCESS_TOKEN_TTL': '900'})
            .accessTokenTtl,
        const Duration(seconds: 900),
      );
      expect(
        () => testConfig(overrides: {'ATRIA_ACCESS_TOKEN_TTL': '15 minutes'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a nonsense body limit instead of ignoring it', () {
      // Regression: the duration and body-size checks used to run inside the
      // Config(...) argument list, after the throw — so a typo here silently
      // fell back to the default. The test asserts the check is live.
      expect(
        () => testConfig(overrides: {'ATRIA_MAX_BODY_BYTES': 'a lot'}),
        throwsA(
          isA<ConfigException>().having(
            (error) => error.problems.single,
            'problem',
            contains('ATRIA_MAX_BODY_BYTES'),
          ),
        ),
      );
      expect(
        () => testConfig(overrides: {'ATRIA_MAX_BODY_BYTES': '10'}),
        throwsA(isA<ConfigException>()),
      );
      expect(testConfig().maxRequestBodyBytes, 256 * 1024);
    });

    test('percent-encodes a database password containing URL delimiters', () {
      // `openssl rand -base64 48` routinely produces these characters. Building
      // the URL by string concatenation would silently truncate the password
      // and produce a baffling "password authentication failed".
      const password = 'a/b+c=d@e:f?g#h';
      final config = testConfig(overrides: {'ATRIA_DB_PASSWORD': password});

      final uri = Uri.parse(config.databaseUrl);
      expect(uri.scheme, 'postgresql');
      expect(uri.host, '127.0.0.1');
      expect(uri.path, '/atria');
      expect(uri.userInfo, startsWith('atria_api:'));
      expect(
        Uri.decodeComponent(uri.userInfo.split(':').sublist(1).join(':')),
        password,
      );
    });

    test('carries the pool and timeout settings in the URL', () {
      final uri = Uri.parse(testConfig().databaseUrl);
      expect(uri.queryParameters['sslmode'], 'disable');
      expect(uri.queryParameters['max_connection_count'], '8');
      expect(uri.queryParameters['application_name'], 'atria_api');
      expect(uri.queryParameters['connect_timeout'], '5');
    });

    test('rejects an unknown sslmode', () {
      expect(
        () => testConfig(overrides: {'ATRIA_DB_SSLMODE': 'trust-me'}),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
