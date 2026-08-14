import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/daily_steps.dart';
import '../models/hourly_steps.dart';

/// Handles all local persistence of daily and hourly step records via
/// sqflite.
///
/// Table schema:
///   daily_steps(date TEXT PRIMARY KEY, stepCount INTEGER NOT NULL)
///   hourly_steps(date TEXT, hour INTEGER, stepCount INTEGER NOT NULL,
///                PRIMARY KEY(date, hour))
class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static Database? _db;

  Future<Database> get database async {
    _db ??= await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'step_counter.db');
    return openDatabase(
      path,
      version: 2,
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Existing installs (v1) only have daily_steps — add the new
        // hourly table without touching any existing data.
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
      },
    );
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
    final startStr = _formatDate(start);

    final rows = await db.query(
      'daily_steps',
      where: 'date >= ?',
      whereArgs: [startStr],
      orderBy: 'date ASC',
    );
    return rows.map(DailySteps.fromMap).toList();
  }

  static String _formatDate(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
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

  /// The persisted step count for one specific (date, hour), or null if
  /// nothing's been recorded for it yet. Used by the background service to
  /// correctly resume mid-hour after a restart, rather than losing or
  /// double-counting that hour's steps.
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
}
