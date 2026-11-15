const sfspVersion = 1;

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

  factory PushOp.fromJson(Map<String, Object?> json) => PushOp(
    opId: json['opId'] as String,
    entityType: json['entityType'] as String,
    entityId: json['entityId'] as String,
    seq: json['seq'] as int,
    opType: json['opType'] as String,
    payload: (json['payload'] as Map).cast<String, Object?>(),
    payloadHash: json['payloadHash'] as String,
  );

  final String opId;
  final String entityType;
  final String entityId;
  final int seq;
  final String opType; // create, update or delete
  final Map<String, Object?> payload;
  final String payloadHash;

  Map<String, Object?> toJson() => {
    'opId': opId,
    'entityType': entityType,
    'entityId': entityId,
    'seq': seq,
    'opType': opType,
    'payload': payload,
    'payloadHash': payloadHash,
  };
}

final class PushReply {
  const PushReply(this.opId, this.result, {this.serverVersion, this.reason});

  factory PushReply.fromJson(Map<String, Object?> json) => PushReply(
    json['opId'] as String,
    PushResult.values.byName(json['result'] as String),
    serverVersion: json['serverVersion'] as int?,
    reason: json['reason'] as String?,
  );

  final String opId;
  final PushResult result;
  final int? serverVersion;
  final String? reason;

  Map<String, Object?> toJson() => {
    'opId': opId,
    'result': result.name,
    if (serverVersion != null) 'serverVersion': serverVersion,
    if (reason != null) 'reason': reason,
  };

  @override
  String toString() =>
      '${result.name} op=$opId'
      '${serverVersion == null ? '' : ' v$serverVersion'}'
      '${reason == null ? '' : ' ($reason)'}';
}

/// The server's answer to "did you get this change?".
final class StatusReply {
  const StatusReply(this.opId, {required this.applied, this.serverVersion});

  factory StatusReply.fromJson(Map<String, Object?> json) => StatusReply(
    json['opId'] as String,
    applied: json['applied'] as bool,
    serverVersion: json['serverVersion'] as int?,
  );

  final String opId;

  /// true: the server has it (phone event statusApplied).
  /// false: the server never got it (phone event statusUnknown).
  final bool applied;
  final int? serverVersion;

  Map<String, Object?> toJson() => {
    'opId': opId,
    'applied': applied,
    if (serverVersion != null) 'serverVersion': serverVersion,
  };
}
