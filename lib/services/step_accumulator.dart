import 'dart:async';

import '../models/daily_steps.dart';
import 'formatting.dart';
import 'database_helper.dart';
import 'preferences_service.dart';

/// Storage the accumulator depends on.
abstract class StepStore {
  Future<int?> readBaseline(String date);
  Future<void> writeBaseline(String date, int baseline);

  Future<int> readManualSteps(String date);
  Future<void> writeManualSteps(String date, int steps);

  Future<int?> readDailySteps(String date);
  Future<void> writeDailySteps(String date, int steps);

  Future<int?> readHourlySteps(String date, int hour);
  Future<void> writeHourlySteps(String date, int hour, int steps);

  /// The last raw reading seen, across all days. Device-wide, not per-date.
  Future<int?> readLastRaw();
  Future<void> writeLastRaw(int rawCumulative);
}

/// What one sensor reading worked out to.
class StepReading {
  /// Local date the reading belongs to, as `yyyy-MM-dd`.
  final String date;
  final int hour;

  /// The day's total derived from the sensor alone.
  final int sensorSteps;

  /// What the user is shown: [sensorSteps] plus any manually credited steps.
  final int displaySteps;

  /// Sensor steps within [hour]. Manual credits never appear here.
  final int hourlySteps;

  const StepReading({
    required this.date,
    required this.hour,
    required this.sensorSteps,
    required this.displaySteps,
    required this.hourlySteps,
  });
}

class StepAccumulator {
  StepAccumulator(this._store, {this.correctionFactor = 1.0});

  final StepStore _store;

  double correctionFactor;

  String? _trackedDate;
  int? _baseline;
  int _manualSteps = 0;

  String? _trackedHourKey;

  // The sensor total at hour start, and the total at the previous reading.
  int _hourStartSensorTotal = 0;
  int _lastSensorSteps = 0;
  int? _lastDisplaySteps;

  /// The previous raw reading.
  int? _lastRawSteps;

  /// The most recent displayed total, or null if nothing has been recorded
  /// since this accumulator was created.
  int? get lastDisplaySteps => _lastDisplaySteps;

  /// Folds one raw cumulative reading into the day's totals and persists them.
  Future<StepReading> record(int rawCumulative, DateTime now) async {
    final date = dateKey(now);
    final previousRaw = _lastRawSteps ?? await _store.readLastRaw();
    final sensorReset = previousRaw != null && rawCumulative < previousRaw;

    if (_trackedDate != date || sensorReset) {
      _trackedDate = date;
      // Loaded before the baseline, not after: the baseline is reconstructed
      // from the stored daily total, which includes manual credits, and those
      // have to come back out before that arithmetic means anything.
      _manualSteps = await _store.readManualSteps(date);

      final storedTotal = await _store.readDailySteps(date) ?? 0;
      // Only the sensor-derived part of the stored total is comparable with
      // the readings below. Manual credits never came from the sensor.
      final storedSensorSteps = (storedTotal - _manualSteps).clamp(0, 1 << 30);

      _baseline = await _resolveBaseline(
        date,
        rawCumulative,
        storedSensorSteps,
        sensorReset,
      );
      // A new day's — or a re-baselined day's — running totals no longer line
      // up with what came before.
      _lastDisplaySteps = null;
      // Needed for a mid-day restart.
      _lastSensorSteps = storedSensorSteps;
      _trackedHourKey = null;
    }

    final rawDelta =
        (rawCumulative - (_baseline ?? rawCumulative)).clamp(0, 1 << 30);
    final sensorSteps = (rawDelta * correctionFactor).round();
    final displaySteps = sensorSteps + _manualSteps;

    final hour = now.hour;
    final hourKey = '$date-$hour';
    if (_trackedHourKey != hourKey) {
      _trackedHourKey = hourKey;
      // Anchor the hour to the sensor total as it stood *before* this reading.
      final existingHour = await _store.readHourlySteps(date, hour) ?? 0;
      _hourStartSensorTotal = _lastSensorSteps - existingHour;
    }
    final hourlySteps = (sensorSteps - _hourStartSensorTotal).clamp(0, 1 << 30);

    await _store.writeDailySteps(date, displaySteps);
    await _store.writeHourlySteps(date, hour, hourlySteps);
    // Written on every reading and never buffered. A stale value is a no-no
    _lastRawSteps = rawCumulative;
    await _store.writeLastRaw(rawCumulative);
    _lastDisplaySteps = displaySteps;
    _lastSensorSteps = sensorSteps;

    return StepReading(
      date: date,
      hour: hour,
      sensorSteps: sensorSteps,
      displaySteps: displaySteps,
      hourlySteps: hourlySteps,
    );
  }

  /// The credit lands on the daily total and on no hour: nobody walked these
  /// steps at a particular time, and picking one would make the hourly chart
  /// assert something untrue.
  Future<int?> creditManualSteps(int amount, DateTime now) async {
    if (amount <= 0) return null;
    final date = dateKey(now);

    if (_trackedDate != date) {
      // A credit can arrive before the day's first reading, while _manualSteps
      // still holds yesterday's figure. Reload it but leave _trackedDate alone.
      _manualSteps = await _store.readManualSteps(date);
      _lastDisplaySteps = null;
      _lastSensorSteps = 0;
      _trackedHourKey = null;
    }

    _manualSteps += amount;
    await _store.writeManualSteps(date, _manualSteps);

    // _lastDisplaySteps is null until a reading lands, so fall back to what is
    // stored rather than to zero
    final runningTotal =
        _lastDisplaySteps ?? await _store.readDailySteps(date) ?? 0;
    final newTotal = runningTotal + amount;
    _lastDisplaySteps = newTotal;
    await _store.writeDailySteps(date, newTotal);
    return newTotal;
  }

  /// [storedSensorSteps] is the day's stored total without manual credits.
  Future<int> _resolveBaseline(
    String date,
    int rawCumulative,
    int storedSensorSteps,
    bool sensorHasReset,
  ) async {
    final baseline = resolveBaselineValue(
      rawCumulative: rawCumulative,
      savedBaseline: await _store.readBaseline(date),
      sensorHasReset: sensorHasReset,
      existingSteps: storedSensorSteps,
      correctionFactor: correctionFactor,
    );

    await _store.writeBaseline(date, baseline);
    return baseline;
  }
}

/// The raw-sensor value that counts as "zero steps" for a day.
int resolveBaselineValue({
  required int rawCumulative,
  required int? savedBaseline,
  required bool sensorHasReset,
  required int existingSteps,
  required double correctionFactor,
}) {
  if (savedBaseline != null && !sensorHasReset) {
    return savedBaseline;
  }
  final rawExistingDelta =
      correctionFactor == 0 ? 0 : (existingSteps / correctionFactor).round();
  return rawCumulative - rawExistingDelta;
}

class ThrottledStepStore implements StepStore {
  ThrottledStepStore(
    this._inner, {
    this.flushInterval = const Duration(seconds: 10),
  });

  final StepStore _inner;

  /// How long a write may sit unwritten. Also the ceiling on how stale the
  /// app's own reads of the database can be, since it reads the same rows.
  final Duration flushInterval;

  final Map<String, int> _pendingDaily = {};
  final Map<String, int> _pendingHourly = {};
  Timer? _flushTimer;

  static String _hourKey(String date, int hour) => '$date@$hour';

  @override
  Future<int?> readDailySteps(String date) async =>
      _pendingDaily[date] ?? await _inner.readDailySteps(date);

  @override
  Future<int?> readHourlySteps(String date, int hour) async =>
      _pendingHourly[_hourKey(date, hour)] ??
      await _inner.readHourlySteps(date, hour);

  @override
  Future<void> writeDailySteps(String date, int steps) async {
    _pendingDaily[date] = steps;
    _scheduleFlush();
  }

  @override
  Future<void> writeHourlySteps(String date, int hour, int steps) async {
    _pendingHourly[_hourKey(date, hour)] = steps;
    _scheduleFlush();
  }

  @override
  Future<void> writeBaseline(String date, int baseline) async {
    await flush();
    await _inner.writeBaseline(date, baseline);
  }

  @override
  Future<void> writeManualSteps(String date, int steps) async {
    await flush();
    await _inner.writeManualSteps(date, steps);
  }

  @override
  Future<int?> readBaseline(String date) => _inner.readBaseline(date);

  @override
  Future<int> readManualSteps(String date) => _inner.readManualSteps(date);

  @override
  Future<int?> readLastRaw() => _inner.readLastRaw();

  // Not buffered, unlike the rows above. Losing this one is different as a
  // value left sitting below a post-reboot reading makes the restart invisible.
  @override
  Future<void> writeLastRaw(int rawCumulative) =>
      _inner.writeLastRaw(rawCumulative);

  /// Commits everything buffered. Call before the service stops — a timer that
  /// never fires is the one way buffered steps go missing for good.
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;

    for (final entry in Map<String, int>.from(_pendingDaily).entries) {
      await _inner.writeDailySteps(entry.key, entry.value);
      // Only drop it if nothing newer arrived while the write was in flight.
      if (_pendingDaily[entry.key] == entry.value) {
        _pendingDaily.remove(entry.key);
      }
    }

    for (final entry in Map<String, int>.from(_pendingHourly).entries) {
      final split = entry.key.lastIndexOf('@');
      await _inner.writeHourlySteps(
        entry.key.substring(0, split),
        int.parse(entry.key.substring(split + 1)),
        entry.value,
      );
      if (_pendingHourly[entry.key] == entry.value) {
        _pendingHourly.remove(entry.key);
      }
    }
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }
}

/// The real [StepStore], over the app's database and preferences.
class PersistentStepStore implements StepStore {
  PersistentStepStore({DatabaseHelper? database, PreferencesService? prefs})
      : _db = database ?? DatabaseHelper.instance,
        _prefs = prefs ?? PreferencesService();

  final DatabaseHelper _db;
  final PreferencesService _prefs;

  @override
  Future<int?> readBaseline(String date) => _prefs.getStepBaseline(date);

  @override
  Future<void> writeBaseline(String date, int baseline) =>
      _prefs.setStepBaseline(date, baseline);

  @override
  Future<int> readManualSteps(String date) => _prefs.getManualSteps(date);

  @override
  Future<void> writeManualSteps(String date, int steps) =>
      _prefs.setManualSteps(date, steps);

  @override
  Future<int?> readDailySteps(String date) async =>
      (await _db.getStepsForDate(date))?.stepCount;

  @override
  Future<void> writeDailySteps(String date, int steps) =>
      _db.upsertSteps(DailySteps(date: date, stepCount: steps));

  @override
  Future<int?> readHourlySteps(String date, int hour) =>
      _db.getHourlyStepsForDateAndHour(date, hour);

  @override
  Future<void> writeHourlySteps(String date, int hour, int steps) =>
      _db.upsertHourlySteps(date, hour, steps);

  @override
  Future<int?> readLastRaw() => _prefs.getLastRawSteps();

  @override
  Future<void> writeLastRaw(int rawCumulative) =>
      _prefs.setLastRawSteps(rawCumulative);
}
