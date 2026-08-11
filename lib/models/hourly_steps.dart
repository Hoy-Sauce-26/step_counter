/// Represents step count for a single hour of a single day.
class HourlySteps {
  final String date; // ISO-8601, e.g. "2026-08-11"
  final int hour; // 0-23
  final int stepCount;

  const HourlySteps({
    required this.date,
    required this.hour,
    required this.stepCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'date': date,
      'hour': hour,
      'stepCount': stepCount,
    };
  }

  factory HourlySteps.fromMap(Map<String, dynamic> map) {
    return HourlySteps(
      date: map['date'] as String,
      hour: map['hour'] as int,
      stepCount: map['stepCount'] as int,
    );
  }
}
