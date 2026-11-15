import 'dart:io';

import 'package:sf_server/sf_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 8080 : int.parse(args.first);
  final store = ServerStore.open('server.db');
  final server = await SyncHttpServer.start(store, port: port);
  print(
    'SFSP server listening on http://127.0.0.1:${server.port}  (Ctrl+C to stop)',
  );

  await ProcessSignal.sigint.watch().first; // wait for Ctrl+C
  await server.close();
  store.close();
  print('Stopped.');
}
