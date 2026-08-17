import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/step_accumulator.dart';

int displayedSteps({
  required int rawCumulative,
  required int baseline,
  double correctionFactor = 1.0,
}) {
  final rawDelta = (rawCumulative - baseline).clamp(0, 1 << 30);
  return (rawDelta * correctionFactor).round();
}

void main() {
  group('resolveBaselineValue', () {
    test('keeps the saved baseline while the sensor is still climbing', () {
      final baseline = resolveBaselineValue(
        rawCumulative: 500100,
        sensorHasReset: false,
        savedBaseline: 500000,
        existingSteps: 100,
        correctionFactor: 1.0,
      );

      expect(baseline, 500000);
      expect(displayedSteps(rawCumulative: 500100, baseline: baseline), 100);
    });

    test('keeps the saved baseline when the reading has not moved', () {
      expect(
        resolveBaselineValue(
          rawCumulative: 500000,
          sensorHasReset: false,
        savedBaseline: 500000,
          existingSteps: 0,
          correctionFactor: 1.0,
        ),
        500000,
      );
    });

    test('baselines a fresh day to the current raw reading', () {
      final baseline = resolveBaselineValue(
        rawCumulative: 500000,
        sensorHasReset: false,
        savedBaseline: null,
        existingSteps: 0,
        correctionFactor: 1.0,
      );

      expect(baseline, 500000);
      expect(displayedSteps(rawCumulative: 500000, baseline: baseline), 0);
    });

    test('baselines a fresh day to the previous reading when there is one',
        () {
      final baseline = resolveBaselineValue(
        rawCumulative: 503000,
        sensorHasReset: false,
        savedBaseline: null,
        existingSteps: 0,
        correctionFactor: 1.0,
        previousRaw: 500000,
      );

      expect(baseline, 500000);
      expect(
        displayedSteps(rawCumulative: 503000, baseline: baseline),
        3000,
        reason: 'the steps batched since the last reading are the new day\'s',
      );
    });

    test('carries the previous reading over through the correction factor',
        () {
      final baseline = resolveBaselineValue(
        rawCumulative: 501000,
        sensorHasReset: false,
        savedBaseline: null,
        existingSteps: 0,
        correctionFactor: 0.9,
        previousRaw: 500000,
      );

      expect(
        displayedSteps(
          rawCumulative: 501000,
          baseline: baseline,
          correctionFactor: 0.9,
        ),
        900,
      );
    });

    test('ignores the previous reading after a reset', () {
      final baseline = resolveBaselineValue(
        rawCumulative: 40,
        sensorHasReset: true,
        savedBaseline: null,
        existingSteps: 0,
        correctionFactor: 1.0,
        previousRaw: 500000,
      );

      expect(baseline, 40, reason: 'the counter restarted below the reading');
      expect(displayedSteps(rawCumulative: 40, baseline: baseline), 0);
    });

    test('prefers a day\'s own saved baseline over the previous reading', () {
      expect(
        resolveBaselineValue(
          rawCumulative: 500100,
          sensorHasReset: false,
          savedBaseline: 500000,
          existingSteps: 100,
          correctionFactor: 1.0,
          previousRaw: 500050,
        ),
        500000,
        reason: 'a day already under way is anchored, not re-anchored',
      );
    });

    test("a reboot mid-day keeps the day's total and resumes counting", () {
      final baseline = resolveBaselineValue(
        rawCumulative: 0,
        sensorHasReset: true,
        savedBaseline: 500000,
        existingSteps: 100,
        correctionFactor: 1.0,
      );

      expect(baseline, -100, reason: 'negative is intended after a reset');
      expect(
        displayedSteps(rawCumulative: 0, baseline: baseline),
        100,
        reason: "the day's stored total must survive the reboot",
      );
      expect(
        displayedSteps(rawCumulative: 25, baseline: baseline),
        125,
        reason: 'steps after the reboot must accumulate on top',
      );
    });

    test('a reboot before any steps today baselines to the raw reading', () {
      final baseline = resolveBaselineValue(
        rawCumulative: 5,
        sensorHasReset: true,
        savedBaseline: 500000,
        existingSteps: 0,
        correctionFactor: 1.0,
      );

      expect(baseline, 5);
      expect(displayedSteps(rawCumulative: 5, baseline: baseline), 0);
    });

    test('re-derives through the correction factor after a reboot', () {
      // 90 corrected steps at 0.9 came from 100 raw ones.
      final baseline = resolveBaselineValue(
        rawCumulative: 0,
        sensorHasReset: true,
        savedBaseline: 500000,
        existingSteps: 90,
        correctionFactor: 0.9,
      );

      expect(baseline, -100);
      expect(
        displayedSteps(
          rawCumulative: 0,
          baseline: baseline,
          correctionFactor: 0.9,
        ),
        90,
      );
    });

    test('treats a zero correction factor as no correction', () {
      expect(
        resolveBaselineValue(
          rawCumulative: 0,
          sensorHasReset: true,
        savedBaseline: 500000,
          existingSteps: 100,
          correctionFactor: 0,
        ),
        0,
      );
    });
  });
}
