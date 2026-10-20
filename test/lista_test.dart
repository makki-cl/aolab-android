// La lista de evaluaciones (PLAN F4.1 y F5): sale al tiro desde la tablet aunque el servidor tarde, títulos con centro y
// fecha, filtro por estado, borrar una Agendada creada por error y la barra de la sincronización en palabras del
// evaluador.
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/evidencias_en_fila.dart';
import 'package:aolab_android/ui/audit_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoyo/base_falsa.dart';
import 'apoyo/servidor_falso.dart';
import 'modelo_hoy_test.dart' show centroDeMentira;
import 'terreno_test.dart' show docConPuntos;

void main() {
  final centro = CenterRef.fromDto(centroDeMentira());
  late BaseEnMemoria db;
  late ServidorFalso srv;
  late AppDePrueba app;

  setUp(sinPlugins);

  Future<void> abrir(WidgetTester t, {bool settle = true}) async {
    app = AppDePrueba(db, srv, conPlantilla: false);
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(app.montar(const AuditListScreen()));
    if (settle) await t.pumpAndSettle();
  }

  void tres() {
    db = BaseEnMemoria([centro]);
    final nueva = evaluacion(id: 'nueva', status: 3, serverVersion: 0)
      ..centerName = '(sin nombre)'
      ..centerId = null
      ..dirty = true;
    db.audits['nueva'] = nueva;
    db.audits['curso'] = evaluacion(id: 'curso', status: 0)..folio = 3002;
    db.audits['fin'] = evaluacion(id: 'fin', status: 1);
    db.audits['agendada-servidor'] = evaluacion(id: 'agendada-servidor', status: 3, serverVersion: 7);
    srv = ServidorFalso();
  }

  testWidgets('la lista sale desde la tablet aunque la plantilla tarde en llegar', (t) async {
    tres();
    srv.demoras['GET /api/questionnaire/template'] = const Duration(seconds: 30);
    await abrir(t, settle: false);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('ev-curso')), findsOneWidget);
    await t.pump(const Duration(seconds: 31)); // termina la consulta lenta
    await t.pumpAndSettle();
  });

  testWidgets('títulos con centro y fecha; una nueva dice «Evaluación nueva»', (t) async {
    tres();
    await abrir(t);
    expect(find.text('Evaluación nueva · 20-10-2026'), findsOneWidget);
    expect(find.text('Centro Demo · 20-10-2026'), findsNWidgets(3));
    expect(find.textContaining('Sin cliente'), findsNothing);
    expect(find.textContaining('Folio 3002'), findsOneWidget);
  });

  testWidgets('filtro por estado', (t) async {
    tres();
    await abrir(t);
    expect(find.text('Agendadas (2)'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('filtro-finalizadas')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ev-fin')), findsOneWidget);
    expect(find.byKey(const ValueKey('ev-curso')), findsNothing);
    await t.tap(find.byKey(const ValueKey('filtro-enCurso')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ev-curso')), findsOneWidget);
    expect(find.byKey(const ValueKey('ev-fin')), findsNothing);
  });

  testWidgets('solo una Agendada que nunca subió se puede borrar, y con confirmación', (t) async {
    tres();
    await abrir(t);
    expect(find.byKey(const ValueKey('menu-nueva')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-agendada-servidor')), findsNothing);
    expect(find.byKey(const ValueKey('menu-curso')), findsNothing);
    await t.tap(find.byKey(const ValueKey('menu-nueva')));
    await t.pumpAndSettle();
    await t.tap(find.text('Borrar'));
    await t.pumpAndSettle();
    expect(find.text('Borrar evaluación'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Borrar'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('ev-nueva')), findsNothing);
    expect(db.audits['nueva']!.isDeleted, isTrue);
    expect(db.audits['nueva']!.dirty, isTrue); // el envío se lo avisa al servidor, por si alcanzó a llegar
  });

  testWidgets('sin señal, la barra lo dice con lo que queda por subir', (t) async {
    tres();
    await abrir(t);
    expect(find.text('Sin señal · 1 evaluación por subir: quedan guardadas en la tablet'), findsOneWidget);
  });

  testWidgets('la foto que Android dejó perdida se recupera al abrir y se avisa', (t) async {
    db = BaseEnMemoria([centro]);
    db.audits['e1'] = evaluacion(doc: docConPuntos());
    srv = ServidorFalso();
    db.kv[FotoEnCurso.llave] = '{"a":"e1","p":"m-tramo"}';
    app = AppDePrueba(db, srv, conPlantilla: false);
    app.media.perdida = app.media.archivoDePrueba();
    await t.runAsync(() async {
      await t.pumpWidget(app.montar(const AuditListScreen()));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pumpAndSettle();
    expect(find.text('Se recuperó la foto de «POST Manifold».'), findsOneWidget);
  });

  group('La barra de la sincronización', () {
    String texto(SyncStatus s, {int pendientes = 0, String? error, DateTime? hora}) =>
        StatusBarSync(status: s, pending: pendientes, lastError: error, lastSyncAt: hora).estado.$1;

    test('en palabras del evaluador', () {
      expect(texto(SyncStatus.idle), 'Todo sincronizado');
      expect(texto(SyncStatus.idle, hora: DateTime(2026, 10, 20, 9, 5)), 'Todo sincronizado · 09:05');
      expect(texto(SyncStatus.idle, pendientes: 2), '2 evaluaciones por subir');
      expect(texto(SyncStatus.offline), 'Sin señal');
      expect(texto(SyncStatus.error, error: AuditSyncService.kSesionVencida), 'Sesión vencida: entra de nuevo para sincronizar');
      expect(texto(SyncStatus.error, pendientes: 1, error: 'Subir: el servidor no respondió a tiempo.'),
          'No se pudo sincronizar todo · 1 evaluación por subir · toca para ver por qué');
    });
  });

  test('una evaluación sin centro todavía se titula «Evaluación nueva»', () {
    expect(Audit(id: 'x', createdAtUtc: DateTime.utc(2026), updatedAtUtc: DateTime.utc(2026), document: AuditDocument.nueva()).tituloCentro,
        'Evaluación nueva');
  });
}
