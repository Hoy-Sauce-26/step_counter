import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/daily_steps.dart';

/// Bar chart for the past 7 days.
///
/// - The y-axis is always labeled, with a floor of [dailyTarget] — it only
///   extends higher if some day in the week actually beat the target, so
///   the target is never scrolled off the top of a mostly-under-target
///   week.
/// - Each bar is colored by whether that day met the target: theme primary
///   if it did, gray if it didn't.
/// - A dashed reference line marks the target itself.
/// - Tapping a bar shows the exact date and step count, and calls
///   [onDaySelected] with that day's date, if provided.
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
    final interval = _niceInterval(maxY);

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
              // No inline label here on purpose — wherever it's anchored
              // (left, right, or centered), some day's bar can end up
              // right behind it depending on the data. The target value
              // is shown as text in the section header above instead,
              // where nothing can ever overlap it.
            ),
          ]),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                interval: interval,
                getTitlesWidget: (value, meta) {
                  if (value < 0) return const SizedBox.shrink();
                  // fl_chart always renders a label at the axis's exact
                  // computed max in addition to the interval-based ticks,
                  // which — since that max is usually not a clean multiple
                  // of `interval` — ends up overlapping the nearest real
                  // tick label (e.g. a "2.05K" boundary label crowding a
                  // "2K" gridline label right next to it). Only draw a
                  // label when the value actually lands on our interval.
                  final remainder = value % interval;
                  final onInterval =
                      remainder < 0.5 || (interval - remainder) < 0.5;
                  if (!onInterval) return const SizedBox.shrink();
                  return Text(
                    NumberFormat.compact().format(value),
                    style: theme.textTheme.labelSmall,
                  );
                },
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
  double _niceInterval(double maxY) {
    if (maxY <= 0) return 1000;
    final rough = maxY / 4;
    final magnitude = pow(10, (log(rough) / ln10).floor()).toDouble();
    final residual = rough / magnitude;
    final niceResidual = residual >= 5 ? 5.0 : (residual >= 2 ? 2.0 : 1.0);
    return niceResidual * magnitude;
  }
}
