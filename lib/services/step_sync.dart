import 'package:flutter/foundation.dart';
import 'package:roameter/roameter.dart';

import '../models/step_journal_entry.dart';
import 'step_projection.dart';

/// Takes a reading and folds it in, without any service running.
///
/// This is what keeps the count honest when the foreground service is off:
/// the hardware counter never stopped, so one reading on resume closes the
/// whole gap since the last one. It is also the cheapest possible sample —
/// a registration, the value the sensor reports on it, and done.
class StepSync {
  StepSync({
    StepProjection? projection,
    Roameter sensor = const Roameter(),
    this.minInterval = const Duration(minutes: 1),
  })  : _projection = projection ?? StepProjection(),
        _sensor = sensor;

  final StepProjection _projection;
  final Roameter _sensor;

  /// How close to the last journalled reading a sample may fall before it is
  /// skipped. Several launch paths ask for one within the same second, and
  /// three identical readings say nothing the first already did.
  final Duration minInterval;

  /// Records one reading. Returns false when there was nothing to read, or
  /// when the journal already has something this recent.
  Future<bool> sample({DateTime? now, bool force = false}) async {
    final at = now ?? DateTime.now();
    try {
      if (!force) {
        final latest = await _projection.latestEntry();
        if (latest != null &&
            !at.isBefore(latest.at) &&
            at.difference(latest.at) < minInterval) {
          return false;
        }
      }
      final reading = await _sensor.readStepCount();
      if (reading == null) return false;

      // The sensor's own event time is when the count last changed, which on
      // a quiet phone can be hours ago. The journal wants to know when the
      // counter stood at this value *as far as we observed*, so the interval
      // to the next reading is right — that is now, not then.
      await _projection.record(
        StepJournalEntry(at: at, rawSteps: reading.steps),
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint('[StepSync] sample failed: $error\n$stackTrace');
      return false;
    }
  }
}
