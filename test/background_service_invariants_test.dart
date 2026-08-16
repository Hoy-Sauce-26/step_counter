import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A guard, not a unit test: it reads the source of [_serviceSource] instead
/// of calling into it, because the rule it protects can't be observed from a
/// single isolate.
///
/// The background service runs in its own isolate, and SharedPreferences
/// hands each isolate a private in-memory copy of the store. A setting the
/// app writes is therefore invisible to the service. Settings that can change
/// while it runs are read once at start-up and kept current by an `invoke`
/// handler — so re-reading one further down doesn't refresh anything. It
/// returns the start-up snapshot and silently reverts whatever was mirrored
/// in since.
///
/// That has now happened twice in this file: the daily target never reached
/// the isolate at all, and a re-read on date change was quietly reverting
/// recalibrations to the value held when the service started. The README
/// states an equivalent rule for the single step-count listener in prose, and
/// by its own account that rule has been broken twice as well. This asserts
/// it instead.
const _serviceSource = 'lib/services/background_service.dart';

/// Settings mirrored into the background isolate, as
/// `accessor: invoke channel`. Add an entry here when a new setting starts
/// being mirrored.
const _mirroredSettings = <String, String>{
  'getDailyTarget': 'setDailyTarget',
  'getCorrectionFactor': 'setCorrectionFactor',
};

/// Everything above this line runs once when the isolate spins up; everything
/// below it runs per sensor reading.
const _startupBoundary = 'Pedometer.stepCountStream.listen';

/// Source lines with `//` comments stripped, so a comment that names an
/// accessor (`// don't call getDailyTarget() here`) can't trip the check.
List<String> _sourceLines() {
  final file = File(_serviceSource);
  expect(
    file.existsSync(),
    isTrue,
    reason: '$_serviceSource not found — run this from the package root.',
  );
  return file.readAsLinesSync().map((line) {
    final comment = line.indexOf('//');
    return comment == -1 ? line : line.substring(0, comment);
  }).toList();
}

List<int> _linesContaining(List<String> lines, String needle) => [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains(needle)) i + 1,
    ];

void main() {
  group('background isolate prefs invariants', () {
    test('mirrored settings are read once, only at start-up', () {
      final lines = _sourceLines();

      final boundary = _linesContaining(lines, _startupBoundary);
      expect(
        boundary,
        hasLength(1),
        reason: 'Expected exactly one "$_startupBoundary" to divide start-up '
            'from per-reading work, found $boundary. If the listener moved, '
            'update _startupBoundary.',
      );
      final startupEndsAt = boundary.single;

      for (final MapEntry(key: accessor, value: channel)
          in _mirroredSettings.entries) {
        final reads = _linesContaining(lines, '$accessor(');

        expect(
          reads,
          hasLength(1),
          reason: '$accessor() should be read exactly once in $_serviceSource, '
              'at start-up. Found ${reads.length} at lines $reads. Every read '
              'after the first returns the same start-up snapshot, so it '
              'reverts anything mirrored in via "$channel" since.',
        );

        expect(
          reads.single,
          lessThan(startupEndsAt),
          reason: '$accessor() is read at line ${reads.single}, below the step '
              'listener at line $startupEndsAt. A read there sees this '
              "isolate's start-up snapshot, not the app's current value — use "
              'the local kept current by the "$channel" handler instead.',
        );
      }
    });

    test('every mirrored setting has an invoke handler', () {
      final lines = _sourceLines();

      for (final MapEntry(key: accessor, value: channel)
          in _mirroredSettings.entries) {
        expect(
          lines.any((line) => line.contains("service.on('$channel')")),
          isTrue,
          reason: 'No handler for "$channel" in $_serviceSource. Without one, '
              'the value read from $accessor() at start-up never updates and '
              'the app\'s changes never reach this isolate.',
        );
      }
    });
  });
}
