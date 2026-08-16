import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/pedometer_service.dart';

/// The sensor-availability signal has one property that isn't obvious from
/// reading it, and that a well-meaning simplification would quietly remove:
/// it replays its last value to late subscribers.
///
/// That matters because the report is a single event. The background service
/// settles whether the device has a step counter once and then goes quiet, so
/// a plain broadcast stream would leave any subscriber created afterwards —
/// a provider rebuilt on hot reload, a navigation, a rotation — waiting
/// forever on an event that already happened. The symptom would be the exact
/// bug B4 fixed: a sensor-less device showing an ordinary zero. And it would
/// only ever appear on hardware without a step counter, which is the hardest
/// place to notice it.
void main() {
  group('sensorAvailableStream', () {
    late PedometerService service;

    setUp(() => service = PedometerService());
    tearDown(() => service.dispose());

    test('replays the last report to a subscriber that arrives after it',
        () async {
      service.setSensorAvailable(false);

      await expectLater(
        service.sensorAvailableStream.first,
        completion(isFalse),
        reason: 'the report is a single event — a subscriber created after '
            'it must still see it, or the UI never learns',
      );
    });

    test('delivers a report to a subscriber that arrives before it', () async {
      final firstValue = service.sensorAvailableStream.first;

      service.setSensorAvailable(false);

      expect(await firstValue, isFalse);
    });

    test('replays to each subscriber independently', () async {
      service.setSensorAvailable(true);

      expect(await service.sensorAvailableStream.first, isTrue);
      expect(await service.sensorAvailableStream.first, isTrue);
    });

    test('emits nothing before anything has been reported', () async {
      final seen = <bool>[];
      final subscription = service.sensorAvailableStream.listen(seen.add);
      await pumpEventQueue();
      await subscription.cancel();

      expect(
        seen,
        isEmpty,
        reason: 'unknown is not the same as available — the UI treats an '
            'absent value as "assume present" and must not be handed a guess',
      );
    });

    test('does not re-emit a report that repeats the previous one', () async {
      final seen = <bool>[];
      final subscription = service.sensorAvailableStream.listen(seen.add);

      service.setSensorAvailable(false);
      service.setSensorAvailable(false);
      await pumpEventQueue();
      await subscription.cancel();

      expect(seen, <bool>[false]);
    });

    test('emits a report that changes the previous one', () async {
      final seen = <bool>[];
      final subscription = service.sensorAvailableStream.listen(seen.add);

      service.setSensorAvailable(false);
      service.setSensorAvailable(true);
      await pumpEventQueue();
      await subscription.cancel();

      expect(seen, <bool>[false, true]);
    });
  });
}
