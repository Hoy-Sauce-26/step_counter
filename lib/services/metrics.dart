/// Which unit system to display values in. Internal storage/calculation
/// always uses metric-ish canonical units (km, kg, inches for the stride
/// formula) — this only affects what's shown to the user.
enum UnitSystem { metric, imperial }

/// Distance paired with the unit label it's already expressed in — avoids
/// callers accidentally displaying a km value with a "mi" label or similar.
class DistanceResult {
  final double value;
  final String unit;
  const DistanceResult(this.value, this.unit);
}

/// Conversion formulas from raw step counts to distance/calories/time.
///
/// Distance and calories both support optional personalization — if the
/// user hasn't entered a height/weight, these fall back to the original
/// flat-rate constants ([kmPerStep], [kcalPerStep]) rather than requiring
/// personal data to work at all.
class StepMetrics {
  // Fallback constants, used when the user hasn't personalized.
  static const double kmPerStep = 0.000762; // ~0.762 m per stride
  static const double kcalPerStep = 0.04; // ~40 kcal per 1,000 steps

  static const double stepsPerMinute = 100;

  // Personalization formulas.
  static const double strideFactor = 0.415; // stride length = height * this
  static const double averageMets = 2.8; // average walking MET value
  static const double _inchesToKm = 0.0000254;
  static const double lbsToKg = 0.45359237;
  static const double kgToLbs = 1 / lbsToKg;
  static const double inchesToCm = 2.54;
  static const double cmToInches = 1 / inchesToCm;
  static const double kmToMiles = 0.621371;

  /// Distance in km (the canonical internal unit — see [distance] for a
  /// unit-aware version). If [heightInches] is provided, stride length is
  /// derived as `height * 0.415` (a standard walking-stride estimate)
  /// rather than using the flat [kmPerStep] average.
  static double distanceKm(int steps, {double? heightInches}) {
    if (heightInches == null || heightInches <= 0) {
      return steps * kmPerStep;
    }
    final strideKm = heightInches * strideFactor * _inchesToKm;
    return steps * strideKm;
  }

  /// Distance in whichever unit [unit] specifies, with its label attached.
  static DistanceResult distance(
    int steps, {
    double? heightInches,
    required UnitSystem unit,
  }) {
    final km = distanceKm(steps, heightInches: heightInches);
    if (unit == UnitSystem.imperial) {
      return DistanceResult(km * kmToMiles, 'mi');
    }
    return DistanceResult(km, 'km');
  }

  /// Calories burned. If [weightKg] is provided, uses the standard MET
  /// formula (`METs × weight(kg) × duration(hours)`) with an average
  /// walking MET of 2.8, using [activeMinutes] for duration — rather than
  /// the flat [kcalPerStep] average. Calories aren't unit-system-dependent
  /// (kcal is used regardless), so there's no imperial/metric variant here.
  static double calories(int steps, {double? weightKg}) {
    if (weightKg == null || weightKg <= 0) {
      return steps * kcalPerStep;
    }
    final hours = activeMinutes(steps) / 60;
    return averageMets * weightKg * hours;
  }

  static double activeMinutes(int steps) => steps / stepsPerMinute;

  /// Percentage (0-100+) of [dailyTarget] reached this month, given
  /// [totalSteps] logged so far and [daysInMonth] days in that month.
  static double monthlyProgressPercent({
    required int totalSteps,
    required int dailyTarget,
    required int daysInMonth,
  }) {
    if (dailyTarget <= 0 || daysInMonth <= 0) return 0;
    return (totalSteps / (dailyTarget * daysInMonth)) * 100;
  }
}

