import '../data/app_database.dart';
import '../models/master.dart';
import 'api_client.dart';

/// Pull read-only de maestros (clientes/centros). No hay push: el alta/edición vive
/// en la web. Cursor global por ServerVersion (igual patrón que las auditorías).
class MasterSyncService {
  final AppDatabase db;
  final ApiClient api;

  MasterSyncService({required this.db, required this.api});

  /// Una vez por versión de la app: se vuelven a bajar los centros completos. Un centro que no cambió desde la última
  /// sincronización no vuelve a llegar por el cursor, y su copia podía ser de antes de la posición por nivel (19-10-2026).
  /// Sin cambiar el esquema de la base: la versión anterior de la app la sigue abriendo.
  static const String _llaveModelo = 'centros_modelo';
  static const String _modeloVigente = 'niveles-20261020';

  Future<void> pull() async {
    if (await db.getValue(_llaveModelo) != _modeloVigente) {
      await db.setCenterCursor(0);
      await db.setValue(_llaveModelo, _modeloVigente);
    }
    await _pullClients();
    await _pullCenters();
    await _pullUsers();
    await _pullCatalogs();
  }

  // Catálogos (tipos de punto/sistema, afluentes): lista chica, se reemplaza completa.
  Future<void> _pullCatalogs() async {
    final res = await api.dio.get('/api/masters/catalogs');
    if (res.data is Map) await db.setCatalogs((res.data as Map).cast<String, dynamic>());
  }

  // Usuarios: lista chica, se reemplaza completa (sin cursor).
  Future<void> _pullUsers() async {
    final res = await api.dio.get('/api/masters/users');
    final list = (res.data as List).cast<Map<String, dynamic>>();
    await db.replaceUsers(list.map(UserRef.fromDto).toList());
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
