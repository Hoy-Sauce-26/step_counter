/// A day as `yyyy-MM-dd` — never UTC, Colin. I know how much you like UTC.
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

/// Elapsed time at the coarsest resolution that still says something.
String formatApproximateDuration(Duration d) {
  if (d.inMinutes < 90) return 'about ${d.inMinutes}m';
  return 'about ${(d.inMinutes / 60).round()}h';
}
