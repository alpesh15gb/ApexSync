import 'package:postgres/postgres.dart';

import '../database.dart';
import '../errors.dart';

class Account {
  const Account({required this.id, required this.email});

  final String id;
  final String email;
}

class Membership {
  const Membership({
    required this.firmId,
    required this.firmName,
    required this.role,
  });

  final String firmId;
  final String firmName;
  final String role;

  Map<String, Object?> toJson() => {
        'firmId': firmId,
        'firmName': firmName,
        'role': role,
      };
}

class RotatedSession {
  const RotatedSession({required this.userId, required this.deviceId});

  final String userId;
  final String? deviceId;
}

/// All identity and tenancy SQL.
///
/// Two deliberate choices run through this file:
///
/// * **Passwords and refresh tokens are hashed by Postgres**, not by Dart — see
///   `crypt()`/`gen_salt()` and `digest()` in `db/migrations/0001_identity.sql`.
///   The plaintext never reaches a table, a query log or a dump, and we don't
///   ship a password-hashing implementation of our own.
/// * **Nothing here can be tricked into returning another tenant's rows**,
///   because every tenant read runs through [Database.asUser], which sets
///   `app.user_id` for the transaction and lets the row-level security policies
///   decide. The `WHERE` clauses are a second line of defence, not the first.
class AuthRepository {
  AuthRepository(this._db);

  final Database _db;

  static const String _uniqueViolation = '23505';

  Future<Account> createAccount({
    required String email,
    required String password,
  }) async {
    final Result result;
    try {
      result = await _db.pool.execute(
        Sql.named('''
          INSERT INTO app_users (email, password_hash)
          VALUES (lower(@email), crypt(@password, gen_salt('bf', 12)))
          RETURNING id::text AS id, email
        '''),
        parameters: {'email': email, 'password': password},
      );
    } on ServerException catch (error) {
      if (error.code == _uniqueViolation) {
        throw const ApiException.conflict(
          'An account with that email already exists.',
        );
      }
      rethrow;
    }
    final row = result.first.toColumnMap();
    return Account(id: row['id'] as String, email: row['email'] as String);
  }

  /// Returns null when the email is unknown *or* the password is wrong.
  ///
  /// Known gap: we don't burn a `crypt()` against a dummy hash when the email is
  /// unknown, so the response time differs slightly between "no such account"
  /// and "wrong password". The client-visible message is identical, which
  /// removes the easy enumeration path; timing equalisation is a later job.
  Future<Account?> verifyCredentials({
    required String email,
    required String password,
  }) async {
    final result = await _db.pool.execute(
      Sql.named('''
        SELECT id::text AS id, email
        FROM app_users
        WHERE email = lower(@email)
          AND is_disabled = false
          AND password_hash = crypt(@password, password_hash)
      '''),
      parameters: {'email': email, 'password': password},
    );
    if (result.isEmpty) return null;
    final row = result.first.toColumnMap();
    return Account(id: row['id'] as String, email: row['email'] as String);
  }

  /// Records (or refreshes) a device, so a lost phone can be revoked on its own
  /// rather than by invalidating the account's every session.
  Future<void> recordDevice({
    required String userId,
    required String deviceId,
    String? name,
    String? platform,
  }) async {
    await _db.pool.execute(
      Sql.named('''
        INSERT INTO devices (user_id, device_id, name, platform, last_seen_at)
        VALUES (@userId::uuid, @deviceId, @name::text, @platform::text, now())
        ON CONFLICT (user_id, device_id) DO UPDATE SET
          name = COALESCE(EXCLUDED.name, devices.name),
          platform = COALESCE(EXCLUDED.platform, devices.platform),
          last_seen_at = now()
      '''),
      parameters: {
        'userId': userId,
        'deviceId': deviceId,
        'name': name,
        'platform': platform,
      },
    );
  }

  Future<void> storeRefreshToken({
    required String userId,
    required String deviceId,
    required String token,
    required DateTime expiresAt,
  }) async {
    await _db.pool.execute(
      Sql.named('''
        INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at)
        VALUES (
          @userId::uuid,
          @deviceId,
          encode(digest(@token, 'sha256'), 'hex'),
          @expiresAt
        )
      '''),
      parameters: {
        'userId': userId,
        'deviceId': deviceId,
        'token': token,
        'expiresAt': expiresAt,
      },
    );
  }

  /// Rotates a refresh token: the presented one is revoked and the replacement
  /// is issued in a single transaction.
  ///
  /// The revoke is a conditional `UPDATE ... RETURNING`, not a read followed by
  /// a write, so two simultaneous refreshes of the same token cannot both
  /// succeed — the second finds no row and gets a 401. That property comes free
  /// from making the check part of the statement that changes the row.
  ///
  /// Known gap: we don't yet detect *reuse* of an already-rotated token and
  /// revoke the whole token family, which is what you want if the token was
  /// stolen. The single-use guarantee above is what makes that safe to add
  /// later.
  Future<RotatedSession> rotateRefreshToken({
    required String presented,
    required String replacement,
    required DateTime replacementExpiresAt,
  }) {
    return _db.pool.runTx((session) async {
      final revoked = await session.execute(
        Sql.named('''
          UPDATE refresh_tokens
          SET revoked_at = now()
          WHERE token_hash = encode(digest(@token, 'sha256'), 'hex')
            AND revoked_at IS NULL
            AND expires_at > now()
          RETURNING user_id::text AS user_id, device_id
        '''),
        parameters: {'token': presented},
      );
      if (revoked.isEmpty) {
        throw const ApiException.unauthorized(
          'Refresh token is not valid. Sign in again.',
        );
      }
      final row = revoked.first.toColumnMap();
      final userId = row['user_id'] as String;
      final deviceId = row['device_id'] as String;

      await session.execute(
        Sql.named('''
          INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at)
          VALUES (
            @userId::uuid,
            @deviceId,
            encode(digest(@token, 'sha256'), 'hex'),
            @expiresAt
          )
        '''),
        parameters: {
          'userId': userId,
          'deviceId': deviceId,
          'token': replacement,
          'expiresAt': replacementExpiresAt,
        },
      );

      return RotatedSession(userId: userId, deviceId: deviceId);
    });
  }

  /// Idempotent: revoking an unknown or already-revoked token is a success,
  /// because the caller's desired end state is "this token no longer works".
  Future<void> revokeRefreshToken(String token) async {
    await _db.pool.execute(
      Sql.named('''
        UPDATE refresh_tokens
        SET revoked_at = now()
        WHERE token_hash = encode(digest(@token, 'sha256'), 'hex')
          AND revoked_at IS NULL
      '''),
      parameters: {'token': token},
    );
  }

  Future<List<Membership>> membershipsFor(String userId) {
    return _db.asUser(userId, (session) async {
      final result = await session.execute(
        Sql.named('''
          SELECT f.id::text AS firm_id, f.name AS firm_name, m.role AS role
          FROM firm_members m
          JOIN firms f ON f.id = m.firm_id
          WHERE m.user_id = @userId::uuid
          ORDER BY f.name
        '''),
        parameters: {'userId': userId},
      );
      return result
          .map(
            (row) {
              final map = row.toColumnMap();
              return Membership(
                firmId: map['firm_id'] as String,
                firmName: map['firm_name'] as String,
                role: map['role'] as String,
              );
            },
          )
          .toList();
    });
  }

  /// Creates a firm and the caller's membership in it.
  ///
  /// This goes through the `app_create_firm` stored procedure rather than two
  /// plain inserts, because a brand-new firm has no members and therefore no
  /// row-level security policy can authorise its own creation. The procedure is
  /// `SECURITY DEFINER` precisely so that it can, and it is the *only* way to
  /// create a tenant.
  Future<void> createFirm({
    required String userId,
    required String firmId,
    required String name,
    required String memberName,
    String? gstin,
  }) async {
    // An erased firm id can never come back. Without this check a device that
    // was offline when the erasure happened would push its local copy back on
    // the next sync and silently undo a deletion the user asked for — the one
    // outcome a DPDP erasure request is not allowed to have. Firm ids are
    // UUID v7 minted by the client, so refusing one can never block a
    // legitimate create. See `db/migrations/0002_firm_purges.sql`.
    //
    // A read, not a `SECURITY DEFINER` procedure: `app_firm_purges` is only
    // ever consulted for the exact id being created, and the table holds
    // nothing worth protecting beyond the fact of the deletion itself.
    final purged = await _db.pool.execute(
      Sql.named('SELECT 1 FROM app_firm_purges WHERE firm_id = @firmId::text'),
      parameters: {'firmId': firmId},
    );
    if (purged.isNotEmpty) {
      throw const ApiException.conflict(
        'That business was deleted from Atria and cannot be re-created under '
        'the same id.',
      );
    }

    try {
      await _db.asUser(userId, (session) async {
        await session.execute(
          Sql.named('''
            SELECT app_create_firm(
              @userId::uuid,
              -- `firms.id` is text, not uuid: the client mints these ids and its
              -- column is text, so asking Postgres for a uuid here finds no
              -- matching function at all.
              @firmId::text,
              @name::text,
              @gstin::text,
              @memberName::text
            )
          '''),
          parameters: {
            'userId': userId,
            'firmId': firmId,
            'name': name,
            'gstin': gstin,
            'memberName': memberName,
          },
        );
      });
    } on ServerException catch (error) {
      // The unique violation comes out of the stored procedure's INSERT into
      // firms. Without this, a retry of an already-created firm — which a client
      // on a flaky connection will absolutely do — reports a server fault and
      // looks like our bug rather than "you already have this".
      if (error.code == _uniqueViolation) {
        throw const ApiException.conflict('That firm already exists.');
      }
      rethrow;
    }
  }

  /// Erases a firm, its memberships, and nothing else.
  ///
  /// A real `DELETE`, not a flag: a tombstone is not an erasure (audit/07 §9),
  /// and `firm_members.firm_id` carries `ON DELETE CASCADE` so the membership
  /// rows go with it. Referential actions bypass row-level security, which is
  /// what lets a member row be removed by a statement that had to pass the
  /// `firm_members` policies to be authorised in the first place.
  ///
  /// Authorization is the `firms_delete_admin` policy rather than an `if` in
  /// Dart: the delete runs inside [Database.asUser], so a caller who is not an
  /// admin of this firm matches zero rows. That keeps a non-admin and an
  /// unknown firm indistinguishable from the outside, which is the point.
  ///
  /// Returns false when there was nothing to delete; the route turns that into
  /// a 404. The ledger row is written in the *same* transaction as the delete,
  /// so a crash cannot leave an erased firm that a stale device could still
  /// re-create.
  Future<bool> purgeFirm({
    required String userId,
    required String firmId,
  }) {
    return _db.asUser(userId, (session) async {
      // `RETURNING` is what makes this a single decision rather than a read
      // followed by a write: an empty result proves nothing was authorised to
      // be deleted, whatever the reason.
      final deleted = await session.execute(
        Sql.named('''
          DELETE FROM firms
          WHERE id = @firmId::text
          RETURNING id
        '''),
        parameters: {'firmId': firmId},
      );
      if (deleted.isEmpty) return false;

      await session.execute(
        Sql.named('''
          INSERT INTO app_firm_purges (firm_id, purged_by)
          VALUES (@firmId::text, @userId::uuid)
          ON CONFLICT (firm_id) DO NOTHING
        '''),
        parameters: {'firmId': firmId, 'userId': userId},
      );
      return true;
    });
  }
}
