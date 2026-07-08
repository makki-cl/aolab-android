import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../models/audit.dart';
import 'api_client.dart';
import 'master_sync_service.dart';
import 'media_service.dart';

enum SyncStatus { idle, syncing, offline, error }

/// Sincroniza auditorías offline-first:
/// PUSH de las locales con cambios (dirty) y PULL de los cambios del servidor por cursor.
/// También refresca los maestros (clientes/centros) en el mismo ciclo.
class AuditSyncService extends ChangeNotifier {
  final AppDatabase db;
  final ApiClient api;
  final MasterSyncService masters;
  final MediaService media;

  SyncStatus status = SyncStatus.idle;
  String? lastError;
  DateTime? lastSyncAt;

  AuditSyncService({required this.db, required this.api, required this.masters, required this.media});

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
    try {
      await _uploadMedia();
      await _push();
      await _pull();
      await masters.pull(); // refresca clientes/centros para los selectores
      lastSyncAt = DateTime.now();
      _set(SyncStatus.idle);
    } on DioException catch (e) {
      lastError = e.message;
      _set(SyncStatus.error);
    } catch (e) {
      lastError = '$e';
      _set(SyncStatus.error);
    }
  }

  /// Sube las evidencias (fotos/audio) pendientes de cada auditoría local. Si alguna cambió
  /// su estado a "subida", re-guarda la auditoría (dirty) para que el push refleje el flag.
  Future<void> _uploadMedia() async {
    final audits = await db.visibleAudits();
    for (final a in audits) {
      final evs = <Evidencia>[];
      for (final s in a.document.salas) {
        for (final pc in s.puntosControl) {
          evs.addAll(pc.fotos);
          evs.addAll(pc.audios);
        }
      }
      if (evs.isEmpty) continue;
      final changed = await media.uploadPending(evs);
      if (changed) {
        a.updatedAtUtc = DateTime.now().toUtc();
        await db.upsertLocal(a); // markDirty -> el push envía el documento con uploaded=true
      }
    }
  }

  Future<void> _push() async {
    final pending = await db.dirtyAudits();
    if (pending.isEmpty) return;
    final res = await api.dio.post('/api/audits/push', data: {
      'audits': pending.map((a) => a.toDto()).toList(),
    });
    final results = (res.data['results'] as List).cast<Map<String, dynamic>>();
    for (final r in results) {
      if ((r['status'] as int) == 0) {
        await db.markSynced(r['id'] as String, (r['serverVersion'] ?? 0) as int);
      }
      // Conflict/Rejected se resuelven en el pull siguiente (gana el servidor).
    }
  }

  Future<void> _pull() async {
    var cursor = await db.getCursor();
    var hasMore = true;
    while (hasMore) {
      final res = await api.dio.get('/api/audits/pull', queryParameters: {
        'cursor': cursor,
        'pageSize': 100,
      });
      final audits = (res.data['audits'] as List).cast<Map<String, dynamic>>();
      for (final d in audits) {
        await db.applyFromServer(Audit.fromDto(d));
      }
      cursor = (res.data['cursor'] ?? cursor) as int;
      hasMore = (res.data['hasMore'] ?? false) as bool;
      await db.setCursor(cursor);
    }
  }

  void _set(SyncStatus s) {
    status = s;
    notifyListeners();
  }
}
