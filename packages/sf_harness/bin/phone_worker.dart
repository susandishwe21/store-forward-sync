import 'dart:io';
import 'dart:math';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_harness/sf_harness.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sf_sync/sf_sync.dart';

/// One "phone": saves random changes and syncs, forever, until it is killed.
/// With --drain it only syncs until every change is confirmed, then exits.
Future<void> main(List<String> args) async {
  final options = parseOptions(args);
  final store = LocalStore.open(options['db']!);
  final transport = HttpTransport(
    Uri.parse(options['server']!),
    connectTimeout: const Duration(seconds: 2),
    replyTimeout: const Duration(seconds: 2),
  );
  final engine = SyncEngine(
    store: store,
    transport: transport,
    batchSize: 10,
    backoff: fixedBackoff(Duration.zero),
  );

  if (options['drain'] == 'true') {
    await _drain(engine, store);
    transport.close();
    store.close();
    return;
  }

  final random = Random(int.parse(options['seed'] ?? '1'));
  final entities = int.parse(options['entities'] ?? '40');
  final log = File(options['log']!);
  while (true) {
    if (random.nextDouble() < 0.7) {
      _saveSomething(store, random, entities, log);
    } else {
      await engine.syncOnce();
    }
  }
}

void _saveSomething(LocalStore store, Random random, int entities, File log) {
  final id = 'e${random.nextInt(entities)}';
  final existing = store.get('item', id); // null when missing or deleted
  final LocalRecord saved;
  if (existing != null && random.nextDouble() < 0.2) {
    saved = store.delete('item', id);
  } else {
    saved = store.put('item', id, {'value': random.nextInt(1 << 30)});
  }
  // Written only AFTER the save returned: the app now believes it is saved.
  log.writeAsStringSync(
    '${saved.entityId} ${saved.localSeq} ok\n',
    mode: FileMode.append,
    flush: true,
  );
}

Future<void> _drain(SyncEngine engine, LocalStore store) async {
  for (var i = 0; i < 1000; i++) {
    await engine.syncAll();
    final s = store.outboxSummary();
    final open =
        s[SyncStatus.queued]! +
        s[SyncStatus.sending]! +
        s[SyncStatus.retryScheduled]! +
        s[SyncStatus.sentUnconfirmed]!;
    if (open == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  stderr.writeln('drain gave up: ${store.outboxSummary()}');
  exitCode = 1;
}
