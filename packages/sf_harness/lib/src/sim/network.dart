import 'dart:math';

/// What the network is like during one simulated minute.
final class NetworkMinute {
  const NetworkMinute({required this.good, required this.bars});

  /// Hidden truth: can a request get through? Policies may NOT look at this.
  final bool good;

  /// What the phone can see: signal bars 0–4, a noisy hint of [good].
  final int bars;
}

/// A synthetic intermittent network: a two-state Markov chain (Gilbert–Elliott)
/// with a bad evening period and rare long blackouts.
final class NetworkTrace {
  NetworkTrace._(this.minutes, this.start);

  factory NetworkTrace.generate({
    required int days,
    required int seed,
    DateTime? start,
  }) {
    final random = Random(seed);
    final minutes = <NetworkMinute>[];
    var good = true;
    var blackoutLeft = 0;
    for (var i = 0; i < days * 24 * 60; i++) {
      final hour = (i ~/ 60) % 24;
      final evening = hour >= 18 && hour < 22;
      if (blackoutLeft > 0) {
        blackoutLeft--; // a long outage is still going on
        good = false;
      } else if (random.nextDouble() < 0.0005) {
        blackoutLeft = 120 + random.nextInt(361); // a 2–8 hour blackout starts
        good = false;
      } else if (good) {
        good =
            random.nextDouble() >= (evening ? 0.10 : 0.02); // chance to break
      } else {
        good = random.nextDouble() < 0.08; // chance to recover
      }
      final noisy = (good ? 3.0 : 0.8) + (random.nextDouble() - 0.5) * 4.0;
      minutes.add(
        NetworkMinute(good: good, bars: noisy.round().clamp(0, 4).toInt()),
      );
    }
    return NetworkTrace._(minutes, start ?? DateTime.utc(2026, 11, 2));
  }

  final List<NetworkMinute> minutes;
  final DateTime start;

  int get length => minutes.length;

  NetworkMinute at(DateTime time) =>
      minutes[time
          .difference(start)
          .inMinutes
          .clamp(0, minutes.length - 1)
          .toInt()];
}
