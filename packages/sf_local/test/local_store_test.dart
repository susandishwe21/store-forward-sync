import 'dart:io';

import 'package:sf_local/sf_local.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('sf_local_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('opening a new database creates the three tables', () {
    final store = LocalStore.open('${dir.path}/store.db');
    expect(store.tableNames(), containsAll(['sf_meta', 'sf_outbox', 'sf_record']));
    store.close();
  });

  test('the client ID stays the same after closing and reopening', () {
    final first = LocalStore.open('${dir.path}/store.db');
    final id = first.clientId;
    first.close();

    final second = LocalStore.open('${dir.path}/store.db');
    expect(second.clientId, id);
    second.close();
  });

  test('two different databases get different client IDs', () {
    final a = LocalStore.open('${dir.path}/a.db');
    final b = LocalStore.open('${dir.path}/b.db');
    expect(a.clientId, isNot(b.clientId));
    a.close();
    b.close();
  });

  test('an in-memory database works for quick tests', () {
    final store = LocalStore.open(':memory:');
    expect(store.tableNames(), contains('sf_outbox'));
    store.close();
  });
}