import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/daily_steps.dart';

/// Displays daily step counts for the past 7 days as bars, with a
/// horizontal dashed line marking the 7-day average.
class WeeklyBarChart extends StatelessWidget {
  final List<DailySteps> last7Days; // zero-filled, chronological, len 7
  final double average;

  const WeeklyBarChart({
    super.key,
    required this.last7Days,
    required this.average,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxY = [
      average,
      ...last7Days.map((d) => d.stepCount.toDouble()),
    ].reduce((a, b) => a > b ? a : b) *
        1.2 +
        1;

    return SizedBox(
      height: 220,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: const FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          extraLinesData: ExtraLinesData(horizontalLines: [
            HorizontalLine(
              y: average,
              color: theme.colorScheme.secondary,
              strokeWidth: 2,
              dashArray: [6, 4],
              label: HorizontalLineLabel(
                show: true,
                labelResolver: (line) => 'avg ${average.round()}',
                style: TextStyle(
                  color: theme.colorScheme.secondary,
                  fontSize: 11,
                ),
              ),
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
                  if (index < 0 || index >= last7Days.length) {
                    return const SizedBox.shrink();
                  }
                  final label =
                      DateFormat.E().format(last7Days[index].dateTime);
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(label, style: theme.textTheme.labelSmall),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < last7Days.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: last7Days[i].stepCount.toDouble(),
                  color: theme.colorScheme.primary,
                  width: 18,
                  borderRadius: BorderRadius.circular(4),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
