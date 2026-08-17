import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// A round number to step the y-axis by, aiming for roughly four gridlines.
double niceInterval(double maxY, {required double emptyFallback}) {
  if (maxY <= 0) return emptyFallback;
  final rough = maxY / 4;
  final magnitude = pow(10, (log(rough) / ln10).floor()).toDouble();
  final residual = rough / magnitude;
  final niceResidual = residual >= 5 ? 5.0 : (residual >= 2 ? 2.0 : 1.0);
  return niceResidual * magnitude;
}

/// fl_chart always adds a label at the axis maximum, which is usually not a
/// clean multiple and collides with the nearest real tick.
SideTitles stepCountAxis({
  required double interval,
  required double reservedSize,
  required TextStyle? labelStyle,
}) {
  return SideTitles(
    showTitles: true,
    reservedSize: reservedSize,
    interval: interval,
    getTitlesWidget: (value, meta) {
      if (value < 0) return const SizedBox.shrink();
      final remainder = value % interval;
      final onInterval = remainder < 0.5 || (interval - remainder) < 0.5;
      if (!onInterval) return const SizedBox.shrink();
      return Text(NumberFormat.compact().format(value), style: labelStyle);
    },
  );
}
