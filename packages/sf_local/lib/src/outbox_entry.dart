import 'dart:convert';

import 'package:sf_contracts/sf_contracts.dart';

/// One change in the outbox, as the sync engine sees it.
final class OutboxEntry {
  const OutboxEntry({
    required this.opId,
    required this.entityType,
    required this.entityId,
    required this.seq,
    required this.opType,
    required this.payloadJson,
    required this.payloadHash,
    required this.status,
    required this.attempts,
  });

  final String opId;
  final String entityType;
  final String entityId;
  final int seq;
  final String opType;

  /// The canonical JSON exactly as it was fingerprinted.
  final String payloadJson;
  final String payloadHash;
  final SyncStatus status;

  /// How many times this change has been handed out for sending.
  final int attempts;

  /// The same change in the shape the protocol sends.
  PushOp toPushOp() => PushOp(
    opId: opId,
    entityType: entityType,
    entityId: entityId,
    seq: seq,
    opType: opType,
    payload: (jsonDecode(payloadJson) as Map).cast<String, Object?>(),
    payloadHash: payloadHash,
  );
}
