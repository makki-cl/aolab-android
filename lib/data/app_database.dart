import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/audit.dart';
import '../models/master.dart';

/// Almacenamiento local offline (SQLite). Fuente de verdad en el dispositivo:
/// guarda las auditorías, el cursor de sync y la plantilla cacheada.
class AppDatabase {
  static const _dbName = 'aolab.db';
  static const _dbVersion = 8;

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createAudits(db);
        await _createMasters(db);
        await _createUsers(db);
        await db.execute('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);');
      },
      onUpgrade: (db, oldV, newV) async {
        // Canal test: recreamos audits con el esquema nuevo y reseteamos el cursor
        // (las auditorías compartidas se vuelven a bajar del servidor).
        if (oldV < 2) {
          await db.execute('DROP TABLE IF EXISTS audits;');
          await _createAudits(db);
          await db.execute("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);");
          await db.delete('kv', where: 'key = ?', whereArgs: ['pull_cursor']);
        }
        if (oldV < 3) {
          await _createMasters(db);
        }
        if (oldV < 4) {
          await _createUsers(db);
        }
        if (oldV < 5) {
          // Serie de auditorías (seguimiento). try/catch por si oldV<2 ya recreó audits con la columna.
          try { await db.execute('ALTER TABLE audits ADD COLUMN previous_audit_id TEXT;'); } catch (_) {}
        }
        if (oldV < 6) {
          // Sistemas del maestro por centro (nombre+tipo). Se resetea el cursor de centros
          // para re-bajarlos con los sistemas.
          try { await db.execute('ALTER TABLE centers ADD COLUMN sistemas TEXT;'); } catch (_) {}
          try { await db.delete('kv', where: 'key = ?', whereArgs: ['center_cursor']); } catch (_) {}
        }
        if (oldV < 7) {
          // Afluente del centro (single/multi). Los puntos de control y el afluente por
          // sistema viajan en el blob 'sistemas'; se resetea el cursor para re-bajar todo.
          try { await db.execute('ALTER TABLE centers ADD COLUMN afluente_mode TEXT;'); } catch (_) {}
          try { await db.execute('ALTER TABLE centers ADD COLUMN afluente TEXT;'); } catch (_) {}
          try { await db.delete('kv', where: 'key = ?', whereArgs: ['center_cursor']); } catch (_) {}
        }
        if (oldV < 8) {
          // Folio del informe (lo asigna el servidor). El correlativo del punto viaja en el
          // documento jsonb. Se resetea el cursor para re-bajar auditorías con folio.
          try { await db.execute('ALTER TABLE audits ADD COLUMN folio INTEGER;'); } catch (_) {}
          try { await db.delete('kv', where: 'key = ?', whereArgs: ['pull_cursor']); } catch (_) {}
        }
      },
    );
  }

  Future<void> _createAudits(Database db) async {
    await db.execute('''
      CREATE TABLE audits (
        id              TEXT PRIMARY KEY,
        status          INTEGER NOT NULL DEFAULT 0,
        folio           INTEGER,
        type            INTEGER NOT NULL DEFAULT 0,
        center_name     TEXT NOT NULL,
        auditor         TEXT,
        sampled_at      TEXT,
        center_id       TEXT,
        client_id       TEXT,
        client_name     TEXT,
        created_by_name TEXT,
        scheduled_for   TEXT,
        previous_audit_id TEXT,
        document        TEXT NOT NULL,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        is_deleted      INTEGER NOT NULL DEFAULT 0,
        server_version  INTEGER NOT NULL DEFAULT 0,
        dirty           INTEGER NOT NULL DEFAULT 1
      );
    ''');
    await db.execute('CREATE INDEX idx_audits_dirty ON audits(dirty);');
  }

  Future<void> _createMasters(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS clients (
        id             TEXT PRIMARY KEY,
        name           TEXT NOT NULL,
        legal_id       TEXT,
        has_logo       INTEGER NOT NULL DEFAULT 0,
        is_active      INTEGER NOT NULL DEFAULT 1,
        is_deleted     INTEGER NOT NULL DEFAULT 0,
        server_version INTEGER NOT NULL DEFAULT 0
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS centers (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        code            TEXT,
        latitude        REAL,
        longitude       REAL,
        owner_client_id TEXT,
        operator_name   TEXT,
        afluente_mode   TEXT,
        afluente        TEXT,
        sistemas        TEXT,
        is_active       INTEGER NOT NULL DEFAULT 1,
        is_deleted      INTEGER NOT NULL DEFAULT 0,
        server_version  INTEGER NOT NULL DEFAULT 0
      );
    ''');
  }

  Future<void> _createUsers(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id        TEXT PRIMARY KEY,
        email     TEXT NOT NULL,
        full_name TEXT
      );
    ''');
  }

  // ---- Usuarios (para elegir auditor) ----

  /// Reemplaza la lista local de usuarios por la del servidor.
  Future<void> replaceUsers(List<UserRef> users) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('users');
    for (final u in users) {
      batch.insert('users', u.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<UserRef>> allUsers() async {
    final db = await database;
    final rows = await db.query('users', orderBy: 'coalesce(full_name, email) COLLATE NOCASE');
    return rows.map(UserRef.fromRow).toList();
  }

  // ---- Maestros (clientes / centros) ----

  Future<void> applyClientFromServer(ClientRef c) async {
    final db = await database;
    await db.insert('clients', c.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> applyCenterFromServer(CenterRef c) async {
    final db = await database;
    await db.insert('centers', c.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ClientRef>> activeClients() async {
    final db = await database;
    final rows = await db.query('clients',
        where: 'is_deleted = 0 AND is_active = 1', orderBy: 'name COLLATE NOCASE');
    return rows.map(ClientRef.fromRow).toList();
  }

  Future<List<CenterRef>> activeCenters() async {
    final db = await database;
    final rows = await db.query('centers',
        where: 'is_deleted = 0 AND is_active = 1', orderBy: 'name COLLATE NOCASE');
    return rows.map(CenterRef.fromRow).toList();
  }

  Future<int> getClientCursor() async => int.tryParse(await getValue('client_cursor') ?? '0') ?? 0;
  Future<void> setClientCursor(int v) async => setValue('client_cursor', '$v');
  Future<int> getCenterCursor() async => int.tryParse(await getValue('center_cursor') ?? '0') ?? 0;
  Future<void> setCenterCursor(int v) async => setValue('center_cursor', '$v');

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

  Future<void> markSynced(String id, int serverVersion, {int? folio}) async {
    final db = await database;
    final values = <String, Object?>{'dirty': 0, 'server_version': serverVersion};
    // Folio: lo asigna el servidor al recibir la auditoría iniciada (inmutable, no se pisa si no viene).
    if (folio != null) values['folio'] = folio;
    await db.update('audits', values, where: 'id = ?', whereArgs: [id]);
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

  // Catálogos del maestro (tipos de punto/sistema y afluentes) sincronizados de la web.
  Future<Map<String, List<String>>> getCatalogs() async {
    final raw = await getValue('catalogs');
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, ((v ?? []) as List).map((e) => e.toString()).toList()));
    } catch (_) {
      return {};
    }
  }

  Future<void> setCatalogs(Map<String, dynamic> catalogs) async =>
      setValue('catalogs', jsonEncode(catalogs));

  Future<int> getCursor() async => int.tryParse(await getValue('pull_cursor') ?? '0') ?? 0;
  Future<void> setCursor(int value) async => setValue('pull_cursor', '$value');
}
