import 'dart:convert';
import 'dart:io';

import 'package:sf_harness/sf_harness.dart';
import 'package:test/test.dart';

String _writeModel(Directory dir, Map<String, Object?> json) {
  final path = '${dir.path}/model.json';
  File(path).writeAsStringSync(jsonEncode(json));
  return path;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sf_model_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the Dart model gives the same probability as Python', () {
    final file = File('../../ml/models/logreg.json');
    if (!file.existsSync()) {
      markTestSkipped('run python ml/train.py first');
      return;
    }
    final check = (jsonDecode(file.readAsStringSync()) as Map)['check'] as Map;
    final features = [for (final v in check['features'] as List) (v as num).toDouble()];
    final model = LogisticModel.load(file.path);
    expect(model.predict(features), closeTo((check['probability'] as num).toDouble(), 1e-9));
  });

  test('a model trained on different features is refused', () {
    final path = _writeModel(dir, {
      'features': ['something_else'],
      'mean': [0],
      'scale': [1],
      'coef': [1],
      'intercept': 0,
    });
    expect(() => LogisticModel.load(path), throwsStateError);
  });

  test('the liveness guard tries even when the model says no', () {
    final n = Observation.featureNames.length;
    final path = _writeModel(dir, {
      'features': Observation.featureNames,
      'mean': List.filled(n, 0),
      'scale': List.filled(n, 1),
      'coef': List.filled(n, 0),
      'intercept': -20, // always "almost surely fails"
    });
    final policy = learnedPolicy(LogisticModel.load(path), threshold: 0.5, probeEveryMinutes: 60);
    Observation waitedSinceAttempt(int minutes) => Observation(
          time: DateTime.utc(2026, 11, 2, 10),
          bars: 4,
          minutesSinceSuccess: 0,
          lastAttemptFailed: false,
          failuresInARow: 0,
          pending: 1,
          oldestPendingMinutes: 0,
          minutesSinceAttempt: minutes,
        );
    expect(policy(waitedSinceAttempt(10)), isFalse); // the model says no
    expect(policy(waitedSinceAttempt(60)), isTrue); // but an hour is the limit
  });
}