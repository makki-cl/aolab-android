import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../models/audit.dart';
import 'api_client.dart';

enum SyncStatus { idle, syncing, offline, error }

/// Sincroniza auditorías offline-first:
/// PUSH de las locales con cambios (dirty) y PULL de los cambios del servidor por cursor.
class AuditSyncService extends ChangeNotifier {
  final AppDatabase db;
  final ApiClient api;

  SyncStatus status = SyncStatus.idle;
  String? lastError;
  DateTime? lastSyncAt;

  AuditSyncService({required this.db, required this.api});

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
