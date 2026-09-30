import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_repository.dart';
import '../auth/credentials.dart';
import '../config.dart';
import '../errors.dart';
import '../http/json.dart';
import '../http/middleware.dart';

/// Routes that need an authenticated caller.
///
/// Each handler is wrapped in [guard] individually rather than putting the whole
/// `/v1/` prefix behind one guard. Wrapping per-handler is what keeps an unknown
/// path answering 404 instead of 401 — otherwise every client typo looks like an
/// authentication failure, and you debug the wrong thing.
void addProtectedRoutes(
  Router router, {
  required AuthRepository repository,
  required Config config,
  required Middleware guard,
}) {
  router.get(
    '/v1/me',
    guard((Request request) async {
      final principal = requirePrincipal(request);
      final memberships = await repository.membershipsFor(principal.userId);
      return jsonResponse({
        'user': {'id': principal.userId},
        'deviceId': principal.deviceId,
        'firms': memberships.map((membership) => membership.toJson()).toList(),
      });
    }),
  );

  router.post(
    '/v1/firms',
    guard((Request request) async {
      final principal = requirePrincipal(request);
      final body = await readJsonObject(
        request,
        maxBytes: config.maxRequestBodyBytes,
      );

      // The *client* mints the firm id — `IdUtils.newId()` in the app generates
      // a UUID v7. That is the property the whole sync plan rests on: no entity
      // needs a server-assigned identifier, so an offline device can create a
      // firm, an invoice or a payment and never have to remap it later. We only
      // insist it is a well-formed UUID, because Postgres would otherwise reject
      // it with a 22P02 error that surfaces as an opaque 500.
      final firmId = normaliseUuid(
        requiredString(body, 'firmId', maxLength: 36),
        'firmId',
      );
      final name = requiredString(body, 'name', maxLength: 120);
      final gstin = optionalString(body, 'gstin', maxLength: 15);
      final memberName = optionalString(body, 'memberName', maxLength: 120);

      await repository.createFirm(
        userId: principal.userId,
        firmId: firmId,
        name: name,
        gstin: gstin,
        memberName: memberName ?? name,
      );

      return jsonResponse({'firmId': firmId, 'name': name}, status: 201);
    }),
  );

  /// Erases a firm from the server: the half of "remove this business" that
  /// cannot be done on the device.
  ///
  /// This is the erasure path DPDP Rule 8 needs (audit/07 §9), and it is
  /// deliberately separate from the client-side tombstones that keep sync
  /// correct — a tombstone is not an erasure. Devices that still hold the firm
  /// locally are dealt with by the ledger entry this writes: the next push
  /// gets a 409 instead of resurrecting it.
  ///
  /// A 404 covers three cases on purpose — no such firm, someone else's firm,
  /// and one you are not an admin of — because telling them apart would turn
  /// this into a way for a signed-in caller to probe other tenants' firm ids.
  /// The app reads a 404 as "nothing left there", which is the state the
  /// caller was asking for anyway, and that is what makes a retry of an
  /// already-erased firm safe.
  router.delete(
    '/v1/firms/<firmId>',
    guard((Request request) async {
      final principal = requirePrincipal(request);

      // Read through `request.params` rather than taking the parameter as a
      // second handler argument. `guard` returns a plain one-argument
      // `Handler`, and shelf_router only passes path parameters positionally
      // to an *unwrapped* function — a wrapped one is called with the request
      // alone, so `(Request, String)` here would throw at runtime on every
      // call rather than fail to compile.
      final firmId = normaliseUuid(request.params['firmId'] ?? '', 'firmId');

      final erased = await repository.purgeFirm(
        userId: principal.userId,
        firmId: firmId,
      );
      if (!erased) {
        throw const ApiException.notFound(
          'No such business on this server, or you do not administer it.',
        );
      }

      return jsonResponse({'firmId': firmId, 'erased': true});
    }),
  );
}
