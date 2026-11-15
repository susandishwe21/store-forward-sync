import 'package:sf_contracts/sf_contracts.dart';
import 'package:sqlite3/sqlite3.dart';
import 'dart:convert';
import 'validation.dart';
import 'local_record.dart';

final class LocalStore {
  LocalStore._(this._db, this.clientId);
  final Map<String, RecordValidator> _validators = {};

  void registerValidator(String entityType, RecordValidator validator) {
    _validators[entityType] = validator;
  }

  void validate(String entityType, Map<String, Object?> payload) {
    final validator = _validators[entityType];
    if (validator == null) return; // no rules for this type
    final problems = validator(payload);
    if (problems.isNotEmpty) throw ValidationException(entityType, problems);
  }

  factory LocalStore.open(String path) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);

    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');

    _createTables(db);
    final clientId = _loadOrCreateClientId(db);
    final store = LocalStore._(db, clientId);
    store.recoverAfterRestart();
    return store;
  }

  final Database _db;
  final String clientId;

  LocalRecord create(String entityType, Map<String, Object?> payload) =>
      put(entityType, newUuidV7(), payload);

  LocalRecord put(
    String entityType,
    String entityId,
    Map<String, Object?> payload,
  ) {
    validate(entityType, payload);
    return _transaction(
      () => _write(entityType, entityId, payload, deleting: false),
    );
  }

  LocalRecord delete(String entityType, String entityId) => _transaction(
    () => _write(entityType, entityId, const {}, deleting: true),
  );

  LocalRecord? get(
    String entityType,
    String entityId, {
    bool includeDeleted = false,
  }) {
    final rows = _db.select(
      'SELECT * FROM sf_record WHERE entity_type = ? AND entity_id = ?',
      [entityType, entityId],
    );
    if (rows.isEmpty) return null;
    final record = _toRecord(rows.first);
    if (record.deleted && !includeDeleted) return null;
    return record;
  }

  List<LocalRecord> query(String entityType, {bool includeDeleted = false}) {
    final rows = _db.select(
      'SELECT * FROM sf_record WHERE entity_type = ? AND (deleted = 0 OR ?) '
      'ORDER BY entity_id',
      [entityType, includeDeleted ? 1 : 0],
    );
    return rows.map(_toRecord).toList();
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
    );
  }

  int operationCount() =>
      _db.select('SELECT COUNT(*) AS n FROM sf_outbox').first['n'] as int;

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

  LocalRecord _write(
    String entityType,
    String entityId,
    Map<String, Object?> payload, {
    required bool deleting,
  }) {
    final canonical = canonicalJson(payload);
    final hash = sha256Hex(canonical);
    final now = DateTime.now().millisecondsSinceEpoch;

    final existing = _db.select(
      'SELECT local_seq, deleted FROM sf_record WHERE entity_type = ? AND entity_id = ?',
      [entityType, entityId],
    );

    final int seq;
    final String opType;
    if (existing.isEmpty) {
      if (deleting) {
        throw StateError(
          'Cannot delete $entityType/$entityId: it does not exist',
        );
      }
      seq = 1;
      opType = 'create';
      _db.execute(
        'INSERT INTO sf_record (entity_type, entity_id, payload, deleted, '
        'local_seq, sync_status, saved_at) VALUES (?, ?, ?, 0, 1, ?, ?)',
        [entityType, entityId, canonical, SyncStatus.queued.name, now],
      );
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
        ],
      );
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
      ],
    );

    return get(entityType, entityId, includeDeleted: true)!;
  }

  /// Names of all tables, sorted. Useful for tests and learning.
  List<String> tableNames() => [
    for (final row in _db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
    ))
      row['name'] as String,
  ];

  void close() => _db.dispose();

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
        server_version INTEGER NOT NULL DEFAULT 0,
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
    db.execute("INSERT INTO sf_meta (key, value) VALUES ('client_id', ?)", [
      id,
    ]);
    return id;
  }

  void recoverAfterRestart() {
    final next = transition(SyncStatus.sending, SyncEvent.appRestarted);
    if (next == null) {
      throw StateError('State machine has no rule for sending + appRestarted');
    }
    _db.execute('UPDATE sf_outbox SET status = ? WHERE status = ?', [
      next.name,
      SyncStatus.sending.name,
    ]);
  }

  Map<SyncStatus, int> outboxSummary() {
    final counts = {for (final s in SyncStatus.values) s: 0};
    final rows = _db.select(
      'SELECT status, COUNT(*) AS n FROM sf_outbox GROUP BY status',
    );
    for (final row in rows) {
      counts[SyncStatus.values.byName(row['status'] as String)] =
          row['n'] as int;
    }
    return counts;
  }
}
