
final class PulledRecord {
  const PulledRecord({
    required this.entityType,
    required this.entityId,
    required this.payload,
    required this.deleted,
    required this.version,
  });

  factory PulledRecord.fromJson(Map<String, Object?> json) => PulledRecord(
        entityType: json['entityType'] as String,
        entityId: json['entityId'] as String,
        payload: (json['payload'] as Map?)?.cast<String, Object?>(),
        deleted: json['deleted'] as bool,
        version: json['version'] as int,
      );

  final String entityType;
  final String entityId;

  /// The data, or null when [deleted].
  final Map<String, Object?>? payload;
  final bool deleted;
  final int version;

  Map<String, Object?> toJson() => {
        'entityType': entityType,
        'entityId': entityId,
        'payload': payload,
        'deleted': deleted,
        'version': version,
      };
}

/// One page of changes from the server.
final class PullReply {
  const PullReply({required this.records, required this.cursor, required this.hasMore});

  factory PullReply.fromJson(Map<String, Object?> json) => PullReply(
        records: [
          for (final r in json['records'] as List)
            PulledRecord.fromJson((r as Map).cast<String, Object?>()),
        ],
        cursor: json['cursor'] as int,
        hasMore: json['hasMore'] as bool,
      );

  final List<PulledRecord> records;

  /// Pass this as `since` in the next pull.
  final int cursor;
  final bool hasMore;

  Map<String, Object?> toJson() => {
        'records': [for (final r in records) r.toJson()],
        'cursor': cursor,
        'hasMore': hasMore,
      };
}
