import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:step_counter/models/daily_steps.dart';
import 'package:step_counter/services/database_helper.dart';

/// Yesterday, today and so on as the helper formats them — derived from the
/// clock rather than hardcoded, because [DatabaseHelper.getPastNDays] builds
/// its window from `DateTime.now()` and a fixed date would rot overnight.
String dayOffset(int days) {
  final d = DateTime.now().subtract(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

void main() {
  setUpAll(sqfliteFfiInit);

  late DatabaseHelper db;

  setUp(() async {
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.databasePathOverride = inMemoryDatabasePath;
    await DatabaseHelper.resetForTesting();
    db = DatabaseHelper.instance;
  });

  tearDown(() async {
    await DatabaseHelper.resetForTesting();
    DatabaseHelper.databasePathOverride = null;
  });

  group('opening the database', () {
    // Two callers reach for the database at once on any launch — the pedometer
    // service and the seven-day chart provider.
    //
    // Counting opens is the only way to see this.
    test('concurrent first callers trigger a single open', () async {
      DatabaseHelper.openCount = 0;

      await Future.wait([db.database, db.database, db.database]);

      expect(DatabaseHelper.openCount, 1);
    });

    test('a later caller reuses the open rather than repeating it', () async {
      await db.database;
      DatabaseHelper.openCount = 0;

      await db.database;

      expect(DatabaseHelper.openCount, 0);
    });
  });

  group('daily steps', () {
    test('stores and reads back a day', () async {
      await db.upsertSteps(DailySteps(date: '2026-08-16', stepCount: 4200));

      expect((await db.getStepsForDate('2026-08-16'))?.stepCount, 4200);
    });

    test('a day with nothing recorded reads as null, not zero', () async {
      // The distinction matters: the accumulator treats a missing row as "no
      // baseline yet" and a zero as "a real day with no steps".
      expect(await db.getStepsForDate('2026-08-16'), isNull);
    });

    test('writing the same day again replaces rather than duplicates',
        () async {
      await db.upsertSteps(DailySteps(date: '2026-08-16', stepCount: 100));
      await db.upsertSteps(DailySteps(date: '2026-08-16', stepCount: 900));

      expect((await db.getStepsForDate('2026-08-16'))?.stepCount, 900);
      expect((await db.getPastNDays(7)).length, 1, reason: 'one row, not two');
    });
  });

  group('the past-N-days window', () {
    test('includes today and the oldest day in range', () async {
      for (final offset in [0, 6]) {
        await db.upsertSteps(DailySteps(date: dayOffset(offset), stepCount: 1));
      }

      expect((await db.getPastNDays(7)).length, 2);
    });

    test('excludes the day just outside the window', () async {
      await db.upsertSteps(DailySteps(date: dayOffset(6), stepCount: 1));
      await db.upsertSteps(DailySteps(date: dayOffset(7), stepCount: 1));

      final week = await db.getPastNDays(7);

      expect(week.map((d) => d.date), [dayOffset(6)],
          reason: '7 days back is one day too far for a 7-day window');
    });

    test('comes back oldest first', () async {
      for (final offset in [1, 5, 3]) {
        await db.upsertSteps(DailySteps(date: dayOffset(offset), stepCount: 1));
      }

      final dates = (await db.getPastNDays(7)).map((d) => d.date).toList();

      expect(dates, [dayOffset(5), dayOffset(3), dayOffset(1)]);
    });

    test('leaves gaps for days with no data', () async {
      // Documented behaviour: callers zero-fill. The chart depends on this
      // being a gap rather than a zero row.
      await db.upsertSteps(DailySteps(date: dayOffset(0), stepCount: 1));

      expect((await db.getPastNDays(7)).length, 1);
    });
  });

  group('hourly steps', () {
    test('stores each hour of a day separately', () async {
      await db.upsertHourlySteps('2026-08-16', 9, 300);
      await db.upsertHourlySteps('2026-08-16', 10, 150);

      expect(await db.getHourlyStepsForDateAndHour('2026-08-16', 9), 300);
      expect(await db.getHourlyStepsForDateAndHour('2026-08-16', 10), 150);
    });

    test('the same hour on different days does not collide', () async {
      await db.upsertHourlySteps('2026-08-16', 9, 300);
      await db.upsertHourlySteps('2026-08-17', 9, 40);

      expect(await db.getHourlyStepsForDateAndHour('2026-08-16', 9), 300);
    });

    test('an unrecorded hour reads as null', () async {
      expect(await db.getHourlyStepsForDateAndHour('2026-08-16', 3), isNull);
    });

    test('rewriting an hour replaces it', () async {
      await db.upsertHourlySteps('2026-08-16', 9, 100);
      await db.upsertHourlySteps('2026-08-16', 9, 500);

      expect(await db.getHourlyStepsForDateAndHour('2026-08-16', 9), 500);
      expect((await db.getHourlyStepsForDate('2026-08-16')).length, 1);
    });

    test('a day reads back in hour order', () async {
      for (final hour in [14, 2, 9]) {
        await db.upsertHourlySteps('2026-08-16', hour, hour);
      }

      expect(
        (await db.getHourlyStepsForDate('2026-08-16')).map((h) => h.hour),
        [2, 9, 14],
      );
    });
  });

  group('routes', () {
    test('a new route has no sessions and no average yet', () async {
      await db.insertRoute('Canal loop');

      final routes = await db.getRoutes();

      expect(routes.single.name, 'Canal loop');
      expect(routes.single.avgSteps, isNull,
          reason: 'no sessions means no average, not an average of zero');
    });

    test('averages the sessions recorded against a route', () async {
      final id = await db.insertRoute('Canal loop');
      for (final steps in [1000, 2000, 3000]) {
        await db.insertRouteSession(
          routeId: id,
          date: '2026-08-16',
          steps: steps,
          durationSeconds: 600,
        );
      }

      final route = (await db.getRoutes()).single;

      expect(route.avgSteps, closeTo(2000, 0.001));
    });

    test('lists newest first', () async {
      await db.insertRoute('First');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await db.insertRoute('Second');

      expect((await db.getRoutes()).map((r) => r.name), ['Second', 'First']);
    });

    test('counts sessions for one route without counting another\'s',
        () async {
      final kept = await db.insertRoute('Kept');
      final other = await db.insertRoute('Other');
      await db.insertRouteSession(
        routeId: kept,
        date: '2026-08-16',
        steps: 500,
        durationSeconds: 300,
      );

      expect(await db.getSessionCountForRoute(kept), 1);
      expect(await db.getSessionCountForRoute(other), 0);
    });

    test('deleting a route takes its sessions and leaves others alone',
        () async {
      final doomed = await db.insertRoute('Doomed');
      final kept = await db.insertRoute('Kept');
      for (final id in [doomed, kept]) {
        await db.insertRouteSession(
          routeId: id,
          date: '2026-08-16',
          steps: 500,
          durationSeconds: 300,
        );
      }

      await db.deleteRoute(doomed);

      expect((await db.getRoutes()).map((r) => r.name), ['Kept']);
      expect(await db.getSessionCountForRoute(doomed), 0,
          reason: 'no orphaned sessions — there is no FK cascade to do it');
      expect(await db.getSessionCountForRoute(kept), 1);
    });
  });

  // Migrations are the one part of this file that can destroy data a user
  // already has, and the only part that never runs during development on a
  // freshly installed app. These open a database at an older schema, then
  // reopen it through DatabaseHelper and check the upgrade path.
  group('migrations', () {
    late Directory tempDir;
    late String dbPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('roamfree_migration');
      dbPath = p.join(tempDir.path, 'step_counter.db');
      DatabaseHelper.databasePathOverride = dbPath;
      await DatabaseHelper.resetForTesting();
    });

    tearDown(() async {
      await DatabaseHelper.resetForTesting();
      await tempDir.delete(recursive: true);
    });

    test('a version 1 install gains the newer tables and keeps its steps',
        () async {
      final legacy = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) => db.execute('''
            CREATE TABLE daily_steps (
              date TEXT PRIMARY KEY,
              stepCount INTEGER NOT NULL
            )
          '''),
        ),
      );
      await legacy.insert('daily_steps', {'date': '2026-08-01', 'stepCount': 7});
      await legacy.close();

      final upgraded = DatabaseHelper.instance;

      expect((await upgraded.getStepsForDate('2026-08-01'))?.stepCount, 7,
          reason: 'existing history must survive the upgrade');
      await upgraded.upsertHourlySteps('2026-08-01', 9, 3);
      expect(await upgraded.getHourlyStepsForDateAndHour('2026-08-01', 9), 3);
      expect(await upgraded.getRoutes(), isEmpty,
          reason: 'route tables exist and are queryable');
    });

    test('a version 3 install has its sessions table renamed, not recreated',
        () async {
      final legacy = await databaseFactory.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, _) async {
            await db.execute('''
              CREATE TABLE daily_steps (
                date TEXT PRIMARY KEY, stepCount INTEGER NOT NULL)
            ''');
            await db.execute('''
              CREATE TABLE hourly_steps (
                date TEXT NOT NULL, hour INTEGER NOT NULL,
                stepCount INTEGER NOT NULL, PRIMARY KEY (date, hour))
            ''');
            await db.execute('''
              CREATE TABLE routes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL, createdAt TEXT NOT NULL)
            ''');
            await db.execute('''
              CREATE TABLE walk_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                routeId INTEGER NOT NULL, date TEXT NOT NULL,
                steps INTEGER NOT NULL, durationSeconds INTEGER NOT NULL)
            ''');
          },
        ),
      );
      await legacy.insert('routes', {
        'name': 'Canal loop',
        'createdAt': DateTime.now().toIso8601String(),
      });
      await legacy.insert('walk_sessions', {
        'routeId': 1,
        'date': '2026-08-01',
        'steps': 1500,
        'durationSeconds': 900,
      });
      await legacy.close();

      final route = (await DatabaseHelper.instance.getRoutes()).single;

      expect(route.name, 'Canal loop');
      expect(route.avgSteps, isNotNull,
          reason: 'the rename must carry the rows, not start an empty table');
      expect(route.avgSteps, closeTo(1500, 0.001));
    });
  });
}
