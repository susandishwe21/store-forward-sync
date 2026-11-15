import 'package:sf_local/sf_local.dart';

void main() {
  final store = LocalStore.open('demo.db');
  store.registerValidator(
    'survey',
    requireFields({'site': FieldType.text, 'depth_cm': FieldType.integer}),
  );

  try {
    store.create('survey', {'site': 'Bridge', 'depth_cm': 'very deep'});
  } on ValidationException catch (e) {
    print('Refused: ${e.problems}');
  }

  final s = store.create('survey', {'site': 'Bridge', 'depth_cm': 135});
  print('Latest: ${store.get('survey', s.entityId)}');
  print('All surveys: ${store.query('survey').length}');
  print('Outbox: ${store.outboxSummary()}');
  store.close();
}
