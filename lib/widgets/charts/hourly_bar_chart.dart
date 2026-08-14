import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models/hourly_steps.dart';

/// Bar chart for a single day's hourly breakdown: 24 bars, one per hour.
/// No target-based coloring — target is a daily concept, not hourly.
class HourlyBarChart extends StatelessWidget {
  final List<HourlySteps> hours; // zero-filled, length 24, hour 0-23

  const HourlyBarChart({super.key, required this.hours});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxSteps = hours.isEmpty
        ? 0
        : hours.map((h) => h.stepCount).reduce((a, b) => a > b ? a : b);
    final maxY = maxSteps <= 0 ? 1.0 : maxSteps * 1.2;
    final interval = _niceInterval(maxY);

    return SizedBox(
      height: 220,
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
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: interval,
                getTitlesWidget: (value, meta) {
                  if (value < 0) return const SizedBox.shrink();
                  // Same fix as the weekly chart's y-axis — only draw
                  // labels that land on our interval, avoiding overlap
                  // with fl_chart's auto label at the axis max.
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
                // fl_chart ignores `interval` for categorical x-axes, so
                // all 24 hours would render on top of each other — filter
                // manually instead, same as the y-axis fix above.
                getTitlesWidget: (value, meta) {
                  final hour = value.toInt();
                  if (hour < 0 || hour > 23) return const SizedBox.shrink();
                  if (hour % 3 != 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_hourLabel(hour),
                        style: theme.textTheme.labelSmall),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final hour = hours[group.x];
                return BarTooltipItem(
                  '${_hourLabel(hour.hour)}\n${hour.stepCount} steps',
                  const TextStyle(color: Colors.white, fontSize: 12),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < hours.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: hours[i].stepCount.toDouble(),
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

  static String _hourLabel(int hour) {
    if (hour == 0) return '12a';
    if (hour == 12) return '12p';
    return hour < 12 ? '${hour}a' : '${hour - 12}p';
  }

  double _niceInterval(double maxY) {
    if (maxY <= 0) return 100;
    final rough = maxY / 4;
    final magnitude = pow(10, (log(rough) / ln10).floor()).toDouble();
    final residual = rough / magnitude;
    final niceResidual = residual >= 5 ? 5.0 : (residual >= 2 ? 2.0 : 1.0);
    return niceResidual * magnitude;
  }
}
