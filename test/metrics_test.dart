import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/metrics.dart';

/// These cover branch selection, unit conversion and magnitude rather than
/// re-stating the constants. Asserting that 1,000 steps is 0.762 km only
/// proves kmPerStep is still 0.000762, which the source already says; what's
/// worth catching is a formula picking the wrong branch, a conversion applied
/// backwards, or a constant that quietly moved by a factor of ten.
void main() {
  group('distance', () {
    test('falls back to the flat rate when no height is set', () {
      expect(
        StepMetrics.distanceKm(1000),
        closeTo(1000 * StepMetrics.kmPerStep, 1e-9),
      );
    });

    test('uses stride length when a height is set', () {
      // 175 cm × 0.415 = 72.625 cm per step.
      expect(StepMetrics.distanceKm(1000, heightCm: 175), closeTo(0.72625, 1e-6));
    });

    test('a taller person covers more ground in the same number of steps', () {
      expect(
        StepMetrics.distanceKm(1000, heightCm: 190),
        greaterThan(StepMetrics.distanceKm(1000, heightCm: 160)),
      );
    });

    test('a nonsense height falls back rather than collapsing to zero', () {
      // Someone clearing the field shouldn't be told they walked nowhere.
      for (final height in <double>[0, -175]) {
        expect(
          StepMetrics.distanceKm(1000, heightCm: height),
          closeTo(StepMetrics.distanceKm(1000), 1e-9),
          reason: 'height $height should use the flat rate',
        );
      }
    });

    test('personalised and flat-rate estimates stay in the same ballpark', () {
      // The guard that matters: a mis-scaled conversion constant would show
      // up here as an order-of-magnitude gap, where an exact-value test would
      // just encode the mistake.
      final flat = StepMetrics.distanceKm(10000);
      final personalised = StepMetrics.distanceKm(10000, heightCm: 175);

      expect(personalised / flat, closeTo(1.0, 0.25));
    });

    test('no steps is no distance, personalised or not', () {
      expect(StepMetrics.distanceKm(0), 0);
      expect(StepMetrics.distanceKm(0, heightCm: 175), 0);
    });
  });

  group('distance units', () {
    test('metric reports kilometres unconverted', () {
      final result = StepMetrics.distance(10000, unit: UnitSystem.metric);

      expect(result.unit, 'km');
      expect(result.value, closeTo(StepMetrics.distanceKm(10000), 1e-9));
    });

    test('imperial reports a smaller number of miles', () {
      final metric = StepMetrics.distance(10000, unit: UnitSystem.metric);
      final imperial = StepMetrics.distance(10000, unit: UnitSystem.imperial);

      expect(imperial.unit, 'mi');
      // A mile is longer than a kilometre, so the figure must come down. This
      // is the assertion that catches the conversion being applied backwards.
      expect(imperial.value, lessThan(metric.value));
      expect(imperial.value, closeTo(metric.value * 0.621371, 1e-6));
    });

    test('carries the height through to both unit systems', () {
      final metric =
          StepMetrics.distance(10000, heightCm: 190, unit: UnitSystem.metric);
      final flat = StepMetrics.distance(10000, unit: UnitSystem.metric);

      expect(metric.value, greaterThan(flat.value));
    });
  });

  group('calories', () {
    test('falls back to the flat rate when no weight is set', () {
      expect(StepMetrics.calories(1000), closeTo(40, 1e-9));
    });

    test('uses the MET formula when a weight is set', () {
      // 2.8 METs × 70 kg × (1000 steps ÷ 100 per minute ÷ 60) hours.
      expect(StepMetrics.calories(1000, weightKg: 70), closeTo(32.667, 0.01));
    });

    test('a heavier person burns more over the same steps', () {
      expect(
        StepMetrics.calories(10000, weightKg: 100),
        greaterThan(StepMetrics.calories(10000, weightKg: 60)),
      );
    });

    test('a nonsense weight falls back rather than collapsing to zero', () {
      for (final weight in <double>[0, -70]) {
        expect(
          StepMetrics.calories(1000, weightKg: weight),
          closeTo(StepMetrics.calories(1000), 1e-9),
          reason: 'weight $weight should use the flat rate',
        );
      }
    });

    test('personalised and flat-rate estimates stay in the same ballpark', () {
      final flat = StepMetrics.calories(10000);
      final personalised = StepMetrics.calories(10000, weightKg: 70);

      expect(personalised / flat, closeTo(1.0, 0.4));
    });

    test('no steps is no calories, personalised or not', () {
      expect(StepMetrics.calories(0), 0);
      expect(StepMetrics.calories(0, weightKg: 70), 0);
    });
  });

  group('active time', () {
    test('converts steps at the assumed cadence', () {
      expect(StepMetrics.activeMinutes(1000), closeTo(10, 1e-9));
    });

    test('scales linearly and starts at zero', () {
      expect(StepMetrics.activeMinutes(0), 0);
      expect(
        StepMetrics.activeMinutes(2000),
        closeTo(StepMetrics.activeMinutes(1000) * 2, 1e-9),
      );
    });
  });
}
