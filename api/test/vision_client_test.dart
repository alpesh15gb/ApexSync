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
  /// the OS pick, so parallel test runs cannot collide. [sequence] scripts
  /// successive answers (the last repeats), which is how retry behaviour is
  /// exercised against the same wire protocol.
  Future<void> startGateway(
    int status,
    String body, {
    List<MapEntry<int, String>>? sequence,
  }) async {
    final script = sequence ?? [MapEntry(status, body)];
    var index = 0;
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      // Drain the request body first, or the client can see a connection
      // error instead of the response.
      sentPayload = await utf8.decoder.bind(request).join();
      seen.add(request);
      final step = script[index < script.length - 1 ? index : script.length - 1];
      index++;
      request.response.statusCode = step.key;
      request.response.headers.contentType = ContentType.json;
      request.response.write(step.value);
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

  test('a 502 on both attempts fails after exactly two requests', () async {
    // This is the live shape observed from the deployment's gateway: it
    // accepts the key, then fails downstream and answers 502 with the reason
    // in its body. The client retries once - the gateway's pools have flaky
    // providers - but a persistent failure must still surface as a named
    // error, with every attempt's reason in the log.
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

    expect(seen, hasLength(2));
    final msgs = log.entries.map((e) => e['msg']).toList();
    expect(msgs, ['scan_gateway_error', 'scan_retry', 'scan_gateway_error']);
    expect(log.entries.first['body'], contains('No active credentials for provider'));
    expect(log.entries.first['url'], endsWith('/v1/chat/completions'));
    expect(log.entries[1]['reason'], contains('HTTP 502'));
  });

  test('a transient 502 is retried once and the second answer wins', () async {
    const goodAnswer =
        '{"choices":[{"message":{"content":"{\\"supplierName\\":\\"Sharma Traders\\"}"}}]}';
    await startGateway(
      502,
      '',
      sequence: [
        const MapEntry(
          502,
          '{"error":{"message":"Cloudflare Playground browser session failed"}}',
        ),
        const MapEntry(200, goodAnswer),
      ],
    );

    final bill = await clientFor(server.port, captured: log).scanBill(
      imageBytes: image,
      mimeType: 'image/jpeg',
    );

    expect(bill.raw['supplierName'], 'Sharma Traders');
    expect(seen, hasLength(2));
    // The retry hardens the prompt, because the usual first-try failure is a
    // model that ignored the JSON-only contract.
    expect(sentPayload, contains('machine-parsed'));
    expect(
      log.entries.map((e) => e['msg']),
      ['scan_gateway_error', 'scan_retry'],
    );
  });

  test('a canned prose answer is retried once and the retry answers JSON',
      () async {
    // The gateway's provider pool sometimes answers HTTP 200 with boilerplate
    // instead of the requested JSON. That is a junk answer, not a bill
    // reading - so it is retried exactly once rather than failing the scan.
    await startGateway(
      200,
      '',
      sequence: [
        const MapEntry(
          200,
          '{"choices":[{"message":{"content":"Gemini 3 Pro is no longer '
              'available. Please switch to Gemini 3.1 Pro."}}]}',
        ),
        const MapEntry(
          200,
          '{"choices":[{"message":{"content":"{\\"supplierName\\":'
              '\\"Sharma Traders\\"}"}}]}',
        ),
      ],
    );

    final bill = await clientFor(server.port, captured: log).scanBill(
      imageBytes: image,
      mimeType: 'image/jpeg',
    );

    expect(bill.raw['supplierName'], 'Sharma Traders');
    expect(seen, hasLength(2));
    expect(log.entries.single['msg'], 'scan_retry');
    expect(log.entries.single['reason'], contains('readable bill data'));
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
    // A verdict is final: retrying the same photo would only double the wait.
    expect(seen, hasLength(1));
  });
}
