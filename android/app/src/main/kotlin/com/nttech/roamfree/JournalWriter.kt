package com.nttech.roamfree

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log

/**
 * Appends one reading to the step journal from Kotlin.
 *
 * Opened without an `SQLiteOpenHelper` on purpose: the schema belongs to
 * sqflite on the Dart side, and a helper here would carry its own version
 * number and try to "upgrade" a database it does not own. This only ever
 * inserts, and only into a table Dart has already created.
 *
 * The two columns below are therefore a contract with
 * `DatabaseHelper._createJournalTables`. They are the whole contract.
 */
object JournalWriter {
    private const val TAG = "JournalWriter"
    private const val DATABASE = "step_counter.db"
    private const val TABLE = "step_journal"

    fun append(context: Context, recordedAt: Long, rawSteps: Int): Boolean {
        val path = context.getDatabasePath(DATABASE)
        // Nothing to write to until the app has run once and built the schema.
        if (!path.exists()) return false

        var db: SQLiteDatabase? = null
        return try {
            db = SQLiteDatabase.openDatabase(
                path.absolutePath,
                null,
                SQLiteDatabase.OPEN_READWRITE,
            )
            db.insertWithOnConflict(
                TABLE,
                null,
                ContentValues().apply {
                    put("recordedAt", recordedAt)
                    put("rawSteps", rawSteps)
                },
                SQLiteDatabase.CONFLICT_REPLACE,
            )
            true
        } catch (error: Exception) {
            // An app mid-migration, or a schema older than the journal. The
            // next reading Dart takes covers the same ground, so this is worth
            // noting and not worth crashing over.
            Log.w(TAG, "could not append to the journal: ${error.message}")
            false
        } finally {
            db?.close()
        }
    }
}
