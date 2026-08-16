import '../models/daily_steps.dart';
import 'database_helper.dart';
import 'preferences_service.dart';

/// Storage the accumulator depends on.
///
/// Deliberately narrow, and deliberately not SharedPreferences or sqflite: a
/// fake backed by a couple of maps satisfies it, which is what lets the step
/// accounting be tested without a sensor, a database, or a service isolate.
abstract class StepStore {
  Future<int?> readBaseline(String date);
  Future<void> writeBaseline(String date, int baseline);

  Future<int> readManualSteps(String date);
  Future<void> writeManualSteps(String date, int steps);

  Future<int?> readDailySteps(String date);
  Future<void> writeDailySteps(String date, int steps);

  Future<int?> readHourlySteps(String date, int hour);
  Future<void> writeHourlySteps(String date, int hour, int steps);
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

/// Turns a stream of raw cumulative sensor readings into daily and hourly
/// step totals, and folds in steps credited by hand.
///
/// The hardware counter reports steps since the device last booted, so every
/// figure here is a delta against a baseline. Keeping that bookkeeping in one
/// place — rather than in locals captured by the background service's start
/// callback — is what makes it reachable from a test.
///
/// [correctionFactor] is a plain field rather than something read from
/// storage. The background service runs in its own isolate with its own
/// private copy of SharedPreferences, so a value written by the app is
/// invisible here; the app mirrors changes across explicitly, and having no
/// storage access at all makes re-reading it impossible by construction.
class StepAccumulator {
  StepAccumulator(this._store, {this.correctionFactor = 1.0});

  final StepStore _store;

  double correctionFactor;

  String? _trackedDate;
  int? _baseline;
  int _manualSteps = 0;

  String? _trackedHourKey;
  int? _hourStartSensorTotal;
  int? _lastSensorSteps;
  int? _lastDisplaySteps;

  /// The most recent displayed total, or null if nothing has been recorded
  /// since this accumulator was created.
  int? get lastDisplaySteps => _lastDisplaySteps;

  /// Folds one raw cumulative reading into the day's totals and persists them.
  Future<StepReading> record(int rawCumulative, DateTime now) async {
    final date = dateKey(now);

    // A reading below the baseline means the hardware counter restarted — it
    // counts from the last boot, so a reboot zeroes it. Re-resolving rebuilds
    // the baseline around the steps already stored for the day; without it
    // every later delta clamps to zero and overwrites the day's total.
    final sensorReset = _baseline != null && rawCumulative < _baseline!;

    if (_trackedDate != date || sensorReset) {
      _trackedDate = date;
      // Loaded before the baseline, not after: the baseline is reconstructed
      // from the stored daily total, which includes manual credits, and those
      // have to come back out before that arithmetic means anything.
      _manualSteps = await _store.readManualSteps(date);
      _baseline = await _resolveBaseline(date, rawCumulative);
      // A new day's — or a re-baselined day's — running totals no longer line
      // up with what came before.
      _lastDisplaySteps = null;
      _lastSensorSteps = null;
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
      // If this hour already has a stored count (the service restarted
      // mid-hour), resume from it rather than resetting or double counting.
      // Otherwise start from the previous reading's sensor total, so this
      // hour's first step shows up right away.
      final existingHour = await _store.readHourlySteps(date, hour);
      _hourStartSensorTotal = existingHour != null
          ? sensorSteps - existingHour
          : (_lastSensorSteps ?? sensorSteps);
    }
    final hourlySteps =
        (sensorSteps - (_hourStartSensorTotal ?? sensorSteps)).clamp(0, 1 << 30);

    await _store.writeDailySteps(date, displaySteps);
    await _store.writeHourlySteps(date, hour, hourlySteps);
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

  /// Credits [amount] steps to the day containing [now] — a route logged
  /// without live tracking, say — and returns the day's new total. Returns
  /// null if [amount] isn't a usable number of steps.
  ///
  /// The credit lands on the daily total and on no hour: nobody walked these
  /// steps at a particular time, and picking one would make the hourly chart
  /// assert something untrue.
  Future<int?> creditManualSteps(int amount, DateTime now) async {
    if (amount <= 0) return null;
    final date = dateKey(now);

    if (_trackedDate != date) {
      // A credit can arrive before the day's first reading, while _manualSteps
      // still holds yesterday's figure. Reload it — but leave _trackedDate
      // alone. It is what makes the next reading re-resolve the baseline, and
      // claiming the day is already resolved here would leave yesterday's
      // baseline in place and fold yesterday's steps into today.
      _manualSteps = await _store.readManualSteps(date);
      _lastDisplaySteps = null;
      _lastSensorSteps = null;
      _trackedHourKey = null;
    }

    _manualSteps += amount;
    await _store.writeManualSteps(date, _manualSteps);

    // _lastDisplaySteps is null until a reading lands, so fall back to what is
    // stored rather than to zero — treating "nothing read yet" as "no steps
    // yet" would overwrite the day's total with just this credit.
    final runningTotal =
        _lastDisplaySteps ?? await _store.readDailySteps(date) ?? 0;
    final newTotal = runningTotal + amount;
    _lastDisplaySteps = newTotal;
    await _store.writeDailySteps(date, newTotal);
    return newTotal;
  }

  Future<int> _resolveBaseline(String date, int rawCumulative) async {
    final existing = await _store.readDailySteps(date) ?? 0;
    // Only the sensor-derived part of the stored total can be turned back
    // into a raw reading. Manual credits never came from the sensor, so
    // dividing them by the correction factor would invent raw steps that were
    // never taken, push the baseline too far back, and count them twice.
    final sensorPortion = (existing - _manualSteps).clamp(0, 1 << 30);

    final baseline = resolveBaselineValue(
      rawCumulative: rawCumulative,
      savedBaseline: await _store.readBaseline(date),
      existingSteps: sensorPortion,
      correctionFactor: correctionFactor,
    );

    await _store.writeBaseline(date, baseline);
    return baseline;
  }
}

/// The raw-sensor value that counts as "zero steps" for a day.
///
/// [savedBaseline] is reused as long as the sensor is still above it. A
/// [rawCumulative] *below* it means the hardware counter reset — it counts
/// from the last reboot — so the baseline is re-derived from the steps already
/// stored for the day. That result is deliberately negative (raw restarts near
/// zero while the day already has steps), which is what keeps the stored total
/// intact and lets new readings add on top of it.
int resolveBaselineValue({
  required int rawCumulative,
  required int? savedBaseline,
  required int existingSteps,
  required double correctionFactor,
}) {
  if (savedBaseline != null && rawCumulative >= savedBaseline) {
    return savedBaseline;
  }
  final rawExistingDelta =
      correctionFactor == 0 ? 0 : (existingSteps / correctionFactor).round();
  return rawCumulative - rawExistingDelta;
}

/// Local date as `yyyy-MM-dd`. Deliberately not UTC: a day rolls over when it
/// does for the person walking, not at midnight in Greenwich.
String dateKey(DateTime moment) {
  return '${moment.year.toString().padLeft(4, '0')}-'
      '${moment.month.toString().padLeft(2, '0')}-'
      '${moment.day.toString().padLeft(2, '0')}';
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
}
