/// Display unit system. Storage/calculation always use metric-ish
/// canonical units — this only affects what's shown to the user.
enum UnitSystem { metric, imperial }

/// Distance paired with its unit label, so callers can't mismatch a km
/// value with a "mi" label.
class DistanceResult {
  final double value;
  final String unit;
  const DistanceResult(this.value, this.unit);
}

/// Conversion formulas from step counts to distance/calories/time.
///
/// Distance and calories fall back to flat-rate constants ([kmPerStep],
/// [kcalPerStep]) when height/weight aren't set — personalization is
/// optional, not required.
class StepMetrics {
  // Fallback constants, used when the user hasn't personalized.
  static const double kmPerStep = 0.000762; // ~0.762 m per stride
  static const double kcalPerStep = 0.04; // ~40 kcal per 1,000 steps

  /// Assumed cadence when the user hasn't measured their own.
  static const double defaultStepsPerMinute = 100;

  /// Compendium METs describe sustained, purposeful, level walking. A day's
  /// step total is mostly not that — kitchen trips, corridors, stop-start
  /// pottering — which is genuinely less intense. Applied to [metWalking]
  /// rather than baked into the anchors, so those stay checkable against the
  /// published table and this stays one number to argue about.
  static const double incidentalWalkingFactor = 0.85;

  // Personalization formulas.
  static const double strideFactor = 0.415; // stride length = height * this
  static const double _cmToKm = 0.00001;
  static const double lbsToKg = 0.45359237;
  static const double kgToLbs = 1 / lbsToKg;
  static const double inchesToCm = 2.54;
  static const double cmToInches = 1 / inchesToCm;
  static const double kmToMiles = 0.621371;

  /// Distance in km (canonical unit — see [distance] for unit-aware).
  /// Uses `height * 0.415` as stride length when [heightCm] is given,
  /// otherwise the flat [kmPerStep] average.
  static double distanceKm(int steps, {double? heightCm}) {
    if (heightCm == null || heightCm <= 0) {
      return steps * kmPerStep;
    }
    final strideKm = heightCm * strideFactor * _cmToKm;
    return steps * strideKm;
  }

  /// Distance in whichever unit [unit] specifies, with its label attached.
  static DistanceResult distance(
    int steps, {
    double? heightCm,
    required UnitSystem unit,
  }) {
    final km = distanceKm(steps, heightCm: heightCm);
    if (unit == UnitSystem.metric) {
      return DistanceResult(km, 'km');
    }
    return DistanceResult(km * kmToMiles, 'mi');
  }

  /// Calories burned. Uses the MET formula (METs × weight(kg) ×
  /// duration(hours)) when [weightKg] is given, otherwise the flat
  /// [kcalPerStep] average. Always kcal — no imperial/metric variant.
  ///
  /// [heightCm] and [stepsPerMinute] only matter on the personalised branch,
  /// where they set the walking speed and so the intensity. Without a weight
  /// there is no MET formula to feed, and the flat rate is per-step.
  static double calories(
    int steps, {
    double? weightKg,
    double? heightCm,
    double? stepsPerMinute,
  }) {
    if (weightKg == null || weightKg <= 0) {
      return steps * kcalPerStep;
    }
    final cadence = _cadence(stepsPerMinute);
    final hours = activeMinutes(steps, stepsPerMinute: cadence) / 60;
    final mets = metWalking(speedKmh(cadence, heightCm: heightCm));
    return mets * weightKg * hours;
  }

  static double activeMinutes(int steps, {double? stepsPerMinute}) =>
      steps / _cadence(stepsPerMinute);

  /// Walking speed implied by a cadence.
  ///
  /// Goes through [distanceKm] so the stride model lives in exactly one
  /// place. That is what controls for height: a 193 cm walker at 90 spm and
  /// a 162 cm walker at 110 spm come out within 3% of each other, because
  /// they are in fact walking at the same speed.
  static double speedKmh(double stepsPerMinute, {double? heightCm}) =>
      distanceKm(1, heightCm: heightCm) * _cadence(stepsPerMinute) * 60;

  /// METs for level walking at [speedKmh], linearly interpolated between the
  /// Compendium of Physical Activities anchors for level, firm-surface
  /// walking, clamped flat beyond either end, and discounted by
  /// [incidentalWalkingFactor].
  ///
  /// Intensity is a function of speed, not of cadence — mapping cadence
  /// straight to a MET would call a tall, unhurried walker brisk and a short,
  /// hurrying one slow.
  static double metWalking(double speedKmh) {
    const anchors = <({double kmh, double met})>[
      (kmh: 1.6, met: 2.0), // 1.0 mph
      (kmh: 3.2, met: 2.8), // 2.0 mph
      (kmh: 4.0, met: 3.0), // 2.5 mph
      (kmh: 4.8, met: 3.5), // 3.0 mph
      (kmh: 5.6, met: 4.3), // 3.5 mph
      (kmh: 6.4, met: 5.0), // 4.0 mph
      (kmh: 7.2, met: 7.0), // 4.5 mph
      (kmh: 8.0, met: 8.3), // 5.0 mph
    ];

    if (speedKmh <= anchors.first.kmh) {
      return anchors.first.met * incidentalWalkingFactor;
    }
    for (var i = 1; i < anchors.length; i++) {
      final upper = anchors[i];
      if (speedKmh <= upper.kmh) {
        final lower = anchors[i - 1];
        final t = (speedKmh - lower.kmh) / (upper.kmh - lower.kmh);
        final met = lower.met + t * (upper.met - lower.met);
        return met * incidentalWalkingFactor;
      }
    }
    return anchors.last.met * incidentalWalkingFactor;
  }

  /// A cadence that can't produce a divide-by-zero or a negative duration.
  /// Falls back rather than collapsing, the same way height and weight do —
  /// someone clearing the field shouldn't be told they walked for -4 hours.
  static double _cadence(double? stepsPerMinute) =>
      (stepsPerMinute == null || stepsPerMinute <= 0)
          ? defaultStepsPerMinute
          : stepsPerMinute;
}

