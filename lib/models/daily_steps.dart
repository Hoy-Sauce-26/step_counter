/// A single day's step count. [date] is ISO-8601 (yyyy-MM-dd) so plain
/// string comparisons in SQL (BETWEEN, ORDER BY, LIKE) sort chronologically.
class DailySteps {
  final String date; // ISO-8601, e.g. "2026-08-08"
  final int stepCount;

  const DailySteps({
    required this.date,
    required this.stepCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'date': date,
      'stepCount': stepCount,
    };
  }

  factory DailySteps.fromMap(Map<String, dynamic> map) {
    return DailySteps(
      date: map['date'] as String,
      stepCount: map['stepCount'] as int,
    );
  }

  DateTime get dateTime => DateTime.parse(date);
}
