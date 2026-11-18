import 'dart:convert';

import 'package:sf_contracts/sf_contracts.dart';
import 'package:sqlite3/sqlite3.dart';

import 'local_record.dart';
import 'outbox_entry.dart';
import 'validation.dart';

/// The offline data engine: records and their outbox, in one SQLite file.
final class LocalStore {
  LocalStore._(this._db, this.clientId);

  /// Opens (or creates) the store at [path]. Use ':memory:' for a throwaway store.
  ///
  /// With [encryptionKeyHex] (64 hex characters = 256 bits) the whole database
  /// is encrypted with SQLCipher. If SQLCipher is not available, opening fails
  /// instead of silently storing data unencrypted.
  factory LocalStore.open(String path, {String? encryptionKeyHex}) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    if (encryptionKeyHex != null) {
      _unlock(db, encryptionKeyHex); // must happen before ANY other statement
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
    _createTables(db);
    final clientId = _loadOrCreateClientId(db);

    final store = LocalStore._(db, clientId);
    store._recoverAfterRestart();
    return store;
  }

  /// Turns on SQLCipher encryption with a raw 256-bit key.
  static void _unlock(Database db, String keyHex) {
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(keyHex)) {
      db.dispose();
      throw ArgumentError('encryptionKeyHex must be 64 hex characters (256 bits)');
    }
    // Plain SQLite does not know this pragma and returns no rows.
    if (db.select('PRAGMA cipher_version').isEmpty) {
      db.dispose();
      throw StateError('SQLCipher is not available: refusing to store data unencrypted');
    }
    // x'...' = a raw key: no slow password derivation, because the key is already random.
    db.execute("PRAGMA key = \"x'$keyHex'\"");
    try {
      db.select('SELECT count(*) FROM sqlite_master'); // fails if the key is wrong
    } on SqliteException {
      db.dispose();
      throw StateError('Wrong encryption key, or the file is not encrypted with this key');
    }
  }

  final Database _db;

  /// This device's permanent ID. The server uses it to tell phones apart.
  final String clientId;

  final Map<String, RecordValidator> _validators = {};

  // ─────────────────────────── Validation ───────────────────────────

  /// Every record of [entityType] must pass [validator] before it is saved.
  void registerValidator(String entityType, RecordValidator validator) {
    _validators[entityType] = validator;
  }

  // ───────────────────────────── Writes ─────────────────────────────

  /// Creates a new record with a fresh ID. Saved on the device when this returns.
  LocalRecord create(String entityType, Map<String, Object?> payload) =>
      put(entityType, newUuidV7(), payload);

  /// Creates or replaces the record [entityId].
  LocalRecord put(String entityType, String entityId, Map<String, Object?> payload) {
    _validate(entityType, payload);
    return _transaction(() => _write(entityType, entityId, payload, deleting: false));
  }

  /// Deletes a record. It stays as a "tombstone" until the server confirms.
  LocalRecord delete(String entityType, String entityId) =>
      _transaction(() => _write(entityType, entityId, const {}, deleting: true));

  // ───────────────────────────── Reads ──────────────────────────────

  /// Reads one record. Returns null if it does not exist or is deleted.
  LocalRecord? get(String entityType, String entityId, {bool includeDeleted = false}) {
    final rows = _db.select(
        'SELECT * FROM sf_record WHERE entity_type = ? AND entity_id = ?',
        [entityType, entityId]);
    if (rows.isEmpty) return null;
    final record = _toRecord(rows.first);
    if (record.deleted && !includeDeleted) return null;
    return record;
  }

  /// All records of one type, in the order they were first saved.
  /// Deleted ones are hidden unless asked.
  List<LocalRecord> query(String entityType, {bool includeDeleted = false}) {
    final rows = _db.select(
        'SELECT * FROM sf_record WHERE entity_type = ? AND (deleted = 0 OR ?) '
        'ORDER BY rowid',
        [entityType, includeDeleted ? 1 : 0]);
    return rows.map(_toRecord).toList();
  }

  /// How many changes are in the outbox.
  int operationCount() =>
      _db.select('SELECT COUNT(*) AS n FROM sf_outbox').first['n'] as int;

  /// How many outbox entries are in each status.
  Map<SyncStatus, int> outboxSummary() {
    final counts = {for (final s in SyncStatus.values) s: 0};
    final rows = _db.select('SELECT status, COUNT(*) AS n FROM sf_outbox GROUP BY status');
    for (final row in rows) {
      counts[SyncStatus.values.byName(row['status'] as String)] = row['n'] as int;
    }
    return counts;
  }

  /// The names of all tables in the database (handy in tests).
  List<String> tableNames() => [
        for (final row in _db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
          row['name'] as String,
      ];

  // ───────────────────── Outbox: the sending side ─────────────────────

  /// Picks up to [limit] changes that are ready to send, oldest first, and marks
  /// them `sending`. A change waits while an earlier change to the SAME record
  /// is still unresolved, so the server always receives a record's changes in order.
  List<OutboxEntry> takeBatch({int limit = 100, DateTime? now}) => _transaction(() {
        final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;

        _db.execute(
            'UPDATE sf_outbox SET status = ? WHERE status = ? AND next_attempt_at <= ?',
            [
              _next(SyncStatus.retryScheduled, SyncEvent.backoffElapsed).name,
              SyncStatus.retryScheduled.name,
              nowMs,
            ]);

        final rows = _db.select('''
          SELECT o.* FROM sf_outbox o
          WHERE o.status = ?
            AND NOT EXISTS (
              SELECT 1 FROM sf_outbox p
              WHERE p.entity_type = o.entity_type
                AND p.entity_id = o.entity_id
                AND p.seq < o.seq
                AND p.status NOT IN (?, ?))
          ORDER BY o.rowid
          LIMIT ?''', [
          SyncStatus.queued.name,
          SyncStatus.queued.name,
          SyncStatus.confirmed.name,
          limit,
        ]);

        final sending = _next(SyncStatus.queued, SyncEvent.batchBuilt);
        final batch = <OutboxEntry>[];
        for (final row in rows) {
          _db.execute(
              'UPDATE sf_outbox SET status = ?, attempts = COALESCE(attempts, 0) + 1 '
              'WHERE op_id = ?',
              [sending.name, row['op_id']]);
          _refreshRecordStatus(row['entity_type'] as String, row['entity_id'] as String);
          batch.add(_toEntry(row,
              status: sending, attempts: ((row['attempts'] as int?) ?? 0) + 1));
        }
        return batch;
      });

  /// Applies [event] to every change in [opIds], all or nothing.
  void applyEvent(SyncEvent event, List<String> opIds,
      {DateTime? retryAt, Map<String, int> serverVersions = const {}}) {
    _transaction(() {
      for (final opId in opIds) {
        final rows = _db.select(
            'SELECT status, entity_type, entity_id FROM sf_outbox WHERE op_id = ?', [opId]);
        if (rows.isEmpty) throw StateError('Unknown change $opId');
        final entityType = rows.first['entity_type'] as String;
        final entityId = rows.first['entity_id'] as String;

        final from = SyncStatus.values.byName(rows.first['status'] as String);
        final to = _next(from, event);
        if (to == SyncStatus.retryScheduled && retryAt == null) {
          throw ArgumentError('retryAt is required for ${event.name}');
        }

        _db.execute(
            'UPDATE sf_outbox SET status = ?, next_attempt_at = COALESCE(?, next_attempt_at) '
            'WHERE op_id = ?',
            [
              to.name,
              to == SyncStatus.retryScheduled ? retryAt!.millisecondsSinceEpoch : null,
              opId,
            ]);

        final version = serverVersions[opId];
        if (to == SyncStatus.confirmed && version != null) {
          _db.execute(
              'UPDATE sf_record SET server_version = MAX(COALESCE(server_version, 0), ?) '
              'WHERE entity_type = ? AND entity_id = ?',
              [version, entityType, entityId]);
        }
        _refreshRecordStatus(entityType, entityId);
      }
    });
  }

  /// Changes the server may or may not have. The engine asks the server about these first.
  List<OutboxEntry> awaitingConfirmation({int limit = 500}) => [
        for (final row in _db.select(
            'SELECT * FROM sf_outbox WHERE status = ? ORDER BY rowid LIMIT ?',
            [SyncStatus.sentUnconfirmed.name, limit]))
          _toEntry(row),
      ];

  // ─────────────────────── Download: the pull side ───────────────────────

  /// Where the last download stopped. 0 means "never downloaded".
  int pullCursor() {
    final rows = _db.select("SELECT value FROM sf_meta WHERE key = 'pull_cursor'");
    return rows.isEmpty ? 0 : int.parse(rows.first['value'] as String);
  }

  /// Applies records downloaded from the server and remembers [cursor], all or
  /// nothing. A record with a local change the server has not confirmed yet is
  /// left alone: the phone's newer edit wins until it has been sent.
  int applyRemote(List<PulledRecord> records, {required int cursor}) => _transaction(() {
        var changed = 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final r in records) {
          final pending = _db.select(
              'SELECT 1 FROM sf_outbox WHERE entity_type = ? AND entity_id = ? '
              'AND status <> ? LIMIT 1',
              [r.entityType, r.entityId, SyncStatus.confirmed.name]);
          if (pending.isNotEmpty) continue;

          final local = _db.select(
              'SELECT server_version FROM sf_record WHERE entity_type = ? AND entity_id = ?',
              [r.entityType, r.entityId]);
          final localVersion =
              local.isEmpty ? 0 : (local.first['server_version'] as int?) ?? 0;
          if (r.version <= localVersion) continue;

          _db.execute('''
            INSERT INTO sf_record (entity_type, entity_id, payload, deleted, local_seq,
                                   server_version, sync_status, saved_at)
            VALUES (?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT (entity_type, entity_id) DO UPDATE SET
              payload = excluded.payload,
              deleted = excluded.deleted,
              server_version = excluded.server_version,
              sync_status = excluded.sync_status,
              saved_at = excluded.saved_at''', [
            r.entityType,
            r.entityId,
            r.deleted || r.payload == null ? null : canonicalJson(r.payload!),
            r.deleted ? 1 : 0,
            r.version,
            SyncStatus.confirmed.name,
            now,
          ]);
          changed++;
        }
        _db.execute(
            "INSERT INTO sf_meta (key, value) VALUES ('pull_cursor', ?) "
            'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
            ['$cursor']);
        return changed;
      });

  void close() => _db.dispose();

  // ──────────────────────────── Private ─────────────────────────────

  static void _createTables(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS sf_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sf_record (
        entity_type    TEXT NOT NULL,
        entity_id      TEXT NOT NULL,
        payload        TEXT,
        deleted        INTEGER NOT NULL DEFAULT 0,
        local_seq      INTEGER NOT NULL,
        server_version INTEGER,
        sync_status    TEXT NOT NULL,
        saved_at       INTEGER NOT NULL,
        PRIMARY KEY (entity_type, entity_id)
      )''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sf_outbox (
        op_id           TEXT PRIMARY KEY,
        entity_type     TEXT NOT NULL,
        entity_id       TEXT NOT NULL,
        seq             INTEGER NOT NULL,
        op_type         TEXT NOT NULL,
        payload         TEXT NOT NULL,
        payload_hash    TEXT NOT NULL,
        status          TEXT NOT NULL,
        attempts        INTEGER NOT NULL DEFAULT 0,
        next_attempt_at INTEGER NOT NULL,
        created_at      INTEGER NOT NULL,
        UNIQUE (entity_type, entity_id, seq)
      )''');
  }

  static String _loadOrCreateClientId(Database db) {
    final rows = db.select("SELECT value FROM sf_meta WHERE key = 'client_id'");
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final id = newUuidV7();
    db.execute("INSERT INTO sf_meta (key, value) VALUES ('client_id', ?)", [id]);
    return id;
  }

  void _recoverAfterRestart() {
    final next = _next(SyncStatus.sending, SyncEvent.appRestarted);
    _db.execute('UPDATE sf_outbox SET status = ? WHERE status = ?',
        [next.name, SyncStatus.sending.name]);
    _refreshAllRecordStatuses();
  }

  void _validate(String entityType, Map<String, Object?> payload) {
    final validator = _validators[entityType];
    if (validator == null) return;
    final problems = validator(payload);
    if (problems.isNotEmpty) throw ValidationException(entityType, problems);
  }

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

  LocalRecord _write(String entityType, String entityId, Map<String, Object?> payload,
      {required bool deleting}) {
    final canonical = canonicalJson(payload);
    final hash = sha256Hex(canonical);
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = _db.select(
        'SELECT local_seq, deleted FROM sf_record WHERE entity_type = ? AND entity_id = ?',
        [entityType, entityId]);

    final int seq;
    final String opType;
    if (existing.isEmpty) {
      if (deleting) {
        throw StateError('Cannot delete $entityType/$entityId: it does not exist');
      }
      seq = 1;
      opType = 'create';
      _db.execute(
          'INSERT INTO sf_record (entity_type, entity_id, payload, deleted, '
          'local_seq, sync_status, saved_at) VALUES (?, ?, ?, 0, 1, ?, ?)',
          [entityType, entityId, canonical, SyncStatus.queued.name, now]);
    } else {
      seq = (existing.first['local_seq'] as int) + 1;
      final wasDeleted = existing.first['deleted'] == 1;
      opType = deleting ? 'delete' : (wasDeleted ? 'create' : 'update');
      _db.execute(
          'UPDATE sf_record SET payload = ?, deleted = ?, local_seq = ?, '
          'sync_status = ?, saved_at = ? WHERE entity_type = ? AND entity_id = ?',
          [
            deleting ? null : canonical,
            deleting ? 1 : 0,
            seq,
            SyncStatus.queued.name,
            now,
            entityType,
            entityId,
          ]);
    }

    _db.execute(
        'INSERT INTO sf_outbox (op_id, entity_type, entity_id, seq, op_type, '
        'payload, payload_hash, status, next_attempt_at, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          newUuidV7(),
          entityType,
          entityId,
          seq,
          opType,
          canonical,
          hash,
          SyncStatus.queued.name,
          now,
          now,
        ]);

    _refreshRecordStatus(entityType, entityId);
    return get(entityType, entityId, includeDeleted: true)!;
  }

  LocalRecord _toRecord(Row row) {
    final payload = row['payload'] as String?;
    return LocalRecord(
      entityType: row['entity_type'] as String,
      entityId: row['entity_id'] as String,
      payload: payload == null
          ? null
          : (jsonDecode(payload) as Map).cast<String, Object?>(),
      deleted: row['deleted'] == 1,
      syncStatus: SyncStatus.values.byName(row['sync_status'] as String),
      localSeq: row['local_seq'] as int,
      savedAt: DateTime.fromMillisecondsSinceEpoch(row['saved_at'] as int),
      serverVersion: row['server_version'] as int?,
    );
  }

  OutboxEntry _toEntry(Row row, {SyncStatus? status, int? attempts}) => OutboxEntry(
        opId: row['op_id'] as String,
        entityType: row['entity_type'] as String,
        entityId: row['entity_id'] as String,
        seq: row['seq'] as int,
        opType: row['op_type'] as String,
        payloadJson: row['payload'] as String,
        payloadHash: row['payload_hash'] as String,
        status: status ?? SyncStatus.values.byName(row['status'] as String),
        attempts: attempts ?? (row['attempts'] as int?) ?? 0,
      );

  SyncStatus _next(SyncStatus from, SyncEvent event) =>
      transition(from, event) ??
      (throw StateError('No rule for ${from.name} + ${event.name}'));

  static const _recordStatusSql = '''
    UPDATE sf_record SET sync_status = COALESCE(
      (SELECT o.status FROM sf_outbox o
       WHERE o.entity_type = sf_record.entity_type
         AND o.entity_id = sf_record.entity_id
         AND o.status <> ?
       ORDER BY o.seq LIMIT 1),
      ?)''';

  void _refreshRecordStatus(String entityType, String entityId) => _db.execute(
      '$_recordStatusSql WHERE entity_type = ? AND entity_id = ?',
      [SyncStatus.confirmed.name, SyncStatus.confirmed.name, entityType, entityId]);

  void _refreshAllRecordStatuses() => _db.execute(
      _recordStatusSql, [SyncStatus.confirmed.name, SyncStatus.confirmed.name]);
}
