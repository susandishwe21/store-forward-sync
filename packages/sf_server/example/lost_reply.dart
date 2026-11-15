import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_server/sf_server.dart';

void main() {
  final server = ServerStore.open(':memory:');
  final payload = {'site': 'Bridge', 'depth_cm': 135};
  final x = PushOp(
    opId: newUuidV7(),
    entityType: 'survey',
    entityId: newUuidV7(),
    seq: 1,
    opType: 'create',
    payload: payload,
    payloadHash: payloadHash(payload),
  );

  print('Phone sends X     -> ${server.receive('phone-A', x)}');
  print('  ...the reply is lost, the phone does not know what happened...');
  print('Phone asks status -> ${server.status('phone-A', x.opId)}');
  print('Phone retries X   -> ${server.receive('phone-A', x)}');
  server.close();
}
