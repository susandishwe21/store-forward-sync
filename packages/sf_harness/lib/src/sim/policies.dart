import 'dart:math';

/// What the phone can observe when deciding whether to try syncing now.
/// It NEVER includes the hidden network truth.
final class Observation {
  const Observation({
    required this.time,
    required this.bars,
    required this.minutesSinceSuccess,
    required this.lastAttemptFailed,
    required this.failuresInARow,
    required this.pending,
    required this.oldestPendingMinutes,
    required this.minutesSinceAttempt,
  });

  final DateTime time;
  final int bars;
  final int minutesSinceSuccess;
  final bool lastAttemptFailed;
  final int failuresInARow;
  final int pending;
  final int oldestPendingMinutes;
  final int minutesSinceAttempt;

  /// Feature names, in the same order as [features]. Used as CSV columns.
  static const featureNames = [
    'hour_sin',
    'hour_cos',
    'bars',
    'min_since_success',
    'last_failed',
    'failures_in_a_row',
    'pending',
    'oldest_pending_min',
    'min_since_attempt',
  ];

  /// The numbers the ML model sees.
  List<double> get features {
    final hour = time.hour + time.minute / 60;
    return [
      sin(2 * pi * hour / 24),
      cos(2 * pi * hour / 24),
      bars.toDouble(),
      min(minutesSinceSuccess, 1440).toDouble(),
      lastAttemptFailed ? 1.0 : 0.0,
      min(failuresInARow, 50).toDouble(),
      min(pending, 1000).toDouble(),
      min(oldestPendingMinutes, 1440).toDouble(),
      min(minutesSinceAttempt, 1440).toDouble(),
    ];
  }
}

/// Decides, once per simulated minute, whether to try a sync now.
typedef SyncDecider = bool Function(Observation observation);

/// Try every minute while something is waiting.
bool eagerPolicy(Observation o) => true;

/// Try at most once every [minutes] minutes.
SyncDecider fixedIntervalPolicy(int minutes) =>
    (o) => o.minutesSinceAttempt >= minutes;

/// After a failure, wait a full-jitter backoff (in minutes); after success, go on.
SyncDecider backoffPolicy({
  required Random random,
  int baseMinutes = 1,
  int capMinutes = 60,
}) {
  var waitFor = 0;
  var seenFailures = 0;
  return (o) {
    if (o.failuresInARow == 0) return true;
    if (o.failuresInARow != seenFailures) {
      seenFailures = o.failuresInARow; // a new failure: draw a new random wait
      final ceiling = min(
        capMinutes,
        baseMinutes * (1 << min(o.failuresInARow - 1, 20)),
      );
      waitFor = random.nextInt(ceiling + 1);
    }
    return o.minutesSinceAttempt >= waitFor;
  };
}

/// Rule of thumb: try only when the signal looks decent.
SyncDecider signalPolicy({int minBars = 2}) =>
    (o) => o.bars >= minBars;

/// For collecting training data: try at random moments, good or bad.
SyncDecider randomPolicy(double probability, Random random) =>
    (o) => random.nextDouble() < probability;
