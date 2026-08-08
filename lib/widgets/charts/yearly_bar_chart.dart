import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// Bar chart for the current year: x-axis = months (Jan-Dec), each bar
/// height = that month's total steps as a percentage of
/// (dailyTarget * daysInMonth).
class YearlyBarChart extends StatelessWidget {
  /// Progress percentage per month, keyed 1-12.
  final Map<int, double> monthlyProgressPercent;

  const YearlyBarChart({super.key, required this.monthlyProgressPercent});

  static const _monthLabels = [
    'J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxVal = monthlyProgressPercent.values.isEmpty
        ? 100.0
        : monthlyProgressPercent.values
            .reduce((a, b) => a > b ? a : b)
            .clamp(100.0, double.infinity);

    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          maxY: maxVal * 1.15,
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(horizontalLines: [
            HorizontalLine(
              y: 100,
              color: theme.colorScheme.tertiary,
              strokeWidth: 1.5,
              dashArray: [4, 4],
            ),
          ]),
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
                getTitlesWidget: (value, meta) {
                  final index = value.toInt();
                  if (index < 0 || index >= 12) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_monthLabels[index],
                        style: theme.textTheme.labelSmall),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var m = 1; m <= 12; m++)
              BarChartGroupData(x: m - 1, barRods: [
                BarChartRodData(
                  toY: monthlyProgressPercent[m] ?? 0,
                  color: (monthlyProgressPercent[m] ?? 0) >= 100
                      ? Colors.green
                      : theme.colorScheme.primary,
                  width: 14,
                  borderRadius: BorderRadius.circular(4),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
