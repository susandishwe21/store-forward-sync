import 'dart:io';
import 'dart:math';

import 'package:sf_harness/sf_harness.dart';

/// dataset: explore at random and log every attempt  → results/dataset.csv
/// compare: run every baseline policy on the same weeks → results/sim_results.csv
Future<void> main(List<String> args) async {
  final options = parseOptions(args);
  final mode = options['mode'] ?? 'compare';
  final days = int.parse(options['days'] ?? (mode == 'dataset' ? '14' : '7'));
  final seeds = _range(
    options['seeds'] ?? (mode == 'dataset' ? '101-120' : '1-5'),
  );
  Directory('results').createSync();

  if (mode == 'dataset') {
    final file = File('results/dataset.csv').openWrite();
    file.writeln(
      [...Observation.featureNames, 'success', 'policy', 'seed'].join(','),
    );
    for (final seed in seeds) {
      final r = await simulate(
        policyName: 'explore',
        decide: randomPolicy(0.3, Random(seed)),
        seed: seed,
        days: days,
        dataset: file,
      );
      stdout.writeln(
        'seed $seed: ${r.attempts} attempts logged, safe=${r.safe}',
      );
    }
    await file.close();
    stdout.writeln('Wrote results/dataset.csv');
    return;
  }

  final out = File('results/sim_results.csv').openWrite()
    ..writeln(SimResult.csvHeader);
  stdout.writeln(SimResult.csvHeader);
  for (final seed in seeds) {
    final policies = <String, SyncDecider>{
      'eager': eagerPolicy,
      'fixed_15min': fixedIntervalPolicy(15),
      'backoff_jitter': backoffPolicy(random: Random(seed)),
      'signal_2bars': signalPolicy(),
    };
    for (final entry in policies.entries) {
      final r = await simulate(
        policyName: entry.key,
        decide: entry.value,
        seed: seed,
        days: days,
      );
      out.writeln(r.toCsv());
      stdout.writeln(r.toCsv());
    }
    final r = await simulate(
      policyName: 'oracle',
      decide: eagerPolicy,
      oracle: true,
      seed: seed,
      days: days,
    );
    out.writeln(r.toCsv());
    stdout.writeln(r.toCsv());
  }
  await out.close();
  stdout.writeln('Wrote results/sim_results.csv');
}

/// "1-5" → [1, 2, 3, 4, 5]
List<int> _range(String text) {
  final parts = text.split('-').map(int.parse).toList();
  return [for (var s = parts.first; s <= parts.last; s++) s];
}
