import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/services/background_service.dart';

/// Folds a sequence of raw readings through [resolveRouteProgress] the way
/// the service does, carrying each result into the next call.
RouteProgress walk(
  List<int> rawReadings, {
  required int rawBaseline,
  double correctionFactor = 1.0,
}) {
  var progress = RouteProgress(
    rawBaseline: rawBaseline,
    stepsBefore: 0,
    steps: 0,
    lastRaw: rawBaseline,
  );
  for (final raw in rawReadings) {
    progress = resolveRouteProgress(
      rawCumulative: raw,
      rawBaseline: progress.rawBaseline,
      stepsBefore: progress.stepsBefore,
      bankedSteps: progress.steps,
      lastRaw: progress.lastRaw,
      correctionFactor: correctionFactor,
    );
  }
  return progress;
}

void main() {
  group('resolveRouteProgress', () {
    test('counts steps taken since the route started', () {
      expect(walk([500100], rawBaseline: 500000).steps, 100);
    });

    test('applies the correction factor', () {
      expect(
        walk([500100], rawBaseline: 500000, correctionFactor: 0.9).steps,
        90,
      );
    });

    test('applies the factor per segment, not per reading', () {
      // A hundred single-step readings. Rounding each one at 0.9 would give
      // 100 — every 0.9 rounds up — instead of the 90 steps actually taken.
      final readings = [for (var i = 1; i <= 100; i++) 500000 + i];

      expect(
        walk(readings, rawBaseline: 500000, correctionFactor: 0.9).steps,
        90,
      );
    });

    // The regression B2 exists for. A reboot mid-walk zeroes the hardware
    // counter and kills the service isolate, so the baseline reloaded from
    // storage sits far above the reading. Before the fix the delta clamped
    // to zero for the rest of the route — and since the count committed to
    // the route's history is this one, finishing the walk wrote a zero-step
    // session and skewed the route's average for good.
    test('a reboot mid-route keeps the steps already walked', () {
      final progress = resolveRouteProgress(
        rawCumulative: 0,
        rawBaseline: 500000,
        stepsBefore: 0,
        bankedSteps: 1200,
        lastRaw: null,
        correctionFactor: 1.0,
      );

      expect(progress.steps, 1200, reason: 'the walk so far must survive');
      expect(progress.rawBaseline, 0, reason: 're-baselined to the reading');
      expect(progress.stepsBefore, 1200);
    });

    test('keeps counting after a reboot, on top of what was banked', () {
      var progress = resolveRouteProgress(
        rawCumulative: 0,
        rawBaseline: 500000,
        stepsBefore: 0,
        bankedSteps: 1200,
        lastRaw: null,
        correctionFactor: 1.0,
      );

      progress = resolveRouteProgress(
        rawCumulative: 300,
        rawBaseline: progress.rawBaseline,
        stepsBefore: progress.stepsBefore,
        bankedSteps: progress.steps,
        lastRaw: progress.lastRaw,
        correctionFactor: 1.0,
      );

      expect(progress.steps, 1500);
    });

    test('does not bank a second time on later readings', () {
      // Only the reading that detects the reset may promote the banked
      // total; if a later one did too, the pre-reboot steps would be added
      // again on every event for the rest of the walk.
      final progress = walk(
        [0, 100, 200, 300],
        rawBaseline: 500000,
      );

      expect(progress.steps, 300);
      expect(progress.stepsBefore, 0);
    });

    test('survives two resets in one route', () {
      var progress = resolveRouteProgress(
        rawCumulative: 0,
        rawBaseline: 500000,
        stepsBefore: 0,
        bankedSteps: 800,
        lastRaw: null,
        correctionFactor: 1.0,
      );
      progress = resolveRouteProgress(
        rawCumulative: 200,
        rawBaseline: progress.rawBaseline,
        stepsBefore: progress.stepsBefore,
        bankedSteps: progress.steps,
        lastRaw: progress.lastRaw,
        correctionFactor: 1.0,
      );
      // Second reboot. The baseline is 0 from the first one, so nothing is
      // below it — only the previous reading exposes this.
      progress = resolveRouteProgress(
        rawCumulative: 0,
        rawBaseline: progress.rawBaseline,
        stepsBefore: progress.stepsBefore,
        bankedSteps: progress.steps,
        lastRaw: progress.lastRaw,
        correctionFactor: 1.0,
      );
      progress = resolveRouteProgress(
        rawCumulative: 50,
        rawBaseline: progress.rawBaseline,
        stepsBefore: progress.stepsBefore,
        bankedSteps: progress.steps,
        lastRaw: progress.lastRaw,
        correctionFactor: 1.0,
      );

      expect(progress.steps, 1050);
    });

    test('a route started before any reading counts from its first one', () {
      // rawBaseline falls back to the current reading in that case, so the
      // route opens at zero rather than at the whole day's raw total.
      expect(walk([500000], rawBaseline: 500000).steps, 0);
    });
  });
}
