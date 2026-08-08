/// Represents a single day's step count record.
///
/// [date] is stored as an ISO-8601 date string (yyyy-MM-dd) so that
/// lexicographic string comparisons in SQL (BETWEEN, ORDER BY, LIKE)
/// line up with chronological order.
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

  DailySteps copyWith({String? date, int? stepCount}) {
    return DailySteps(
      date: date ?? this.date,
      stepCount: stepCount ?? this.stepCount,
    );
  }

  DateTime get dateTime => DateTime.parse(date);
}
