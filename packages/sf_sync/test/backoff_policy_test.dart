import 'dart:math';

import 'package:sf_sync/sf_sync.dart';
import 'package:test/test.dart';

void main() {
  group('backoff', () {
    test(
      'full jitter stays between zero and the ceiling, never above the cap',
      () {
        final backoff = fullJitterBackoff(
          base: const Duration(seconds: 2),
          cap: const Duration(minutes: 10),
          random: Random(42),
        );
        for (var failures = 1; failures <= 15; failures++) {
          final ceiling = min(600000, 2000 * (1 << (failures - 1)));
          for (var i = 0; i < 200; i++) {
            expect(
              backoff(failures).inMilliseconds,
              inInclusiveRange(0, ceiling),
            );
          }
        }
        expect(backoff(0), Duration.zero);
      },
    );

    test('1000 phones: jitter spreads the retries out', () {
      int busiestSecond(BackoffStrategy backoff) {
        final phonesPerSecond = <int, int>{};
        for (var phone = 0; phone < 1000; phone++) {
          final second = backoff(5).inSeconds;
          phonesPerSecond[second] = (phonesPerSecond[second] ?? 0) + 1;
        }
        return phonesPerSecond.values.reduce(max);
      }

      final fixed = fixedBackoff(const Duration(seconds: 30));
      final jitter = fullJitterBackoff(random: Random(7));
      expect(busiestSecond(fixed), 1000); // every phone in the same second
      expect(busiestSecond(jitter), lessThan(100)); // spread over ~32 seconds
    });
  });

  group('policies', () {
    SyncContext at(int hour, int minute, {bool wifi = false}) =>
        SyncContext(now: DateTime(2026, 11, 16, hour, minute), onWifi: wifi);

    test('a night window that crosses midnight', () {
      final night = syncWindow(fromHour: 22, toHour: 5);
      expect(night(at(22, 0)), isTrue);
      expect(night(at(23, 30)), isTrue);
      expect(night(at(0, 30)), isTrue);
      expect(night(at(4, 59)), isTrue);
      expect(night(at(5, 0)), isFalse);
      expect(night(at(12, 0)), isFalse);
    });

    test('combining a window with Wi-Fi only', () {
      final policy = syncWhenAll([
        syncWindow(fromHour: 1, toHour: 3),
        syncOnWifiOnly,
      ]);
      expect(policy(at(2, 0, wifi: true)), isTrue);
      expect(policy(at(2, 0)), isFalse); // mobile data
      expect(policy(at(4, 0, wifi: true)), isFalse); // outside the window
    });
  });
}
