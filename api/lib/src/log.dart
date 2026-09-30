import 'dart:convert';
import 'dart:io';

enum LogLevel { debug, info, warn, error }

/// One JSON object per line on stdout.
///
/// Deliberately not a logging framework: this writes what `docker logs`, `jq`
/// and any log shipper can read without a configuration file, and there is no
/// place for a secret to hide in a format string.
class Logger {
  Logger({required LogLevel level, void Function(String line)? sink})
      : _level = level,
        _sink = sink ?? stdout.writeln;

  final LogLevel _level;
  final void Function(String line) _sink;

  bool isEnabled(LogLevel level) => level.index >= _level.index;

  void debug(String message, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.debug, message, fields);
  void info(String message, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.info, message, fields);
  void warn(String message, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.warn, message, fields);
  void error(String message, [Map<String, Object?> fields = const {}]) =>
      _write(LogLevel.error, message, fields);

  void _write(LogLevel level, String message, Map<String, Object?> fields) {
    if (!isEnabled(level)) return;
    _sink(
      jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'level': level.name,
        'msg': message,
        ...fields,
      }),
    );
  }

  static LogLevel parse(String value) => switch (value) {
        'debug' => LogLevel.debug,
        'warn' => LogLevel.warn,
        'error' => LogLevel.error,
        _ => LogLevel.info,
      };
}
