import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/metrics.dart';

/// These cover branch selection, unit conversion and magnitude rather than
/// re-stating the constants. Asserting that 1,000 steps is 0.762 km only
/// proves kmPerStep is still 0.000762, which the source already says; what's
/// worth catching is a formula picking the wrong branch, a conversion applied
/// backwards, or a constant that quietly moved by a factor of ten.
void main() {
  group('walking speed', () {
    test('is cadence times stride length', () {
      // 175 cm × 0.415 = 72.625 cm per step = 0.00072625 km, 100 a minute.
      expect(
        StepMetrics.speedKmh(100, heightCm: 175),
        closeTo(0.00072625 * 100 * 60, 1e-9),
      );
    });

    test('falls back to the flat stride when no height is set', () {
      expect(
        StepMetrics.speedKmh(100),
        closeTo(StepMetrics.kmPerStep * 100 * 60, 1e-9),
      );
    });

    // The whole reason intensity goes through speed rather than cadence.
    test('a tall slow walker and a short quick one come out the same', () {
      final tall = StepMetrics.speedKmh(90, heightCm: 193);
      final short = StepMetrics.speedKmh(110, heightCm: 162);

      expect((tall - short).abs() / tall, lessThan(0.03),
          reason: '193cm at 90/min and 162cm at 110/min is the same pace');
    });

    test('a nonsense cadence falls back rather than collapsing', () {
      for (final cadence in <double>[0, -100]) {
        expect(
          StepMetrics.speedKmh(cadence, heightCm: 175),
          closeTo(StepMetrics.speedKmh(
            StepMetrics.defaultStepsPerMinute,
            heightCm: 175,
          ), 1e-9),
          reason: 'cadence $cadence should use the default',
        );
      }
    });
  });

  group('walking METs', () {
    // Published Compendium values for level walking, discounted by the
    // incidental-movement factor. If an anchor moves, it should be because
    // someone went back to the table, not by accident.
    test('match the published anchors at the anchor speeds', () {
      const published = <({double kmh, double met})>[
        (kmh: 1.6, met: 2.0),
        (kmh: 3.2, met: 2.8),
        (kmh: 4.8, met: 3.5),
        (kmh: 6.4, met: 5.0),
        (kmh: 8.0, met: 8.3),
      ];
      for (final anchor in published) {
        expect(
          StepMetrics.metWalking(anchor.kmh),
          closeTo(anchor.met * StepMetrics.incidentalWalkingFactor, 1e-9),
          reason: '${anchor.kmh} km/h',
        );
      }
    });

    test('interpolates between anchors', () {
      // Midway between 4.0 (3.0) and 4.8 (3.5) is 3.25.
      expect(
        StepMetrics.metWalking(4.4),
        closeTo(3.25 * StepMetrics.incidentalWalkingFactor, 1e-9),
      );
    });

    test('rises with speed', () {
      expect(StepMetrics.metWalking(6.0),
          greaterThan(StepMetrics.metWalking(3.0)));
    });

    test('clamps flat beyond either end rather than extrapolating', () {
      expect(StepMetrics.metWalking(0.1), StepMetrics.metWalking(1.6),
          reason: 'a crawl is not less than the slowest published walk');
      expect(StepMetrics.metWalking(40), StepMetrics.metWalking(8.0),
          reason: 'a bad cadence must not invent a 40-MET sprint');
    });
  });

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
      // Default cadence and no height is 100 × 0.000762 × 60 = 4.572 km/h,
      // which interpolates to 3.358 METs, discounted to 2.854. Then
      // × 70 kg × (1000 steps ÷ 100 per minute ÷ 60) hours.
      expect(StepMetrics.calories(1000, weightKg: 70), closeTo(33.295, 0.01));
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

  group('cadence and calories together', () {
    // The guarantee made when this shipped: nobody's calorie figure moves
    // noticeably just because the model changed underneath them.
    test('default settings stay within 2% of the old flat 2.8 METs', () {
      const oldFlatMets = 2.8;
      final old = oldFlatMets * 70 * (10000 / 100 / 60);
      final now = StepMetrics.calories(10000, weightKg: 70);

      expect((now - old).abs() / old, lessThan(0.02));
    });

    test('a brisk walker burns more than an average one', () {
      // The trap in deriving hours from cadence: faster walking takes less
      // time, so without an intensity curve it would read as less energy.
      expect(
        StepMetrics.calories(10000, weightKg: 70, stepsPerMinute: 130),
        greaterThan(
          StepMetrics.calories(10000, weightKg: 70, stepsPerMinute: 100),
        ),
      );
    });

    // Walking economy is U-shaped: cost per step bottoms out around a normal
    // pace and climbs at both ends, because a shuffle is inefficient and a
    // near-jog is hard work. Pinned because the slow end looks like a bug
    // until you know it is the literature.
    test('cost per step is lowest at an ordinary pace, not at the slowest',
        () {
      double perStep(double cadence) =>
          StepMetrics.calories(10000, weightKg: 70, stepsPerMinute: cadence) /
          10000;

      expect(perStep(100), lessThan(perStep(60)),
          reason: 'a 2.7 km/h shuffle costs more per step than a walk');
      expect(perStep(100), lessThan(perStep(150)),
          reason: 'and so does a near-jog');
    });

    // Equal steps is not equal work when strides differ — the tall walker
    // covers 8.0 km to the short one's 6.7 km. Per kilometre is where the
    // two must agree, and that is what says height is handled once.
    test('two walkers at the same pace burn the same per kilometre', () {
      double perKm(double heightCm, double cadence) =>
          StepMetrics.calories(
            10000,
            weightKg: 70,
            heightCm: heightCm,
            stepsPerMinute: cadence,
          ) /
          StepMetrics.distanceKm(10000, heightCm: heightCm);

      final tall = perKm(193, 90);
      final short = perKm(162, 110);

      expect((tall - short).abs() / tall, lessThan(0.02),
          reason: '193cm at 90/min and 162cm at 110/min is the same pace');
    });

    test('cadence does not touch the flat rate when no weight is set', () {
      expect(
        StepMetrics.calories(10000, stepsPerMinute: 140),
        closeTo(StepMetrics.calories(10000, stepsPerMinute: 60), 1e-9),
        reason: 'no weight means no MET formula to feed',
      );
    });
  });

  group('active time', () {
    test('converts steps at the assumed cadence', () {
      expect(StepMetrics.activeMinutes(1000), closeTo(10, 1e-9));
    });

    test('uses a measured cadence when one is set', () {
      expect(
        StepMetrics.activeMinutes(1000, stepsPerMinute: 125),
        closeTo(8, 1e-9),
        reason: '1000 steps at 125/min is 8 minutes, not 10',
      );
    });

    test('a nonsense cadence falls back rather than collapsing', () {
      for (final cadence in <double>[0, -125]) {
        expect(
          StepMetrics.activeMinutes(1000, stepsPerMinute: cadence),
          closeTo(10, 1e-9),
          reason: 'cadence $cadence should use the default',
        );
      }
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
