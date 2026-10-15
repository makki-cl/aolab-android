import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/audit.dart';
import '../models/master.dart';
import 'reglas_sync.dart';

/// Almacenamiento local offline (SQLite). Fuente de verdad en el dispositivo:
/// guarda las auditorías, el cursor de sync y la plantilla cacheada.
class AppDatabase {
  static const _dbName = 'aolab.db';
  static const _dbVersion = 10;

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
        if (oldV < 9) {
          // F3, modelo con equipos. (1) Los centros guardan la versión de su modelo, y su blob
          // 'sistemas' trae ahora etapa, afluentes y, por punto, equipo, grupo y ubicación. Se
          // resetea el cursor de centros para volver a bajar el maestro completo: sin eso, un centro
          // que no cambió en el servidor seguiría con el blob viejo, sin grupos.
          // (2) La cabecera de la auditoría guarda en 'extra' los campos que esta versión no
          // conoce, para que la copia local quede completa (no se suben: ver llaves_ajenas.dart).
          // NO se resetea 'pull_cursor': volver a bajar todas las auditorías pisaría las que
          // quedaron sin subir si el push falló. No hace falta, porque el servidor conserva lo que
          // el push no trae (fusión de F0); 'extra' se llena la próxima vez que cada una cambie.
          try { await db.execute('ALTER TABLE centers ADD COLUMN modelo_version INTEGER NOT NULL DEFAULT 1;'); } catch (_) {}
          try { await db.execute('ALTER TABLE audits ADD COLUMN extra TEXT;'); } catch (_) {}
          try { await db.delete('kv', where: 'key = ?', whereArgs: ['center_cursor']); } catch (_) {}
        }
        if (oldV < 10) {
          // Contador de escrituras del contenido de cada evaluación (local_rev): con él, markSynced deja pendiente
          // una fila que se editó mientras el envío iba y volvía, y el editor sabe si el servidor le reemplazó la fila
          // mientras la tenía abierta. No se resetea ningún cursor.
          try { await db.execute('ALTER TABLE audits ADD COLUMN local_rev INTEGER NOT NULL DEFAULT 0;'); } catch (_) {}
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
        extra           TEXT,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL,
        is_deleted      INTEGER NOT NULL DEFAULT 0,
        server_version  INTEGER NOT NULL DEFAULT 0,
        dirty           INTEGER NOT NULL DEFAULT 1,
        local_rev       INTEGER NOT NULL DEFAULT 0
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
        modelo_version  INTEGER NOT NULL DEFAULT 1,
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

  /// Guarda lo que editó el evaluador (queda pendiente de subir).
  ///
  /// [a] es una copia que se leyó de la fila (o se guardó) en algún momento, con su [Audit.localRev]. Al guardarla:
  /// - Si la fila sigue siendo esa (misma revisión), solo pudo cambiarle markSynced la versión y el folio: se quedan
  ///   los de la fila (la versión es la de la copia que el servidor guardó de lo que esta tablet le mandó).
  /// - Si el servidor la reemplazó entretanto (applyFromServer, con el editor abierto), lo que [a] tiene viene de su
  ///   propia versión: se guarda con esa, y el próximo envío se mezcla contra la copia correcta. Con la versión de la
  ///   fila, el servidor creería que la tablet vio lo último y desharía lo que se cambió en la web.
  /// - El folio: si el evaluador no lo cambió desde que leyó la copia, manda el de la fila (el servidor lo arbitra).
  /// - Una evidencia que la fila ya tiene subida no vuelve a quedar sin subir.
  /// Después de guardar, [a] queda con la versión, el folio y la revisión de la fila.
  Future<void> upsertLocal(Audit a, {bool markDirty = true}) async {
    final db = await database;
    await db.transaction((txn) async {
      if (markDirty) a.dirty = true;
      final rows = await txn.query('audits', where: 'id = ?', whereArgs: [a.id]);
      if (rows.isEmpty) {
        a.localRev = 1;
        await txn.insert('audits', a.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        final fila = Audit.fromRow(rows.first);
        if (fila.localRev == a.localRev) a.serverVersion = fila.serverVersion;
        if (a.folio == a.folioLeido) a.folio = fila.folio;
        conservarSubidas(a.document, fila.document);
        a.localRev = fila.localRev + 1;
        await txn.update('audits', a.toRow(), where: 'id = ?', whereArgs: [a.id]);
      }
      a.folioLeido = a.folio;
    });
  }

  Future<void> softDelete(String id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE audits SET is_deleted = 1, dirty = 1, updated_at = ?, local_rev = local_rev + 1 WHERE id = ?',
      [DateTime.now().toUtc().toIso8601String(), id],
    );
  }

  Future<List<Audit>> dirtyAudits() async {
    final db = await database;
    final rows = await db.query('audits', where: 'dirty = 1');
    return rows.map(Audit.fromRow).toList();
  }

  /// Aplica una evaluación recibida del servidor (ya sincronizada). No pisa una fila con cambios sin subir: esos se
  /// mandan en el próximo envío, el servidor los mezcla, le da a la evaluación una versión nueva y el pull siguiente la
  /// trae mezclada (lo mismo que hace el editor offline). Devuelve si la aplicó.
  Future<bool> applyFromServer(Audit a) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query('audits', columns: ['dirty', 'local_rev'], where: 'id = ?', whereArgs: [a.id]);
      if (rows.isNotEmpty && ((rows.first['dirty'] as int?) ?? 0) == 1) return false;
      a.dirty = false;
      a.localRev = rows.isEmpty ? 1 : ((rows.first['local_rev'] as int?) ?? 0) + 1;
      await txn.insert('audits', a.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  /// Lo que vuelve del push para una evaluación aplicada. La versión se copia siempre (es la de la copia que el
  /// servidor guardó de lo que se mandó: con ella el próximo envío se mezcla bien). Pendiente y folio, según
  /// [marcaSincronizada]: si la fila cambió mientras el envío iba y volvía, sigue pendiente.
  Future<void> markSynced(String id, int serverVersion,
      {int? folio, required int revEnviada, int? folioEnviado}) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('audits', columns: ['local_rev', 'folio'], where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      final marca = marcaSincronizada(
        revEnviada: revEnviada,
        revActual: (rows.first['local_rev'] as int?) ?? 0,
        folioEnviado: folioEnviado,
        folioActual: rows.first['folio'] as int?,
        folioRespuesta: folio,
      );
      await txn.update(
        'audits',
        {'dirty': marca.dirty ? 1 : 0, 'server_version': serverVersion, 'folio': marca.folio},
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Marca como subidas las evidencias [ids] sobre la fila RECIÉN LEÍDA (no sobre una copia de antes de subir, que
  /// pisaría lo que el evaluador editó mientras tanto) y la deja pendiente, para que el dato llegue al servidor. No
  /// cambia la revisión: el editor abierto conserva lo subido al guardar (upsertLocal).
  Future<void> marcarEvidenciasSubidas(String auditId, Set<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('audits', where: 'id = ?', whereArgs: [auditId]);
      if (rows.isEmpty) return;
      final a = Audit.fromRow(rows.first);
      if (marcarSubidas(a.document, ids) == 0) return;
      await txn.update('audits', {'document': a.document.encode(), 'dirty': 1}, where: 'id = ?', whereArgs: [auditId]);
    });
  }

  // ---- Evidencias por borrar en el servidor (papelera vaciada al finalizar) ----
  // Se borran recién cuando la evaluación que las quitó ya subió: así, si la oficina restauró una mientras tanto, el
  // servidor la conserva (y su DELETE no borra una evidencia que siga viva en alguna evaluación).

  Future<List<Map<String, String>>> evidenciasPorBorrar() async {
    final raw = await getValue('evidencias_por_borrar');
    if (raw == null || raw.isEmpty) return [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          if (e is Map && e['a'] is String && e['e'] is String) {'a': e['a'] as String, 'e': e['e'] as String},
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> setEvidenciasPorBorrar(List<Map<String, String>> lista) async =>
      setValue('evidencias_por_borrar', jsonEncode(lista));

  Future<void> encolarBorrado(String auditId, Iterable<String> evidenciaIds) async {
    final lista = await evidenciasPorBorrar();
    for (final id in evidenciaIds) {
      if (!lista.any((x) => x['e'] == id)) lista.add({'a': auditId, 'e': id});
    }
    await setEvidenciasPorBorrar(lista);
  }

  /// ¿La evaluación sigue con cambios sin subir?
  Future<bool> isDirty(String id) async {
    final db = await database;
    final rows = await db.query('audits', columns: ['dirty'], where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty && ((rows.first['dirty'] as int?) ?? 0) == 1;
  }

  // ---- Avisos del servidor (se muestran hasta que el evaluador los cierra) ----

  Future<List<String>> getAvisos() async {
    final raw = await getValue('avisos');
    if (raw == null || raw.isEmpty) return [];
    try {
      return [for (final e in jsonDecode(raw) as List) e.toString()];
    } catch (_) {
      return [];
    }
  }

  Future<void> setAvisos(List<String> avisos) async => setValue('avisos', jsonEncode(avisos));

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
