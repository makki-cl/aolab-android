// En terreno con mala señal (PLAN F4): la foto y el audio aparecen al tiro y quedan en la tablet aunque no haya red; lo
// anotado y el audio en curso se guardan al salir; la foto que Android dejó perdida vuelve a su punto; quitar un punto
// del RPN pasa por la papelera; RPN y Muestreo van agrupados como la pestaña Sistemas; y la red se reintenta sin colgar.
import 'dart:convert';

import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/modelo_puntos.dart';
import 'package:aolab_android/services/api_client.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/evidencias_en_fila.dart';
import 'package:aolab_android/ui/audit_edit_screen.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoyo/base_falsa.dart';
import 'apoyo/servidor_falso.dart';
import 'modelo_hoy_test.dart' show centroDeMentira;

/// Incubación A con sus puntos marcados: dos muestras del rack (una con posición), el tramo, la entrada del UV y un punto
/// adicional, desordenados a propósito.
String docConPuntos() => jsonEncode({
      'center': {},
      'entrevistaDesactivada': true,
      'rpnDesactivado': false,
      'labDesactivado': false,
      'salas': [
        {
          'id': 'sala-inc', 'name': 'Incubación A', 'tipo': 'HATCHERY', 'fromMaster': true, 'masterId': 's-inc', 'etapa': 'HATCHERY',
          'answers': {},
          'puntosControl': [
            {'id': 'm-adhoc', 'nombre': 'Llave de muestreo', 'tipo': 'Otro', 'fromMaster': false, 'estadoOperacional': 2},
            {'id': 'm-rack-2', 'nombre': 'Racks · Rack · Salida', 'fromMaster': true, 'masterId': 'p-rack-s', 'equipoId': 'g-racks',
             'equipoAlias': 'Racks', 'grupo': 'equipo', 'correlativo': 3},
            {'id': 'm-tramo', 'nombre': 'POST Manifold', 'tipo': 'Estanque Cabecera', 'fromMaster': true, 'masterId': 'p-tramo',
             'equipoId': 'e-man', 'equipoAlias': 'Manifold', 'equipoTipo': 'Estanque Cabecera', 'grupo': 'tramo', 'correlativo': 2},
            {'id': 'm-rack-1', 'nombre': 'Racks · Rack · Salida', 'fromMaster': true, 'masterId': 'p-rack-s', 'equipoId': 'g-racks',
             'equipoAlias': 'Racks', 'grupo': 'equipo', 'correlativo': 4,
             'niveles': [{'nivel': 1, 'posicion': 'final', 'numero': '17'}], 'nivelesEtiqueta': 'Rack 17 (final)'},
            {'id': 'm-uv', 'nombre': 'UV · Entrada', 'tipo': 'Pre UV', 'fromMaster': true, 'masterId': 'p-uv-e', 'equipoId': 'e-uv',
             'equipoAlias': 'UV', 'grupo': 'equipo', 'correlativo': 1},
          ],
        },
      ],
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(sinPlugins);
  final centro = CenterRef.fromDto(centroDeMentira());
  final inc = centro.sistemas.firstWhere((s) => s.id == 's-inc');

  group('RPN y Muestreo agrupados como Sistemas', () {
    test('grupo › equipo › muestra en el orden del agua; lo adicional al final; ninguna se pierde', () {
      final a = evaluacion(doc: docConPuntos());
      final puntos = a.document.salas.single.puntosControl;
      final secs = agruparMuestras(puntos, inc);
      expect(secs.map((s) => s.titulo).toList(), ['Equipos', 'Tramos (PRE / POST)', 'Puntos adicionales']);
      expect(secs.first.bloques.map((b) => b.titulo).toList(), ['UV', 'Racks']);
      // Las dos muestras del rack, juntas y en el orden en que se anotaron.
      expect(secs.first.bloques[1].puntos.map((p) => p.id).toList(), ['m-rack-2', 'm-rack-1']);
      expect(secs.expand((s) => s.puntos).length, puntos.length);
    });

    test('un punto que el maestro ya no trae va aparte; sin maestro, todo junto y sin títulos', () {
      final huerfano = PuntoControl(id: 'x', nombre: 'Viejo', fromMaster: true, masterId: 'retirado');
      final secs = agruparMuestras([huerfano], inc);
      expect(secs.single.titulo, 'Fuera del modelo actual');
      final plano = agruparMuestras([huerfano, PuntoControl(id: 'y', nombre: 'Otro')], null);
      expect(plano.single.titulo, isNull);
      expect(plano.single.puntos, hasLength(2));
    });
  });

  group('La red se reintenta sin colgar', () {
    test('una consulta que no alcanzó a volver se reintenta y sale bien', () async {
      final srv = ServidorFalso();
      var veces = 0;
      srv.rutas['GET /api/audits/pull'] = (o) {
        veces++;
        if (veces < 3) return DioException(requestOptions: o, type: DioExceptionType.connectionTimeout);
        return (status: 200, body: {'audits': []});
      };
      final dio = srv.dio();
      dio.interceptors.add(Reintentos(dio, pausas: const [Duration.zero, Duration.zero]));
      final r = await dio.get('/api/audits/pull');
      expect(r.statusCode, 200);
      expect(veces, 3);
    });

    test('un envío (POST) no se reintenta: puede haber llegado', () async {
      final srv = ServidorFalso()..fallar('POST /api/audits/push', DioExceptionType.receiveTimeout);
      final dio = srv.dio();
      dio.interceptors.add(Reintentos(dio, pausas: const [Duration.zero, Duration.zero]));
      await expectLater(dio.post('/api/audits/push'), throwsA(isA<DioException>()));
      expect(srv.pedidos, hasLength(1));
    });

    test('sin señal para las fotos: la primera se intenta tres veces, las demás quedan para la próxima y se avisa', () async {
      final srv = ServidorFalso();
      final app = AppDePrueba(BaseEnMemoria([centro]), srv);
      final a = await app.media.guardarFoto(app.media.archivoDePrueba());
      final b = await app.media.guardarFoto(app.media.archivoDePrueba());
      srv.fallar('PUT /api/evidencias/${a.id}', DioExceptionType.connectionError);
      final subidas = await app.media.uploadPending([a, b]);
      expect(subidas, isEmpty);
      expect(app.media.sinRed, isTrue);
      expect(srv.pedidos.where((o) => o.path == '/api/evidencias/${a.id}'), hasLength(3));
      expect(srv.pedidos.where((o) => o.path == '/api/evidencias/${b.id}'), isEmpty);
      expect(AuditSyncService.mensajeDeSync('Fotos y audios', const SinSenal()),
          'Fotos y audios: la señal no alcanzó para subirlos. Quedan en la tablet y se suben en la próxima sincronización.');
    });

    test('con señal, la foto sube y se marca', () async {
      final srv = ServidorFalso();
      final app = AppDePrueba(BaseEnMemoria([centro]), srv);
      final a = await app.media.guardarFoto(app.media.archivoDePrueba());
      srv.responder('PUT /api/evidencias/${a.id}', 200, null);
      expect(await app.media.uploadPending([a]), {a.id});
      expect(a.uploaded, isTrue);
      expect(app.media.sinRed, isFalse);
    });
  });

  group('La foto que Android dejó perdida', () {
    test('vuelve al punto que estaba abierto y queda por subir', () async {
      final db = BaseEnMemoria([centro]);
      db.audits['e1'] = evaluacion(doc: docConPuntos());
      final app = AppDePrueba(db, ServidorFalso());
      await FotoEnCurso.anotar(db, 'e1', 'm-tramo');
      app.media.perdida = app.media.archivoDePrueba();
      final nombre = await FotoEnCurso.recuperar(db, app.media);
      expect(nombre, 'POST Manifold');
      final p = puntoPorId(db.audits['e1']!.document, 'm-tramo')!;
      expect(p.fotos, hasLength(1));
      expect(p.fotos.single.uploaded, isFalse);
      expect(app.media.hasLocal(p.fotos.single.id), isTrue);
      expect(db.audits['e1']!.dirty, isTrue);
      expect(db.kv[FotoEnCurso.llave], '');
    });

    test('sin foto perdida no se toca nada y la marca se limpia', () async {
      final db = BaseEnMemoria([centro]);
      db.audits['e1'] = evaluacion(doc: docConPuntos());
      final app = AppDePrueba(db, ServidorFalso());
      await FotoEnCurso.anotar(db, 'e1', 'm-tramo');
      expect(await FotoEnCurso.recuperar(db, app.media), isNull);
      expect(db.guardados, 0);
      expect(db.kv[FotoEnCurso.llave], '');
    });
  });

  group('La pantalla en terreno', () {
    late BaseEnMemoria db;
    late AppDePrueba app;
    late ServidorFalso srv;

    Future<void> abrir(WidgetTester t, {Size tamano = const Size(1000, 2600)}) async {
      db = BaseEnMemoria([centro]);
      db.audits['e1'] = evaluacion(doc: docConPuntos());
      srv = ServidorFalso(); // sin rutas de evidencias: el servidor «no responde» (404) y nada sube
      app = AppDePrueba(db, srv);
      t.view.physicalSize = tamano;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(app.montar(const AuditEditScreen(auditId: 'e1')));
      await t.pumpAndSettle();
    }

    Future<void> irA(WidgetTester t, String pestana) async {
      await t.ensureVisible(find.text(pestana));
      await t.pumpAndSettle();
      await t.tap(find.text(pestana));
      await t.pumpAndSettle();
    }

    // Cierra la pantalla (como volver atrás o que Android la saque).
    Future<void> salir(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
    }

    testWidgets('Muestreo y RPN: los grupos y los equipos en el orden del agua, sin desbordar', (t) async {
      await abrir(t, tamano: const Size(380, 2600));
      await irA(t, 'Muestreo');
      double y(String s) => t.getTopLeft(find.text(s).first).dy;
      expect(y('EQUIPOS'), lessThan(y('UV')));
      expect(y('UV'), lessThan(y('Racks')));
      expect(y('Racks'), lessThan(y('TRAMOS (PRE / POST)')));
      expect(y('TRAMOS (PRE / POST)'), lessThan(y('PUNTOS ADICIONALES')));
      expect(find.text('Rack 17 (final)'), findsOneWidget); // la posición subida, de solo lectura
      expect(t.takeException(), isNull);
      await irA(t, 'Evaluación RPN');
      expect(y('EQUIPOS'), lessThan(y('TRAMOS (PRE / POST)')));
      expect(find.text('Llave de muestreo'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('quitar un punto en el RPN pide confirmación, lo deja en la papelera y se restaura', (t) async {
      await abrir(t);
      await irA(t, 'Evaluación RPN');
      final quitar = find.descendant(
          of: find.byKey(const ValueKey('rpn-m-tramo')), matching: find.byTooltip('Quitar punto'));
      await t.tap(quitar);
      await t.pumpAndSettle();
      expect(find.text('Quitar punto'), findsWidgets); // el diálogo
      await t.tap(find.widgetWithText(FilledButton, 'Quitar'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rpn-m-tramo')), findsNothing);
      await t.pump(const Duration(seconds: 1));
      expect(puntoPorId(db.audits['e1']!.document, 'm-tramo')!.isDeleted, isTrue); // no se borró: va a la papelera
      await t.ensureVisible(find.text('Papelera (1)'));
      await t.pumpAndSettle();
      await t.tap(find.text('Papelera (1)'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Restaurar'));
      await t.pumpAndSettle();
      await t.tap(find.text('Restaurar'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('rpn-m-tramo')), findsOneWidget);
    });

    testWidgets('la foto aparece al tiro sin señal y queda en la tablet al salir', (t) async {
      await abrir(t);
      await irA(t, 'Evaluación RPN');
      final foto = find.descendant(of: find.byKey(const ValueKey('rpn-m-uv')), matching: find.text('Foto'));
      await t.ensureVisible(foto);
      await t.pumpAndSettle();
      await t.tap(foto);
      await t.pumpAndSettle();
      await t.tap(find.text('Tomar foto'));
      await t.pumpAndSettle();
      expect(app.media.fotosTomadas, 1);
      expect(find.byTooltip('Falta subir'), findsWidgets);
      await salir(t);
      final p = puntoPorId(db.audits['e1']!.document, 'm-uv')!;
      expect(p.fotos, hasLength(1));
      expect(p.fotos.single.uploaded, isFalse); // la sube la sincronización
      expect(app.media.hasLocal(p.fotos.single.id), isTrue);
      expect(db.kv[FotoEnCurso.llave], ''); // la cámara volvió: no queda nada por recuperar
    });

    testWidgets('lo escrito 100 ms antes de salir queda guardado', (t) async {
      await abrir(t);
      await irA(t, 'Evaluación RPN');
      await t.enterText(find.byKey(const ValueKey('pcom-m-uv')), 'Biofilm en la llave');
      await t.pump(const Duration(milliseconds: 100));
      await salir(t);
      expect(puntoPorId(db.audits['e1']!.document, 'm-uv')!.comentario, 'Biofilm en la llave');
    });

    testWidgets('un audio que se está grabando al salir se detiene y se guarda en su punto', (t) async {
      await abrir(t);
      await irA(t, 'Evaluación RPN');
      final audio = find.descendant(of: find.byKey(const ValueKey('rpn-m-uv')), matching: find.text('Audio'));
      await t.ensureVisible(audio);
      await t.pumpAndSettle();
      await t.tap(audio);
      await t.pump();
      expect(app.media.grabandoAhora, isTrue);
      await salir(t);
      final p = puntoPorId(db.audits['e1']!.document, 'm-uv')!;
      expect(p.audios, hasLength(1));
      expect(p.audios.single.uploaded, isFalse);
    });

    testWidgets('sin centro, el aviso lleva a Identificación', (t) async {
      db = BaseEnMemoria([centro]);
      final a = evaluacion(doc: docConPuntos())..centerId = null;
      db.audits['e1'] = a;
      app = AppDePrueba(db, ServidorFalso());
      t.view.physicalSize = const Size(1000, 2000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(app.montar(const AuditEditScreen(auditId: 'e1')));
      await t.pumpAndSettle();
      await irA(t, 'Sistemas');
      expect(find.text('Falta el centro'), findsOneWidget);
      await t.tap(find.text('Elegir'));
      await t.pumpAndSettle();
      expect(find.text('Tipo de evaluación'), findsOneWidget); // Identificación
    });
  });
}
