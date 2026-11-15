import 'dart:convert';
import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_server/sf_server.dart';
import 'package:sf_sync/sf_sync.dart';
import 'package:test/test.dart';

PushOp change(String opId) {
  final payload = {'title': 'note $opId'};
  return PushOp(
    opId: opId,
    entityType: 'note',
    entityId: 'n-$opId',
    seq: 1,
    opType: 'create',
    payload: payload,
    payloadHash: payloadHash(payload),
  );
}

void main() {
  late ServerStore store;
  late SyncHttpServer real;
  final fakes = <HttpServer>[];
  final transports = <HttpTransport>[];

  setUp(() async {
    store = ServerStore.open(':memory:');
    real = await SyncHttpServer.start(store, port: 0);
  });

  tearDown(() async {
    for (final t in transports) {
      t.close();
    }
    transports.clear();
    for (final f in fakes) {
      await f.close(force: true);
    }
    fakes.clear();
    await real.close();
    store.close();
  });

  HttpTransport transportTo(int port) {
    final t = HttpTransport(
      Uri.parse('http://127.0.0.1:$port'),
      replyTimeout: const Duration(milliseconds: 300),
    );
    transports.add(t);
    return t;
  }

  /// Starts a pretend server that behaves however the test says.
  Future<int> fakeServer(
    Future<void> Function(HttpRequest request) behave,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(behave);
    fakes.add(server);
    return server.port;
  }

  test('talks to the real server: applied, then duplicate', () async {
    final t = transportTo(real.port);
    expect(
      (await t.push('phone-A', [change('op1')])).single.result,
      PushResult.applied,
    );
    expect(
      (await t.push('phone-A', [change('op1')])).single.result,
      PushResult.duplicate,
    );
  });

  test('status says which changes the server has', () async {
    final t = transportTo(real.port);
    await t.push('phone-A', [change('op1')]);
    final statuses = await t.status('phone-A', ['op1', 'op-never-sent']);
    expect(statuses.map((s) => s.applied), [true, false]);
  });

  test('A: server is down → NotDelivered', () async {
    final gone = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = gone.port;
    await gone.close(); // nobody is listening on this port any more

    await expectLater(
      transportTo(port).push('phone-A', [change('op1')]),
      throwsA(isA<NotDelivered>()),
    );
  });

  test(
    'B: server takes the request but never answers → DeliveryUnknown',
    () async {
      final port = await fakeServer((request) async {
        await request.drain<void>(); // read everything... then say nothing
      });
      await expectLater(
        transportTo(port).push('phone-A', [change('op1')]),
        throwsA(isA<DeliveryUnknown>()),
      );
    },
  );

  test('B: server crashes with 500 → DeliveryUnknown', () async {
    final port = await fakeServer((request) async {
      await request.drain<void>();
      request.response.statusCode = 500;
      await request.response.close();
    });
    await expectLater(
      transportTo(port).push('phone-A', [change('op1')]),
      throwsA(isA<DeliveryUnknown>()),
    );
  });

  test('400 → RequestRejected', () async {
    final port = await fakeServer((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = 400
        ..write('{"error":"broken"}');
      await request.response.close();
    });
    await expectLater(
      transportTo(port).push('phone-A', [change('op1')]),
      throwsA(isA<RequestRejected>()),
    );
  });

  test('a garbled 200 answer → DeliveryUnknown', () async {
    final port = await fakeServer((request) async {
      await request.drain<void>();
      request.response.write('{"replies": "this is not a list"}');
      await request.response.close();
    });
    await expectLater(
      transportTo(port).push('phone-A', [change('op1')]),
      throwsA(isA<DeliveryUnknown>()),
    );
  });

  test(
    'why B is not A: the server SAVED it, only the reply was lost',
    () async {
      // This pretend server really saves the changes, then never replies.
      final port = await fakeServer((request) async {
        final body =
            (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
                .cast<String, Object?>();
        for (final o in body['ops'] as List) {
          store.receive(
            body['clientId'] as String,
            PushOp.fromJson((o as Map).cast<String, Object?>()),
          );
        }
      });

      await expectLater(
        transportTo(port).push('phone-A', [change('op1')]),
        throwsA(isA<DeliveryUnknown>()),
      );

      // The phone asks the real server: "did you get op1?"
      final answer = await transportTo(real.port).status('phone-A', ['op1']);
      expect(
        answer.single.applied,
        isTrue,
      ); // saved! Calling it "not sent" would be a lie.
    },
  );
}
