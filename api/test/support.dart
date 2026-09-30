import 'package:atria_api/src/config.dart';
import 'package:atria_api/src/log.dart';

/// A valid environment, so each test overrides only the field it is about.
Map<String, String> validEnvironment({
  Map<String, String> overrides = const {},
}) =>
    {
      'ATRIA_DB_HOST': '127.0.0.1',
      // Port 1 on loopback: nothing listens there, so any test that does reach
      // for the database fails immediately instead of hanging.
      'ATRIA_DB_PORT': '1',
      'ATRIA_DB_NAME': 'atria',
      'ATRIA_DB_USER': 'atria_api',
      'ATRIA_DB_PASSWORD': 'test-password',
      'ATRIA_JWT_SECRET': 'a' * 48,
      ...overrides,
    };

Config testConfig({Map<String, String> overrides = const {}}) =>
    Config.fromMap(validEnvironment(overrides: overrides));

/// A logger that writes nowhere, so a passing test run stays quiet.
Logger silentLogger() => Logger(level: LogLevel.error, sink: (_) {});
