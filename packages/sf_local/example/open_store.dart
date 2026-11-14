import 'package:sf_local/sf_local.dart';

void main() {
  final store = LocalStore.open('demo.db');
  print('Client ID: ${store.clientId}');
  print('Tables:    ${store.tableNames()}');
  store.close();
}