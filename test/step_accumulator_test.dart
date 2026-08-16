import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/step_accumulator.dart';

/// In-memory [StepStore]. The whole reason the accumulator takes a store
/// rather than reaching for SharedPreferences and sqflite directly: the step
/// accounting can now be driven through a day, a reboot and an hour boundary
/// in a few milliseconds, with no device involved.
class FakeStepStore implements StepStore {
  final Map<String, int> baselines = {};
  final Map<String, int> manual = {};
  final Map<String, int> daily = {};
  final Map<String, int> hourly = {};

  String _hourKey(String date, int hour) => '$date@$hour';

  @override
  Future<int?> readBaseline(String date) async => baselines[date];

  @override
  Future<void> writeBaseline(String date, int baseline) async {
    baselines
      ..clear()
      ..[date] = baseline;
  }

  @override
  Future<int> readManualSteps(String date) async => manual[date] ?? 0;

  @override
  Future<void> writeManualSteps(String date, int steps) async =>
      manual[date] = steps;

  @override
  Future<int?> readDailySteps(String date) async => daily[date];

  @override
  Future<void> writeDailySteps(String date, int steps) async =>
      daily[date] = steps;

  @override
  Future<int?> readHourlySteps(String date, int hour) async =>
      hourly[_hourKey(date, hour)];

  @override
  Future<void> writeHourlySteps(String date, int hour, int steps) async =>
      hourly[_hourKey(date, hour)] = steps;
}

final day1 = DateTime(2026, 8, 16, 9);
final day2 = DateTime(2026, 8, 17, 9);

void main() {
  late FakeStepStore store;
  late StepAccumulator accumulator;

  setUp(() {
    store = FakeStepStore();
    accumulator = StepAccumulator(store);
  });

  group('recording readings', () {
    test('the first reading of a day counts as zero, not as the raw total',
        () async {
      final reading = await accumulator.record(1000, day1);

      expect(reading.displaySteps, 0);
      expect(store.daily['2026-08-16'], 0);
    });

    test('counts steps taken since the first reading', () async {
      await accumulator.record(1000, day1);
      final reading = await accumulator.record(1500, day1);

      expect(reading.sensorSteps, 500);
      expect(reading.displaySteps, 500);
    });

    test('applies the correction factor', () async {
      accumulator.correctionFactor = 0.9;
      await accumulator.record(1000, day1);

      expect((await accumulator.record(1100, day1)).displaySteps, 90);
    });

    test('a new day starts from zero and leaves yesterday alone', () async {
      await accumulator.record(1000, day1);
      await accumulator.record(1500, day1);

      final reading = await accumulator.record(1600, day2);

      expect(reading.displaySteps, 0, reason: 'the new day starts fresh');
      expect(store.daily['2026-08-16'], 500, reason: "yesterday's total holds");
    });

    // B1, at the sequencing level rather than the arithmetic level.
    test('a reboot mid-day keeps the total and resumes counting', () async {
      await accumulator.record(1000, day1);
      await accumulator.record(1500, day1);

      // The counter restarts near zero; the stored baseline is now far above
      // the reading.
      expect((await accumulator.record(3, day1)).displaySteps, 500);
      expect((await accumulator.record(103, day1)).displaySteps, 600);
    });
  });

  group('hourly buckets', () {
    test('a new hour starts from the previous reading, not from zero',
        () async {
      await accumulator.record(1000, DateTime(2026, 8, 16, 9));
      await accumulator.record(1500, DateTime(2026, 8, 16, 9));

      final reading = await accumulator.record(1600, DateTime(2026, 8, 16, 10));

      expect(reading.hourlySteps, 100);
      expect(store.hourly['2026-08-16@9'], 500);
    });

    // Characterises B6 rather than asserting what would be right. The hour
    // does resume from its stored count instead of restarting at zero — that
    // part works. But the reading that revives it gets absorbed into
    // re-establishing the boundary, so its steps vanish: 500 were walked in
    // this hour and 400 are recorded. Normally that costs one step; after a
    // stretch with the screen off, where readings arrive batched, it costs
    // the whole batch.
    //
    // Preserved deliberately through this extraction so that a refactor
    // break and a deliberate fix stay distinguishable. B6 turns the 400 into
    // a 500, and this test should go red when it does.
    test('a restart mid-hour resumes the hour, minus the reviving reading',
        () async {
      await accumulator.record(1000, DateTime(2026, 8, 16, 9));
      await accumulator.record(1400, DateTime(2026, 8, 16, 9));

      // A fresh accumulator over the same storage — the service was killed
      // and came back.
      final revived = StepAccumulator(store);
      final reading = await revived.record(1500, DateTime(2026, 8, 16, 9));

      expect(reading.hourlySteps, 400);
    });
  });

  group('manual credits', () {
    test('add to the day and show up in the total', () async {
      await accumulator.record(1000, day1);
      await accumulator.record(1500, day1);

      expect(await accumulator.creditManualSteps(300, day1), 800);
      expect(store.daily['2026-08-16'], 800);
    });

    test('never land in an hourly bucket', () async {
      await accumulator.record(1000, day1);
      await accumulator.record(1500, day1);
      await accumulator.creditManualSteps(300, day1);

      expect(store.hourly['2026-08-16@9'], 500,
          reason: 'nobody walked credited steps at a particular time');
    });

    test('are ignored when the amount is not usable', () async {
      expect(await accumulator.creditManualSteps(0, day1), isNull);
      expect(await accumulator.creditManualSteps(-5, day1), isNull);
    });

    // Regression: falling back to zero when no reading has landed yet
    // overwrote the day's stored total with just the credit.
    test('build on the stored total when no reading has landed yet', () async {
      store.daily['2026-08-16'] = 4000;

      expect(await accumulator.creditManualSteps(500, day1), 4500);
      expect(store.daily['2026-08-16'], 4500);
    });

    test('survive a reboot without being counted twice', () async {
      await accumulator.record(1000, day1);
      await accumulator.record(1500, day1);
      await accumulator.creditManualSteps(200, day1);

      // The baseline is reconstructed from the stored total, which now holds
      // 500 walked plus 200 credited. Only the walked part came from the
      // sensor; treating all 700 as sensor steps would double the credit.
      expect((await accumulator.record(3, day1)).displaySteps, 700);
    });

    // Regression: the credit used to mark the day as resolved, which stopped
    // the next reading from re-baselining and folded yesterday into today.
    test('on a new day do not suppress the next reading rebaselining',
        () async {
      await accumulator.record(1000, day1);
      await accumulator.record(1500, day1);

      await accumulator.creditManualSteps(100, day2);
      final reading = await accumulator.record(1600, day2);

      expect(
        reading.displaySteps,
        100,
        reason: "only the credit — yesterday's 500 must not carry over",
      );
    });
  });
}
