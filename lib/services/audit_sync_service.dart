import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../data/reglas_sync.dart';
import '../models/audit.dart';
import '../models/llaves_ajenas.dart';
import 'api_client.dart';
import 'master_sync_service.dart';
import 'media_service.dart';

enum SyncStatus { idle, syncing, offline, error }

/// Sincroniza las evaluaciones offline-first: sube las evidencias pendientes, hace PUSH de las locales con cambios
/// (dirty) y PULL de los cambios del servidor por cursor. También refresca los maestros (clientes/centros) en el mismo
/// ciclo.
///
/// El servidor mezcla cada envío campo por campo contra la copia que esta tablet tenía (la versión que guarda cada fila),
/// así que nada de lo que llega se pierde. Lo que cuida la app es no perder lo que todavía no sale de la tablet: una fila
/// que se edita mientras el envío va y vuelve sigue pendiente (markSynced), y el pull no pisa una fila pendiente
/// (applyFromServer).
class AuditSyncService extends ChangeNotifier {
  final AppDatabase db;
  final ApiClient api;
  final MasterSyncService masters;
  final MediaService media;

  SyncStatus status = SyncStatus.idle;
  String? lastError;
  DateTime? lastSyncAt;

  /// Cuántos ciclos terminaron (para que el editor abierto sepa que la fila pudo cambiar bajo él).
  int ciclos = 0;

  /// Avisos que devolvió el servidor en el push: un folio que ya usaba otra evaluación (quedó con el anterior o sin
  /// folio: hay que escribir otro), una evaluación que ya estaba finalizada en la oficina, una eliminación que no se
  /// aplicó, datos que reemplazaron lo que otro había cambiado… El push se aplica igual —no se pierde el trabajo de
  /// terreno—, pero el evaluador tiene que enterarse. Quedan a la vista (y guardados) hasta que los cierra.
  final List<String> avisos = [];

  AuditSyncService({required this.db, required this.api, required this.masters, required this.media});

  /// Recupera los avisos que quedaron sin cerrar la vez anterior.
  Future<void> cargarAvisos() async {
    final guardados = await db.getAvisos();
    if (guardados.isEmpty) return;
    for (final a in guardados) {
      if (!avisos.contains(a)) avisos.add(a);
    }
    notifyListeners();
  }

  /// El evaluador los leyó.
  Future<void> cerrarAvisos() async {
    avisos.clear();
    await db.setAvisos(const []);
    notifyListeners();
  }

  void _avisar(String msg) {
    final m = msg.trim();
    if (m.isNotEmpty && !avisos.contains(m)) avisos.add(m);
  }

  Future<bool> _isOnline() async {
    final r = await Connectivity().checkConnectivity();
    return !r.contains(ConnectivityResult.none);
  }

  Future<void> sync() async {
    if (status == SyncStatus.syncing) return;
    if (!await _isOnline()) {
      _set(SyncStatus.offline);
      return;
    }
    _set(SyncStatus.syncing);
    // Cada paso se aísla: si uno falla (p.ej. subir una evidencia), los demás
    // siguen — así el PULL siempre trae las evaluaciones del servidor aunque el
    // push/media fallen. Se acumulan los errores para mostrarlos en la UI.
    final errors = <String>[];
    Future<void> step(String name, Future<void> Function() run) async {
      try {
        await run();
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 401) {
          errors.add('sesión expirada (401) — cierra sesión y vuelve a entrar');
        } else if (code == 403) {
          errors.add('$name: tu cuenta no tiene acceso (403). La app es para el personal de AOLAB.');
        } else {
          errors.add('$name: ${code ?? ''} ${e.message ?? e.type.name}'.trim());
        }
      } catch (e) {
        errors.add('$name: $e');
      }
    }

    await step('media', _uploadMedia);
    await step('subir', _push);
    await step('papelera', _borrarEvidencias);
    await step('bajar', () => _pull(errors));
    await step('maestros', masters.pull); // refresca clientes/centros para los selectores
    try {
      await db.setAvisos(avisos);
    } catch (_) {}
    lastSyncAt = DateTime.now();
    ciclos++;
    if (errors.isEmpty) {
      lastError = null;
      _set(SyncStatus.idle);
    } else {
      lastError = errors.join(' · ');
      _set(SyncStatus.error);
    }
  }

  /// Sube las evidencias (fotos/audio) pendientes de cada evaluación local y las marca como subidas sobre la fila
  /// recién leída (no sobre la copia de antes de subir: con mala señal tarda minutos y el evaluador puede haber editado
  /// mientras tanto). La fila queda pendiente para que el push lleve el dato.
  Future<void> _uploadMedia() async {
    final audits = await db.visibleAudits();
    for (final a in audits) {
      final pendientes = evidenciasDe(a.document).where((e) => !e.uploaded && !e.isDeleted).toList();
      if (pendientes.isEmpty) continue;
      final subidas = await media.uploadPending(pendientes);
      await db.marcarEvidenciasSubidas(a.id, subidas);
    }
  }

  Future<void> _push() async {
    final pending = await db.dirtyAudits();
    if (pending.isEmpty) return;
    // Lo que se mandó de cada una (revisión y folio), para saber al volver si se editó entretanto.
    final enviadas = {for (final a in pending) a.id.toLowerCase(): a};
    final res = await api.dio.post('/api/audits/push', data: {
      'audits': pending.map((a) => a.toDto()).toList(),
    });
    final results = (res.data['results'] as List).cast<Map<String, dynamic>>();
    for (final r in results) {
      // Todo lo que el servidor avisa se muestra, también en una cerrada (ignorado) o en un rechazo.
      final msg = r['message'];
      if (msg is String) _avisar(msg);
      final id = r['id'] as String;
      if (enteroOpcional(r['status']) != 0) continue; // Conflict/Rejected: siguen en la cola
      final enviada = enviadas[id.toLowerCase()];
      await db.markSynced(
        enviada?.id ?? id,
        enteroOpcional(r['serverVersion']) ?? 0,
        folio: enteroOpcional(r['folio']),
        revEnviada: enviada?.localRev ?? -1,
        folioEnviado: enviada?.folio,
      );
    }
  }

  /// Borra en el servidor las evidencias de la papelera que se vació al finalizar, una vez que la evaluación subió sin
  /// ellas. Si falla, quedan para el ciclo siguiente.
  Future<void> _borrarEvidencias() async {
    final lista = await db.evidenciasPorBorrar();
    if (lista.isEmpty) return;
    final quedan = <Map<String, String>>[];
    for (final x in lista) {
      final auditId = x['a']!;
      if (await db.isDirty(auditId) || !await media.removeRemote(x['e']!)) quedan.add(x);
    }
    await db.setEvidenciasPorBorrar(quedan);
  }

  Future<void> _pull(List<String> errors) async {
    var cursor = await db.getCursor();
    var hasMore = true;
    var ilegibles = 0;
    while (hasMore) {
      final res = await api.dio.get('/api/audits/pull', queryParameters: {
        'cursor': cursor,
        'pageSize': 100,
      });
      final audits = (res.data['audits'] as List).cast<Map<String, dynamic>>();
      for (final d in audits) {
        // Una evaluación que esta versión no sabe leer no detiene el resto: se avisa y se sigue.
        final a = _leer(d);
        if (a == null) {
          ilegibles++;
          continue;
        }
        await db.applyFromServer(a); // no pisa una fila con cambios sin subir
      }
      cursor = (res.data['cursor'] ?? cursor) as int;
      hasMore = (res.data['hasMore'] ?? false) as bool;
      await db.setCursor(cursor);
    }
    if (ilegibles > 0) {
      errors.add('bajar: $ilegibles evaluación(es) no se pudieron leer con esta versión de la app. Actualízala.');
    }
  }

  static Audit? _leer(Map<String, dynamic> d) {
    try {
      return Audit.fromDto(d);
    } catch (_) {
      return null;
    }
  }

  void _set(SyncStatus s) {
    status = s;
    notifyListeners();
  }
}
