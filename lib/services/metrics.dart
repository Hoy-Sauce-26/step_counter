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

  static const double stepsPerMinute = 100;

  // Personalization formulas.
  static const double strideFactor = 0.415; // stride length = height * this
  static const double averageMets = 2.8; // average walking MET value
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
  static double calories(int steps, {double? weightKg}) {
    if (weightKg == null || weightKg <= 0) {
      return steps * kcalPerStep;
    }
    final hours = activeMinutes(steps) / 60;
    return averageMets * weightKg * hours;
  }

  static double activeMinutes(int steps) => steps / stepsPerMinute;
}

