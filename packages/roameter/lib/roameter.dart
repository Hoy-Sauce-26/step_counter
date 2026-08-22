import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/step_reading.dart';

export 'src/step_reading.dart';

/// Android's hardware step counter, with the three things it actually offers
/// and most wrappers discard: control over sensor batching, the real event
/// timestamps, and a reading without an open subscription.
class Roameter {
  const Roameter();

  @visibleForTesting
  static const MethodChannel methodChannel = MethodChannel('roameter/methods');

  @visibleForTesting
  static const EventChannel stepCountChannel =
      EventChannel('roameter/step_counts');

  /// Whether the device has a step counter at all. False is a permanent
  /// property of the hardware, not a transient failure.
  Future<bool> isStepCountingAvailable() async =>
      await methodChannel.invokeMethod<bool>('isStepCountingAvailable') ?? false;

  /// Takes one reading and lets go.
  ///
  /// The counter is an on-change sensor, so the platform reports its current
  /// value on registration — this returns in milliseconds without anyone
  /// having to walk. Sampling this way costs no wakelock and no standing
  /// subscription, which is what makes accurate daily totals affordable.
  ///
  /// Null when there is no sensor, or when one is present but reports
  /// nothing in time.
  Future<StepCountReading?> readStepCount() async =>
      StepCountReading.tryParse(
        await methodChannel.invokeMethod<Object?>('readStepCount'),
      );

  /// Continuous readings.
  ///
  /// [batchLatency] is how long the sensor hub may buffer events in hardware
  /// before waking the application processor. [Duration.zero] wakes it per
  /// step, which is what a live notification needs and what an always-on
  /// subscription cannot afford. Anything longer lets the device sleep
  /// through a walk and deliver it in one go — no steps are lost either way,
  /// since the counter is cumulative and each event carries its own time.
  Stream<StepCountReading> stepCounts({
    Duration batchLatency = Duration.zero,
  }) {
    return stepCountChannel
        .receiveBroadcastStream({
          'batchLatencyMicros': batchLatency.inMicroseconds,
        })
        .map(StepCountReading.tryParse)
        .where((reading) => reading != null)
        .cast<StepCountReading>();
  }
}
