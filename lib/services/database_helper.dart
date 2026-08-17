import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/daily_steps.dart';
import 'formatting.dart';
import '../models/hourly_steps.dart';
import '../models/saved_route.dart';

/// Local persistence for daily/hourly step records and saved routes, via
/// sqflite.
///
/// Schema:
///   daily_steps(date TEXT PRIMARY KEY, stepCount INTEGER NOT NULL)
///   hourly_steps(date TEXT, hour INTEGER, stepCount INTEGER NOT NULL,
///                PRIMARY KEY(date, hour))
///   routes(id INTEGER PRIMARY KEY, name TEXT NOT NULL, createdAt TEXT)
///   route_sessions(id INTEGER PRIMARY KEY, routeId INTEGER, date TEXT,
///                  steps INTEGER, durationSeconds INTEGER)
class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static Future<Database>? _db;

  /// Full path to open instead of the app's own database file. Tests point
  /// this at an in-memory or temporary database; nothing else should set it.
  @visibleForTesting
  static String? databasePathOverride;

  /// The only way to observe that concurrent callers share one open
  @visibleForTesting
  static int openCount = 0;

  /// Closes the cached connection so the next access opens a fresh one.
  /// Without this the singleton would carry one database across a whole test
  /// file, and no test could start from an empty schema.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    final pending = _db;
    _db = null;
    if (pending == null) return;
    try {
      await (await pending).close();
    } catch (_) {
      // The open itself failed, so there is no connection to close. Swallowing
      // it keeps a tearDown from masking the failure the test actually hit.
    }
  }

  Future<Database> get database => _db ??= _open();

  /// Un-caches itself if the open fails
  Future<Database> _open() async {
    try {
      return await _initDatabase();
    } catch (_) {
      _db = null;
      rethrow;
    }
  }

  Future<Database> _initDatabase() async {
    openCount++;
    final path =
        databasePathOverride ?? p.join(await getDatabasesPath(), 'step_counter.db');
    return openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE daily_steps (
            date TEXT PRIMARY KEY,
            stepCount INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE hourly_steps (
            date TEXT NOT NULL,
            hour INTEGER NOT NULL,
            stepCount INTEGER NOT NULL,
            PRIMARY KEY (date, hour)
          )
        ''');
        await _createRouteTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 installs only have daily_steps — add hourly_steps without
        // touching existing data.
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE hourly_steps (
              date TEXT NOT NULL,
              hour INTEGER NOT NULL,
              stepCount INTEGER NOT NULL,
              PRIMARY KEY (date, hour)
            )
          ''');
        }
        if (oldVersion < 3) {
          await _createRouteTables(db);
        } else if (oldVersion < 4) {
          // v3 already has routes/sessions, just under the sessions
          // table's old name.
          await db.execute('ALTER TABLE walk_sessions RENAME TO route_sessions');
        }
      },
    );
  }

  Future<void> _createRouteTables(Database db) async {
    await db.execute('''
      CREATE TABLE routes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE route_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        routeId INTEGER NOT NULL,
        date TEXT NOT NULL,
        steps INTEGER NOT NULL,
        durationSeconds INTEGER NOT NULL
      )
    ''');
  }

  /// Insert today's count, or update it if a record for that date exists.
  Future<void> upsertSteps(DailySteps entry) async {
    final db = await database;
    await db.insert(
      'daily_steps',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<DailySteps?> getStepsForDate(String date) async {
    final db = await database;
    final rows = await db.query(
      'daily_steps',
      where: 'date = ?',
      whereArgs: [date],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return DailySteps.fromMap(rows.first);
  }

  /// Returns records for the past [days] days (inclusive of today),
  /// ordered chronologically. Missing days are NOT filled in here —
  /// callers should zero-fill by date if a continuous series is needed.
  Future<List<DailySteps>> getPastNDays(int days) async {
    final db = await database;
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: days - 1));
    final startStr = dateKey(start);

    final rows = await db.query(
      'daily_steps',
      where: 'date >= ?',
      whereArgs: [startStr],
      orderBy: 'date ASC',
    );
    return rows.map(DailySteps.fromMap).toList();
  }

  /// Insert/update a single hour's running total for a given date.
  Future<void> upsertHourlySteps(String date, int hour, int stepCount) async {
    final db = await database;
    await db.insert(
      'hourly_steps',
      {'date': date, 'hour': hour, 'stepCount': stepCount},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Persisted step count for one (date, hour), or null if not recorded
  /// yet. Lets the background service resume mid-hour after a restart
  /// instead of losing or double-counting steps.
  Future<int?> getHourlyStepsForDateAndHour(String date, int hour) async {
    final db = await database;
    final rows = await db.query(
      'hourly_steps',
      where: 'date = ? AND hour = ?',
      whereArgs: [date, hour],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['stepCount'] as int;
  }

  /// All recorded hours for a given date, ordered chronologically. Hours
  /// with no data are NOT filled in here — callers should zero-fill for a
  /// continuous 0-23 series if needed.
  Future<List<HourlySteps>> getHourlyStepsForDate(String date) async {
    final db = await database;
    final rows = await db.query(
      'hourly_steps',
      where: 'date = ?',
      whereArgs: [date],
      orderBy: 'hour ASC',
    );
    return rows.map(HourlySteps.fromMap).toList();
  }

  /// Saves a new route and returns its id.
  Future<int> insertRoute(String name) async {
    final db = await database;
    return db.insert('routes', {
      'name': name,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

  /// All saved routes, newest first, with each one's average step count
  /// (null if no sessions yet).
  Future<List<SavedRoute>> getRoutes() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT r.id, r.name,
             AVG(s.steps) AS avgSteps
      FROM routes r
      LEFT JOIN route_sessions s ON s.routeId = r.id
      GROUP BY r.id
      ORDER BY r.createdAt DESC
    ''');
    return rows
        .map((row) => SavedRoute(
              id: row['id'] as int,
              name: row['name'] as String,
              avgSteps: (row['avgSteps'] as num?)?.toDouble(),
            ))
        .toList();
  }

  Future<int> getSessionCountForRoute(int routeId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM route_sessions WHERE routeId = ?',
      [routeId],
    );
    return (result.first['count'] as num).toInt();
  }

  /// Records one completed session of a route.
  Future<void> insertRouteSession({
    required int routeId,
    required String date,
    required int steps,
    required int durationSeconds,
  }) async {
    final db = await database;
    await db.insert('route_sessions', {
      'routeId': routeId,
      'date': date,
      'steps': steps,
      'durationSeconds': durationSeconds,
    });
  }

  /// Deletes a route and its sessions (no FK cascade, so both explicitly).
  Future<void> deleteRoute(int routeId) async {
    final db = await database;
    await db.delete('route_sessions', where: 'routeId = ?', whereArgs: [routeId]);
    await db.delete('routes', where: 'id = ?', whereArgs: [routeId]);
  }
}
