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
    this.serverVersion,
  });

  final String entityType;
  final String entityId;

  /// The data, or null if the record is deleted.
  final Map<String, Object?>? payload;
  final bool deleted;

  /// The status of this record's oldest change that is not confirmed yet.
  final SyncStatus syncStatus;

  /// How many times this record has been changed on this device.
  final int localSeq;
  final DateTime savedAt;

  /// The server's version of this record, once confirmed. Null until then.
  final int? serverVersion;

  @override
  String toString() => '$entityType/$entityId [${syncStatus.name}] $payload';
}
