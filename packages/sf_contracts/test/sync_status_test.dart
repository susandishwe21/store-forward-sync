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
}
