import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sf_contracts/sf_contracts.dart';
import 'package:sf_local/sf_local.dart';
import 'package:sf_sync/sf_sync.dart';

/// Set at run time:  flutter run --dart-define=SERVER_URL=http://192.168.1.5:8090
/// 10.0.2.2 is "the computer running the emulator", as seen from an Android emulator.
const serverUrl = String.fromEnvironment('SERVER_URL', defaultValue: 'http://10.0.2.2:8090');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final folder = await getApplicationDocumentsDirectory();

  // 1. The offline store: everything works without a network.
  final store = LocalStore.open('${folder.path}/field_survey.db');
  store.registerValidator(
      'survey', requireFields({'site': FieldType.text, 'depth_cm': FieldType.integer}));

  // 2. The sync engine: sends the outbox when it can.
  final transport = HttpTransport(Uri.parse(serverUrl),
      connectTimeout: const Duration(seconds: 5), replyTimeout: const Duration(seconds: 15));
  final engine = SyncEngine(store: store, transport: transport);

  runApp(FieldSurveyApp(store: store, engine: engine));
}

class FieldSurveyApp extends StatelessWidget {
  const FieldSurveyApp({super.key, required this.store, required this.engine});

  final LocalStore store;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Field Survey',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: SurveyListPage(store: store, engine: engine),
      );
}

class SurveyListPage extends StatefulWidget {
  const SurveyListPage({super.key, required this.store, required this.engine});

  final LocalStore store;
  final SyncEngine engine;

  @override
  State<SurveyListPage> createState() => _SurveyListPageState();
}

class _SurveyListPageState extends State<SurveyListPage> {
  Timer? _timer;
  bool _syncing = false;
  String _lastSync = 'not synced yet';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _sync()); // try regularly
    _sync();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final report = await widget.engine.syncAll();
      final failure = report?.failure;
      _lastSync = report == null
          ? 'sync not allowed now'
          : failure == null
              ? 'last sync OK'
              : 'offline, will retry';
    } catch (e) {
      _lastSync = 'sync error: $e';
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _edit(LocalRecord? existing) async {
    final payload = await showDialog<Map<String, Object?>>(
        context: context, builder: (_) => SurveyDialog(initial: existing?.payload));
    if (payload == null) return;
    try {
      if (existing == null) {
        widget.store.create('survey', payload);
      } else {
        widget.store.put('survey', existing.entityId, payload);
      }
    } on ValidationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Not saved: ${e.problems.join(', ')}')));
      return;
    }
    setState(() {}); // saved on the phone: show it right away
    unawaited(_sync()); // and try to send it
  }

  void _delete(LocalRecord survey) {
    widget.store.delete('survey', survey.entityId);
    setState(() {});
    unawaited(_sync());
  }

  @override
  Widget build(BuildContext context) {
    final surveys = widget.store.query('survey').reversed.toList(); // newest first
    final summary = widget.store.outboxSummary();
    final waiting = summary[SyncStatus.queued]! +
        summary[SyncStatus.sending]! +
        summary[SyncStatus.retryScheduled]! +
        summary[SyncStatus.sentUnconfirmed]!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Field Survey'),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            onPressed: _syncing ? null : _sync,
            icon: _syncing
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusBanner(
              waiting: waiting, rejected: summary[SyncStatus.rejected]!, lastSync: _lastSync),
          Expanded(
            child: surveys.isEmpty
                ? const Center(child: Text('No surveys yet. Tap "New survey".'))
                : ListView.separated(
                    itemCount: surveys.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final s = surveys[index];
                      return Dismissible(
                        key: ValueKey(s.entityId),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) => _delete(s),
                        child: ListTile(
                          leading: _StatusIcon(s.syncStatus),
                          title: Text('${s.payload!['site']}'),
                          subtitle: Text('Depth ${s.payload!['depth_cm']} cm · ${s.syncStatus.name}'),
                          trailing: s.serverVersion == null ? null : Text('v${s.serverVersion}'),
                          onTap: () => _edit(s),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('New survey'),
      ),
    );
  }
}

/// Tells the field worker, honestly, whether their data is safe yet.
class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.waiting, required this.rejected, required this.lastSync});

  final int waiting;
  final int rejected;
  final String lastSync;

  @override
  Widget build(BuildContext context) {
    final allSafe = waiting == 0 && rejected == 0;
    return Container(
      width: double.infinity,
      color: allSafe ? Colors.green.shade50 : Colors.orange.shade50,
      padding: const EdgeInsets.all(12),
      child: Text(allSafe
          ? 'All surveys are safe on the server · $lastSync'
          : '$waiting not yet confirmed'
              '${rejected > 0 ? ' · $rejected rejected' : ''} · $lastSync'),
    );
  }
}

/// One icon per sync status: what the user sees of your state machine.
class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);

  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color, String label) = switch (status) {
      SyncStatus.queued => (Icons.phone_android, Colors.grey, 'Saved on this phone'),
      SyncStatus.sending => (Icons.cloud_upload, Colors.blue, 'Sending'),
      SyncStatus.retryScheduled => (Icons.schedule, Colors.orange, 'Waiting to retry'),
      SyncStatus.sentUnconfirmed => (Icons.help_outline, Colors.amber, 'Sent, checking with server'),
      SyncStatus.confirmed => (Icons.cloud_done, Colors.green, 'Safe on the server'),
      SyncStatus.rejected => (Icons.error, Colors.red, 'Rejected by the server'),
    };
    return Tooltip(message: label, child: Icon(icon, color: color));
  }
}

class SurveyDialog extends StatefulWidget {
  const SurveyDialog({super.key, this.initial});

  final Map<String, Object?>? initial;

  @override
  State<SurveyDialog> createState() => _SurveyDialogState();
}

class _SurveyDialogState extends State<SurveyDialog> {
  late final _site = TextEditingController(text: '${widget.initial?['site'] ?? ''}');
  late final _depth = TextEditingController(text: '${widget.initial?['depth_cm'] ?? ''}');
  late final _notes = TextEditingController(text: '${widget.initial?['notes'] ?? ''}');

  @override
  void dispose() {
    _site.dispose();
    _depth.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.initial == null ? 'New survey' : 'Edit survey'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _site, decoration: const InputDecoration(labelText: 'Site')),
            TextField(
                controller: _depth,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Water depth (cm)')),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final site = _site.text.trim();
              final depth = _depth.text.trim();
              Navigator.pop(context, <String, Object?>{
                if (site.isNotEmpty) 'site': site,
                'depth_cm': int.tryParse(depth) ?? (depth.isEmpty ? null : depth),
                'notes': _notes.text.trim(),
              });
            },
            child: const Text('Save'),
          ),
        ],
      );
}