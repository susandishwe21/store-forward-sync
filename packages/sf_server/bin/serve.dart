import 'dart:io';

import 'package:sf_server/sf_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final host = args.length > 1 ? InternetAddress(args[1]) : InternetAddress.loopbackIPv4;
  final store = ServerStore.open('server.db');
  final server = await SyncHttpServer.start(store, port: port, address: host);
  print('SFSP server listening on ${host.address}:${server.port}  (Ctrl+C to stop)');

  await ProcessSignal.sigint.watch().first;
  await server.close();
  store.close();
  print('Stopped.');
}