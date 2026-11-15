import 'dart:convert';
import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_server/sf_server.dart';
import 'package:test/test.dart';

void main() {
  late ServerStore store;
  late SyncHttpServer server;

  setUp(() async {
    store = ServerStore.open(':memory:');
    server = await SyncHttpServer.start(store, port: 0); // any free port
  });
  tearDown(() async {
    await server.close();
    store.close();
  });

  Future<(int, Map<String, Object?>)> send(String method, String path, [Object? body]) async {
    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(body is String ? body : jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      return (res.statusCode, (jsonDecode(text) as Map).cast<String, Object?>());
    } finally {
      client.close();
    }
  }

  Map<String, Object?> op(String opId, String entityId, Map<String, Object?> payload,
          {String? hash}) =>
      PushOp(
        opId: opId,
        entityType: 'note',
        entityId: entityId,
        seq: 1,
        opType: 'create',
        payload: payload,
        payloadHash: hash ?? payloadHash(payload),
      ).toJson();

  Map<String, Object?> batch(List<Map<String, Object?>> ops) =>
      {'sfsp': sfspVersion, 'clientId': 'phone-A', 'ops': ops};

  List<PushResult> resultsOf(Map<String, Object?> json) => [
        for (final r in json['replies'] as List)
          PushReply.fromJson((r as Map).cast<String, Object?>()).result,
      ];

  final threeChanges = [
    op('op1', 'n1', {'title': 'A'}),
    op('op2', 'n2', {'title': 'B'}, hash: payloadHash({'title': 'damaged'})),
    op('op3', 'n3', {'title': 'C'}),
  ];

  test('health check answers', () async {
    final (status, json) = await send('GET', '/health');
    expect(status, 200);
    expect(json['sfsp'], sfspVersion);
  });

  test('each change in a batch gets its own reply', () async {
    final (status, json) = await send('POST', '/sync/push', batch(threeChanges));
    expect(status, 200);
    expect(resultsOf(json), [PushResult.applied, PushResult.rejected, PushResult.applied]);
  });

  test('resending the whole batch is safe', () async {
    await send('POST', '/sync/push', batch(threeChanges));
    final (_, json) = await send('POST', '/sync/push', batch(threeChanges));
    expect(resultsOf(json), [PushResult.duplicate, PushResult.rejected, PushResult.duplicate]);
  });

  test('status tells the phone which changes the server has', () async {
    await send('POST', '/sync/push', batch([op('op1', 'n1', {'title': 'A'})]));
    final (status, json) = await send('POST', '/sync/ops/status',
        {'sfsp': sfspVersion, 'clientId': 'phone-A', 'opIds': ['op1', 'never-sent']});
    expect(status, 200);
    final statuses = [
      for (final s in json['statuses'] as List)
        StatusReply.fromJson((s as Map).cast<String, Object?>()),
    ];
    expect(statuses[0].applied, isTrue);
    expect(statuses[0].serverVersion, 1);
    expect(statuses[1].applied, isFalse);
  });

  test('broken requests get 400, and the server keeps working', () async {
    final (s1, _) = await send('POST', '/sync/push', 'this is not json');
    expect(s1, 400);
    final (s2, _) = await send('POST', '/sync/push', {
      'sfsp': sfspVersion,
      'clientId': 'phone-A',
      'ops': [
        {'opId': 5},
      ],
    });
    expect(s2, 400);
    final (s3, _) = await send('GET', '/health');
    expect(s3, 200);
  });

  test('an unknown protocol version is refused', () async {
    final (status, json) = await send('POST', '/sync/push',
        {'sfsp': 99, 'clientId': 'phone-A', 'ops': <Object>[]});
    expect(status, 400);
    expect(json['error'], contains('version'));
  });

  test('unknown address gives 404', () async {
    final (status, _) = await send('GET', '/');
    expect(status, 404);
  });
}