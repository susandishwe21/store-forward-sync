import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'policies.dart';

/// Logistic regression trained in Python (ml/train.py), run in Dart.
final class LogisticModel {
  LogisticModel._(this.mean, this.scale, this.coef, this.intercept);

  factory LogisticModel.load(String path) {
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final features = (json['features'] as List).cast<String>();
    if (features.join(',') != Observation.featureNames.join(',')) {
      throw StateError('Model features $features do not match ${Observation.featureNames}');
    }
    List<double> numbers(String key) =>
        [for (final v in json[key] as List) (v as num).toDouble()];
    return LogisticModel._(
        numbers('mean'), numbers('scale'), numbers('coef'), (json['intercept'] as num).toDouble());
  }

  final List<double> mean;
  final List<double> scale;
  final List<double> coef;
  final double intercept;

  /// Probability that a sync attempt right now succeeds.
  double predict(List<double> features) {
    var z = intercept;
    for (var i = 0; i < coef.length; i++) {
      z += coef[i] * (features[i] - mean[i]) / scale[i];
    }
    return 1 / (1 + exp(-z)); // the sigmoid turns any number into 0..1
  }
}

/// Try when the model is confident enough, and never let waiting data go
/// longer than [probeEveryMinutes] without at least one try (liveness guard).
SyncDecider learnedPolicy(LogisticModel model,
        {double threshold = 0.5, int probeEveryMinutes = 60}) =>
    (o) =>
        model.predict(o.features) >= threshold ||
        o.minutesSinceAttempt >= probeEveryMinutes;