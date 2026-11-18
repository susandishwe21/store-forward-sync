import 'dart:ffi';
import 'dart:io';

import 'package:sf_local/sf_local.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Uses Homebrew's SQLCipher if it is installed (brew install sqlcipher).
bool _useSqlCipher() {
  for (final path in [
    '/opt/homebrew/opt/sqlcipher/lib/libsqlcipher.dylib', // Apple Silicon Mac
    '/usr/local/opt/sqlcipher/lib/libsqlcipher.dylib', // Intel Mac
  ]) {
    if (File(path).existsSync()) {
      open.overrideFor(OperatingSystem.macOS, () => DynamicLibrary.open(path));
      return true;
    }
  }
  return false;
}

const key = '2dd29ca851e7b56e4697b0e1f08507293d761a05ce4d1b628663f411a8086d99';
const wrongKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  final hasCipher = _useSqlCipher(); // must run before anything opens a database
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sf_encryption_test');
    path = '${dir.path}/secret.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a key that is not 256-bit hex is refused', () {
    expect(() => LocalStore.open(path, encryptionKeyHex: 'too-short'), throwsArgumentError);
  });

  test('without SQLCipher, an encrypted store refuses to open', () {
    expect(() => LocalStore.open(path, encryptionKeyHex: key), throwsStateError);
  }, skip: hasCipher ? 'SQLCipher is installed on this machine' : false);

  group('with SQLCipher', () {
    test('data on disk is unreadable without the key', () {
      final store = LocalStore.open(path, encryptionKeyHex: key);
      final id = store.create('survey', {'site': 'TOP SECRET SITE'}).entityId;
      store.close();

      // 1. The raw file does not contain the text.
      final raw = String.fromCharCodes(File(path).readAsBytesSync());
      expect(raw.contains('TOP SECRET SITE'), isFalse);

      // 2. Opening it without the key fails.
      final plain = sqlite3.open(path);
      expect(() => plain.select('SELECT * FROM sf_record'), throwsA(isA<SqliteException>()));
      plain.dispose();

      // 3. With the right key, everything is back.
      final again = LocalStore.open(path, encryptionKeyHex: key);
      expect(again.get('survey', id)!.payload, {'site': 'TOP SECRET SITE'});
      again.close();
    });

    test('the wrong key is refused', () {
      LocalStore.open(path, encryptionKeyHex: key).close();
      expect(() => LocalStore.open(path, encryptionKeyHex: wrongKey), throwsStateError);
    });
  }, skip: hasCipher ? false : 'install SQLCipher to run: brew install sqlcipher');
}
