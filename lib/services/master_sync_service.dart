import '../data/app_database.dart';
import '../models/master.dart';
import 'api_client.dart';

/// Pull read-only de maestros (clientes/centros). No hay push: el alta/edición vive
/// en la web. Cursor global por ServerVersion (igual patrón que las auditorías).
class MasterSyncService {
  final AppDatabase db;
  final ApiClient api;

  MasterSyncService({required this.db, required this.api});

  Future<void> pull() async {
    await _pullClients();
    await _pullCenters();
  }

  Future<void> _pullClients() async {
    var cursor = await db.getClientCursor();
    var hasMore = true;
    while (hasMore) {
      final res = await api.dio.get('/api/masters/clients/pull',
          queryParameters: {'cursor': cursor, 'pageSize': 200});
      final list = (res.data['clients'] as List).cast<Map<String, dynamic>>();
      for (final d in list) {
        await db.applyClientFromServer(ClientRef.fromDto(d));
      }
      cursor = (res.data['cursor'] ?? cursor) as int;
      hasMore = (res.data['hasMore'] ?? false) as bool;
      await db.setClientCursor(cursor);
    }
  }

  Future<void> _pullCenters() async {
    var cursor = await db.getCenterCursor();
    var hasMore = true;
    while (hasMore) {
      final res = await api.dio.get('/api/masters/centers/pull',
          queryParameters: {'cursor': cursor, 'pageSize': 200});
      final list = (res.data['centers'] as List).cast<Map<String, dynamic>>();
      for (final d in list) {
        await db.applyCenterFromServer(CenterRef.fromDto(d));
      }
      cursor = (res.data['cursor'] ?? cursor) as int;
      hasMore = (res.data['hasMore'] ?? false) as bool;
      await db.setCenterCursor(cursor);
    }
  }
}
