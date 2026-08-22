import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/background_service.dart';
import 'package:step_counter/services/formatting.dart';

void main() {
  final now = DateTime(2026, 8, 22, 14, 0);

  group('stalledFor', () {
    test('a service beating on schedule is not stalled', () {
      expect(
        stalledFor(
          lastHeartbeat: now.subtract(serviceHeartbeatInterval),
          now: now,
        ),
        isNull,
      );
    });

    test('one missed beat is not enough to restart anything', () {
      expect(
        stalledFor(
          lastHeartbeat: now.subtract(serviceHeartbeatInterval * 2),
          now: now,
        ),
        isNull,
        reason: 'a Doze-delayed timer must not look like a dead service',
      );
    });

    test('silence past the timeout reports how long it has been', () {
      final gap = serviceHeartbeatTimeout + const Duration(minutes: 5);

      expect(stalledFor(lastHeartbeat: now.subtract(gap), now: now), gap);
    });

    test('a night with no steps taken is not a stall', () {
      // Reusing the last reading's timestamp instead would restart the
      // service every morning after 8 sleeping hours.
      expect(
        stalledFor(
          lastHeartbeat: now.subtract(const Duration(minutes: 10)),
          now: now,
        ),
        isNull,
      );
    });

    test('never having beaten is not a stall', () {
      expect(
        stalledFor(lastHeartbeat: null, now: now),
        isNull,
        reason: 'a fresh install has no heartbeat yet and needs no restart',
      );
    });

    test('a heartbeat from the future is not evidence of anything', () {
      expect(
        stalledFor(
          lastHeartbeat: now.add(const Duration(hours: 3)),
          now: now,
        ),
        isNull,
      );
    });

    test('exactly at the timeout is still within tolerance', () {
      expect(
        stalledFor(
          lastHeartbeat: now.subtract(serviceHeartbeatTimeout),
          now: now,
        ),
        isNull,
      );
    });
  });

  group('SensorStatusLatch', () {
    test('the first report is always worth recording', () {
      expect(SensorStatusLatch().accept(true), isTrue);
      expect(SensorStatusLatch().accept(false), isTrue);
    });

    test('a repeat of what was already recorded is dropped', () {
      final latch = SensorStatusLatch();

      expect(latch.accept(false), isTrue);
      expect(latch.accept(false), isFalse,
          reason: 'rewriting an unchanged value costs a whole-file commit');
    });

    test('a working sensor overturns an earlier failure', () {
      final latch = SensorStatusLatch();
      latch.accept(false);

      expect(
        latch.accept(true),
        isTrue,
        reason: 'an error raised before the plugin was wired up must not '
            'strand the user on the no-sensor screen',
      );
    });

    test('a confirmed sensor can never be un-confirmed', () {
      final latch = SensorStatusLatch();
      latch.accept(true);

      expect(
        latch.accept(false),
        isFalse,
        reason: 'hardware that has produced a reading exists',
      );
    });
  });

  group('formatApproximateDuration', () {
    test('reports minutes below an hour and a half', () {
      expect(formatApproximateDuration(const Duration(minutes: 45)),
          'about 45m');
    });

    test('rounds to the nearest hour above that', () {
      expect(formatApproximateDuration(const Duration(minutes: 100)),
          'about 2h');
      expect(formatApproximateDuration(const Duration(hours: 3, minutes: 10)),
          'about 3h');
    });
  });
}
