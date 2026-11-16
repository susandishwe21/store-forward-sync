import 'package:sf_harness/sf_harness.dart';
import 'package:test/test.dart';

void main() {
  test('the same seed gives the same network', () {
    final a = NetworkTrace.generate(days: 2, seed: 42);
    final b = NetworkTrace.generate(days: 2, seed: 42);
    expect(
      [for (final m in a.minutes) m.good],
      [for (final m in b.minutes) m.good],
    );
  });

  test('signal bars are a noisy hint, not the truth', () {
    final trace = NetworkTrace.generate(days: 7, seed: 1);
    double averageBars(bool good) {
      final bars = [
        for (final m in trace.minutes)
          if (m.good == good) m.bars,
      ];
      return bars.reduce((a, b) => a + b) / bars.length;
    }

    expect(
      averageBars(true),
      greaterThan(averageBars(false) + 1.5),
    ); // a real hint...
    final twoBars = [
      for (final m in trace.minutes)
        if (m.bars == 2) m.good,
    ];
    expect(
      twoBars,
      containsAll([true, false]),
    ); // ...but 2 bars can mean either
  });

  test('a simulated run keeps every safety guarantee', () async {
    final r = await simulate(
      policyName: 'eager',
      decide: eagerPolicy,
      seed: 1,
      days: 2,
    );
    expect(r.saves, greaterThan(0));
    expect(r.safe, isTrue);
  });

  test('the oracle almost never wastes a request', () async {
    final r = await simulate(
      policyName: 'oracle',
      decide: eagerPolicy,
      oracle: true,
      seed: 1,
      days: 2,
    );
    expect(r.failedRequests / r.requests, lessThan(0.08));
    expect(r.safe, isTrue);
  });
}
