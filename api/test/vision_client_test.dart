import 'dart:convert';
import 'dart:io';

import 'package:atria_api/src/log.dart';
import 'package:atria_api/src/scan/vision_client.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A logger that keeps its lines, standing in for the container log: what a
/// test asserts here is what an operator would have read in
/// `docker compose logs api` after a failed scan.
class CapturedLog {
  final List<String> lines = [];

  Logger get logger => Logger(level: LogLevel.warn, sink: lines.add);

  List<Map<String, Object?>> get entries => lines
      .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
      .toList();
}

void main() {
  /// The image never matters to these tests - only that a request is made and
  /// its answer is interpreted. A JPEG magic number keeps it realistic.
  final image = <int>[0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(600, 0x11)];

  late HttpServer server;
  late CapturedLog log;
  late List<HttpRequest> seen;
  late String sentPayload;

  /// Starts a fake gateway on a real loopback socket, because the client's
  /// whole job is HTTP: a stubbed HttpClient would test the stub. Port 0 lets
  /// the OS pick, so parallel test runs cannot collide.
  Future<void> startGateway(int status, String body) async {
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      // Drain the request body first, or the client can see a connection
      // error instead of the response.
      sentPayload = await utf8.decoder.bind(request).join();
      seen.add(request);
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    });
  }

  VisionClient clientFor(int port, {CapturedLog? captured}) => VisionClient(
        testConfig(overrides: {
          'ATRIA_SCAN_API_URL': 'http://127.0.0.1:$port/v1',
          'ATRIA_SCAN_API_KEY': 'gateway-key',
          'ATRIA_SCAN_MODEL': 'gpt-4o-mini',
        }),
        logger: captured?.logger,
      );

  setUp(() {
    log = CapturedLog();
    sentPayload = '';
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('a healthy answer is parsed out of markdown fences', () async {
    await startGateway(
      200,
      jsonEncode({
        'choices': [
          {
            'message': {
              'content': '```json\n{"supplierName":"Sharma Traders"}\n```',
            },
          },
        ],
      }),
    );

    final bill = await clientFor(server.port).scanBill(
      imageBytes: image,
      mimeType: 'image/jpeg',
    );

    expect(bill.raw['supplierName'], 'Sharma Traders');
    // The base URL was normalised to the wire path, and the key travelled in
    // the header rather than the body: both are what a gateway will actually
    // accept.
    expect(seen.single.uri.path, '/v1/chat/completions');
    expect(seen.single.headers.value('authorization'), 'Bearer gateway-key');
    expect(sentPayload, contains('"model":"gpt-4o-mini"'));
  });

  test('a 502 from the gateway is a scan failure that logs why', () async {
    // This is the live shape observed from the deployment's gateway: it
    // accepts the key, then fails downstream and answers 502 with the reason
    // in its body. The app must get a named failure; the log must get the
    // reason, or every diagnosis is a guess.
    await startGateway(
      502,
      jsonEncode({
        'error': {'message': 'No active credentials for provider: openai.'},
      }),
    );

    await expectLater(
      clientFor(server.port, captured: log).scanBill(
        imageBytes: image,
        mimeType: 'image/jpeg',
      ),
      throwsA(
        isA<ScanException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.message, 'message', contains('HTTP 502')),
      ),
    );

    final entry = log.entries.single;
    expect(entry['msg'], 'scan_gateway_error');
    expect(entry['status'], 502);
    expect(entry['body'], contains('No active credentials for provider'));
    expect(entry['url'], endsWith('/v1/chat/completions'));
  });

  test('a rejected key names the server variable the operator must fix',
      () async {
    await startGateway(
      401,
      jsonEncode({
        'error': {'message': 'Invalid API key', 'code': 'invalid_api_key'},
      }),
    );

    await expectLater(
      clientFor(server.port, captured: log).scanBill(
        imageBytes: image,
        mimeType: 'image/jpeg',
      ),
      throwsA(
        isA<ScanException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.message, 'message', contains('ATRIA_SCAN_API_KEY')),
      ),
    );

    expect(log.entries.single['msg'], 'scan_gateway_rejected_key');
    expect(log.entries.single['body'], contains('Invalid API key'));
  });

  test('rate limiting keeps its own status so the app can say try again',
      () async {
    await startGateway(429, jsonEncode({'error': {'message': 'slow down'}}));

    await expectLater(
      clientFor(server.port, captured: log).scanBill(
        imageBytes: image,
        mimeType: 'image/jpeg',
      ),
      throwsA(
        isA<ScanException>().having((e) => e.statusCode, 'statusCode', 429),
      ),
    );

    expect(log.entries.single['msg'], 'scan_gateway_rate_limited');
  });

  test('an unreachable gateway says the server could not reach it', () async {
    // Bind and immediately release a port so the connection is refused rather
    // than left hanging: the point is the client's own failure path.
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = probe.port;
    await probe.close(force: true);

    await expectLater(
      clientFor(deadPort, captured: log).scanBill(
        imageBytes: image,
        mimeType: 'image/jpeg',
      ),
      throwsA(
        isA<ScanException>()
            .having((e) => e.message, 'message', contains('could not reach')),
      ),
    );

    expect(log.entries.single['msg'], 'scan_gateway_unreachable');
  });

  test('a photo that is not a bill is a 502 the person can act on', () async {
    await startGateway(
      200,
      jsonEncode({
        'choices': [
          {
            'message': {'content': '{"error":"not_a_bill"}'},
          },
        ],
      }),
    );

    await expectLater(
      clientFor(server.port).scanBill(
        imageBytes: image,
        mimeType: 'image/jpeg',
      ),
      throwsA(
        isA<ScanException>().having(
          (e) => e.message,
          'message',
          contains('does not look like a purchase bill'),
        ),
      ),
    );
  });
}
