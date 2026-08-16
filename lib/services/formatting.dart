// Shared display and storage formatting.
//
// Both of these had drifted into half a dozen private copies apiece, which is
// how a storage key ends up with two definitions that agree today and not
// next year.

/// A day as `yyyy-MM-dd` — the key every stored step total is filed under.
///
/// Deliberately local time, never UTC: a day rolls over when it does for the
/// person walking, not at midnight in Greenwich.
String dateKey(DateTime moment) {
  return '${moment.year.toString().padLeft(4, '0')}-'
      '${moment.month.toString().padLeft(2, '0')}-'
      '${moment.day.toString().padLeft(2, '0')}';
}

/// Today's [dateKey].
String todayKey() => dateKey(DateTime.now());

/// Elapsed time as `1h 04m 09s`, dropping the hours when there are none.
String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  final seconds = d.inSeconds % 60;
  final paddedMinutes = minutes.toString().padLeft(2, '0');
  final paddedSeconds = seconds.toString().padLeft(2, '0');
  return hours > 0
      ? '${hours}h ${paddedMinutes}m ${paddedSeconds}s'
      : '${minutes}m ${paddedSeconds}s';
}
