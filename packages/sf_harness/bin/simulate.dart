import 'dart:io';
import 'dart:math';

import 'package:sf_harness/sf_harness.dart';

/// dataset: explore at random and log every attempt      → results/dataset.csv
/// tune:    choose the learned policy's threshold         → results/tuning.csv
/// compare: every policy on the same unseen test weeks    → results/sim_results.csv
Future<void> main(List<String> args) async {
  final options = parseOptions(args);
  final mode = options['mode'] ?? 'compare';
  final modelPath = options['model'] ?? 'ml/models/logreg.json';
  Directory('results').createSync();

  switch (mode) {
    case 'dataset':
      await _dataset(
          seeds: _range(options['seeds'] ?? '101-120'),
          days: int.parse(options['days'] ?? '14'));
    case 'tune':
      await _tune(
          seeds: _range(options['seeds'] ?? '201-205'),
          days: int.parse(options['days'] ?? '7'),
          model: LogisticModel.load(modelPath));
    default:
      await _compare(
          seeds: _range(options['seeds'] ?? '1-5'),
          days: int.parse(options['days'] ?? '7'),
          model: File(modelPath).existsSync() ? LogisticModel.load(modelPath) : null,
          threshold: double.parse(options['threshold'] ?? '0.5'));
  }
}

Future<void> _dataset({required List<int> seeds, required int days}) async {
  final file = File('results/dataset.csv').openWrite();
  file.writeln([...Observation.featureNames, 'success', 'policy', 'seed'].join(','));
  for (final seed in seeds) {
    final r = await simulate(
        policyName: 'explore',
        decide: randomPolicy(0.3, Random(seed)),
        seed: seed,
        days: days,
        dataset: file);
    stdout.writeln('seed $seed: ${r.attempts} attempts logged, safe=${r.safe}');
  }
  await file.close();
  stdout.writeln('Wrote results/dataset.csv');
}

Future<void> _tune(
    {required List<int> seeds, required int days, required LogisticModel model}) async {
  Future<_Summary> runAll(String name, SyncDecider Function() make) async {
    final results = <SimResult>[];
    for (final seed in seeds) {
      results.add(await simulate(policyName: name, decide: make(), seed: seed, days: days));
    }
    return _Summary(results);
  }

  final out = File('results/tuning.csv').openWrite()
    ..writeln('policy,threshold,mean_exposure_min,radio_seconds,failed_requests,requests,safe');
  final eager = await runAll('eager', () => eagerPolicy);
  out.writeln('eager,,${eager.csv}');
  stdout.writeln('eager            : $eager');

  final limit = eager.exposure * 1.05;
  double? chosen;
  var chosenRadio = double.infinity;
  for (final threshold in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]) {
    final s = await runAll('learned', () => learnedPolicy(model, threshold: threshold));
    out.writeln('learned,$threshold,${s.csv}');
    stdout.writeln('threshold ${threshold.toStringAsFixed(1)}    : $s');
    if (s.exposure <= limit && s.radio < chosenRadio) {
      chosen = threshold;
      chosenRadio = s.radio;
    }
  }
  await out.close();
  stdout.writeln(chosen == null
      ? '\nNo threshold kept exposure within 5% of eager.'
      : '\nChosen threshold: $chosen (lowest radio time with exposure within 5% of eager)');
}

Future<void> _compare({
  required List<int> seeds,
  required int days,
  required LogisticModel? model,
  required double threshold,
}) async {
  final out = File('results/sim_results.csv').openWrite()..writeln(SimResult.csvHeader);
  stdout.writeln(SimResult.csvHeader);
  for (final seed in seeds) {
    final policies = <String, SyncDecider>{
      'eager': eagerPolicy,
      'fixed_15min': fixedIntervalPolicy(15),
      'backoff_jitter': backoffPolicy(random: Random(seed)),
      'signal_2bars': signalPolicy(),
      if (model != null) 'learned': learnedPolicy(model, threshold: threshold),
    };
    for (final entry in policies.entries) {
      final r = await simulate(policyName: entry.key, decide: entry.value, seed: seed, days: days);
      out.writeln(r.toCsv());
      stdout.writeln(r.toCsv());
    }
    final r = await simulate(
        policyName: 'oracle', decide: eagerPolicy, oracle: true, seed: seed, days: days);
    out.writeln(r.toCsv());
    stdout.writeln(r.toCsv());
  }
  await out.close();
  stdout.writeln('Wrote results/sim_results.csv');
}

final class _Summary {
  _Summary(List<SimResult> results)
      : exposure = _mean(results.map((r) => r.meanExposureMin)),
        radio = _mean(results.map((r) => r.radioSeconds)),
        failed = _mean(results.map((r) => r.failedRequests.toDouble())),
        requests = _mean(results.map((r) => r.requests.toDouble())),
        allSafe = results.every((r) => r.safe);

  final double exposure;
  final double radio;
  final double failed;
  final double requests;
  final bool allSafe;

  String get csv => '${exposure.toStringAsFixed(2)},${radio.toStringAsFixed(1)},'
      '${failed.toStringAsFixed(1)},${requests.toStringAsFixed(1)},$allSafe';

  @override
  String toString() => 'exposure ${exposure.toStringAsFixed(1)} min, '
      'radio ${radio.toStringAsFixed(0)} s, '
      'failed ${failed.toStringAsFixed(0)}/${requests.toStringAsFixed(0)} requests, '
      'safe=$allSafe';
}

double _mean(Iterable<double> values) => values.reduce((a, b) => a + b) / values.length;

/// "1-5" → [1, 2, 3, 4, 5]
List<int> _range(String text) {
  final parts = text.split('-').map(int.parse).toList();
  return [for (var s = parts.first; s <= parts.last; s++) s];
}