import 'dart:io';

import 'package:sf_harness/sf_harness.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sf_server/sf_server.dart';
import 'package:sf_sync/sf_sync.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String phoneDb, serverDb, log;
  late LocalStore phone;
  late ServerStore server;
  late SyncHttpServer http;
  late HttpTransport transport;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sf_verify_test');
    phoneDb = '${dir.path}/phone.db';
    serverDb = '${dir.path}/server.db';
    log = '${dir.path}/saved.log';
    phone = LocalStore.open(phoneDb);
    server = ServerStore.open(serverDb);
    http = await SyncHttpServer.start(server, port: 0);
    transport = HttpTransport(Uri.parse('http://127.0.0.1:${http.port}'));

    for (var i = 0; i < 5; i++) {
      final r = phone.put('item', 'e$i', {'v': i});
      File(log).writeAsStringSync(
        '${r.entityId} ${r.localSeq} ok\n',
        mode: FileMode.append,
      );
    }
    phone.put('item', 'e0', {'v': 100});
    phone.delete('item', 'e1');
    await SyncEngine(store: phone, transport: transport).syncAll();
  });

  tearDown(() async {
    transport.close();
    await http.close();
    phone.close();
    server.close();
    dir.deleteSync(recursive: true);
  });

  Verdict check() =>
      verify(phoneDb: phoneDb, serverDb: serverDb, savedLog: log);

  void tamperServer(String sql) {
    final db = sqlite3.open(serverDb);
    db.execute(sql);
    db.dispose();
  }

  test('a clean run passes', () {
    final verdict = check();
    expect(verdict.passed, isTrue, reason: '$verdict');
    expect(verdict.phoneOps, 7);
  });

  test('catches a change that never reached the server', () {
    phone.put('item', 'e9', {'v': 9}); // saved, never synced
    final verdict = check();
    expect(verdict.lost, 1);
    expect(verdict.passed, isFalse);
  });

  test('catches a change applied twice', () {
    tamperServer(
      "UPDATE srv_record SET version = version + 1 WHERE entity_id = 'e2'",
    );
    expect(check().duplicates, 1);
  });

  test('catches changes applied in the wrong order', () {
    tamperServer('UPDATE srv_op SET server_version = 99 WHERE rowid = 1');
    expect(check().outOfOrder, 1);
  });

  test('catches different final data', () {
    tamperServer(
      "UPDATE srv_record SET payload = '{\"v\":-1}' WHERE entity_id = 'e3'",
    );
    expect(check().mismatches, 1);
  });

  test('catches a save the phone forgot', () {
    File(log).writeAsStringSync('ghost 1 ok\n', mode: FileMode.append);
    expect(check().forgotten, 1);
  });
}
