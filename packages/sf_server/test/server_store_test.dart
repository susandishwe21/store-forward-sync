import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_server/sf_server.dart';
import 'package:test/test.dart';

const phone = 'phone-A';

/// Builds a change the way a phone would, with a correct fingerprint.
PushOp change(
  String opId,
  int seq,
  Map<String, Object?> payload, {
  String opType = 'update',
  String? hash,
}) => PushOp(
  opId: opId,
  entityType: 'note',
  entityId: 'n1',
  seq: seq,
  opType: opType,
  payload: payload,
  payloadHash: hash ?? payloadHash(payload),
);

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sf_server_test');
    path = '${dir.path}/server.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('first arrival is applied as version 1', () {
    final server = ServerStore.open(path);
    final reply = server.receive(
      phone,
      change('op1', 1, {'title': 'A'}, opType: 'create'),
    );
    expect(reply.result, PushResult.applied);
    expect(reply.serverVersion, 1);
    expect(server.payloadOf('note', 'n1'), {'title': 'A'});
    server.close();
  });

  test('sending the same change twice saves it only once', () {
    final server = ServerStore.open(path);
    final op = change('op1', 1, {'title': 'A'}, opType: 'create');
    server.receive(phone, op);
    final again = server.receive(phone, op);
    expect(again.result, PushResult.duplicate);
    expect(again.serverVersion, 1); // same answer as the first time

    final next = server.receive(phone, change('op2', 2, {'title': 'B'}));
    expect(next.serverVersion, 2); // the repeat did not count as a change
    server.close();
  });

  test('the reply was lost: the phone asks, and the server says applied', () {
    final server = ServerStore.open(path);
    expect(server.status(phone, 'op1'), isNull); // never seen
    server.receive(phone, change('op1', 1, {'title': 'A'}, opType: 'create'));
    // ...the reply is lost on the way back to the phone...
    final answer = server.status(phone, 'op1');
    expect(answer!.result, PushResult.applied);
    expect(answer.serverVersion, 1);
    server.close();
  });

  test('a repeat is recognised even after the server restarts', () {
    var server = ServerStore.open(path);
    final op = change('op1', 1, {'title': 'A'}, opType: 'create');
    server.receive(phone, op);
    server.close();

    server = ServerStore.open(path);
    expect(server.receive(phone, op).result, PushResult.duplicate);
    server.close();
  });

  test('same opId with different data is rejected; original data kept', () {
    final server = ServerStore.open(path);
    server.receive(phone, change('op1', 1, {'title': 'A'}, opType: 'create'));
    final evil = server.receive(
      phone,
      change('op1', 1, {'title': 'CHANGED'}, opType: 'create'),
    );
    expect(evil.result, PushResult.rejected);
    expect(server.payloadOf('note', 'n1'), {'title': 'A'});
    server.close();
  });

  test('damaged data (wrong fingerprint) is rejected and not saved', () {
    final server = ServerStore.open(path);
    final reply = server.receive(
      phone,
      change(
        'op1',
        1,
        {'title': 'A'},
        opType: 'create',
        hash: payloadHash({'title': 'B'}),
      ),
    );
    expect(reply.result, PushResult.rejected);
    expect(server.payloadOf('note', 'n1'), isNull);
    server.close();
  });

  test('a change that arrives too early waits for the one before it', () {
    final server = ServerStore.open(path);
    final first = change('op1', 1, {'title': 'A'}, opType: 'create');
    final second = change('op2', 2, {'title': 'B'});

    expect(server.receive(phone, second).result, PushResult.outOfOrder);
    expect(server.receive(phone, first).result, PushResult.applied);
    expect(server.receive(phone, second).result, PushResult.applied);
    expect(server.payloadOf('note', 'n1'), {'title': 'B'});
    server.close();
  });

  test('delete hides the record', () {
    final server = ServerStore.open(path);
    server.receive(phone, change('op1', 1, {'title': 'A'}, opType: 'create'));
    server.receive(phone, change('op2', 2, {}, opType: 'delete'));
    expect(server.payloadOf('note', 'n1'), isNull);
    server.close();
  });
}
