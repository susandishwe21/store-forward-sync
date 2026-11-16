import 'dart:io';
import 'dart:math';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sf_server/sf_server.dart';
import 'package:sf_sync/sf_sync.dart';
import 'package:sqlite3/sqlite3.dart';

import '../verify.dart';
import 'network.dart';
import 'policies.dart';
import 'trace_transport.dart';

/// The outcome of one simulated run.
final class SimResult {
  const SimResult({
    required this.policy,
    required this.seed,
    required this.saves,
    required this.attempts,
    required this.requests,
    required this.failedRequests,
    required this.radioSeconds,
    required this.bytesSent,
    required this.meanExposureMin,
    required this.p95ExposureMin,
    required this.unconfirmedAtEnd,
    required this.safe,
  });

  final String policy;
  final int seed;
  final int saves;
  final int attempts;
  final int requests;
  final int failedRequests;
  final double radioSeconds;
  final int bytesSent;

  /// Minutes from saving a change until it was confirmed (the exposure window).
  final double meanExposureMin;
  final double p95ExposureMin;
  final int unconfirmedAtEnd;

  /// All kill-test invariants hold after the final drain.
  final bool safe;

  static const csvHeader =
      'policy,seed,saves,attempts,requests,failed_requests,'
      'radio_seconds,bytes_sent,mean_exposure_min,p95_exposure_min,unconfirmed_at_end,safe';

  String toCsv() =>
      '$policy,$seed,$saves,$attempts,$requests,$failedRequests,'
      '${radioSeconds.toStringAsFixed(1)},$bytesSent,${meanExposureMin.toStringAsFixed(2)},'
      '${p95ExposureMin.toStringAsFixed(2)},$unconfirmedAtEnd,$safe';
}

/// Runs the REAL store, engine and server for [days] of simulated time, minute
/// by minute. If [dataset] is given, every sync attempt becomes one training row.
Future<SimResult> simulate({
  required String policyName,
  required SyncDecider decide,
  required int seed,
  int days = 7,
  bool oracle = false,
  IOSink? dataset,
}) async {
  final dir = Directory.systemTemp.createTempSync('sf_sim');
  final phoneDb = '${dir.path}/phone.db';
  final serverDb = '${dir.path}/server.db';
  final trace = NetworkTrace.generate(days: days, seed: seed);
  final work = Random(seed * 7919 + 1); // the SAME workload for every policy

  var now = trace.start;
  final phone = LocalStore.open(phoneDb);
  final server = ServerStore.open(serverDb);
  final transport = TraceTransport(
    server: server,
    trace: trace,
    clock: () => now,
    seed: seed,
  );
  final engine = SyncEngine(
    store: phone,
    transport: transport,
    clock: () => now,
    batchSize: 50,
    backoff: fixedBackoff(Duration.zero),
  ); // the POLICY decides timing, not the engine
  final reader = sqlite3.open(phoneDb);

  final savedAt = <String, DateTime>{}; // "entityId seq" → when it was saved
  final open = <String>{}; // saved but not yet confirmed
  final exposures = <double>[];
  var lastSuccess = now;
  var lastAttempt = now.subtract(const Duration(days: 1));
  var lastFailed = false;
  var attempts = 0;
  var saves = 0;

  for (var minute = 0; minute < trace.length; minute++) {
    now = trace.start.add(Duration(minutes: minute));

    // 1. The field worker saves data, mostly during working hours.
    final working = now.hour >= 7 && now.hour < 18;
    if (work.nextDouble() < (working ? 0.08 : 0.005)) {
      final r = phone.put('item', 'e${work.nextInt(50)}', {
        'value': work.nextInt(1 << 30),
        'at': '$now',
      });
      final key = '${r.entityId} ${r.localSeq}';
      savedAt[key] = now;
      open.add(key);
      saves++;
    }
    if (open.isEmpty) continue; // nothing waiting: nothing to decide

    // 2. What can the phone see right now?
    final oldest = open
        .map((k) => savedAt[k]!)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final observation = Observation(
      time: now,
      bars: trace.at(now).bars,
      minutesSinceSuccess: now.difference(lastSuccess).inMinutes,
      lastAttemptFailed: lastFailed,
      failuresInARow: engine.consecutiveFailures,
      pending: open.length,
      oldestPendingMinutes: now.difference(oldest).inMinutes,
      minutesSinceAttempt: now.difference(lastAttempt).inMinutes,
    );

    // 3. The policy decides. Only the oracle may peek at the truth.
    final go = oracle ? trace.at(now).good : decide(observation);
    if (!go) continue;

    attempts++;
    lastAttempt = now;
    final report = await engine.syncAll(maxRounds: 5);
    final success = report != null && report.failure == null;
    if (success) lastSuccess = now;
    lastFailed = !success;

    // 4. One training row: what the phone saw, and whether the attempt worked.
    dataset?.writeln(
      [
        for (final f in observation.features) f.toStringAsFixed(4),
        success ? 1 : 0,
        policyName,
        seed,
      ].join(','),
    );

    // 5. Which changes are now confirmed? Record how long each one waited.
    for (final row in reader.select(
      "SELECT entity_id, seq FROM sf_outbox WHERE status = 'confirmed'",
    )) {
      final key = '${row['entity_id']} ${row['seq']}';
      if (open.remove(key)) {
        exposures.add(now.difference(savedAt[key]!).inSeconds / 60);
      }
    }
  }

  // Changes still waiting at the end count with the time they have waited so far.
  final unconfirmedAtEnd = open.length;
  for (final key in open) {
    exposures.add(now.difference(savedAt[key]!).inSeconds / 60);
  }
  exposures.sort();
  final mean = exposures.isEmpty
      ? 0.0
      : exposures.reduce((a, b) => a + b) / exposures.length;
  final p95 = exposures.isEmpty
      ? 0.0
      : exposures[(exposures.length * 0.95)
            .floor()
            .clamp(0, exposures.length - 1)
            .toInt()];

  // Safety: drain on a perfect network, then check every invariant.
  transport.forceGood = true;
  for (var i = 0; i < 100; i++) {
    await engine.syncAll();
    final s = phone.outboxSummary();
    final waiting =
        s[SyncStatus.queued]! +
        s[SyncStatus.sending]! +
        s[SyncStatus.retryScheduled]! +
        s[SyncStatus.sentUnconfirmed]!;
    if (waiting == 0) break;
  }
  final verdict = verify(phoneDb: phoneDb, serverDb: serverDb);

  final result = SimResult(
    policy: policyName,
    seed: seed,
    saves: saves,
    attempts: attempts,
    requests: transport.requests,
    failedRequests: transport.failedRequests,
    radioSeconds: transport.radioSeconds,
    bytesSent: transport.bytesSent,
    meanExposureMin: mean,
    p95ExposureMin: p95,
    unconfirmedAtEnd: unconfirmedAtEnd,
    safe: verdict.passed,
  );

  reader.dispose();
  phone.close();
  server.close();
  dir.deleteSync(recursive: true);
  return result;
}
