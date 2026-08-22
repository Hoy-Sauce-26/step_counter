import 'package:flutter_test/flutter_test.dart';
import 'package:step_counter/models/step_journal_entry.dart';
import 'package:step_counter/services/step_journal.dart';

StepJournalEntry at(String time, int raw) =>
    StepJournalEntry(at: DateTime.parse(time), rawSteps: raw);

void main() {
  group('foldJournal', () {
    test('nothing to difference produces nothing', () {
      expect(foldJournal([]).daily, isEmpty);
      expect(foldJournal([at('2026-08-22 09:00', 1000)]).daily, isEmpty,
          reason: 'one reading is not an interval');
    });

    test('the difference between two readings is the steps between them', () {
      final totals = foldJournal([
        at('2026-08-22 09:00', 1000),
        at('2026-08-22 09:15', 1120),
      ]);

      expect(totals.daily, {'2026-08-22': 120});
      expect(totals.hourly, {('2026-08-22', 9): 120});
    });

    test('consecutive intervals accumulate across the day', () {
      final totals = foldJournal([
        at('2026-08-22 09:00', 1000),
        at('2026-08-22 09:15', 1120),
        at('2026-08-22 10:00', 1200),
        at('2026-08-22 10:15', 1250),
      ]);

      expect(totals.daily, {'2026-08-22': 250});
      expect(totals.hourly, {
        ('2026-08-22', 9): 200,
        ('2026-08-22', 10): 50,
      });
    });

    test('a long gap is still counted in full', () {
      // The point of the whole design: the counter kept running while nothing
      // was listening, so a service that died at 14:00 Monday and came back
      // Friday still yields the steps taken in between.
      final totals = foldJournal([
        at('2026-08-17 14:00', 900000),
        at('2026-08-21 10:00', 930000),
      ]);

      expect(totals.daily, {'2026-08-17': 30000},
          reason: 'attributed to the interval it started in, not discarded');
    });

    group('day boundaries', () {
      test('a midnight reading splits the days exactly', () {
        final totals = foldJournal([
          at('2026-08-22 23:45', 5000),
          at('2026-08-23 00:00', 5100),
          at('2026-08-23 00:15', 5150),
        ]);

        expect(totals.daily, {'2026-08-22': 100, '2026-08-23': 50},
            reason: 'the interval ending at midnight belongs to the day that '
                'just finished; the one starting there to the new day');
      });

      test('without a midnight reading the whole span lands on the start day',
          () {
        final totals = foldJournal([
          at('2026-08-22 23:45', 5000),
          at('2026-08-23 00:15', 5100),
        ]);

        expect(totals.daily, {'2026-08-22': 100},
            reason: 'biased early on purpose — see the doc on foldJournal');
      });
    });

    group('reboots', () {
      test('a counter that went backwards counts from its new zero', () {
        final totals = foldJournal([
          at('2026-08-22 09:00', 900000),
          at('2026-08-22 11:00', 40),
        ]);

        expect(totals.daily, {'2026-08-22': 40},
            reason: 'steps between 09:00 and the reboot are unknowable, and '
                'the 40 since it are real');
      });

      test('counting resumes normally after the restart', () {
        final totals = foldJournal([
          at('2026-08-22 09:00', 900000),
          at('2026-08-22 11:00', 40),
          at('2026-08-22 11:15', 190),
        ]);

        expect(totals.daily, {'2026-08-22': 190});
      });
    });

    group('readings that move nothing', () {
      test('a repeated count contributes no steps', () {
        final totals = foldJournal([
          at('2026-08-22 09:00', 1000),
          at('2026-08-22 09:15', 1000),
          at('2026-08-22 09:30', 1050),
        ]);

        expect(totals.daily, {'2026-08-22': 50});
      });

      test('an empty hour is absent rather than zero', () {
        final totals = foldJournal([
          at('2026-08-22 09:00', 1000),
          at('2026-08-22 09:15', 1000),
        ]);

        expect(totals.daily, isEmpty);
        expect(totals.hourly, isEmpty,
            reason: 'callers zero-fill for display; the fold reports only '
                'what it observed');
      });
    });

    group('correction factor', () {
      test('scales the counted steps', () {
        final totals = foldJournal(
          [at('2026-08-22 09:00', 1000), at('2026-08-22 09:15', 1100)],
          correctionFactor: 1.1,
        );

        expect(totals.daily, {'2026-08-22': 110});
      });

      test('a zero or negative factor is ignored rather than erasing the day',
          () {
        for (final factor in [0.0, -1.0]) {
          final totals = foldJournal(
            [at('2026-08-22 09:00', 1000), at('2026-08-22 09:15', 1100)],
            correctionFactor: factor,
          );

          expect(totals.daily, {'2026-08-22': 100},
              reason: 'a stored factor of $factor is a bug, not an instruction '
                  'to throw the day away');
        }
      });
    });

    test('entries arriving out of order are ordered before differencing', () {
      final totals = foldJournal([
        at('2026-08-22 10:00', 1200),
        at('2026-08-22 09:00', 1000),
        at('2026-08-22 09:15', 1120),
      ]);

      expect(totals.daily, {'2026-08-22': 200},
          reason: 'differencing adjacent pairs is silently wrong if unsorted');
    });
  });
}
