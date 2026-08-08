import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../models/daily_steps.dart';

/// Bar chart for the current calendar month: x-axis = day number
/// (1..daysInMonth), y-axis = steps for that day (0 for days with no
/// record yet, including future days).
class MonthlyBarChart extends StatelessWidget {
  final List<DailySteps> monthRecords;
  final int daysInMonth;

  const MonthlyBarChart({
    super.key,
    required this.monthRecords,
    required this.daysInMonth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Zero-fill by day-of-month for a continuous 1..daysInMonth series.
    final byDay = <int, int>{};
    for (final r in monthRecords) {
      byDay[r.dateTime.day] = r.stepCount;
    }
    final values = List<int>.generate(
      daysInMonth,
      (i) => byDay[i + 1] ?? 0,
    );

    final maxVal = values.isEmpty
        ? 1.0
        : values.reduce((a, b) => a > b ? a : b).toDouble();

    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          maxY: maxVal * 1.2 + 1,
          alignment: BarChartAlignment.spaceBetween,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 5,
                getTitlesWidget: (value, meta) {
                  final day = value.toInt() + 1;
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child:
                        Text('$day', style: theme.textTheme.labelSmall),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < values.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: values[i].toDouble(),
                  color: theme.colorScheme.primary,
                  width: 6,
                  borderRadius: BorderRadius.circular(2),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
