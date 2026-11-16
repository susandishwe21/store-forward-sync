import 'package:sf_local/sf_local.dart';
import 'package:sf_sync/sf_sync.dart';

Future<void> main(List<String> args) async {
  final store = LocalStore.open('phone.db');
  final transport = HttpTransport(
    Uri.parse(args.isEmpty ? 'http://127.0.0.1:8090' : args.first),
    connectTimeout: const Duration(seconds: 3),
  );
  final engine = SyncEngine(
    store: store,
    transport: transport,
    backoff: fixedBackoff(const Duration(seconds: 5)),
  );

  final note = store.create('note', {'title': 'Saved at ${DateTime.now()}'});
  print('Saved locally: ${store.get('note', note.entityId)}');

  final report = await engine.syncOnce();
  print('Sync round:    $report');
  print('Now:           ${store.get('note', note.entityId)}');
  print('Outbox:        ${store.outboxSummary()}');

  transport.close();
  store.close();
}
