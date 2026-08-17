import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A guard, not a unit test: it reads the source of [_serviceSource] instead
/// of calling into it, because the rule it protects can't be observed from a
/// single isolate.
const _serviceSource = 'lib/services/background_service.dart';

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

    test('every mirrored setting has a handler registered', () {
      final lines = _sourceLines();

      for (final MapEntry(key: accessor, value: channelName)
          in _mirroredSettings.entries) {
        expect(
          lines.any((line) => line.contains('$channelName.handle(')),
          isTrue,
          reason: 'Nothing handles the "$channelName" channel in '
              '$_serviceSource. Without a handler the value read from '
              '$accessor() at start-up never updates, the app\'s changes are '
              'accepted and dropped, and the service runs on its start-up '
              'copy for as long as it lives.',
        );
      }
    });
  });
}
