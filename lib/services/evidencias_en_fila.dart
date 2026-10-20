import 'dart:convert';

import '../data/app_database.dart';
import '../models/audit.dart';
import '../models/modelo_puntos.dart';
import 'media_service.dart';

/// Lo que esta tablet tiene por subir (las evidencias, solo si su archivo está aquí: ver [quedaPorSubir]).
Future<int> pendientesDeLaTablet(AppDatabase db, MediaService media) async {
  await media.dirPath();
  return db.pendientesDeSubir(enEstaTablet: media.hasLocal);
}

/// El punto de la evaluación con ese id (en cualquier sistema), o null.
PuntoControl? puntoPorId(AuditDocument d, String id) {
  for (final s in d.salas) {
    for (final p in s.puntosControl) {
      if (p.id == id) return p;
    }
  }
  return null;
}

/// Pega una foto o un audio a un punto directamente en la fila (cuando la pantalla ya se cerró o la app se reinició).
/// Devuelve el punto, o null si la evaluación o el punto ya no están (la evidencia queda en la carpeta y no se pierde
/// el archivo, pero no se puede asociar).
Future<PuntoControl?> agregarEvidenciaEnFila(AppDatabase db, String auditId, String puntoId, Evidencia ev,
    {bool audio = false}) async {
  final a = await db.findById(auditId);
  if (a == null || a.isLocked) return null;
  final p = puntoPorId(a.document, puntoId);
  if (p == null) return null;
  (audio ? p.audios : p.fotos).add(ev);
  a.updatedAtUtc = DateTime.now().toUtc();
  await db.upsertLocal(a);
  return p;
}

/// La foto que se estaba tomando: si Android cierra la app con la cámara abierta, al volver se sabe a qué punto iba.
abstract final class FotoEnCurso {
  static const String llave = 'foto_en_curso';

  static Future<void> anotar(AppDatabase db, String auditId, String puntoId) =>
      db.setValue(llave, jsonEncode({'a': auditId, 'p': puntoId}));

  static Future<void> limpiar(AppDatabase db) => db.setValue(llave, '');

  /// Al abrir la app: si Android guardó una foto que no alcanzó a volver, se pega al punto que estaba abierto (queda
  /// pendiente de subir). Devuelve el nombre del punto, o null si no había nada que recuperar.
  static Future<String?> recuperar(AppDatabase db, MediaService media) async {
    final raw = await db.getValue(llave);
    if (raw == null || raw.isEmpty) return null;
    String? auditId, puntoId;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      auditId = m['a'] as String?;
      puntoId = m['p'] as String?;
    } catch (_) {}
    String? nombre;
    String? ruta;
    try {
      ruta = await media.fotoPerdida();
    } catch (_) {}
    if (ruta != null && auditId != null && puntoId != null) {
      final ev = await media.guardarFoto(ruta);
      final p = await agregarEvidenciaEnFila(db, auditId, puntoId, ev);
      if (p != null) nombre = nombrePunto(p);
    }
    await limpiar(db);
    return nombre;
  }
}
