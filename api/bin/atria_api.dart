import 'dart:io';

import 'package:atria_api/src/app.dart';
import 'package:atria_api/src/config.dart';
import 'package:atria_api/src/database.dart';
import 'package:atria_api/src/log.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> main(List<String> arguments) async {
  final Config config;
  try {
    config = Config.fromEnvironment();
  } on ConfigException catch (error) {
    // Refuse to start rather than run with a missing secret. 78 is EX_CONFIG.
    stderr.writeln(error);
    exit(78);
  }

  final logger = Logger(level: Logger.parse(config.logLevel));
  final database = Database.connect(config);
  final handler = buildHandler(
    config: config,
    database: database,
    logger: logger,
  );

  final HttpServer server;
  try {
    // Binds all interfaces *inside* the container. Docker maps it to
    // 127.0.0.1 on the host, so it is not publicly reachable — host nginx is
    // the only thing that talks to it.
    server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      config.apiPort,
      // shelf advertises "Dart with package:shelf" on every response by default.
      // Announcing the runtime to the internet is free reconnaissance; nginx
      // does not strip it for us.
      poweredByHeader: null,
    );
  } on SocketException catch (error) {
    logger.error('cannot_bind', {
      'port': config.apiPort,
      'error': error.toString(),
    });
    exit(70);
  }
  server.autoCompress = true;

  logger.info('listening', {
    'port': config.apiPort,
    'version': config.version,
    'issuer': config.jwtIssuer,
    'publicBaseUrl': config.publicBaseUrl,
  });

  var shuttingDown = false;
  Future<void> shutdown(String signal) async {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info('shutting_down', {'signal': signal});
    // Stop accepting new work, let in-flight requests finish, then release the
    // pool. Without this a deploy cuts whatever is mid-flight.
    await server.close();
    await database.close();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown('SIGINT'));
  // Windows has no SIGTERM, but `docker stop` on the server sends it — which is
  // the case that actually matters.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown('SIGTERM'));
  }
}
