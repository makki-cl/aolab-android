// Prueba de contrato contra un servidor local (una copia, NUNCA prod ni TEST): lo que manda el servidor de hoy, la app lo
// lee sin perder nada, y lo que la app sube (la posición por nivel de varias muestras) vuelve igual.
//
// No corre en el CI (no está en test/) y no trae datos: los baja del servidor al correr.
//   AOLAB_CONTRATO_URL=http://127.0.0.1:5097 AOLAB_CONTRATO_CORREO=… AOLAB_CONTRATO_CLAVE=… \
//     flutter test integration_local/contrato_test.dart
// Escribe en esa copia: crea una evaluación de prueba y la deja borrada al terminar.
import 'dart:convert';
import 'dart:io';

import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/modelo_puntos.dart';
import 'package:aolab_android/models/niveles.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/services/media_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Memoria implements AlmacenSesion {
  final Map<String, String> d = {};
  @override
  Future<String?> leer(String llave) async => d[llave];
  @override
  Future<void> escribir(String llave, String valor) async => d[llave] = valor;
  @override
  Future<void> borrar(String llave) async => d.remove(llave);
}

final _fecha = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$');

/// Para comparar lo que importa: sin las llaves con null ni las listas vacías (la app no escribe un null ni una lista
/// vacía que el servidor sí), y las fechas como el mismo instante («…Z» y «…+00:00» son lo mismo).
Object? sinNulos(Object? v) {
  if (v is Map) {
    return {
      for (final e in v.entries)
        if (e.value != null && !(e.value is List && (e.value as List).isEmpty)) e.key.toString(): sinNulos(e.value),
    };
  }
  if (v is List) return v.map(sinNulos).toList();
  if (v is String && _fecha.hasMatch(v)) return DateTime.parse(v).toUtc().toIso8601String();
  return v;
}

void main() {
  final url = Platform.environment['AOLAB_CONTRATO_URL'] ?? '';
  final correo = Platform.environment['AOLAB_CONTRATO_CORREO'] ?? '';
  final clave = Platform.environment['AOLAB_CONTRATO_CLAVE'] ?? '';
  final local = RegExp(r'^http://(127\.0\.0\.1|localhost):\d+$').hasMatch(url);
  final omitir = !local || correo.isEmpty || clave.isEmpty
      ? 'Solo contra un servidor local (AOLAB_CONTRATO_URL=http://127.0.0.1:<puerto>) con AOLAB_CONTRATO_CORREO y _CLAVE.'
      : null;

  late AuthService auth;
  late Dio dio;
  final centrosCrudos = <Map<String, dynamic>>[];
  final evaluacionesCrudas = <Map<String, dynamic>>[];

  setUpAll(() async {
    if (omitir != null) return;
    dio = Dio(BaseOptions(baseUrl: url, headers: {'Content-Type': 'application/json'}));
    auth = AuthService(almacen: _Memoria(), dio: dio, conGoogle: false);
    await auth.cargarEntradas();
    final err = await auth.login(correo, clave);
    if (err != null) fail('No se pudo entrar en la copia: $err');
    var cursor = 0;
    var mas = true;
    while (mas) {
      final r = await dio.get('/api/masters/centers/pull', queryParameters: {'cursor': cursor, 'pageSize': 200});
      centrosCrudos.addAll((r.data['centers'] as List).cast<Map<String, dynamic>>());
      cursor = r.data['cursor'] as int;
      mas = r.data['hasMore'] as bool;
    }
    cursor = 0;
    mas = true;
    while (mas) {
      final r = await dio.get('/api/audits/pull', queryParameters: {'cursor': cursor, 'pageSize': 100});
      evaluacionesCrudas.addAll((r.data['audits'] as List).cast<Map<String, dynamic>>());
      cursor = r.data['cursor'] as int;
      mas = r.data['hasMore'] as bool;
    }
  });

  test('el servidor dice con qué se entra (la clave siempre)', () {
    expect(auth.entradas, contains(kEntradaClave));
    expect(auth.conClave, isTrue);
  }, skip: omitir);

  test('los centros se leen y la copia local los conserva enteros, con los puntos de nivel', () {
    expect(centrosCrudos, isNotEmpty);
    var deNivel = 0;
    for (final c in centrosCrudos) {
      final centro = CenterRef.fromDto(c);
      final copia = CenterRef.fromRow(centro.toRow());
      final crudos = (c['sistemas'] as List).cast<Map<String, dynamic>>();
      expect(copia.sistemas.length, crudos.length);
      for (var i = 0; i < crudos.length; i++) {
        expect(sinNulos(copia.sistemas[i].toJson()), sinNulos(crudos[i]), reason: '${centro.name} · ${crudos[i]['nombre']}');
        for (final pd in copia.sistemas[i].puntosControl) {
          final ng = pd.nivelPunto;
          if (ng == null) continue;
          deNivel++;
          expect(ng.grupoId, pd.equipoId);
          expect(ng.niveles.length, ng.nivel);
        }
      }
    }
    expect(deNivel, greaterThan(0), reason: 'la copia tiene puntos de nivel');
  }, skip: omitir);

  test('las evaluaciones se leen todas, la copia local no pierde nada y las compartidas se reconocen', () {
    expect(evaluacionesCrudas, isNotEmpty);
    var compartidas = 0;
    var conNiveles = 0;
    for (final d in evaluacionesCrudas) {
      final a = Audit.fromDto(d);
      final copia = Audit.fromRow(a.toRow());
      expect(sinNulos(copia.document.toJson()), sinNulos(d['document']), reason: 'evaluación ${d['folio'] ?? d['id']}');
      if (copia.compartida) compartidas++;
      for (final s in copia.document.salas) {
        for (final p in s.puntosControl) {
          if (p.tieneNiveles) conNiveles++;
        }
      }
      // Lo que se sube no lleva lo que la app no edita ni lo que es solo de la tablet.
      final envio = jsonEncode(copia.toDto());
      expect(envio, isNot(contains('sharedWithClientUtc')));
      expect(envio, isNot(contains(kLlaveNivelesLocal)));
    }
    expect(compartidas, greaterThanOrEqualTo(3), reason: 'la 2999, la 3002 y la 3014 están compartidas con el cliente');
    expect(conNiveles, greaterThan(0), reason: 'la 2999 tiene muestras de racks con posición');
  }, skip: omitir);

  test('dos muestras de un punto de nivel suben con su posición y vuelven igual (y no se juntan)', () async {
    final c = centrosCrudos.map(CenterRef.fromDto).firstWhere((c) => c.sistemas.any((s) => s.puntosControl.any((p) => p.nivelPunto != null)));
    final sis = c.sistemas.firstWhere((s) => s.puntosControl.any((p) => p.nivelPunto != null));
    final pd = sis.puntosControl.firstWhere((p) => p.nivelPunto != null);
    final ng = pd.nivelPunto!;
    final id = 'a0a0a0a0-0000-4000-8000-${DateTime.now().millisecondsSinceEpoch.toString().padLeft(12, '0').substring(0, 12)}';
    final ahora = DateTime.now().toUtc();
    final sala = AuditSala(id: 'contrato-sala', name: sis.nombre, tipo: sis.tipo, fromMaster: true, masterId: sis.id, etapa: sis.etapa);
    final m1 = puntoDesdeMaestro(pd, id: 'contrato-m1', conEquipos: true);
    var n = NivelesMuestra.vacio;
    for (var k = 1; k <= ng.nivel; k++) {
      n = n.con(k, TramosGrupo.finalTramo, '${k == 1 ? 17 : 1844}');
    }
    expect(anotarNiveles(m1, ng, n), isNull);
    sala.puntosControl.add(m1);
    final m2 = otraMuestra(pd, ng, ultima: m1, conEquipos: true, id: 'contrato-m2');
    anotarNiveles(m2, ng, m2.nivelesMuestra.con(ng.nivel, TramosGrupo.principio, '9'));
    sala.puntosControl.add(m2);
    final a = Audit(
      id: id,
      status: 0,
      centerId: c.id,
      centerName: c.name,
      createdAtUtc: ahora,
      updatedAtUtc: ahora,
      document: AuditDocument(salas: [sala], entrevistaDesactivada: true, rpnDesactivado: false, labDesactivado: false),
    );
    try {
      final r = await dio.post('/api/audits/push', data: {'audits': [a.toDto()]});
      final res = (r.data['results'] as List).single as Map;
      expect(res['status'], 0, reason: '${res['message']}');
      a.serverVersion = (res['serverVersion'] as num).toInt();

      Map<String, dynamic>? d;
      var cursor = 0;
      var mas = true;
      while (mas && d == null) {
        final vuelta = await dio.get('/api/audits/pull', queryParameters: {'cursor': cursor, 'pageSize': 100});
        for (final x in (vuelta.data['audits'] as List).cast<Map<String, dynamic>>()) {
          if (x['id'] == id) d = x;
        }
        cursor = vuelta.data['cursor'] as int;
        mas = vuelta.data['hasMore'] as bool;
      }
      expect(d, isNotNull);
      final puntos = Audit.fromDto(d!).document.salas.single.puntosControl;
      expect(puntos.map((p) => p.id), ['contrato-m1', 'contrato-m2']);
      expect(puntos[0].nivelesMuestra, m1.nivelesMuestra);
      expect(puntos[0].nivelesEtiqueta, m1.nivelesEtiqueta);
      expect(puntos[1].nivelesMuestra, m2.nivelesMuestra);
      expect(puntos.every((p) => !p.nivelesLocal), isTrue, reason: 'lo que baja del servidor ya no es «de esta tablet»');
    } finally {
      // La evaluación de prueba queda borrada en la copia.
      a.isDeleted = true;
      a.updatedAtUtc = DateTime.now().toUtc();
      await dio.post('/api/audits/push', data: {'audits': [a.toDto()]});
    }
  }, skip: omitir);

  test('una foto tomada sin señal queda en la tablet y la sincronización la sube después', () async {
    final carpeta = Directory.systemTemp.createTempSync('contrato-evidencias');
    final media = MediaService(api: auth.api, carpeta: carpeta.path)..pausaEntreIntentos = Duration.zero;
    final origen = File('${carpeta.path}/origen.jpg')..writeAsBytesSync(List<int>.generate(2048, (i) => i % 251));
    final ev = await media.guardarFoto(origen.path);
    expect(ev.uploaded, isFalse);
    expect(media.hasLocal(ev.id), isTrue);
    try {
      expect(await media.uploadPending([ev]), {ev.id});
      expect(ev.uploaded, isTrue);
      final r = await dio.get<List<int>>('/api/evidencias/${ev.id}', options: Options(responseType: ResponseType.bytes));
      expect(r.data, origen.readAsBytesSync());
    } finally {
      await media.removeRemote(ev.id);
      carpeta.deleteSync(recursive: true);
    }
  }, skip: omitir);
}
