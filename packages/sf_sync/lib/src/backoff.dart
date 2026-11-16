import 'dart:math';

/// How long to wait after [failures] failed rounds in a row (1, 2, 3, ...).
typedef BackoffStrategy = Duration Function(int failures);

/// The same delay every time. Handy in tests and demos.
BackoffStrategy fixedBackoff(Duration delay) =>
    (_) => delay;

/// Exponential backoff with "full jitter": wait a RANDOM time between zero
/// and base × 2^(failures − 1), never more than [cap].
///
/// failures: 1 → up to 2 s, 2 → up to 4 s, 3 → up to 8 s, ... capped at 10 min.
BackoffStrategy fullJitterBackoff({
  Duration base = const Duration(seconds: 2),
  Duration cap = const Duration(minutes: 10),
  Random? random,
}) {
  final rng = random ?? Random();
  return (failures) {
    if (failures <= 0) return Duration.zero;
    final ceiling = min(
      cap.inMilliseconds,
      base.inMilliseconds * (1 << min(failures - 1, 30)),
    );
    return Duration(milliseconds: rng.nextInt(ceiling + 1));
  };
}
