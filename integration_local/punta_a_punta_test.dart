// Prueba de punta a punta contra un servidor LOCAL (una copia de la base, nunca prod ni TEST), con los servicios de la
// app tal como los arma main.dart: la base SQLite de verdad (sqflite en el PC), Dio contra el servidor, la sincronización
// y las evidencias. Lo que no hay en el PC (cámara, conectividad, almacenamiento seguro) va con dobles; «sin señal» se
// simula en la red de la app (las llamadas fallan como en terreno) y en la conectividad.
//
//   AOLAB_CONTRATO_URL=http://127.0.0.1:5097 AOLAB_CONTRATO_CORREO=… AOLAB_CONTRATO_CLAVE=… AOLAB_E2E_FOLIO=2999 \
//     flutter test integration_local/punta_a_punta_test.dart
//
// Escribe en esa copia (edita la evaluación AOLAB_E2E_FOLIO como lo haría un evaluador y deja en ella las muestras de
// prueba). Lo que se comprueba en la base y en la web va aparte, fuera del repo (usa datos de la copia).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:aolab_android/data/app_database.dart';
import 'package:aolab_android/data/reglas_sync.dart';
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/modelo_puntos.dart';
import 'package:aolab_android/models/niveles.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/services/master_sync_service.dart';
import 'package:aolab_android/services/media_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
// ignore: depend_on_referenced_packages
import 'package:sqlite3/open.dart' as sqlite3;

class _Memoria implements AlmacenSesion {
  final Map<String, String> d = {};
  @override
  Future<String?> leer(String llave) async => d[llave];
  @override
  Future<void> escribir(String llave, String valor) async => d[llave] = valor;
  @override
  Future<void> borrar(String llave) async => d.remove(llave);
}

class _Tablet implements DatosLocales {
  final AppDatabase db;
  final MediaService media;
  _Tablet(this.db, this.media);
  @override
  Future<int> pendientes() => db.pendientesDeSubir();
  @override
  Future<void> borrarTodo() async {
    await db.borrarDatosDeUsuario();
    await media.borrarArchivosLocales();
  }
}

/// La señal de terreno: sin red (nada sale) o con una señal que alcanza para las consultas y los envíos chicos, pero no
/// para subir una foto.
class _Senal extends Interceptor {
  bool sinRed = false;
  bool sinFotos = false;
  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler h) {
    final corta = sinRed || (sinFotos && o.method == 'PUT' && o.path.startsWith('/api/evidencias/'));
    if (corta) {
      h.reject(DioException(requestOptions: o, type: DioExceptionType.connectionError, error: 'sin señal (simulada)'));
      return;
    }
    h.next(o);
  }
}

/// En Debian/Ubuntu sin el paquete -dev solo está libsqlite3.so.0. Corre en el isolate de la base (por eso es de nivel
/// superior).
void _abrirSqlite() {
  sqlite3.open.overrideFor(sqlite3.OperatingSystem.linux, () {
    try {
      return DynamicLibrary.open('libsqlite3.so');
    } catch (_) {
      return DynamicLibrary.open('libsqlite3.so.0');
    }
  });
}

// Cada corrida usa ids propios: se puede repetir sobre la misma copia.
const _uuidE2e = 'e2e00000-0000-4000-8000-';
final _corrida = DateTime.now().millisecondsSinceEpoch.toString().substring(5, 13);
String _idE2e(String sufijo) => '$_uuidE2e$_corrida${sufijo.padLeft(4, '0')}';
final _comentarioOficina = 'e2e-oficina-$_corrida';

/// Un JPEG chico de verdad (el PDF de la web dibuja las fotos).
final List<int> _jpeg = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAoHBwgHBgoICAgLCgoLDhgQDg0NDh0VFhEYIx8lJCIfIiEmKzcvJik0KSEiMEExNDk7Pj4+JS5ESU'
    'M8SDc9Pjv/2wBDAQoLCw4NDhwQEBw7KCIoOzs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozs7Ozv/wAARCAAw'
    'AEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhBy'
    'JxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKT'
    'lJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAA'
    'AAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRom'
    'JygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExc'
    'bHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDFooor1D5kKKKKACiiigAooooAKKKKACiiigAooooAKKKKACii'
    'igAooooAKKKKACiiigD/2Q==');

void main() {
  final url = Platform.environment['AOLAB_CONTRATO_URL'] ?? '';
  final correo = Platform.environment['AOLAB_CONTRATO_CORREO'] ?? '';
  final clave = Platform.environment['AOLAB_CONTRATO_CLAVE'] ?? '';
  final folio = int.tryParse(Platform.environment['AOLAB_E2E_FOLIO'] ?? '') ?? 2999;
  final local = RegExp(r'^http://(127\.0\.0\.1|localhost):\d+$').hasMatch(url);
  final omitir = !local || correo.isEmpty || clave.isEmpty
      ? 'Solo contra un servidor local (AOLAB_CONTRATO_URL=http://127.0.0.1:<puerto>) con AOLAB_CONTRATO_CORREO y _CLAVE.'
      : null;

  TestWidgetsFlutterBinding.ensureInitialized();
  // El binding de flutter_test responde 400 a todo HTTP: esta prueba habla con el servidor de verdad.
  HttpOverrides.global = null;

  var red = 'wifi';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (_) async => [red]);

  final senal = _Senal();
  final carpeta = Directory.systemTemp.createTempSync('aolab-e2e');
  late AppDatabase db;
  late AuthService auth;
  late MediaService media;
  late AuditSyncService sync;
  late Dio oficina; // otra sesión, sin el corte de señal: lo que se hace en la web mientras la tablet está en terreno

  late String auditId;
  late Sistema sistema; // el sistema del maestro con puntos de nivel
  late PuntoControlDef pdRack; // el punto de nivel donde se anota la muestra con foto
  PuntoControlDef? pdSolo; // un punto de nivel sin muestras: la web y la tablet le anotan una cada una (1.6)
  late Evidencia foto;
  late int versionVista; // la versión que la tablet bajó antes de salir a terreno

  Future<Map<String, dynamic>> crudo(Dio d, String id) async {
    var cursor = 0;
    var mas = true;
    Map<String, dynamic>? r;
    while (mas) {
      final res = await d.get('/api/audits/pull', queryParameters: {'cursor': cursor, 'pageSize': 100});
      for (final x in (res.data['audits'] as List).cast<Map<String, dynamic>>()) {
        if (x['id'] == id) r = x;
      }
      cursor = res.data['cursor'] as int;
      mas = res.data['hasMore'] as bool;
    }
    if (r == null) fail('La evaluación $id no está en el pull.');
    return r;
  }

  List<Map<String, dynamic>> puntosCrudos(Map<String, dynamic> dto) => [
        for (final s in (dto['document']['salas'] as List).cast<Map<String, dynamic>>())
          ...(s['puntosControl'] as List).cast<Map<String, dynamic>>(),
      ];

  Map<String, dynamic>? puntoCrudo(Map<String, dynamic> dto, String id) {
    for (final p in puntosCrudos(dto)) {
      if (p['id'] == id) return p;
    }
    return null;
  }

  // Los pasos van en orden y cada uno parte de lo que dejó el anterior: si uno falla, los siguientes no corren (y no
  // escriben nada más en la copia).
  var roto = false;
  void paso(String nombre, Future<void> Function() cuerpo, {String? skip}) => test(nombre, () async {
        if (roto) fail('Falló un paso anterior.');
        try {
          await cuerpo();
        } catch (_) {
          roto = true;
          rethrow;
        }
      }, skip: skip);

  setUpAll(() async {
    if (omitir != null) return;
    databaseFactory = createDatabaseFactoryFfi(ffiInit: _abrirSqlite);
    await databaseFactory.setDatabasesPath('${carpeta.path}/db');
    final dio = Dio(BaseOptions(
      baseUrl: url,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      headers: {'Content-Type': 'application/json'},
    ));
    dio.interceptors.add(senal);
    db = AppDatabase();
    auth = AuthService(almacen: _Memoria(), dio: dio, conGoogle: false);
    media = MediaService(api: auth.api, carpeta: (Directory('${carpeta.path}/media')..createSync()).path)
      ..pausaEntreIntentos = Duration.zero;
    auth.datosLocales = _Tablet(db, media);
    sync = AuditSyncService(
      db: db,
      api: auth.api,
      masters: MasterSyncService(db: db, api: auth.api),
      media: media,
      alVencerSesion: auth.marcarVencida,
      sesionVencida: () => auth.sesionVencida,
    );
  });

  tearDownAll(() {
    if (carpeta.existsSync()) carpeta.deleteSync(recursive: true);
  });

  paso('1. entra con correo y clave (el servidor ofrece la clave)', () async {
    await auth.cargarEntradas();
    expect(auth.conClave, isTrue);
    expect(await auth.login(correo, clave), isNull);
    expect(auth.isAuthenticated, isTrue);
    oficina = Dio(BaseOptions(baseUrl: url, headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${auth.token}'}));
  }, skip: omitir);

  paso('2. baja los centros y las evaluaciones: el centro con puntos de nivel y la $folio compartida', () async {
    await sync.sync();
    expect(sync.lastError, isNull);
    expect(sync.status, SyncStatus.idle);

    final a = (await db.visibleAudits()).firstWhere((x) => x.folio == folio, orElse: () => fail('No bajó la $folio.'));
    auditId = a.id;
    versionVista = a.serverVersion;
    expect(a.compartida, isTrue, reason: 'la $folio está compartida con el cliente: se edita, se finaliza en la web');
    expect(a.dirty, isFalse);

    final centro = (await db.activeCenters()).firstWhere((c) => c.id == a.centerId, orElse: () => fail('No bajó su centro.'));
    // El sistema de la evaluación que ya tiene muestras con posición y su sistema del maestro.
    final sala = a.document.salas.firstWhere((s) => !s.isDeleted && s.puntosControl.any((p) => p.tieneNiveles),
        orElse: () => fail('La $folio no tiene muestras con posición.'));
    final m = sistemaDelMaestro(sala, centro.sistemas);
    if (m == null) fail('«${sala.name}» no está en el maestro de ${centro.name}: ${centro.sistemas.map((x) => x.nombre).join(', ')}');
    sistema = m;
    final deNivel = [for (final p in sistema.puntosControl) if (p.nivelPunto != null) p];
    expect(deNivel, isNotEmpty);

    // Las muestras con posición que ya tiene la evaluación se ven como muestras distintas y no se editan en la tablet.
    final conPosicion = [for (final p in sala.puntosControl) if (!p.isDeleted && p.tieneNiveles) p];
    expect(conPosicion.length, greaterThanOrEqualTo(3));
    expect(conPosicion.map((p) => p.id).toSet().length, conPosicion.length);
    expect(conPosicion.every((p) => !posicionEditable(p)), isTrue, reason: 'lo que ya está en el servidor se corrige en la web');

    // El punto con más de una muestra (Rack 17 y Rack 1) es donde se anota otra; uno sin muestras sirve para 1.6.
    pdRack = deNivel.firstWhere((pd) => muestrasDe(sala, pd).length >= 2 && pd.nivelPunto!.nivel == 1,
        orElse: () => deNivel.firstWhere((pd) => muestrasDe(sala, pd).isNotEmpty));
    for (final pd in deNivel) {
      if (pd.id != pdRack.id && muestrasDe(sala, pd).isEmpty) {
        pdSolo = pd;
        break;
      }
    }
    if (pdSolo == null) {
      // ignore: avoid_print
      print('Aviso: no queda un punto de nivel sin muestras en la $folio; el caso de dos muestras en paralelo no se prueba.');
    }
  }, skip: omitir);

  paso('3. en terreno sin señal: otra muestra con posición de rack, RPN, foto y el interruptor de la entrevista', () async {
    red = 'none';
    senal.sinRed = true;

    final a = (await db.findById(auditId))!;
    final sala = a.document.salas.firstWhere((s) => !s.isDeleted && esMismoSistema(s, sistema));
    final ng = pdRack.nivelPunto!;
    final ultima = muestrasDe(sala, pdRack).last;
    final nueva = otraMuestra(pdRack, ng, ultima: ultima, conEquipos: true, id: _idE2e('1'));
    expect(anotarNiveles(nueva, ng, NivelesMuestra.vacio.con(ng.nivel, TramosGrupo.medio, 'Rack 5')), isNull);
    expect(nueva.niveles!.single.numero, '5', reason: '«Rack 5» se guarda como 5, igual que en la web');
    nueva
      ..estadoOperacional = 2
      ..limpiezaBiofilm = 3
      ..impactoPeces = 1
      ..detectabilidad = 2;
    final origen = File('${carpeta.path}/camara.jpg')..writeAsBytesSync(_jpeg);
    foto = await media.guardarFoto(origen.path);
    nueva.fotos.add(foto);
    sala.puntosControl.add(nueva);

    // 1.6: la tablet le anota una muestra a un punto de nivel que no tenía; la web le anotará otra mientras tanto.
    if (pdSolo != null) {
      final ns = pdSolo!.nivelPunto!;
      final t = puntoDesdeMaestro(pdSolo!, id: _idE2e('2'), conEquipos: true);
      var n = NivelesMuestra.vacio;
      for (var k = 1; k <= ns.nivel; k++) {
        n = n.con(k, TramosGrupo.finalTramo, '${30 + k}');
      }
      expect(anotarNiveles(t, ns, n), isNull);
      sala.puntosControl.add(t);
    }

    a.document.entrevistaDesactivada = !(a.document.entrevistaDesactivada ?? false);
    a.updatedAtUtc = DateTime.now().toUtc();
    await db.upsertLocal(a);

    await sync.sync();
    expect(sync.status, SyncStatus.offline);
    final local = (await db.findById(auditId))!;
    expect(local.dirty, isTrue);
    expect(media.hasLocal(foto.id), isTrue);
    expect(await db.pendientesDeSubir(), 1);
  }, skip: omitir);

  paso('4. mientras tanto, la oficina agrega un comentario al informe y una muestra al punto sin muestras', () async {
    final dto = await crudo(oficina, auditId);
    expect(dto['serverVersion'], versionVista, reason: 'nada de la tablet llegó sin señal');
    final doc = dto['document'] as Map<String, dynamic>;
    doc['comentarios'] = [
      ...((doc['comentarios'] as List?) ?? const []),
      {'id': _comentarioOficina, 'texto': 'Comentario de la oficina (prueba de punta a punta)'},
    ];
    if (pdSolo != null) {
      final ns = pdSolo!.nivelPunto!;
      final salas = (doc['salas'] as List).cast<Map<String, dynamic>>();
      final s = salas.firstWhere((x) => x['masterId'] == sistema.id);
      final w = puntoDesdeMaestro(pdSolo!, id: _idE2e('3'), conEquipos: true);
      var n = NivelesMuestra.vacio;
      for (var k = 1; k <= ns.nivel; k++) {
        n = n.con(k, TramosGrupo.principio, '${20 + k}');
      }
      expect(anotarNiveles(w, ns, n), isNull);
      (s['puntosControl'] as List).add(w.toJson(ajenas: false));
    }
    dto['updatedAtUtc'] = DateTime.now().toUtc().toIso8601String();
    final r = await oficina.post('/api/audits/push', data: {'audits': [dto]});
    final res = (r.data['results'] as List).single as Map;
    expect(res['status'], 0, reason: '${res['message']}');
    expect((res['serverVersion'] as num).toInt(), greaterThan(versionVista));
  }, skip: omitir);

  paso('5. otro usuario no puede entrar en la tablet mientras quede algo sin subir (y no se borra nada)', () async {
    senal.sinRed = false;
    final almacen = _Memoria()..d['aolab_ultimo_email'] = 'otra.persona@ejemplo.invalid';
    final otro = AuthService(almacen: almacen, dio: Dio(BaseOptions(baseUrl: url)), conGoogle: false)
      ..datosLocales = _Tablet(db, media);
    await otro.loadSession(); // como al abrir la app: sabe quién la usó antes
    final err = await otro.login(correo, clave);
    expect(err, contains('sin subir'));
    expect(otro.isAuthenticated, isFalse);
    expect((await db.findById(auditId))!.dirty, isTrue);
    expect(media.hasLocal(foto.id), isTrue);
    senal.sinRed = true;
  }, skip: omitir);

  paso('6. vuelve la señal, pero no alcanza para la foto: lo anotado sube y la foto queda en la tablet', () async {
    red = 'wifi';
    senal
      ..sinRed = false
      ..sinFotos = true;
    await sync.sync();
    expect(sync.status, SyncStatus.error);
    expect(sync.lastError, contains('la señal no alcanzó'));

    final dto = await crudo(oficina, auditId);
    final doc = dto['document'] as Map<String, dynamic>;
    // Lo de la oficina sigue (la tablet traía una copia atrasada) y el interruptor de la tablet se aplicó.
    expect((doc['comentarios'] as List).map((c) => (c as Map)['id']), contains(_comentarioOficina));
    final antes = (await db.findById(auditId))!;
    expect(doc['entrevistaDesactivada'], antes.document.entrevistaDesactivada);
    // La muestra nueva llegó con su posición, su RPN y la foto anotada (todavía sin el archivo).
    final m = puntoCrudo(dto, _idE2e('1'))!;
    expect(m['masterId'], pdRack.id);
    expect(m['niveles'], [
      {'nivel': 1, 'posicion': 'medio', 'numero': '5'}
    ]);
    expect(m['nivelesEtiqueta'], contains('5 (medio)'));
    expect([m['estadoOperacional'], m['limpiezaBiofilm'], m['impactoPeces'], m['detectabilidad']], [2, 3, 1, 2]);
    final f = (m['fotos'] as List).cast<Map>().single;
    expect(f['id'], foto.id);
    expect(f['uploaded'], isFalse);
    // 1.6: la muestra de la web y la de la tablet del mismo punto quedan como dos, cada una con su posición.
    if (pdSolo != null) {
      final dos = puntosCrudos(dto).where((p) => p['masterId'] == pdSolo!.id && p['isDeleted'] != true).toList();
      expect(dos.map((p) => p['id']).toSet(), {_idE2e('2'), _idE2e('3')});
      expect(dos.map((p) => (p['niveles'] as List).first['posicion']).toSet(), {'final', 'principio'});
    }
    // Las muestras que ya estaban no cambiaron.
    final ya = puntosCrudos(dto).where((p) => p['niveles'] != null && !(p['id'] as String).startsWith(_uuidE2e)).length;
    expect(ya, greaterThanOrEqualTo(3));

    final local = (await db.findById(auditId))!;
    final enTablet = local.document.salas.expand((s) => s.puntosControl).firstWhere((p) => p.id == _idE2e('1'));
    expect(posicionEditable(enTablet), isFalse, reason: 'subió: desde ahora se corrige en la web');
    expect(evidenciasDe(local.document).firstWhere((e) => e.id == foto.id).uploaded, isFalse);
    expect(await db.pendientesDeSubir(), 1);
  }, skip: omitir);

  paso('7. con señal, la foto sube y vuelve con los mismos bytes; ya no queda nada pendiente', () async {
    senal.sinFotos = false;
    await sync.sync();
    expect(sync.lastError, isNull);
    expect(sync.status, SyncStatus.idle);
    // El ciclo siguiente baja lo que mezcló el servidor (ya nada pendiente).
    await sync.sync();
    expect(await db.pendientesDeSubir(), 0);

    final r = await oficina.get<List<int>>('/api/evidencias/${foto.id}', options: Options(responseType: ResponseType.bytes));
    expect(r.data, _jpeg);
    final m = puntoCrudo(await crudo(oficina, auditId), _idE2e('1'))!;
    expect(((m['fotos'] as List).single as Map)['uploaded'], isTrue);
    final local = (await db.findById(auditId))!;
    expect(local.dirty, isFalse);
    expect(local.document.comentariosDeLaOficina, isTrue);
  }, skip: omitir);

  paso('8. una posición ya subida que se cambia igual en la tablet no cambia la del servidor', () async {
    final a = (await db.findById(auditId))!;
    final p = a.document.salas.expand((s) => s.puntosControl).firstWhere((p) => p.id == _idE2e('1'));
    // La pantalla no lo deja (posicionEditable); aquí se fuerza para ver la regla del servidor.
    p.niveles = [PosicionNivel(nivel: 1, posicion: 'final', numero: '6')];
    p.nivelesEtiqueta = 'Rack 6 (final)';
    a.updatedAtUtc = DateTime.now().toUtc();
    await db.upsertLocal(a);
    await sync.sync();
    await sync.sync();
    expect(sync.lastError, isNull);
    final m = puntoCrudo(await crudo(oficina, auditId), _idE2e('1'))!;
    expect((m['niveles'] as List).single, {'nivel': 1, 'posicion': 'medio', 'numero': '5'});
    final local = (await db.findById(auditId))!;
    final enTablet = local.document.salas.expand((s) => s.puntosControl).firstWhere((p) => p.id == _idE2e('1'));
    expect(enTablet.nivelesMuestra.numero(1), '5', reason: 'la tablet vuelve a lo que tiene el servidor');
  }, skip: omitir);

  paso('9. una compartida no se finaliza desde la tablet: el estado no cambia y el envío queda retenido', () async {
    final a = (await db.findById(auditId))!;
    a.status = 1;
    a.updatedAtUtc = DateTime.now().toUtc();
    await db.upsertLocal(a);
    await sync.sync();
    expect(sync.avisos.join(' '), contains('web'));
    final dto = await crudo(oficina, auditId);
    expect(dto['status'], 0);
    await sync.sync();
    expect((await db.findById(auditId))!.status, 0, reason: 'la tablet vuelve al estado del servidor');
  }, skip: omitir);
}

extension on AuditDocument {
  /// ¿La copia de la tablet conserva lo que hizo la oficina (llaves que la app no edita, en `extra`)?
  bool get comentariosDeLaOficina => jsonEncode(toJson()).contains(_comentarioOficina);
}
