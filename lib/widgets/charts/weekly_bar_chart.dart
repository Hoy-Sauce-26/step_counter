import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/daily_steps.dart';

import 'chart_axis.dart';

/// Bar chart for the past 7 days.
///
/// - Y-axis floors at [dailyTarget], only growing if a day beat it, so
///   the target line never scrolls off-screen.
/// - Bars are colored primary if that day hit the target, gray if not.
/// - A dashed line marks the target.
/// - Tapping a bar calls [onDaySelected] with that day's date.
class WeeklyBarChart extends StatelessWidget {
  final List<DailySteps> last7Days; // zero-filled, chronological, len 7
  final int dailyTarget;
  final void Function(DateTime date)? onDaySelected;

  const WeeklyBarChart({
    super.key,
    required this.last7Days,
    required this.dailyTarget,
    this.onDaySelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missedColor = theme.brightness == Brightness.dark
        ? Colors.grey.shade600
        : Colors.grey.shade400;

    final highestSteps = last7Days.isEmpty
        ? 0
        : last7Days.map((d) => d.stepCount).reduce((a, b) => a > b ? a : b);
    final axisCeiling = max(dailyTarget, highestSteps);
    final maxY = axisCeiling <= 0 ? 1.0 : axisCeiling * 1.15;
    final interval = niceInterval(maxY, emptyFallback: 1000);

    return SizedBox(
      height: 240,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: interval,
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              bottom: BorderSide(color: theme.colorScheme.outline, width: 1),
            ),
          ),
          extraLinesData: ExtraLinesData(horizontalLines: [
            HorizontalLine(
              y: dailyTarget.toDouble(),
              color: theme.colorScheme.outline,
              strokeWidth: 1.5,
              dashArray: const [6, 4],
              // No inline label — any anchor position can end up behind
              // a bar depending on the data. Target value is shown in
              // the header above instead.
            ),
          ]),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: stepCountAxis(
                interval: interval,
                reservedSize: 44,
                labelStyle: theme.textTheme.labelSmall,
              ),
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
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final day = last7Days[group.x];
                final dateLabel = DateFormat.MMMd().format(day.dateTime);
                return BarTooltipItem(
                  '$dateLabel\n${day.stepCount} steps',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              },
            ),
            touchCallback: (event, response) {
              if (onDaySelected == null) return;
              if (event is! FlTapUpEvent) return;
              final index = response?.spot?.touchedBarGroupIndex;
              if (index == null || index < 0 || index >= last7Days.length) {
                return;
              }
              onDaySelected!(last7Days[index].dateTime);
            },
          ),
          barGroups: [
            for (var i = 0; i < last7Days.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: last7Days[i].stepCount.toDouble(),
                  color: last7Days[i].stepCount >= dailyTarget
                      ? theme.colorScheme.primary
                      : missedColor,
                  width: 20,
                  borderRadius: BorderRadius.circular(4),
                ),
              ]),
          ],
        ),
      ),
    );
  }

  /// Picks a "nice" gridline interval (1/2/5 × a power of ten) targeting
  /// roughly 4 gridlines across the chart.
}
