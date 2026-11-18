import 'dart:math';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_server/sf_server.dart';
import 'package:sf_sync/sf_sync.dart';

import 'network.dart';

/// A transport whose result depends on the simulated network at the current
/// (virtual) time. It talks to a REAL ServerStore, so dedupe and order are real.
final class TraceTransport implements SyncTransport {
  TraceTransport({
    required this.server,
    required this.trace,
    required this.clock,
    required int seed,
  }) : _random = Random(seed);

  final ServerStore server;
  final NetworkTrace trace;
  final DateTime Function() clock;
  final Random _random;

  /// Turned on at the very end, to drain everything on a perfect network.
  bool forceGood = false;

  int requests = 0;
  int failedRequests = 0;
  int bytesSent = 0;

  /// Seconds the radio was busy. Failures are expensive: you wait for a timeout.
  double radioSeconds = 0;

  bool get _good => forceGood || trace.at(clock()).good;

  /// Decides what happens to one request. Returns normally only on full success.
  void _travel(int bytes, {void Function()? serverWork}) {
    requests++;
    bytesSent += bytes;
    final good = _good;
    final roll = _random.nextDouble();
    if (!good && roll < 0.8) {
      failedRequests++;
      radioSeconds += 10; // connect timeout
      throw const NotDelivered('no network (simulated)');
    }
    serverWork?.call(); // the request reached the server
    if (!good || (!forceGood && roll >= 0.97)) {
      failedRequests++;
      radioSeconds += 30; // waited for a reply that never came
      throw const DeliveryUnknown('reply lost (simulated)');
    }
    radioSeconds += 1 + bytes / 20000; // ~1 s + 20 KB/s
  }

  @override
  Future<List<PushReply>> push(String clientId, List<PushOp> ops) async {
    final bytes = ops.fold<int>(0, (sum, op) => sum + canonicalJson(op.payload).length + 120);
    late List<PushReply> replies;
    _travel(bytes, serverWork: () {
      replies = [for (final op in ops) server.receive(clientId, op)];
    });
    return replies;
  }

  @override
  Future<List<StatusReply>> status(String clientId, List<String> opIds) async {
    _travel(60 + opIds.length * 40);
    return [
      for (final id in opIds)
        StatusReply(id,
            applied: server.status(clientId, id) != null,
            serverVersion: server.status(clientId, id)?.serverVersion),
    ];
  }

  @override
  Future<PullReply> pull(String clientId, {required int since, required int limit}) async {
    _travel(80);
    return server.pull(since: since, limit: limit);
  }

  @override
  void close() {}
}
