import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/credentials.dart';
import '../config.dart';
import '../errors.dart';
import '../http/json.dart';
import '../http/middleware.dart';
import '../log.dart';
import '../scan/vision_client.dart';

/// The bill-scan endpoint.
///
/// The app uploads one photograph of a supplier bill; the server forwards it
/// to the configured vision backend (whose key lives only here) and returns
/// the structured reading. Nothing is persisted: the answer goes straight
/// back to the person who photographed the bill, who reviews every field in
/// the app's preview before anything is saved as a purchase bill. An OCR
/// mistake can therefore cost a correction, not a wrong book.
///
/// Membership is enforced by the same guard as every protected route; the
/// firm id is validated before any work, like the sync routes.
void addScanRoutes(
  Router router, {
  required Config config,
  required Middleware guard,
  VisionClient? visionClient,
  Logger? logger,
}) {
  final vision = visionClient ?? VisionClient(config, logger: logger);

  router.post(
    '/v1/firms/<firmId>/scan-bill',
    guard((Request request) async {
      // requirePrincipal both authenticates the handler chain and proves the
      // token parsed; the user id itself is not needed because nothing here
      // touches the database.
      requirePrincipal(request);
      // Same normalisation as the sync routes: a malformed id is a 400
      // before it can reach anything that might interpret it.
      normaliseUuid(request.params['firmId'] ?? '', 'firmId');

      // The request is validated BEFORE the feature check, so a client always
      // sees the same contract for the same body: validation failures are
      // 400 whether or not the deployment has scan turned on, and 501 means
      // "your request was fine; the server lacks the feature".
      final body = await readJsonObject(
        request,
        maxBytes: config.scanMaxImageBytes + 64 * 1024,
      );

      final image = body['imageBase64'];
      if (image is! String || image.trim().isEmpty) {
        throw const ApiException.badRequest('"imageBase64" is required.');
      }

      List<int> bytes;
      try {
        bytes = base64Decode(image.trim());
      } on FormatException {
        throw const ApiException.badRequest(
          '"imageBase64" is not valid base64.',
        );
      }
      if (bytes.length < 512) {
        throw const ApiException.badRequest(
          'That image is too small to be a bill photo.',
        );
      }
      if (bytes.length > config.scanMaxImageBytes) {
        throw ApiException.badRequest(
          'The photo is larger than the '
          '${(config.scanMaxImageBytes / (1024 * 1024)).round()} MB limit. '
          'Shoot it again; bills do not need full resolution.',
        );
      }

      final mimeType = _sniffImage(bytes);
      if (mimeType == null) {
        throw const ApiException.badRequest(
          'Only JPEG, PNG, WebP and HEIC images can be scanned.',
        );
      }

      if (!config.scanEnabled) {
        // Feature-off is a distinct, actionable answer rather than a 404, and
        // it comes AFTER validation so a client always sees the same contract
        // for the same body: bad requests are 400 whether or not this
        // deployment has scan turned on, and 501 means "your request was
        // fine; the server lacks the feature".
        throw const ApiException(
          501,
          'not_configured',
          'Bill scanning is not configured on this server. Set '
              'ATRIA_SCAN_API_URL and ATRIA_SCAN_API_KEY.',
        );
      }

      final String model;
      final Map<String, Object?> bill;
      try {
        final result = await vision.scanBill(
          imageBytes: bytes,
          mimeType: mimeType,
        );
        model = result.model;
        bill = result.raw;
      } on ScanException catch (error) {
        // The vision client's messages are written to be shown to the person
        // holding the phone - they name the failing side (gateway
        // credentials, model name, timeout) rather than leaking internals.
        // Letting one reach the generic middleware would bury them in a
        // nameless 500 and turn every diagnosis into a log hunt.
        throw ApiException(
          error.statusCode ?? 502,
          'scan_failed',
          error.message,
        );
      }
      return jsonResponse({
        'bill': bill,
        'model': model,
      });
    }),
  );
}

/// Sniffs the image container from magic bytes rather than trusting a
/// filename or header: the base64 payload is all there is, and the vision
/// vendors are strict about the declared type matching the bytes.
String? _sniffImage(List<int> bytes) {
  if (bytes.length < 12) return null;
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  // WebP: RIFF....WEBP
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  // HEIC/HEIF: ....ftypheic / ftypheix / ftypmif1 (Apple photos default).
  final ftyp = String.fromCharCodes(bytes.sublist(4, 8));
  if (ftyp == 'ftyp') {
    final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
    if (brand.startsWith('hei') || brand.startsWith('mif')) {
      return 'image/heic';
    }
  }
  return null;
}
