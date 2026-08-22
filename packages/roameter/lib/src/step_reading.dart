import 'package:flutter/foundation.dart';

/// One reading of the hardware step counter.
@immutable
class StepCountReading {
  const StepCountReading({required this.steps, required this.timestamp});

  /// Cumulative steps since the counter last reset, which is device boot.
  /// Never a delta — the caller owns its own baseline.
  final int steps;

  /// When the sensor recorded the event, not when Dart received it. A batch
  /// delivered on waking carries the times its readings actually happened.
  final DateTime timestamp;

  /// Null when [payload] isn't a reading, so a malformed platform message
  /// drops rather than throwing inside a stream.
  static StepCountReading? tryParse(Object? payload) {
    if (payload is! Map) return null;
    final steps = payload['steps'];
    final millis = payload['timestamp'];
    if (steps is! num || millis is! num) return null;
    return StepCountReading(
      steps: steps.toInt(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(millis.toInt()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StepCountReading &&
      other.steps == steps &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(steps, timestamp);

  @override
  String toString() => 'StepCountReading($steps @ $timestamp)';
}
