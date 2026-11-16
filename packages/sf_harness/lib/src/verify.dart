import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// The result of comparing the phone's database with the server's.
final class Verdict {
  const Verdict({
    required this.phoneOps,
    required this.forgotten,
    required this.lost,
    required this.duplicates,
    required this.outOfOrder,
    required this.mismatches,
    required this.unconfirmed,
    required this.rejected,
  });

  final int phoneOps;
  final int forgotten;
  final int lost;
  final int duplicates;
  final int outOfOrder;
  final int mismatches;
  final int unconfirmed;
  final int rejected;

  bool get passed =>
      forgotten == 0 &&
      lost == 0 &&
      duplicates == 0 &&
      outOfOrder == 0 &&
      mismatches == 0 &&
      unconfirmed == 0 &&
      rejected == 0;

  @override
  String toString() =>
      '''
  phone changes  : $phoneOps
  forgotten      : $forgotten   (app was told "saved", phone does not have it)
  lost           : $lost   (never reached the server)
  duplicates     : $duplicates   (applied more than once)
  out of order   : $outOfOrder   (applied in the wrong order)
  mismatches     : $mismatches   (final data differs)
  unconfirmed    : $unconfirmed   (not confirmed at the end)
  rejected       : $rejected
  RESULT         : ${passed ? 'PASS' : 'FAIL'}''';
}

/// Compares the phone's and the server's databases after a run.
/// [savedLog] has one line "entityId seq ok" per save the app was told succeeded.
Verdict verify({
  required String phoneDb,
  required String serverDb,
  String? savedLog,
}) {
  final db = sqlite3.open(phoneDb);
  try {
    db.execute('ATTACH DATABASE ? AS srv', [serverDb]);
    int count(String sql, [List<Object?> args = const []]) =>
        db.select(sql, args).first['n'] as int;

    final clientId =
        db
                .select("SELECT value FROM sf_meta WHERE key = 'client_id'")
                .first['value']
            as String;

    // Every change the phone has must exist on the server.
    final lost = count(
      '''
      SELECT COUNT(*) AS n FROM sf_outbox o
      WHERE NOT EXISTS (
        SELECT 1 FROM srv.srv_op s WHERE s.client_id = ? AND s.op_id = o.op_id)''',
      [clientId],
    );

    // One phone, so the server's version for change k of a record must be exactly k.
    final outOfOrder = count(
      '''
      SELECT COUNT(*) AS n FROM sf_outbox o
      JOIN srv.srv_op s ON s.client_id = ? AND s.op_id = o.op_id
      WHERE s.server_version <> o.seq''',
      [clientId],
    );

    // A record changed N times on the phone must have version N on the server, not more.
    final duplicates = count('''
      SELECT COALESCE(SUM(r.version - c.changes), 0) AS n
      FROM srv.srv_record r
      JOIN (SELECT entity_type, entity_id, COUNT(*) AS changes
            FROM sf_outbox GROUP BY entity_type, entity_id) c
        ON c.entity_type = r.entity_type AND c.entity_id = r.entity_id
      WHERE r.version > c.changes''');

    // The final data must be identical (both sides store canonical JSON).
    final mismatches = count('''
      SELECT COUNT(*) AS n FROM sf_record p
      LEFT JOIN srv.srv_record r
        ON r.entity_type = p.entity_type AND r.entity_id = p.entity_id
      WHERE r.entity_id IS NULL
         OR p.deleted <> r.deleted
         OR (p.deleted = 0 AND p.payload IS NOT r.payload)''');

    final unconfirmed = count(
      "SELECT COUNT(*) AS n FROM sf_outbox WHERE status NOT IN ('confirmed', 'rejected')",
    );
    final rejected = count(
      "SELECT COUNT(*) AS n FROM sf_outbox WHERE status = 'rejected'",
    );
    final phoneOps = count('SELECT COUNT(*) AS n FROM sf_outbox');

    // Every save the app was told succeeded must still be on the phone.
    var forgotten = 0;
    if (savedLog != null && File(savedLog).existsSync()) {
      final onPhone = {
        for (final row in db.select('SELECT entity_id, seq FROM sf_outbox'))
          '${row['entity_id']} ${row['seq']}',
      };
      for (final line in File(savedLog).readAsLinesSync()) {
        final parts = line.trim().split(' ');
        if (parts.length != 3 || parts[2] != 'ok') {
          continue; // a half-written last line: the kill came mid-write
        }
        if (!onPhone.contains('${parts[0]} ${parts[1]}')) {
          forgotten++;
        }
      }
    }

    return Verdict(
      phoneOps: phoneOps,
      forgotten: forgotten,
      lost: lost,
      duplicates: duplicates,
      outOfOrder: outOfOrder,
      mismatches: mismatches,
      unconfirmed: unconfirmed,
      rejected: rejected,
    );
  } finally {
    db.dispose();
  }
}
