import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../log.dart';

/// The outcome of one bill scan.
class ScannedBill {
  const ScannedBill({required this.raw, required this.model});

  /// The model's structured answer: supplier, invoice number, dates, lines,
  /// totals. Contents are the model's best reading of a photograph and are
  /// ALWAYS reviewed by a person in the app before anything is saved.
  final Map<String, Object?> raw;

  /// Which model produced this, for provenance in the app's preview screen.
  final String model;
}

/// Normalises a configured scan endpoint into a full chat-completions URL.
///
/// Deployments naturally write the base (".../v1") the way every SDK treats
/// it, while the wire protocol wants the full path. Accepting both - and a
/// trailing slash - is cheaper than a deploy failing on a 404 from its own
/// gateway. A URL that already ends in `/chat/completions` passes through
/// untouched.
Uri chatCompletionsUrl(String configured) {
  var trimmed = configured.trim().replaceFirst(RegExp(r'/+$'), '');
  if (!trimmed.endsWith('/chat/completions')) {
    trimmed = '$trimmed/chat/completions';
  }
  return Uri.parse(trimmed);
}

/// Thrown when the vision backend cannot do its job, with a message the app
/// can show as-is.
class ScanException implements Exception {
  const ScanException(this.message, {this.statusCode, this.retryable = true});

  final String message;
  final int? statusCode;

  /// Whether one immediate retry is worth the latency. False for answers that
  /// are certainly final - rejected credentials, rate limits, a photo the
  /// model judged not to be a bill; true for the transient failures this
  /// deployment's gateway produces when one provider in its pool has a bad
  /// moment and the next request would sail through.
  final bool retryable;

  @override
  String toString() => message;
}

/// Calls an OpenAI-compatible chat-completions vision endpoint and parses the
/// structured bill JSON out of the answer.
///
/// Any vendor that speaks the OpenAI chat shape works behind [Config.scanApiUrl]
/// (OpenAI, Gemini's compatibility layer, OpenRouter, a self-hosted gateway):
/// the request is one `chat/completions` call with a base64 image, and the
/// contract is "return only JSON". Keeping the vendor behind the server is the
/// whole point of the feature's shape: the API key never leaves the VPS.
class VisionClient {
  VisionClient(this._config, {Logger? logger}) : _logger = logger;

  final Config _config;

  /// Optional so tests and one-off callers can build a client with nothing to
  /// log to. Every failure that becomes a user-visible message is logged here
  /// first: the message the phone shows says which side failed, and this line
  /// says why, which is the difference between one redeploy and a log hunt.
  final Logger? _logger;

  static const _timeout = Duration(seconds: 60);

  /// Appended to the prompt on the second attempt. Most first-try failures
  /// are a model ignoring the JSON-only contract (or a broken provider in a
  /// gateway pool answering with prose), so the retry repeats the instruction
  /// most often ignored - and perturbs any response cache into fresh tokens.
  static const _retryNudge =
      ' Your answer is machine-parsed: return ONLY the bill JSON object, no '
      'markdown fences, no prose before or after it.';

  /// Bounds a gateway's error body to one log-sized line. A misconfigured
  /// endpoint can answer with a whole HTML page; the point is to name the
  /// failure, not to copy the page into the container log.
  static String _snippet(String body) {
    final collapsed = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= 300
        ? collapsed
        : '${collapsed.substring(0, 300)}…';
  }

  /// What the model is asked to do. Deliberately paranoid about money and
  /// GSTIN fields, because a hallucinated tax figure is worse than an empty
  /// one the user has to type.
  static const _prompt =
      'You read Indian purchase bills (supplier invoices) from photos and '
      'return ONLY compact JSON, no markdown fences, no commentary. Schema: '
      '{"supplierName": string|null, "supplierGstin": string|null, '
      '"supplierPhone": string|null, "supplierAddress": string|null, '
      '"supplierInvoiceNumber": string|null, '
      '"billDate": "YYYY-MM-DD"|null, '
      '"dueDate": "YYYY-MM-DD"|null, '
      '"placeOfSupply": two-letter Indian state code or null, '
      '"lines": [{"name": string, "hsn": string|null, "quantity": number, '
      '"unit": string, "rate": number, "discountPercent": number, '
      '"gstRate": number, "cessRate": number}], '
      '"shippingCharge": number, "otherCharges": number, '
      '"roundOff": number, "grandTotal": number|null, '
      '"confidence": "high"|"medium"|"low", '
      '"warnings": string[]}. '
      'Rules: use null for anything unreadable rather than guessing; '
      '"quantity"/"rate"/tax rates are numbers, not strings; gstRate is the '
      'percent (18, not 0.18); discountPercent is the percent shown per line; '
      'copy unit strings as printed (BOX, PCS, KG); if a line shows an '
      'inclusive price, still report the printed rate and say so in warnings; '
      'omit nothing from the bill - every printed line goes into "lines"; '
      'if the image is not a bill, return {"error": "not_a_bill"}.';

  Future<ScannedBill> scanBill({
    required List<int> imageBytes,
    required String mimeType,
  }) async {
    final uri = chatCompletionsUrl(_config.scanApiUrl);
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      // One immediate retry, because this deployment's gateway mixes flaky
      // providers into its pools: a single 502 or a canned non-JSON answer is
      // common while the very next request sails through. Only retryable
      // failures get the second attempt - auth rejections, rate limits and
      // not_a_bill verdicts are certainly final, and retrying them just
      // doubles what the person holding the phone waits.
      var attempt = 1;
      while (true) {
        try {
          return await _scanOnce(client, uri, imageBytes, mimeType, attempt);
        } on ScanException catch (error) {
          if (!error.retryable || attempt >= 2) rethrow;
          attempt++;
          _logger?.warn('scan_retry', {
            'attempt': 1,
            'reason': _snippet(error.message),
          });
        }
      }
    } on SocketException catch (error) {
      _logger?.warn('scan_gateway_unreachable', {
        'url': uri.toString(),
        'error': error.message,
      });
      throw const ScanException(
        'The server could not reach the scan service.',
      );
    } on TimeoutException {
      _logger?.warn('scan_gateway_timeout', {'url': uri.toString()});
      throw const ScanException(
        'The scan service did not answer in time. Try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// One gateway round-trip. [attempt] is 1 or 2; the second attempt hardens
  /// the prompt with [_retryNudge] because the usual first-try failure is a
  /// model that ignored the JSON-only contract.
  Future<ScannedBill> _scanOnce(
    HttpClient client,
    Uri uri,
    List<int> imageBytes,
    String mimeType,
    int attempt,
  ) async {
    final request = await client.postUrl(uri).timeout(_timeout);
    request.headers.set(
        HttpHeaders.authorizationHeader, 'Bearer ${_config.scanApiKey}');
    request.headers.contentType = ContentType.json;

    final body = jsonEncode({
      'model': _config.scanModel,
      'temperature': 0,
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': attempt == 1 ? _prompt : '$_prompt$_retryNudge',
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:$mimeType;base64,${base64Encode(imageBytes)}',
              },
            },
          ],
        },
      ],
      // Some gateways cap max_tokens strictly; 4096 covers a long bill
      // without inviting the model to write essays.
      'max_tokens': 4096,
    });
    final encoded = utf8.encode(body);
    request.headers.contentLength = encoded.length;
    request.add(encoded);

    final response = await request.close().timeout(_timeout);
    final raw = await response.transform(utf8.decoder).join().timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 403) {
      _logger?.warn('scan_gateway_rejected_key', {
        'status': response.statusCode,
        'url': uri.toString(),
        'body': _snippet(raw),
      });
      throw const ScanException(
        'The scan service rejected its credentials. Check ATRIA_SCAN_API_KEY '
        'on the server.',
        statusCode: 502,
        retryable: false,
      );
    }
    if (response.statusCode == 429) {
      _logger?.warn('scan_gateway_rate_limited', {
        'status': response.statusCode,
        'url': uri.toString(),
        'body': _snippet(raw),
      });
      throw const ScanException(
        'The scan service is rate-limiting requests. Try again in a moment.',
        statusCode: 429,
        retryable: false,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // The gateway is answering, but unhappily: almost always its own
      // upstream (a provider key it does not hold, a model it does not
      // route). Its body is the only place that reason exists, and it is
      // useless to the person holding the phone - so it goes to the log
      // while the app gets a line that names the failing side. Transient by
      // nature, so the caller retries once.
      _logger?.warn('scan_gateway_error', {
        'status': response.statusCode,
        'url': uri.toString(),
        'model': _config.scanModel,
        'body': _snippet(raw),
      });
      throw ScanException(
        'The scan service failed (HTTP ${response.statusCode}).',
        statusCode: 502,
      );
    }

    return _parseAnswer(raw);
  }

  /// Pulls the JSON answer out of a chat-completions response body.
  ///
  /// Models occasionally wrap JSON in ```json fences despite instructions;
  /// the fence is stripped before parsing rather than failing the whole scan.
  ScannedBill _parseAnswer(String responseBody) {
    Map<String, Object?> outer;
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map) {
        throw const ScanException('The scan service answered in an unexpected shape.');
      }
      outer = decoded.cast<String, Object?>();
    } on ScanException {
      rethrow;
    } on FormatException {
      throw const ScanException('The scan service answered with invalid JSON.');
    }

    final choices = outer['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const ScanException('The scan service returned no answer.');
    }
    final first = choices.first;
    if (first is! Map) {
      throw const ScanException('The scan service returned no answer.');
    }
    final message = first['message'];
    if (message is! Map || message['content'] is! String) {
      throw const ScanException('The scan service returned no answer text.');
    }

    var content = message['content'] as String;
    content = content.trim();
    if (content.startsWith('```')) {
      content = content
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'```\s*$'), '')
          .trim();
    }

    Object? bill;
    try {
      bill = jsonDecode(content);
    } on FormatException {
      throw const ScanException(
        'The scan model did not return readable bill data. Try the photo again.',
      );
    }
    if (bill is! Map) {
      throw const ScanException(
        'The scan model did not return readable bill data. Try the photo again.',
      );
    }
    final answer = bill.cast<String, Object?>();
    if (answer['error'] == 'not_a_bill') {
      // A verdict, not a glitch: retrying the same photo would only double
      // the wait before the same advice.
      throw const ScanException(
        'That does not look like a purchase bill. Photograph the whole '
        'invoice, flat and in focus.',
        retryable: false,
      );
    }

    return ScannedBill(raw: answer, model: _config.scanModel);
  }
}
