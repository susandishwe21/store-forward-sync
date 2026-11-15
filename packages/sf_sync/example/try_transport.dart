import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_sync/sf_sync.dart';

Future<void> main(List<String> args) async {
  final url = Uri.parse(args.isEmpty ? 'http://127.0.0.1:8090' : args.first);
  final transport = HttpTransport(
    url,
    connectTimeout: const Duration(seconds: 3),
  );

  final payload = {'site': 'Bridge', 'depth_cm': 135};
  final op = PushOp(
    opId: newUuidV7(),
    entityType: 'survey',
    entityId: newUuidV7(),
    seq: 1,
    opType: 'create',
    payload: payload,
    payloadHash: payloadHash(payload),
  );

  try {
    final replies = await transport.push('phone-demo', [op]);
    print('Server says: ${replies.single}');
  } on SendFailure catch (failure) {
    print(failure);
    print('Next step: ${whatNext(failure)}');
  } finally {
    transport.close();
  }
}

/// The compiler checks that every kind of failure is handled.
String whatNext(SendFailure failure) => switch (failure) {
  NotDelivered() => 'retryScheduled: just send it again later',
  DeliveryUnknown() => 'sentUnconfirmed: ask the server before resending',
  RequestRejected() => 'rejected: retrying will not help, needs a fix',
};
