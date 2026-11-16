import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;
  late LocalStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sf_outbox_test');
    path = '${dir.path}/store.db';
    store = LocalStore.open(path);
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  test('takeBatch marks changes as sending, oldest first', () {
    final a = store.create('note', {'title': 'A'});
    final b = store.create('note', {'title': 'B'});
    final batch = store.takeBatch();
    expect(batch.map((e) => e.entityId), [a.entityId, b.entityId]);
    expect(
      batch.every((e) => e.status == SyncStatus.sending && e.attempts == 1),
      isTrue,
    );
    expect(store.outboxSummary()[SyncStatus.sending], 2);
    expect(store.takeBatch(), isEmpty); // nothing left to take
  });

  test(
    'a change waits while an earlier change to the same record is unresolved',
    () {
      final a = store.create('note', {'title': 'v1'});
      store.takeBatch(); // v1 is now sending
      store.put('note', a.entityId, {'title': 'v2'}); // v2 must wait
      final other = store.create('note', {'title': 'another record'});
      expect(store.takeBatch().map((e) => e.entityId), [other.entityId]);
    },
  );

  test('one record\'s changes stay in order, and limit is respected', () {
    final a = store.create('note', {'title': 'v1'});
    store.put('note', a.entityId, {'title': 'v2'});
    store.put('note', a.entityId, {'title': 'v3'});
    expect(store.takeBatch(limit: 2).map((e) => e.seq), [1, 2]);
    expect(store.takeBatch(), isEmpty); // v3 waits for v1 and v2
  });

  test('ackApplied confirms the change and stores the server version', () {
    final a = store.create('note', {'title': 'A'});
    final op = store.takeBatch().single;
    store.applyEvent(
      SyncEvent.ackApplied,
      [op.opId],
      serverVersions: {op.opId: 7},
    );
    final record = store.get('note', a.entityId)!;
    expect(record.syncStatus, SyncStatus.confirmed);
    expect(record.serverVersion, 7);
  });

  test('a transient error waits until its retry time, with the same opId', () {
    final t0 = DateTime(2026, 11, 16, 9);
    store.create('note', {'title': 'A'});
    final op = store.takeBatch(now: t0).single;
    store.applyEvent(SyncEvent.transientError, [
      op.opId,
    ], retryAt: t0.add(const Duration(seconds: 30)));

    expect(store.takeBatch(now: t0.add(const Duration(seconds: 10))), isEmpty);
    final again = store
        .takeBatch(now: t0.add(const Duration(seconds: 31)))
        .single;
    expect(
      again.opId,
      op.opId,
    ); // same receipt number: the server can spot a repeat
    expect(again.attempts, 2);
  });

  test('an impossible event changes nothing at all', () {
    store.create('note', {'title': 'A'});
    final sent = store.takeBatch().single;

    expect(
      () =>
          store.applyEvent(SyncEvent.ackApplied, [sent.opId, 'no-such-change']),
      throwsStateError,
    );
    expect(
      store.outboxSummary()[SyncStatus.sending],
      1,
    ); // the first one was rolled back too

    store.applyEvent(SyncEvent.ackApplied, [sent.opId]);
    expect(
      () => store.applyEvent(SyncEvent.ackApplied, [sent.opId]),
      throwsStateError,
    ); // confirmed cannot be confirmed again
  });

  test('a rejected change blocks only its own record', () {
    final bad = store.create('note', {'title': 'bad'});
    final op = store.takeBatch().single;
    store.applyEvent(SyncEvent.permanentError, [op.opId]);

    store.put('note', bad.entityId, {
      'title': 'edited after rejection',
    }); // must not jump ahead
    final good = store.create('note', {'title': 'good'});

    expect(store.takeBatch().map((e) => e.entityId), [good.entityId]);
    expect(store.get('note', bad.entityId)!.syncStatus, SyncStatus.rejected);
  });

  test('a record shows the status of its oldest unconfirmed change', () {
    final a = store.create('note', {'title': 'v1'});
    final v1 = store.takeBatch().single;
    expect(store.get('note', a.entityId)!.syncStatus, SyncStatus.sending);

    store.put('note', a.entityId, {'title': 'v2'});
    expect(
      store.get('note', a.entityId)!.syncStatus,
      SyncStatus.sending,
    ); // v1 still on its way

    store.applyEvent(SyncEvent.ackApplied, [v1.opId]);
    expect(
      store.get('note', a.entityId)!.syncStatus,
      SyncStatus.queued,
    ); // now v2 is oldest
  });

  test('after a crash: ask the server, then confirm or resend', () {
    final a = store.create('note', {'title': 'A'});
    final b = store.create('note', {'title': 'B'});
    store.takeBatch();
    store.close();
    store = LocalStore.open(path); // the app restarts

    expect(
      store.get('note', a.entityId)!.syncStatus,
      SyncStatus.sentUnconfirmed,
    );
    final unsure = store.awaitingConfirmation();
    expect(unsure, hasLength(2));

    // The server answers: "I have A. I never got B."
    store.applyEvent(
      SyncEvent.statusApplied,
      [unsure[0].opId],
      serverVersions: {unsure[0].opId: 1},
    );
    store.applyEvent(SyncEvent.statusUnknown, [unsure[1].opId]);

    expect(store.get('note', a.entityId)!.syncStatus, SyncStatus.confirmed);
    final resend = store.takeBatch().single;
    expect(resend.entityId, b.entityId);
    expect(resend.opId, unsure[1].opId); // the same receipt number as before
  });
}
