import 'dart:convert';
import 'dart:math';

/// Generates opaque refresh tokens.
///
/// These are deliberately *not* JWTs. They carry no claims and mean nothing on
/// their own, because they are looked up in the database where they can be
/// revoked per device — which is the whole point: a lost phone must be
/// revocable without invalidating every other device, and a JWT cannot be
/// revoked.
///
/// Only the SHA-256 hash is stored, and it is hashed by Postgres
/// (`encode(digest(token, 'sha256'), 'hex')`), so the plaintext token never
/// lands in a table, a query log, or a `pg_dump`.
class RefreshTokenFactory {
  RefreshTokenFactory([Random? random]) : _random = random ?? Random.secure();

  /// 256 bits, which is far beyond guessable.
  static const int _byteLength = 32;

  final Random _random;

  String generate() {
    final bytes = List<int>.generate(_byteLength, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
