import 'dart:convert';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

/// The server's durable state and its rules for accepting changes.
final class ServerStore {
  ServerStore._(this._db);

  factory ServerStore.open(String path) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');

    // Every change ever accepted: this is how repeats are recognised.
    db.execute('''
      CREATE TABLE IF NOT EXISTS srv_op (
        client_id      TEXT NOT NULL,
        op_id          TEXT NOT NULL,
        payload_hash   TEXT NOT NULL,
        server_version INTEGER NOT NULL,
        received_at    INTEGER NOT NULL,
        PRIMARY KEY (client_id, op_id)
      )''');

    // The current data. changed_seq orders every change, for downloads.
    db.execute('''
      CREATE TABLE IF NOT EXISTS srv_record (
        entity_type TEXT NOT NULL,
        entity_id   TEXT NOT NULL,
        payload     TEXT,
        deleted     INTEGER NOT NULL DEFAULT 0,
        version     INTEGER NOT NULL,
        changed_seq INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (entity_type, entity_id)
      )''');

    // For each phone and record: the last seq accepted. This keeps order.
    db.execute('''
      CREATE TABLE IF NOT EXISTS srv_cursor (
        client_id   TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id   TEXT NOT NULL,
        last_seq    INTEGER NOT NULL,
        PRIMARY KEY (client_id, entity_type, entity_id)
      )''');

    _upgrade(db);
    return ServerStore._(db);
  }

  /// A server.db created before the pull side existed has no changed_seq column.
  /// Add it, and number the existing records so they can be downloaded too.
  static void _upgrade(Database db) {
    final columns = {
      for (final row in db.select('PRAGMA table_info(srv_record)')) row['name'] as String,
    };
    if (!columns.contains('changed_seq')) {
      db.execute('ALTER TABLE srv_record ADD COLUMN changed_seq INTEGER NOT NULL DEFAULT 0');
      db.execute('UPDATE srv_record SET changed_seq = rowid');
    }
    db.execute('CREATE INDEX IF NOT EXISTS srv_record_changed ON srv_record (changed_seq)');
  }

  final Database _db;

  /// Handles one change from [clientId]. Safe to call many times with the same op.
  PushReply receive(String clientId, PushOp op) => _transaction(() {
        // 1. Is the data exactly what the phone fingerprinted?
        final canonical = canonicalJson(op.payload);
        if (sha256Hex(canonical) != op.payloadHash) {
          return PushReply(op.opId, PushResult.rejected,
              reason: 'payload does not match its fingerprint');
        }

        // 2. Have we seen this receipt number before?
        final seen = _db.select(
            'SELECT payload_hash, server_version FROM srv_op '
            'WHERE client_id = ? AND op_id = ?',
            [clientId, op.opId]);
        if (seen.isNotEmpty) {
          if (seen.first['payload_hash'] != op.payloadHash) {
            return PushReply(op.opId, PushResult.rejected,
                reason: 'opId reused with a different payload');
          }
          return PushReply(op.opId, PushResult.duplicate,
              serverVersion: seen.first['server_version'] as int);
        }

        // 3. Is this the next change for this record from this phone?
        final cursor = _db.select(
            'SELECT last_seq FROM srv_cursor '
            'WHERE client_id = ? AND entity_type = ? AND entity_id = ?',
            [clientId, op.entityType, op.entityId]);
        final lastSeq = cursor.isEmpty ? 0 : cursor.first['last_seq'] as int;
        if (op.seq <= lastSeq) {
          return PushReply(op.opId, PushResult.rejected,
              reason: 'seq ${op.seq} was already used');
        }
        if (op.seq != lastSeq + 1) {
          return PushReply(op.opId, PushResult.outOfOrder,
              reason: 'waiting for seq ${lastSeq + 1}');
        }

        // 4. Save the data, remember the op, move the cursor. All in one transaction.
        final current = _db.select(
            'SELECT version FROM srv_record WHERE entity_type = ? AND entity_id = ?',
            [op.entityType, op.entityId]);
        final version = current.isEmpty ? 1 : (current.first['version'] as int) + 1;
        final changeSeq = (_db
                .select('SELECT COALESCE(MAX(changed_seq), 0) AS n FROM srv_record')
                .first['n'] as int) +
            1;
        final deleting = op.opType == 'delete';

        _db.execute(
            'INSERT INTO srv_record (entity_type, entity_id, payload, deleted, version, changed_seq) '
            'VALUES (?, ?, ?, ?, ?, ?) '
            'ON CONFLICT (entity_type, entity_id) DO UPDATE SET '
            'payload = excluded.payload, deleted = excluded.deleted, '
            'version = excluded.version, changed_seq = excluded.changed_seq',
            [
              op.entityType,
              op.entityId,
              deleting ? null : canonical,
              deleting ? 1 : 0,
              version,
              changeSeq,
            ]);

        _db.execute(
            'INSERT INTO srv_op (client_id, op_id, payload_hash, server_version, received_at) '
            'VALUES (?, ?, ?, ?, ?)',
            [clientId, op.opId, op.payloadHash, version, DateTime.now().millisecondsSinceEpoch]);

        _db.execute(
            'INSERT INTO srv_cursor (client_id, entity_type, entity_id, last_seq) '
            'VALUES (?, ?, ?, ?) '
            'ON CONFLICT (client_id, entity_type, entity_id) DO UPDATE SET '
            'last_seq = excluded.last_seq',
            [clientId, op.entityType, op.entityId, op.seq]);

        return PushReply(op.opId, PushResult.applied, serverVersion: version);
      });

  /// "Did you get my change?" Returns null if the server has never seen it.
  PushReply? status(String clientId, String opId) {
    final rows = _db.select(
        'SELECT server_version FROM srv_op WHERE client_id = ? AND op_id = ?',
        [clientId, opId]);
    if (rows.isEmpty) return null;
    return PushReply(opId, PushResult.applied,
        serverVersion: rows.first['server_version'] as int);
  }

  /// Records changed after [since], in the order they changed. Includes deletions.
  PullReply pull({required int since, int limit = 200}) {
    final rows = _db.select(
        'SELECT entity_type, entity_id, payload, deleted, version, changed_seq '
        'FROM srv_record WHERE changed_seq > ? ORDER BY changed_seq LIMIT ?',
        [since, limit + 1]);
    final hasMore = rows.length > limit;
    final page = rows.take(limit).toList();
    return PullReply(
      records: [
        for (final r in page)
          PulledRecord(
            entityType: r['entity_type'] as String,
            entityId: r['entity_id'] as String,
            payload: r['payload'] == null
                ? null
                : (jsonDecode(r['payload'] as String) as Map).cast<String, Object?>(),
            deleted: r['deleted'] == 1,
            version: r['version'] as int,
          ),
      ],
      cursor: page.isEmpty ? since : page.last['changed_seq'] as int,
      hasMore: hasMore,
    );
  }

  /// The current data for a record, or null if missing or deleted.
  Map<String, Object?>? payloadOf(String entityType, String entityId) {
    final rows = _db.select(
        'SELECT payload, deleted FROM srv_record WHERE entity_type = ? AND entity_id = ?',
        [entityType, entityId]);
    if (rows.isEmpty || rows.first['deleted'] == 1) return null;
    return (jsonDecode(rows.first['payload'] as String) as Map).cast<String, Object?>();
  }

  void close() => _db.dispose();

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }
}
