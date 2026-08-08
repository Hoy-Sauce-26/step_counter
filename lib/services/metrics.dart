/// Conversion formulas from raw step counts to distance/calories/time,
/// per the implementation plan (no GPS required).
class StepMetrics {
  static const double kmPerStep = 0.000762; // ~0.762 m per stride
  static const double kcalPerStep = 0.04; // ~40 kcal per 1,000 steps
  static const double stepsPerMinute = 100;

  static double distanceKm(int steps) => steps * kmPerStep;

  static double calories(int steps) => steps * kcalPerStep;

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
