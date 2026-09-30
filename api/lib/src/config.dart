import 'dart:io';

/// Thrown at boot when the environment is missing or unsafe.
///
/// We fail fast on purpose: a server that silently starts with a default JWT
/// secret, or with the database password blank, is worse than one that refuses
/// to start. Every problem found is reported at once rather than one per
/// restart, because restarting into the next error is a miserable way to
/// deploy.
class ConfigException implements Exception {
  ConfigException(this.problems);

  final List<String> problems;

  @override
  String toString() =>
      'Invalid configuration:\n${problems.map((p) => '  - $p').join('\n')}';
}

/// Configuration, read once from the environment at process start.
class Config {
  const Config({
    required this.databaseUrl,
    required this.jwtSecret,
    required this.jwtIssuer,
    required this.accessTokenTtl,
    required this.refreshTokenTtl,
    required this.apiPort,
    required this.publicBaseUrl,
    required this.logLevel,
    required this.maxRequestBodyBytes,
    required this.version,
  });

  /// Full `postgresql://` URL, assembled here so a password containing `/`,
  /// `+`, `=` or `@` (all of which `openssl rand -base64` produces) is
  /// percent-encoded correctly instead of silently corrupting the URL.
  final String databaseUrl;

  final String jwtSecret;
  final String jwtIssuer;
  final Duration accessTokenTtl;
  final Duration refreshTokenTtl;
  final int apiPort;
  final String publicBaseUrl;
  final String logLevel;
  final int maxRequestBodyBytes;
  final String version;

  bool get isDebug => logLevel == 'debug';

  static Config fromEnvironment([Map<String, String>? environment]) =>
      Config.fromMap(environment ?? Platform.environment);

  factory Config.fromMap(Map<String, String> env) {
    final problems = <String>[];

    String? optional(String key) {
      final value = env[key]?.trim();
      return (value == null || value.isEmpty) ? null : value;
    }

    String required(String key) {
      final value = optional(key);
      if (value == null) problems.add('$key is not set');
      return value ?? '';
    }

    int integer(String key, int fallback) {
      final raw = optional(key);
      if (raw == null) return fallback;
      final parsed = int.tryParse(raw);
      if (parsed == null) {
        problems.add('$key must be a whole number, got "$raw"');
        return fallback;
      }
      return parsed;
    }

    Duration duration(String key, Duration fallback) {
      final raw = optional(key);
      if (raw == null) return fallback;
      final parsed = _parseDuration(raw);
      if (parsed == null) {
        problems.add(
          '$key must look like 30s, 15m, 24h or 30d, got "$raw"',
        );
        return fallback;
      }
      return parsed;
    }

    final dbHost = required('ATRIA_DB_HOST');
    final dbPort = integer('ATRIA_DB_PORT', 5432);
    final dbName = required('ATRIA_DB_NAME');
    final dbUser = required('ATRIA_DB_USER');
    final dbPassword = required('ATRIA_DB_PASSWORD');
    final sslMode = optional('ATRIA_DB_SSLMODE') ?? 'disable';

    final jwtSecret = required('ATRIA_JWT_SECRET');
    if (jwtSecret.isNotEmpty && jwtSecret.length < 32) {
      problems.add(
        'ATRIA_JWT_SECRET must be at least 32 characters — generate one with '
        '`openssl rand -base64 48`',
      );
    }

    final apiPort = integer('ATRIA_API_PORT', 8080);
    if (apiPort < 1 || apiPort > 65535) {
      problems.add('ATRIA_API_PORT must be between 1 and 65535, got $apiPort');
    }

    final publicBaseUrl = optional('ATRIA_PUBLIC_BASE_URL') ?? '';
    if (publicBaseUrl.isNotEmpty && !publicBaseUrl.startsWith('http')) {
      problems.add('ATRIA_PUBLIC_BASE_URL must start with http:// or https://');
    }

    final logLevel = (optional('ATRIA_LOG_LEVEL') ?? 'info').toLowerCase();
    const knownLevels = {'debug', 'info', 'warn', 'error'};
    if (!knownLevels.contains(logLevel)) {
      problems.add(
        'ATRIA_LOG_LEVEL must be one of ${knownLevels.join(', ')}, got "$logLevel"',
      );
    }

    // Every remaining value is validated into a local *before* the check below.
    // Reading them inside the `Config(...)` argument list instead would put the
    // throw before the validation and quietly turn those checks into dead code.
    final jwtIssuer = optional('ATRIA_JWT_ISSUER') ?? 'api.apexbooks.in';
    final accessTokenTtl =
        duration('ATRIA_ACCESS_TOKEN_TTL', const Duration(minutes: 15));
    final refreshTokenTtl =
        duration('ATRIA_REFRESH_TOKEN_TTL', const Duration(days: 30));
    final maxRequestBodyBytes = integer('ATRIA_MAX_BODY_BYTES', 256 * 1024);
    final version = optional('ATRIA_VERSION') ?? '0.1.0';

    if (maxRequestBodyBytes < 1024) {
      problems.add('ATRIA_MAX_BODY_BYTES must be at least 1024, got $maxRequestBodyBytes');
    }

    if (problems.isEmpty) {
      // Fail on an unreachable-looking URL too, rather than at the first query.
      problems.addAll(
        _validateDatabaseUrl(dbHost, dbPort, dbName, dbUser, sslMode),
      );
    }

    if (problems.isNotEmpty) throw ConfigException(problems);

    return Config(
      databaseUrl: _databaseUrl(
        host: dbHost,
        port: dbPort,
        database: dbName,
        username: dbUser,
        password: dbPassword,
        sslMode: sslMode,
      ),
      jwtSecret: jwtSecret,
      jwtIssuer: jwtIssuer,
      accessTokenTtl: accessTokenTtl,
      refreshTokenTtl: refreshTokenTtl,
      apiPort: apiPort,
      publicBaseUrl: publicBaseUrl,
      logLevel: logLevel,
      maxRequestBodyBytes: maxRequestBodyBytes,
      version: version,
    );
  }

  static List<String> _validateDatabaseUrl(
    String host,
    int port,
    String database,
    String user,
    String sslMode,
  ) {
    final problems = <String>[];
    if (host.isEmpty) problems.add('ATRIA_DB_HOST is not set');
    if (database.isEmpty) problems.add('ATRIA_DB_NAME is not set');
    if (user.isEmpty) problems.add('ATRIA_DB_USER is not set');
    if (port < 1 || port > 65535) {
      problems.add('ATRIA_DB_PORT must be between 1 and 65535, got $port');
    }
    const knownSslModes = {'disable', 'require', 'verify-ca', 'verify-full'};
    if (!knownSslModes.contains(sslMode)) {
      problems.add(
        'ATRIA_DB_SSLMODE must be one of ${knownSslModes.join(', ')}, got "$sslMode"',
      );
    }
    return problems;
  }

  static String _databaseUrl({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
    required String sslMode,
  }) {
    return Uri(
      scheme: 'postgresql',
      // The `Uri` constructor validates components rather than encoding them,
      // and throws on characters that are legal in a password (`/`, `@`, `#`,
      // `?`) but not in user-info. Encoding each half here — note the colon we
      // add ourselves stays a literal separator — is what keeps a generated
      // password from corrupting the URL or crashing boot.
      userInfo:
          '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}',
      host: host,
      port: port,
      path: '/$database',
      queryParameters: {
        'sslmode': sslMode,
        'application_name': 'atria_api',
        'connect_timeout': '5',
        'query_timeout': '15',
        'max_connection_count': '8',
      },
    ).toString();
  }

  /// Accepts `30s`, `15m`, `24h`, `30d`, or a bare number of seconds.
  static Duration? _parseDuration(String raw) {
    final match = RegExp(r'^(\d+)([smhd]?)$').firstMatch(raw);
    if (match == null) return null;
    final value = int.parse(match.group(1)!);
    if (value == 0) return null;
    return switch (match.group(2)) {
      'm' => Duration(minutes: value),
      'h' => Duration(hours: value),
      'd' => Duration(days: value),
      's' => Duration(seconds: value),
      _ => Duration(seconds: value),
    };
  }
}
