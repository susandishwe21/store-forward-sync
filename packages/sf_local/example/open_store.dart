import 'package:sf_local/sf_local.dart';

void main() {
  final store = LocalStore.open('demo.db');
  final note = store.create('note', {
    'title': 'Water level at bridge',
    'depth_cm': 120,
  });
  store.put('note', note.entityId, {
    'title': 'Water level at bridge',
    'depth_cm': 135,
  });
  print('Saved: $note');
  print('Outbox entries: ${store.operationCount()}');
  store.close();
}
