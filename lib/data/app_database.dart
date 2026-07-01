import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/audit.dart';

/// Almacenamiento local offline (SQLite). Fuente de verdad en el dispositivo:
/// guarda las auditorías, el cursor de sync y la plantilla cacheada.
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
          CREATE TABLE audits (
            id             TEXT PRIMARY KEY,
            status         INTEGER NOT NULL DEFAULT 0,
            center_name    TEXT NOT NULL,
            auditor        TEXT,
            sampled_at     TEXT,
            document       TEXT NOT NULL,
            created_at     TEXT NOT NULL,
            updated_at     TEXT NOT NULL,
            is_deleted     INTEGER NOT NULL DEFAULT 0,
            server_version INTEGER NOT NULL DEFAULT 0,
            dirty          INTEGER NOT NULL DEFAULT 1
          );
        ''');
        await db.execute('CREATE INDEX idx_audits_dirty ON audits(dirty);');
        await db.execute('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);');
      },
    );
  }

  // ---- Auditorías ----

  Future<List<Audit>> visibleAudits() async {
    final db = await database;
    final rows = await db.query('audits', where: 'is_deleted = 0', orderBy: 'updated_at DESC');
    return rows.map(Audit.fromRow).toList();
  }

  Future<Audit?> findById(String id) async {
    final db = await database;
    final rows = await db.query('audits', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Audit.fromRow(rows.first);
  }

  Future<void> upsertLocal(Audit a, {bool markDirty = true}) async {
    final db = await database;
    if (markDirty) a.dirty = true;
    await db.insert('audits', a.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> softDelete(String id) async {
    final db = await database;
    await db.update(
      'audits',
      {'is_deleted': 1, 'dirty': 1, 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Audit>> dirtyAudits() async {
    final db = await database;
    final rows = await db.query('audits', where: 'dirty = 1');
    return rows.map(Audit.fromRow).toList();
  }

  /// Aplica una auditoría recibida del servidor (ya sincronizada).
  Future<void> applyFromServer(Audit a) async {
    final db = await database;
    a.dirty = false;
    await db.insert('audits', a.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markSynced(String id, int serverVersion) async {
    final db = await database;
    await db.update('audits', {'dirty': 0, 'server_version': serverVersion},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> pendingCount() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM audits WHERE dirty = 1');
    return (r.first['c'] as int?) ?? 0;
  }

  // ---- Clave/valor (cursor + plantilla cacheada) ----

  Future<String?> getValue(String key) async {
    final db = await database;
    final rows = await db.query('kv', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setValue(String key, String value) async {
    final db = await database;
    await db.insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> getCursor() async => int.tryParse(await getValue('pull_cursor') ?? '0') ?? 0;
  Future<void> setCursor(int value) async => setValue('pull_cursor', '$value');
}
