import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../data/form_entry.dart';
import 'api_client.dart';

enum SyncStatus { idle, syncing, offline, error }

/// Sincronización offline-first contra la API:
/// 1) PUSH: sube los registros locales con cambios pendientes (dirty).
/// 2) PULL: baja los cambios del servidor con serverVersion > cursor (incluye
///    tombstones) y los aplica al SQLite local.
/// La UI siempre trabaja contra la base local; esto solo reconcilia con el servidor.
class SyncService extends ChangeNotifier {
  final AppDatabase db;
  final ApiClient api;

  SyncStatus status = SyncStatus.idle;
  String? lastError;
  DateTime? lastSyncAt;

  SyncService({required this.db, required this.api});

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  /// Ejecuta push + pull si hay conexión. Seguro de llamar a menudo.
  Future<void> sync() async {
    if (status == SyncStatus.syncing) return;
    if (!await _isOnline()) {
      _set(SyncStatus.offline);
      return;
    }
    _set(SyncStatus.syncing);
    try {
      await _push();
      await _pull();
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

  Future<void> _push() async {
    final pending = await db.dirtyEntries();
    if (pending.isEmpty) return;

    final res = await api.dio.post('/api/sync/push', data: {
      'entries': pending.map((e) => e.toDto()).toList(),
    });
    final results = (res.data['results'] as List).cast<Map<String, dynamic>>();

    for (final r in results) {
      final id = r['id'] as String;
      final statusCode = r['status'] as int; // 0=Applied, 1=Conflict, 2=Rejected
      final serverVersion = (r['serverVersion'] ?? 0) as int;
      if (statusCode == 0) {
        await db.markSynced(id, serverVersion);
      }
      // Conflict/Rejected se resuelven en el pull siguiente (gana el servidor).
    }
  }

  Future<void> _pull() async {
    var cursor = await db.getCursor();
    var hasMore = true;
    while (hasMore) {
      final res = await api.dio.get('/api/sync/pull', queryParameters: {
        'cursor': cursor,
        'pageSize': 200,
      });
      final entries = (res.data['entries'] as List).cast<Map<String, dynamic>>();
      for (final d in entries) {
        await db.applyFromServer(FormEntry.fromDto(d));
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
