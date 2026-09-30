import 'package:atria_api/src/auth/credentials.dart';
import 'package:atria_api/src/errors.dart';
import 'package:test/test.dart';

void main() {
  group('validateEmail', () {
    test('accepts addresses that a stricter regex would wrongly reject', () {
      for (final email in [
        'owner@apexbooks.in',
        'a.b+tag@sub.domain.co.in',
        'gst.help@firm-two.museum',
      ]) {
        expect(() => validateEmail(email), returnsNormally, reason: email);
      }
    });

    test('rejects obvious typos and junk', () {
      for (final email in ['', 'owner', 'owner@', '@apexbooks.in', 'a b@c.in']) {
        expect(
          () => validateEmail(email),
          throwsA(isA<ApiException>()),
          reason: email,
        );
      }
    });

    test('rejects an absurdly long address', () {
      expect(
        () => validateEmail('${'a' * 250}@apexbooks.in'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('validatePassword', () {
    test('requires a minimum length', () {
      expect(
        () => validatePassword('short'),
        throwsA(isA<ApiException>()),
      );
      expect(() => validatePassword('longenough'), returnsNormally);
    });

    test('counts bytes, not characters', () {
      // Six Devanagari characters is 18 bytes in UTF-8, so this passes a
      // character count but must be judged on bytes.
      expect(() => validatePassword('अक्षर'), returnsNormally);
      // A 30-character string that is 90 bytes must fail the 72-byte limit.
      expect(
        () => validatePassword('अ' * 30),
        throwsA(isA<ApiException>()),
      );
    });

    test('rejects more than 72 bytes, because bcrypt ignores the rest', () {
      // Accepting this would tell the user their 100-character passphrase is
      // protecting them when only the first 72 bytes matter.
      expect(
        () => validatePassword('a' * 73),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('72'),
          ),
        ),
      );
      expect(() => validatePassword('a' * 72), returnsNormally);
    });
  });

  group('normaliseUuid', () {
    test('accepts the canonical lowercase form and case-folds it', () {
      expect(
        normaliseUuid('018F2A3B-4C5D-7E8F-9A0B-1C2D3E4F5A6B', 'firmId'),
        '018f2a3b-4c5d-7e8f-9a0b-1c2d3e4f5a6b',
      );
    });

    test('rejects anything Postgres would fail on with a 22P02', () {
      for (final value in ['', 'abc', 'not-a-uuid', '018f2a3b4c5d7e8f']) {
        expect(
          () => normaliseUuid(value, 'firmId'),
          throwsA(isA<ApiException>()),
          reason: value,
        );
      }
    });
  });
}
