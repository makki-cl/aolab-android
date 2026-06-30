import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'form_entry.dart';

/// Almacenamiento local offline (SQLite vía sqflite). Es la fuente de verdad en el
/// dispositivo: la UI siempre lee/escribe aquí, y la sincronización ocurre aparte.
class AppDatabase {
  static const _dbName = 'aolab.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE form_entries (
            id            TEXT PRIMARY KEY,
            title         TEXT NOT NULL,
            notes         TEXT,
            captured_at   TEXT NOT NULL,
            data          TEXT NOT NULL,
            created_at    TEXT NOT NULL,
            updated_at    TEXT NOT NULL,
            is_deleted    INTEGER NOT NULL DEFAULT 0,
            server_version INTEGER NOT NULL DEFAULT 0,
            dirty         INTEGER NOT NULL DEFAULT 1
          );
        ''');
        await db.execute(
            'CREATE INDEX idx_entries_dirty ON form_entries(dirty);');
        await db.execute('''
          CREATE TABLE sync_state (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          );
        ''');
      },
    );
  }

  // ---- Lecturas para la UI ----

  /// Formularios visibles (no borrados), más recientes primero.
  Future<List<FormEntry>> visibleEntries() async {
    final db = await database;
    final rows = await db.query('form_entries',
        where: 'is_deleted = 0', orderBy: 'updated_at DESC');
    return rows.map(FormEntry.fromRow).toList();
  }

  Future<FormEntry?> findById(String id) async {
    final db = await database;
    final rows =
        await db.query('form_entries', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : FormEntry.fromRow(rows.first);
  }

  // ---- Escrituras locales (marcan dirty para el próximo push) ----

  Future<void> upsertLocal(FormEntry e) async {
    final db = await database;
    e.dirty = true;
    await db.insert('form_entries', e.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Borrado lógico (tombstone) que se propaga al servidor en el próximo sync.
  Future<void> softDelete(String id) async {
    final db = await database;
    await db.update(
      'form_entries',
      {
        'is_deleted': 1,
        'dirty': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---- Soporte de sincronización ----

  Future<List<FormEntry>> dirtyEntries() async {
    final db = await database;
    final rows = await db.query('form_entries', where: 'dirty = 1');
    return rows.map(FormEntry.fromRow).toList();
  }

  /// Aplica un registro recibido del servidor (ya sincronizado).
  Future<void> applyFromServer(FormEntry e) async {
    final db = await database;
    e.dirty = false;
    await db.insert('form_entries', e.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Marca un registro como limpio tras un push aceptado, fijando su versión.
  Future<void> markSynced(String id, int serverVersion) async {
    final db = await database;
    await db.update(
      'form_entries',
      {'dirty': 0, 'server_version': serverVersion},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> pendingCount() async {
    final db = await database;
    final r = await db
        .rawQuery('SELECT COUNT(*) AS c FROM form_entries WHERE dirty = 1');
    return (r.first['c'] as int?) ?? 0;
  }

  // ---- Cursor de pull ----

  Future<int> getCursor() async {
    final db = await database;
    final rows = await db
        .query('sync_state', where: 'key = ?', whereArgs: ['pull_cursor']);
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  Future<void> setCursor(int value) async {
    final db = await database;
    await db.insert('sync_state', {'key': 'pull_cursor', 'value': '$value'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
