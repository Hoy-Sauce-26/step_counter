import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/step_accumulator.dart';

import 'step_accumulator_test.dart' show FakeStepStore, day1;

class CountingStepStore extends FakeStepStore {
  int dailyWrites = 0;
  int hourlyWrites = 0;

  @override
  Future<void> writeDailySteps(String date, int steps) {
    dailyWrites++;
    return super.writeDailySteps(date, steps);
  }

  @override
  Future<void> writeHourlySteps(String date, int hour, int steps) {
    hourlyWrites++;
    return super.writeHourlySteps(date, hour, steps);
  }
}

void main() {
  late CountingStepStore inner;
  late ThrottledStepStore store;

  setUp(() {
    inner = CountingStepStore();
    // Long enough that nothing flushes on its own during a test; the timer
    // gets its own test below.
    store = ThrottledStepStore(inner, flushInterval: const Duration(hours: 1));
  });

  tearDown(() => store.dispose());

  group('buffering', () {
    test('holds per-reading writes back', () async {
      await store.writeDailySteps('2026-08-16', 100);
      await store.writeHourlySteps('2026-08-16', 9, 100);

      expect(inner.dailyWrites, 0);
      expect(inner.hourlyWrites, 0);
    });

    test('reads see buffered values, not the stale row underneath', () async {
      inner.daily['2026-08-16'] = 100;
      await store.writeDailySteps('2026-08-16', 900);

      expect(await store.readDailySteps('2026-08-16'), 900);
      expect(await store.readHourlySteps('2026-08-16', 9), isNull);
    });

    test('collapses repeated writes into one', () async {
      for (var steps = 1; steps <= 50; steps++) {
        await store.writeDailySteps('2026-08-16', steps);
      }
      await store.flush();

      expect(inner.dailyWrites, 1, reason: '50 updates, one row written');
      expect(inner.daily['2026-08-16'], 50, reason: 'the latest value wins');
    });

    test('keeps days and hours separate when it flushes', () async {
      await store.writeDailySteps('2026-08-16', 500);
      await store.writeHourlySteps('2026-08-16', 9, 200);
      await store.writeHourlySteps('2026-08-16', 10, 300);
      await store.flush();

      expect(inner.daily['2026-08-16'], 500);
      expect(inner.hourly['2026-08-16@9'], 200);
      expect(inner.hourly['2026-08-16@10'], 300);
    });

    test('flushing with nothing pending writes nothing', () async {
      await store.flush();

      expect(inner.dailyWrites, 0);
      expect(inner.hourlyWrites, 0);
    });
  });

  group('writes that commit the buffer first', () {
    test('a baseline write flushes what is pending', () async {
      await store.writeDailySteps('2026-08-16', 400);
      await store.writeBaseline('2026-08-16', 1000);

      expect(inner.daily['2026-08-16'], 400,
          reason: 'a stored baseline must not outrun the total it anchors');
      expect(inner.baselines['2026-08-16'], 1000);
    });

    test('a manual credit flushes what is pending', () async {
      await store.writeDailySteps('2026-08-16', 400);
      await store.writeManualSteps('2026-08-16', 300);

      expect(inner.daily['2026-08-16'], 400);
      expect(inner.manual['2026-08-16'], 300);
    });
  });

  group('the flush timer', () {
    test('commits on its own once the interval passes', () async {
      final quick = ThrottledStepStore(
        inner,
        flushInterval: const Duration(milliseconds: 20),
      );
      addTearDown(quick.dispose);

      await quick.writeDailySteps('2026-08-16', 700);
      expect(inner.dailyWrites, 0, reason: 'not yet');

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(inner.daily['2026-08-16'], 700);
    });
  });

  group('driving the accumulator through it', () {
    test('the same totals come out, with far fewer writes', () async {
      final direct = CountingStepStore();
      final throttledInner = CountingStepStore();
      final throttled = ThrottledStepStore(
        throttledInner,
        flushInterval: const Duration(hours: 1),
      );
      addTearDown(throttled.dispose);

      final directTotals = <int>[];
      final throttledTotals = <int>[];

      final a = StepAccumulator(direct);
      final b = StepAccumulator(throttled);
      for (var raw = 1000; raw <= 1040; raw++) {
        directTotals.add((await a.record(raw, day1)).displaySteps);
        throttledTotals.add((await b.record(raw, day1)).displaySteps);
      }

      await throttled.flush();

      expect(throttledTotals, directTotals,
          reason: 'throttling changes when rows are written, nothing else');
      expect(direct.dailyWrites, 41, reason: 'one row per reading');
      expect(throttledInner.dailyWrites, 1, reason: 'one row for the lot');
      expect(throttledInner.hourlyWrites, 1);
      expect(throttledInner.daily['2026-08-16'], directTotals.last,
          reason: 'and it lands on the same number');
    });

    test('an unflushed kill still resumes the hour correctly', () async {
      final killed = ThrottledStepStore(
        inner,
        flushInterval: const Duration(hours: 1),
      );
      final before = StepAccumulator(killed);
      await before.record(1000, DateTime(2026, 8, 16, 9));
      await before.record(1200, DateTime(2026, 8, 16, 9));
      await killed.flush();

      // More steps arrive, then the process dies without flushing them.
      await before.record(1500, DateTime(2026, 8, 16, 9));
      killed.dispose();

      final revived = StepAccumulator(ThrottledStepStore(inner));
      final reading = await revived.record(1600, DateTime(2026, 8, 16, 9));

      expect(reading.displaySteps, 600,
          reason: 'the day is derived from the baseline, not the lost row');
      expect(reading.hourlySteps, 600,
          reason: 'the hour still lines up with the day it was stored beside');
    });
  });
}
