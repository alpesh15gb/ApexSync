import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';

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
  const ScanException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

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
  VisionClient(this._config);

  final Config _config;

  static const _timeout = Duration(seconds: 60);

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
      final request = await client.postUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.authorizationHeader,
          'Bearer ${_config.scanApiKey}');
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
                'text': _prompt,
              },
              {
                'type': 'image_url',
                'image_url': {
                  'url':
                      'data:$mimeType;base64,${base64Encode(imageBytes)}',
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
        throw const ScanException(
          'The scan service rejected its credentials. Check ATRIA_SCAN_API_KEY '
          'on the server.',
          statusCode: 502,
        );
      }
      if (response.statusCode == 429) {
        throw const ScanException(
          'The scan service is rate-limiting requests. Try again in a moment.',
          statusCode: 429,
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ScanException(
          'The scan service failed (HTTP ${response.statusCode}).',
          statusCode: 502,
        );
      }

      return _parseAnswer(raw);
    } on ScanException {
      rethrow;
    } on SocketException {
      throw const ScanException(
        'The server could not reach the scan service.',
      );
    } on TimeoutException {
      throw const ScanException(
        'The scan service did not answer in time. Try again.',
      );
    } finally {
      client.close(force: true);
    }
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
      throw const ScanException(
        'That does not look like a purchase bill. Photograph the whole '
        'invoice, flat and in focus.',
      );
    }

    return ScannedBill(raw: answer, model: _config.scanModel);
  }
}
