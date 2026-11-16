import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sf_server/sf_server.dart';
import 'package:sf_sync/sf_sync.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Talks to a ServerStore directly (no network), and misbehaves when told to.
final class FakeTransport implements SyncTransport {
  FakeTransport(this.server);

  final ServerStore server;

  /// Fail the next push BEFORE the server sees anything.
  SendFailure? failNextPush;

  /// The server applies the next push, but the reply is lost on the way back.
  bool loseNextReply = false;

  int pushCalls = 0;

  @override
  Future<List<PushReply>> push(String clientId, List<PushOp> ops) async {
    pushCalls++;
    final failure = failNextPush;
    if (failure != null) {
      failNextPush = null;
      throw failure;
    }
    final replies = [for (final op in ops) server.receive(clientId, op)];
    if (loseNextReply) {
      loseNextReply = false;
      throw const DeliveryUnknown('reply lost on the way back');
    }
    return replies;
  }

  @override
  Future<List<StatusReply>> status(String clientId, List<String> opIds) async =>
      [
        for (final id in opIds)
          StatusReply(
            id,
            applied: server.status(clientId, id) != null,
            serverVersion: server.status(clientId, id)?.serverVersion,
          ),
      ];

  @override
  void close() {}
}

void main() {
  late Directory dir;
  late String path;
  late LocalStore phone;
  late ServerStore server;
  late FakeTransport transport;
  late SyncEngine engine;
  var now = DateTime(2026, 11, 16, 9);

  SyncEngine engineFor(LocalStore store) => SyncEngine(
    store: store,
    transport: transport,
    clock: () => now,
    backoff: fixedBackoff(const Duration(seconds: 30)),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sf_engine_test');
    path = '${dir.path}/phone.db';
    phone = LocalStore.open(path);
    server = ServerStore.open(':memory:');
    transport = FakeTransport(server);
    now = DateTime(2026, 11, 16, 9);
    engine = engineFor(phone);
  });

  tearDown(() {
    phone.close();
    server.close();
    dir.deleteSync(recursive: true);
  });

  test('one round sends everything and confirms it', () async {
    final ids = [
      for (var i = 0; i < 3; i++) phone.create('note', {'n': i}).entityId,
    ];
    final report = await engine.syncOnce();
    expect(report.confirmed, 3);
    for (final id in ids) {
      expect(phone.get('note', id)!.syncStatus, SyncStatus.confirmed);
      expect(phone.get('note', id)!.serverVersion, 1);
      expect(server.payloadOf('note', id), isNotNull);
    }
  });

  test('a record\'s changes arrive in order', () async {
    final id = phone.create('note', {'title': 'v1'}).entityId;
    phone.put('note', id, {'title': 'v2'});
    phone.put('note', id, {'title': 'v3'});
    await engine.syncOnce();
    expect(server.payloadOf('note', id), {'title': 'v3'});
    expect(phone.get('note', id)!.serverVersion, 3);
  });

  test('not delivered: waits, then retries with the same opId', () async {
    final id = phone.create('note', {'title': 'A'}).entityId;
    transport.failNextPush = const NotDelivered('no signal');

    final first = await engine.syncOnce();
    expect(first.retryLater, 1);
    expect(first.failure, isA<NotDelivered>());
    expect(phone.get('note', id)!.syncStatus, SyncStatus.retryScheduled);

    expect((await engine.syncOnce()).confirmed, 0); // too early: still waiting
    now = now.add(const Duration(seconds: 31));
    expect((await engine.syncOnce()).confirmed, 1);
    expect(phone.get('note', id)!.syncStatus, SyncStatus.confirmed);
  });

  test('lost reply: the next round ASKS instead of resending', () async {
    final id = phone.create('note', {'title': 'A'}).entityId;
    transport.loseNextReply = true;

    final first = await engine.syncOnce();
    expect(first.unsure, 1);
    expect(phone.get('note', id)!.syncStatus, SyncStatus.sentUnconfirmed);

    final second = await engine.syncOnce();
    expect(second.confirmed, 1);
    expect(phone.get('note', id)!.syncStatus, SyncStatus.confirmed);
    expect(transport.pushCalls, 1); // the data was NOT sent a second time
  });

  test(
    'unsure, and the server never got it: resent in the same round',
    () async {
      final id = phone.create('note', {'title': 'A'}).entityId;
      transport.failNextPush = const DeliveryUnknown(
        'timed out before the server saw it',
      );
      await engine.syncOnce();
      expect(phone.get('note', id)!.syncStatus, SyncStatus.sentUnconfirmed);

      final second = await engine.syncOnce();
      expect(second.confirmed, 1);
      expect(transport.pushCalls, 2);
      expect(server.payloadOf('note', id), {'title': 'A'});
    },
  );

  test(
    'a rejected change blocks only its own record, and nothing is deleted',
    () async {
      final bad = phone.create('note', {'title': 'bad'}).entityId;
      final good = phone.create('note', {'title': 'good'}).entityId;

      // Damage the bad change's fingerprint behind the store's back.
      final db = sqlite3.open(path);
      db.execute(
        "UPDATE sf_outbox SET payload_hash = 'damaged' WHERE entity_id = ?",
        [bad],
      );
      db.dispose();

      final report = await engine.syncOnce();
      expect(report.rejected, 1);
      expect(report.confirmed, 1);
      expect(phone.get('note', bad)!.syncStatus, SyncStatus.rejected);
      expect(phone.get('note', bad)!.payload, {
        'title': 'bad',
      }); // still on the phone
      expect(phone.get('note', good)!.syncStatus, SyncStatus.confirmed);
    },
  );

  test('crash after the server saved it: restart, ask, confirm', () async {
    final id = phone.create('note', {'title': 'A'}).entityId;
    final batch = phone.takeBatch(); // marked sending...
    await transport.push(phone.clientId, [
      for (final op in batch) op.toPushOp(),
    ]); // ...saved...
    phone.close(); // ...and the phone dies before recording the reply.

    phone = LocalStore.open(path); // the app starts again
    engine = engineFor(phone);
    final report = await engine.syncOnce();
    expect(report.confirmed, 1);
    expect(phone.get('note', id)!.syncStatus, SyncStatus.confirmed);
    expect(transport.pushCalls, 1); // never sent twice
  });

  test('end to end over real HTTP', () async {
    final http = await SyncHttpServer.start(server, port: 0);
    final real = HttpTransport(Uri.parse('http://127.0.0.1:${http.port}'));
    try {
      final ids = [
        for (var i = 0; i < 5; i++)
          phone.create('survey', {'site': 'S$i', 'depth_cm': i * 10}).entityId,
      ];
      final report = await SyncEngine(store: phone, transport: real).syncOnce();
      expect(report.confirmed, 5);
      expect(server.payloadOf('survey', ids.last), {
        'site': 'S4',
        'depth_cm': 40,
      });
    } finally {
      real.close();
      await http.close();
    }
  });

  test('syncAll keeps going until the outbox is empty', () async {
    for (var i = 0; i < 250; i++) {
      phone.create('note', {'n': i});
    }
    final report = await engine.syncAll();
    expect(report!.confirmed, 250);
    expect(transport.pushCalls, 3); // batches of 100 + 100 + 50
  });

  test('syncAll stops at the first failure', () async {
    for (var i = 0; i < 3; i++) {
      phone.create('note', {'n': i});
    }
    transport.failNextPush = const NotDelivered('no signal');
    final report = await engine.syncAll();
    expect(report!.failure, isA<NotDelivered>());
    expect(transport.pushCalls, 1); // did not hammer a dead network
  });

  test('a policy that says no means no network use at all', () async {
    final id = phone.create('note', {'title': 'A'}).entityId;
    final report = await engine.syncAll(
      policy: syncWindow(fromHour: 22, toHour: 5),
      context: SyncContext(now: DateTime(2026, 11, 16, 12)),
    );
    expect(report, isNull);
    expect(transport.pushCalls, 0);
    expect(
      phone.get('note', id)!.syncStatus,
      SyncStatus.queued,
    ); // safe on the phone
  });

  test(
    'backoff grows with each failed round and resets after success',
    () async {
      final seen = <int>[];
      final e = SyncEngine(
        store: phone,
        transport: transport,
        clock: () => now,
        backoff: (failures) {
          seen.add(failures);
          return const Duration(seconds: 10);
        },
      );
      phone.create('note', {'title': 'A'});

      transport.failNextPush = const NotDelivered('down');
      await e.syncOnce();
      now = now.add(const Duration(seconds: 11));
      transport.failNextPush = const NotDelivered('still down');
      await e.syncOnce();
      expect(seen, [
        1,
        2,
      ]); // the second wait was chosen for "2 failures in a row"
      expect(e.consecutiveFailures, 2);

      now = now.add(const Duration(seconds: 11));
      await e.syncOnce(); // the network is back
      expect(e.consecutiveFailures, 0);
    },
  );
}
