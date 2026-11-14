import 'package:sf_contracts/sf_contracts.dart';
import 'package:sqlite3/sqlite3.dart';
final class LocalStore {
  LocalStore._(this._db, this.clientId);

  factory LocalStore.open(String path) {
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);

    
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');

    _createTables(db);
    final clientId = _loadOrCreateClientId(db);
    return LocalStore._(db, clientId);
  }

  final Database _db;

  /// A permanent ID for this device's database. The server uses it, together
  /// with each opId, to recognise duplicates.
  final String clientId;

  /// Names of all tables, sorted. Useful for tests and learning.
  List<String> tableNames() => [
        for (final row in _db.select(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
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
    db.execute("INSERT INTO sf_meta (key, value) VALUES ('client_id', ?)", [id]);
    return id;
  }
}