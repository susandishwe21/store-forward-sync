enum PushResult { applied, duplicate, outOfOrder, rejected }

final class PushOp {
  const PushOp({
    required this.opId,
    required this.entityType,
    required this.entityId,
    required this.seq,
    required this.opType,
    required this.payload,
    required this.payloadHash,
  });

  final String opId;
  final String entityType;
  final String entityId;
  final int seq;
  final String opType; // create, update or delete
  final Map<String, Object?> payload;
  final String payloadHash;
}

final class PushReply {
  const PushReply(this.opId, this.result, {this.serverVersion, this.reason});

  final String opId;
  final PushResult result;
  final int? serverVersion;
  final String? reason;

  @override
  String toString() =>
      '${result.name} op=$opId'
      '${serverVersion == null ? '' : ' v$serverVersion'}'
      '${reason == null ? '' : ' ($reason)'}';
}
