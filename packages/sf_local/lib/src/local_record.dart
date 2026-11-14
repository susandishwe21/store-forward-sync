import 'package:sf_contracts/sf_contracts.dart';

/// A record as the app sees it, with its sync status.
final class LocalRecord {
  const LocalRecord({
    required this.entityType,
    required this.entityId,
    required this.payload,
    required this.deleted,
    required this.syncStatus,
    required this.localSeq,
    required this.savedAt,
  });

  final String entityType;
  final String entityId;

  /// The data, or null if the record is deleted.
  final Map<String, Object?>? payload;
  final bool deleted;
  final SyncStatus syncStatus;

  /// How many times this record has been changed on this device.
  final int localSeq;
  final DateTime savedAt;

  @override
  String toString() => '$entityType/$entityId [${syncStatus.name}] $payload';
}
