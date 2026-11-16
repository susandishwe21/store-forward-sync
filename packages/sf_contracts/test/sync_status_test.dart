import 'package:sf_contracts/sf_contracts.dart';
import 'package:test/test.dart';

void main() {
  test('a saved record can be picked for sending', () {
    expect(
      transition(SyncStatus.queued, SyncEvent.batchBuilt),
      SyncStatus.sending,
    );
  });

  test(
    'a record being sent becomes confirmed when the server says applied',
    () {
      expect(
        transition(SyncStatus.sending, SyncEvent.ackApplied),
        SyncStatus.confirmed,
      );
    },
  );

  test('a record can never jump straight from queued to confirmed', () {
    expect(transition(SyncStatus.queued, SyncEvent.ackApplied), isNull);
  });

  test('network down: the record waits and is not lost', () {
    expect(
      transition(SyncStatus.sending, SyncEvent.transientError),
      SyncStatus.retryScheduled,
    );
    expect(
      transition(SyncStatus.retryScheduled, SyncEvent.backoffElapsed),
      SyncStatus.queued,
    );
  });

  test('a waiting record cannot be sent before its wait is over', () {
    expect(transition(SyncStatus.retryScheduled, SyncEvent.batchBuilt), isNull);
  });

  test('lost reply: the record becomes sentUnconfirmed, not failed', () {
    expect(
      transition(SyncStatus.sending, SyncEvent.ambiguousResponse),
      SyncStatus.sentUnconfirmed,
    );
  });

  test(
    'sentUnconfirmed can never be resent without asking the server first',
    () {
      expect(
        transition(SyncStatus.sentUnconfirmed, SyncEvent.batchBuilt),
        isNull,
      );
    },
  );

  test('asking the server settles the unknown', () {
    expect(
      transition(SyncStatus.sentUnconfirmed, SyncEvent.statusApplied),
      SyncStatus.confirmed,
    );
    expect(
      transition(SyncStatus.sentUnconfirmed, SyncEvent.statusUnknown),
      SyncStatus.queued,
    );
  });

  test('a crash while sending is treated as unknown, not as failed', () {
    expect(
      transition(SyncStatus.sending, SyncEvent.appRestarted),
      SyncStatus.sentUnconfirmed,
    );
  });

  test('a permanent error ends in rejected, and rejected is final', () {
    expect(
      transition(SyncStatus.sending, SyncEvent.permanentError),
      SyncStatus.rejected,
    );
    for (final event in SyncEvent.values) {
      expect(transition(SyncStatus.rejected, event), isNull);
    }
  });
}
