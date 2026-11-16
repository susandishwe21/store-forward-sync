import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';

import 'backoff.dart';
import 'send_failure.dart';
import 'sync_policy.dart';
import 'transport.dart';

/// What one sync round (or several added together) did.
final class SyncReport {
  const SyncReport({
    this.confirmed = 0,
    this.retryLater = 0,
    this.unsure = 0,
    this.rejected = 0,
    this.failure,
  });

  /// Changes the server now has, for certain.
  final int confirmed;

  /// Changes that will be sent again after a wait.
  final int retryLater;

  /// Changes the server may or may not have: asked about next round.
  final int unsure;

  /// Changes the server will never accept.
  final int rejected;

  /// Why the round stopped early, if it did.
  final SendFailure? failure;

  /// True when the round found nothing to do.
  bool get isEmpty =>
      confirmed == 0 && retryLater == 0 && unsure == 0 && rejected == 0;

  /// Two reports added together.
  SyncReport operator +(SyncReport other) => SyncReport(
    confirmed: confirmed + other.confirmed,
    retryLater: retryLater + other.retryLater,
    unsure: unsure + other.unsure,
    rejected: rejected + other.rejected,
    failure: other.failure ?? failure,
  );

  @override
  String toString() =>
      'confirmed=$confirmed retryLater=$retryLater '
      'unsure=$unsure rejected=$rejected${failure == null ? '' : ' ($failure)'}';
}

/// Moves changes from the local outbox to the server.
final class SyncEngine {
  SyncEngine({
    required this.store,
    required this.transport,
    this.batchSize = 100,
    BackoffStrategy? backoff,
    DateTime Function()? clock,
  }) : _backoff = backoff ?? fullJitterBackoff(),
       _clock = clock ?? DateTime.now;

  final LocalStore store;
  final SyncTransport transport;
  final int batchSize;
  final BackoffStrategy _backoff;
  final DateTime Function() _clock;
  bool _running = false;
  int _failures = 0;

  /// How many rounds in a row failed to reach the server. 0 means healthy.
  int get consecutiveFailures => _failures;

  /// How long the app should wait before trying again, given recent failures.
  Duration suggestedWait() =>
      _failures == 0 ? Duration.zero : _backoff(_failures);

  /// Runs rounds until nothing is ready to send, a round fails, or [maxRounds]
  /// is reached. Returns null WITHOUT touching the network when [policy] says no.
  Future<SyncReport?> syncAll({
    SyncPolicy policy = syncAlways,
    SyncContext? context,
    int maxRounds = 50,
  }) async {
    if (!policy(context ?? SyncContext(now: _clock()))) return null;
    var total = const SyncReport();
    for (var i = 0; i < maxRounds; i++) {
      final round = await syncOnce();
      total = total + round;
      if (round.failure != null || round.isEmpty) break;
    }
    return total;
  }

  /// Runs one sync round. Only one round may run at a time.
  Future<SyncReport> syncOnce() async {
    if (_running) throw StateError('syncOnce is already running');
    _running = true;
    try {
      return await _round();
    } finally {
      _running = false;
    }
  }

  Future<SyncReport> _round() async {
    var confirmed = 0;
    var retryLater = 0;
    var unsure = 0;
    var rejected = 0;
    SyncReport report([SendFailure? failure]) => SyncReport(
      confirmed: confirmed,
      retryLater: retryLater,
      unsure: unsure,
      rejected: rejected,
      failure: failure,
    );

    // ── Step 1: settle what we are unsure about, BEFORE sending anything new. ──
    final unsureOps = store.awaitingConfirmation();
    if (unsureOps.isNotEmpty) {
      final asked = {for (final op in unsureOps) op.opId};
      final List<StatusReply> answers;
      try {
        answers = await transport.status(store.clientId, asked.toList());
      } on SendFailure catch (failure) {
        _failures++;
        unsure = unsureOps.length;
        return report(failure); // still unsure: ask again next round
      }
      _failures = 0;
      final applied = [
        for (final a in answers)
          if (asked.contains(a.opId) && a.applied) a,
      ];
      final unknown = [
        for (final a in answers)
          if (asked.contains(a.opId) && !a.applied) a.opId,
      ];
      store.applyEvent(
        SyncEvent.statusApplied,
        [for (final a in applied) a.opId],
        serverVersions: {
          for (final a in applied)
            if (a.serverVersion != null) a.opId: a.serverVersion!,
        },
      );
      store.applyEvent(SyncEvent.statusUnknown, unknown); // back to queued
      confirmed += applied.length;
    }

    // ── Step 2: take the next batch. ──
    final batch = store.takeBatch(limit: batchSize, now: _clock());
    if (batch.isEmpty) return report();
    final ids = [for (final op in batch) op.opId];

    // ── Step 3: push it. How it fails decides what happens next. ──
    final List<PushReply> replies;
    try {
      replies = await transport.push(store.clientId, [
        for (final op in batch) op.toPushOp(),
      ]);
    } on NotDelivered catch (failure) {
      _failures++;
      store.applyEvent(
        SyncEvent.transientError,
        ids,
        retryAt: _clock().add(_backoff(_failures)),
      );
      retryLater += ids.length;
      return report(failure);
    } on DeliveryUnknown catch (failure) {
      _failures++;
      store.applyEvent(SyncEvent.ambiguousResponse, ids);
      unsure += ids.length;
      return report(failure);
    } on RequestRejected catch (failure) {
      // Our own request was refused as broken, and the server applied nothing.
      // Sending the same bytes again cannot help. Nothing is deleted.
      store.applyEvent(SyncEvent.permanentError, ids);
      rejected += ids.length;
      return report(failure);
    } catch (_) {
      // An unexpected bug: be safe and treat it as "unknown", so we ask later.
      store.applyEvent(SyncEvent.ambiguousResponse, ids);
      rethrow;
    }
    _failures = 0; // the server answered: the network is healthy again

    // ── Step 4: apply each change's own reply. ──
    final byId = {for (final r in replies) r.opId: r};
    final acked = <String>[];
    final versions = <String, int>{};
    final later = <String>[];
    final refused = <String>[];
    final missing = <String>[];
    for (final op in batch) {
      final reply = byId[op.opId];
      switch (reply?.result) {
        case PushResult.applied || PushResult.duplicate:
          acked.add(op.opId);
          final version = reply!.serverVersion;
          if (version != null) {
            versions[op.opId] = version;
          }
        case PushResult.outOfOrder:
          later.add(op.opId);
        case PushResult.rejected:
          refused.add(op.opId);
        case null:
          missing.add(op.opId); // no reply for this change: we cannot know
      }
    }
    store.applyEvent(SyncEvent.ackApplied, acked, serverVersions: versions);
    store.applyEvent(
      SyncEvent.transientError,
      later,
      retryAt: _clock().add(_backoff(1)),
    );
    store.applyEvent(SyncEvent.permanentError, refused);
    store.applyEvent(SyncEvent.ambiguousResponse, missing);

    confirmed += acked.length;
    retryLater += later.length;
    rejected += refused.length;
    unsure += missing.length;
    return report();
  }
}
