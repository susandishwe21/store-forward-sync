import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sf_write_test');
    path = '${dir.path}/store.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('create saves the record as queued, with no network at all', () {
    final store = LocalStore.open(path);
    final r = store.create('note', {'title': 'Water level', 'depth_cm': 120});
    expect(r.syncStatus, SyncStatus.queued);
    expect(r.localSeq, 1);
    expect(store.get('note', r.entityId)!.payload!['depth_cm'], 120);
    store.close();
  });

  test('every save adds exactly one outbox entry', () {
    final store = LocalStore.open(path);
    final r = store.create('note', {'title': 'v1'});
    store.put('note', r.entityId, {'title': 'v2'});
    store.put('note', r.entityId, {'title': 'v3'});
    expect(store.operationCount(), 3);
    expect(store.get('note', r.entityId)!.localSeq, 3);
    store.close();
  });

  test('delete keeps a tombstone until the server confirms', () {
    final store = LocalStore.open(path);
    final r = store.create('note', {'title': 'temporary'});
    store.delete('note', r.entityId);
    expect(store.get('note', r.entityId), isNull);
    expect(
      store.get('note', r.entityId, includeDeleted: true)!.deleted,
      isTrue,
    );
    expect(store.operationCount(), 2);
    store.close();
  });

  test('saved data survives closing and reopening the app', () {
    var store = LocalStore.open(path);
    final id = store.create('note', {'title': 'keep me'}).entityId;
    store.close();

    store = LocalStore.open(path);
    expect(store.get('note', id)!.payload!['title'], 'keep me');
    expect(store.operationCount(), 1);
    store.close();
  });

  test('the outbox fingerprint matches the payload', () {
    final store = LocalStore.open(path);
    store.create('note', {'title': 'check me', 'depth_cm': 7});
    store.close();

    final db = sqlite3.open(path);
    final hash = db
        .select('SELECT payload_hash FROM sf_outbox')
        .first['payload_hash'];
    expect(hash, payloadHash({'title': 'check me', 'depth_cm': 7}));
    db.dispose();
  });

  test(
    'ALL OR NOTHING: if the outbox write fails, the record is not saved either',
    () {
      // Create the tables, then add a trap: any insert into sf_outbox fails.
      LocalStore.open(path).close();
      final db = sqlite3.open(path);
      db.execute('''
      CREATE TRIGGER simulated_crash BEFORE INSERT ON sf_outbox
      BEGIN SELECT RAISE(ABORT, 'simulated crash'); END''');
      db.dispose();

      final store = LocalStore.open(path);
      expect(
        () => store.put('note', 'n1', {'title': 'half saved?'}),
        throwsA(isA<SqliteException>()),
      );

      // The record write happened BEFORE the outbox write, but was rolled back.
      expect(store.get('note', 'n1'), isNull);
      expect(store.operationCount(), 0);
      store.close();
    },
  );
}
