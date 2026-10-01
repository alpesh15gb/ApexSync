import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/credentials.dart';
import '../config.dart';
import '../errors.dart';
import '../http/json.dart';
import '../http/middleware.dart';
import '../sync/sync_repository.dart';

/// The largest batch one push may carry.
///
/// 500 covers the app's whole outbox in the common case (a day of billing on
/// one device) while keeping the body well inside the default
/// `ATRIA_MAX_BODY_BYTES`; the app chunks anything larger rather than failing.
const int maxChangesPerPush = 500;

/// The change journal's write endpoint.
///
/// Registered per-handler behind [guard], like the firm routes: an unknown path
/// must answer 404 rather than 401, or every client typo looks like a signed-out
/// session.
void addSyncRoutes(
  Router router, {
  required SyncRepository repository,
  required Config config,
  required Middleware guard,
}) {
  /// Pushes a batch of local changes for one firm.
  ///
  /// Semantics the app depends on, all of them choices rather than accidents:
  ///
  /// * **Idempotent.** The device's own outbox id is the primary key, so a
  ///   batch re-sent after a timeout is stored once. The response reports the
  ///   duplicates instead of failing, because a retry that worked must not look
  ///   like an error — the device would keep trying for ever.
  /// * **Append-only.** Nothing here updates or deletes. The row as the device
  ///   had it is stored in `payload`, so the journal is what was true at the
  ///   time rather than what the table says now.
  /// * **Per-change, not all-or-nothing.** A batch of 500 where one change is
  ///   malformed is rejected as a whole (validation runs before the insert), so
  ///   the device never has to work out which of its rows the server kept.
  router.post(
    '/v1/firms/<firmId>/changes',
    guard((Request request) async {
      final principal = requirePrincipal(request);
      // Read through `request.params`, not a second handler argument: `guard`
      // returns a one-argument `Handler`, and shelf_router only passes path
      // parameters positionally to an unwrapped function.
      final firmId = normaliseUuid(request.params['firmId'] ?? '', 'firmId');

      final body = await readJsonObject(
        request,
        maxBytes: config.maxRequestBodyBytes,
      );
      final rawChanges = body['changes'];
      if (rawChanges is! List) {
        throw const ApiException.badRequest('"changes" must be a list.');
      }
      if (rawChanges.isEmpty) {
        // An empty push is a device with nothing to send. Saying so is not an
        // error, and answering 400 here would make an idle client look broken.
        return jsonResponse(await repository.pushChanges(
          userId: principal.userId,
          firmId: firmId,
          changes: const [],
          deviceId: principal.deviceId,
        ));
      }
      if (rawChanges.length > maxChangesPerPush) {
        throw ApiException.badRequest(
          'Push at most $maxChangesPerPush changes at a time '
          '(${rawChanges.length} were sent).',
        );
      }

      final changes = <PushedChange>[];
      for (var i = 0; i < rawChanges.length; i++) {
        changes.add(_parseChange(rawChanges[i], index: i));
      }

      final result = await repository.pushChanges(
        userId: principal.userId,
        firmId: firmId,
        changes: changes,
        deviceId: principal.deviceId,
      );
      return jsonResponse(result.toJson());
    }),
  );

  /// Pulls the firm's journal from a cursor, oldest first.
  ///
  /// The device keeps the highest `seq` it has applied per firm and sends it as
  /// `afterSeq`; the answer is every change after that point, up to the page
  /// cap, plus `hasMore` so the device knows to loop. Applying is the device's
  /// job — see the app's pull engine for the row-level last-write-wins rules —
  /// because the server never holds row state to arbitrate with.
  router.get(
    '/v1/firms/<firmId>/changes',
    guard((Request request) async {
      final principal = requirePrincipal(request);
      final firmId = normaliseUuid(request.params['firmId'] ?? '', 'firmId');

      final raw = request.url.queryParameters['afterSeq'] ?? '0';
      final afterSeq = int.tryParse(raw);
      if (afterSeq == null || afterSeq < 0) {
        throw const ApiException.badRequest(
          '"afterSeq" must be a non-negative integer.',
        );
      }

      final limitRaw = request.url.queryParameters['limit'] ?? '';
      var limit = maxChangesPerPull;
      if (limitRaw.isNotEmpty) {
        final parsed = int.tryParse(limitRaw);
        if (parsed == null || parsed < 1 || parsed > maxChangesPerPull) {
          throw ApiException.badRequest(
            '"limit" must be between 1 and $maxChangesPerPull.',
          );
        }
        limit = parsed;
      }

      final result = await repository.pullChanges(
        userId: principal.userId,
        firmId: firmId,
        afterSeq: afterSeq,
        limit: limit,
      );
      return jsonResponse(result.toJson());
    }),
  );
}

/// Validates one change out of a batch.
///
/// Every message names the index, because a batch is up to 500 items and "an
/// entity name is invalid" would leave the person (or the developer reading a
/// log) with nothing to look at.
PushedChange _parseChange(Object? raw, {required int index}) {
  if (raw is! Map) {
    throw ApiException.badRequest('changes[$index] must be a JSON object.');
  }
  final map = raw.cast<Object?, Object?>();
  final where = 'changes[$index]';

  final changeId = _string(map['id'], '$where.id', maxLength: 128);
  final entity = _string(map['entity'], '$where.entity', maxLength: 40);
  final entityId = _string(map['entityId'], '$where.entityId', maxLength: 64);
  final operation = _string(map['operation'], '$where.operation', maxLength: 12);

  // Constrained here as well as in the table's CHECK, so a bad value is a 400
  // naming the field rather than a 500 from a constraint violation.
  if (!RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(entity)) {
    throw ApiException.badRequest('$where.entity is not a table name.');
  }
  if (operation != 'insert' && operation != 'update' && operation != 'delete') {
    throw ApiException.badRequest(
      '$where.operation must be insert, update or delete.',
    );
  }

  final rawPayload = map['payload'];
  if (rawPayload != null && rawPayload is! Map) {
    throw ApiException.badRequest('$where.payload must be an object or null.');
  }
  final payload = rawPayload as Map<Object?, Object?>?;

  final rawCreatedAt = map['createdAt'];
  DateTime? createdAt;
  if (rawCreatedAt is String && rawCreatedAt.trim().isNotEmpty) {
    createdAt = DateTime.tryParse(rawCreatedAt.trim())?.toUtc();
    if (createdAt == null) {
      throw ApiException.badRequest('$where.createdAt is not a timestamp.');
    }
  } else if (rawCreatedAt is num) {
    // drift's own JSON shape is milliseconds since the epoch.
    createdAt =
        DateTime.fromMillisecondsSinceEpoch(rawCreatedAt.toInt(), isUtc: true);
  }

  return PushedChange(
    changeId: changeId,
    entity: entity,
    entityId: entityId,
    operation: operation,
    payload: payload?.cast<String, Object?>(),
    createdAt: createdAt,
  );
}

String _string(Object? value, String field, {required int maxLength}) {
  if (value is! String || value.trim().isEmpty) {
    throw ApiException.badRequest('"$field" is required.');
  }
  final trimmed = value.trim();
  if (trimmed.length > maxLength) {
    throw ApiException.badRequest('"$field" is too long.');
  }
  return trimmed;
}
