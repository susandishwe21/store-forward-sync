import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sf_lesson6_test');
    path = '${dir.path}/store.db';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Pretends a sender picked every queued change, then the phone died.
  void simulateCrashWhileSending() {
    final db = sqlite3.open(path);
    db.execute(
      "UPDATE sf_outbox SET status = 'sending' WHERE status = 'queued'",
    );
    db.dispose();
  }

  group('validation', () {
    test('invalid data is refused and NOTHING is stored', () {
      final store = LocalStore.open(path);
      store.registerValidator(
        'survey',
        requireFields({'title': FieldType.text, 'depth_cm': FieldType.integer}),
      );

      expect(
        () => store.put('survey', 's1', {'title': 'Bridge'}),
        throwsA(isA<ValidationException>()),
      );
      expect(store.get('survey', 's1'), isNull);
      expect(store.operationCount(), 0);
      store.close();
    });

    test('all problems are reported at once', () {
      final store = LocalStore.open(path);
      store.registerValidator(
        'survey',
        requireFields({'title': FieldType.text, 'depth_cm': FieldType.integer}),
      );
      try {
        store.create('survey', {'depth_cm': 'abc'});
        fail('should have thrown');
      } on ValidationException catch (e) {
        expect(e.problems, ['title is required', 'depth_cm must be integer']);
      }
      store.close();
    });

    test('valid data is saved; types without rules accept anything', () {
      final store = LocalStore.open(path);
      store.registerValidator(
        'survey',
        requireFields({'title': FieldType.text}),
      );
      store.create('survey', {'title': 'OK'});
      store.create('note', {'anything': true});
      expect(store.operationCount(), 2);
      store.close();
    });
  });

  group('crash recovery', () {
    test('sending becomes sentUnconfirmed after restart, nothing is lost', () {
      var store = LocalStore.open(path);
      store.create('note', {'title': 'in flight'});
      store.close();

      simulateCrashWhileSending();

      store = LocalStore.open(path); // the app starts again
      final summary = store.outboxSummary();
      expect(summary[SyncStatus.sending], 0);
      expect(summary[SyncStatus.sentUnconfirmed], 1);
      expect(store.operationCount(), 1);
      store.close();
    });

    test('changes that were only queued stay queued', () {
      var store = LocalStore.open(path);
      store.create('note', {'title': 'was being sent'});
      store.close();
      simulateCrashWhileSending();

      store = LocalStore.open(path);
      store.create('note', {'title': 'saved after restart'});
      store.close();

      store = LocalStore.open(path);
      final summary = store.outboxSummary();
      expect(summary[SyncStatus.sentUnconfirmed], 1);
      expect(summary[SyncStatus.queued], 1);
      store.close();
    });
  });

  group('reading', () {
    test('query lists live records oldest first and hides deleted ones', () {
      final store = LocalStore.open(path);
      final a = store.create('note', {'title': 'A'});
      final b = store.create('note', {'title': 'B'});
      store.create('task', {'title': 'other type'});
      store.delete('note', a.entityId);

      expect(store.query('note').map((r) => r.payload!['title']), ['B']);
      expect(store.query('note', includeDeleted: true).map((r) => r.entityId), [
        a.entityId,
        b.entityId,
      ]);
      store.close();
    });

    test('outboxSummary counts new saves as queued', () {
      final store = LocalStore.open(path);
      store.create('note', {'title': '1'});
      store.create('note', {'title': '2'});
      expect(store.outboxSummary()[SyncStatus.queued], 2);
      expect(store.outboxSummary()[SyncStatus.confirmed], 0);
      store.close();
    });
  });
}
