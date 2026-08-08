import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/daily_steps.dart';

/// Handles all local persistence of daily step records via sqflite.
///
/// Table schema:
///   daily_steps(date TEXT PRIMARY KEY, stepCount INTEGER NOT NULL)
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
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE daily_steps (
            date TEXT PRIMARY KEY,
            stepCount INTEGER NOT NULL
          )
        ''');
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

  /// Average steps/day over the past [days] days (missing days count as 0).
  Future<double> averageOverPastNDays(int days) async {
    final records = await getPastNDays(days);
    final total = records.fold<int>(0, (sum, r) => sum + r.stepCount);
    return total / days;
  }

  /// All records for a given calendar month (year, month 1-12).
  Future<List<DailySteps>> getRecordsForMonth(int year, int month) async {
    final db = await database;
    final prefix = '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}-';
    final rows = await db.query(
      'daily_steps',
      where: 'date LIKE ?',
      whereArgs: ['$prefix%'],
      orderBy: 'date ASC',
    );
    return rows.map(DailySteps.fromMap).toList();
  }

  /// Total steps for each month (1-12) of [year]. Months with no data
  /// are returned as 0.
  Future<Map<int, int>> getMonthlyTotalsForYear(int year) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT substr(date, 6, 2) AS month, SUM(stepCount) AS total
      FROM daily_steps
      WHERE substr(date, 1, 4) = ?
      GROUP BY month
    ''', [year.toString().padLeft(4, '0')]);

    final result = <int, int>{for (var m = 1; m <= 12; m++) m: 0};
    for (final row in rows) {
      final month = int.parse(row['month'] as String);
      final total = (row['total'] as num).toInt();
      result[month] = total;
    }
    return result;
  }

  static String _formatDate(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}
