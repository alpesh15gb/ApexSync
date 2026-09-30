import 'dart:convert';

import '../errors.dart';

/// Minimum and maximum password length, in **bytes** rather than characters.
///
/// The maximum is not arbitrary: passwords are hashed with bcrypt via Postgres'
/// `crypt()`, and bcrypt only considers the first 72 bytes. Accepting a longer
/// password would silently make everything past byte 72 irrelevant — so a user
/// who believes a 100-character passphrase is protecting them is wrong, and
/// we'd never tell them. Rejecting it is the honest behaviour.
const int minPasswordBytes = 8;
const int maxPasswordBytes = 72;

/// Deliberately permissive. The only authoritative test of an address is
/// whether mail arrives; an elaborate regex rejects real addresses
/// (`+tag@`, new TLDs, long subdomains) while letting `a@b` through anyway.
/// This catches typos and nothing more.
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

void validateEmail(String email) {
  if (email.length > 254 || !_emailPattern.hasMatch(email)) {
    throw const ApiException.badRequest('"email" is not a valid email address.');
  }
}

void validatePassword(String password) {
  final bytes = utf8.encode(password).length;
  if (bytes < minPasswordBytes) {
    throw const ApiException.badRequest(
      '"password" must be at least $minPasswordBytes characters.',
    );
  }
  if (bytes > maxPasswordBytes) {
    throw const ApiException.badRequest(
      '"password" must be at most $maxPasswordBytes bytes.',
    );
  }
}

/// Matches the canonical lowercase UUID form we store and send on the wire.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

String normaliseUuid(String value, String field) {
  final lower = value.trim().toLowerCase();
  if (!_uuidPattern.hasMatch(lower)) {
    throw ApiException.badRequest('"$field" must be a UUID.');
  }
  return lower;
}
