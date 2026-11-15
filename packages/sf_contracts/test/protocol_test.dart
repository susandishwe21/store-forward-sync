import 'dart:convert';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:test/test.dart';

/// Turns a message into JSON text and back, as the network would.
Map<String, Object?> overTheWire(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

void main() {
  test('PushOp survives the trip over the network', () {
    final payload = {'site': 'Bridge', 'depth_cm': 135};
    final op = PushOp(
      opId: 'op1',
      entityType: 'survey',
      entityId: 's1',
      seq: 3,
      opType: 'update',
      payload: payload,
      payloadHash: payloadHash(payload),
    );
    final back = PushOp.fromJson(overTheWire(op.toJson()));
    expect(back.opId, 'op1');
    expect(back.seq, 3);
    expect(back.payload, payload);
    expect(
      payloadHash(back.payload),
      op.payloadHash,
    ); // fingerprint still matches
  });

  test('PushReply and StatusReply survive the trip', () {
    final r = PushReply.fromJson(
      overTheWire(
        const PushReply('op1', PushResult.duplicate, serverVersion: 2).toJson(),
      ),
    );
    expect(r.result, PushResult.duplicate);
    expect(r.serverVersion, 2);
    expect(r.reason, isNull);

    final s = StatusReply.fromJson(
      overTheWire(const StatusReply('op9', applied: false).toJson()),
    );
    expect(s.applied, isFalse);
    expect(s.serverVersion, isNull);
  });
}
