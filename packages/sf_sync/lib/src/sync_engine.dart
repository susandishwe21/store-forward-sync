import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';

import 'send_failure.dart';
import 'transport.dart';

/// What one sync round did.
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

  @override
  String toString() =>
      'confirmed=$confirmed retryLater=$retryLater '
      'unsure=$unsure rejected=$rejected${failure == null ? '' : ' ($failure)'}';
}

/// Moves changes from the local outbox to the server, one round at a time.
final class SyncEngine {
  SyncEngine({
    required this.store,
    required this.transport,
    this.batchSize = 100,
    this.retryDelay = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final LocalStore store;
  final SyncTransport transport;
  final int batchSize;

  /// How long to wait before resending (a fixed delay for now; backoff comes next lesson).
  final Duration retryDelay;
  final DateTime Function() _clock;
  bool _running = false;

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
        unsure = unsureOps.length;
        return report(failure); // still unsure: ask again next round
      }
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
      store.applyEvent(
        SyncEvent.transientError,
        ids,
        retryAt: _clock().add(retryDelay),
      );
      retryLater += ids.length;
      return report(failure);
    } on DeliveryUnknown catch (failure) {
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
          if (reply!.serverVersion != null)
            versions[op.opId] = reply.serverVersion!;
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
      retryAt: _clock().add(retryDelay),
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
