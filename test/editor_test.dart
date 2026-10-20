// La pantalla de la evaluación con el modelo de hoy: sistemas por tipo (como la lista lateral del editor), sin la ficha
// «Dulce», nombres con el tipo debajo, varias muestras de un punto de nivel con su posición, y una evaluación compartida
// que se edita pero no se finaliza en la tablet. Con una base en memoria (sin SQLite) y sin plugins.
import 'dart:convert';
import 'dart:io';

import 'package:aolab_android/data/app_database.dart';
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/questionnaire.dart';
import 'package:aolab_android/services/api_client.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/services/master_sync_service.dart';
import 'package:aolab_android/services/media_service.dart';
import 'package:aolab_android/services/template_service.dart';
import 'package:aolab_android/ui/audit_edit_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'apoyo/servidor_falso.dart';
import 'modelo_hoy_test.dart' show centroDeMentira;

class BaseEnMemoria extends AppDatabase {
  final Map<String, Audit> audits = {};
  final List<CenterRef> centros;
  int guardados = 0;
  BaseEnMemoria(this.centros);

  Audit _copia(Audit a) => Audit.fromRow(a.toRow());

  @override
  Future<Audit?> findById(String id) async => audits[id] == null ? null : _copia(audits[id]!);
  @override
  Future<List<ClientRef>> activeClients() async => [];
  @override
  Future<List<CenterRef>> activeCenters() async => centros;
  @override
  Future<List<UserRef>> allUsers() async => [];
  @override
  Future<Map<String, List<String>>> getCatalogs() async => {};
  @override
  Future<void> upsertLocal(Audit a, {bool markDirty = true}) async {
    if (markDirty) a.dirty = true;
    a.localRev++;
    audits[a.id] = _copia(a);
    guardados++;
  }
}

class EvidenciasSinPlugin extends MediaService {
  EvidenciasSinPlugin(ApiClient api) : super(api: api);
  @override
  Future<String> dirPath() async => Directory.systemTemp.path;
}

Audit evaluacion({bool compartida = false}) {
  final now = DateTime.utc(2026, 10, 20, 12);
  final d = jsonDecode('''{
    "id": "e1", "status": 0, "type": 0, "centerName": "Centro Demo", "centerId": "c0000000-0000-0000-0000-000000000001",
    "createdAtUtc": "${now.toIso8601String()}", "updatedAtUtc": "${now.toIso8601String()}", "serverVersion": 4,
    ${compartida ? '"sharedWithClientUtc": "2026-10-18T14:03:11.123456+00:00",' : ''}
    "document": {"center": {}, "salas": [], "entrevistaDesactivada": true, "rpnDesactivado": false, "labDesactivado": false}
  }''') as Map<String, dynamic>;
  return Audit.fromDto(d);
}

void main() {
  late BaseEnMemoria db;

  setUp(() {
    // audioplayers y record hablan con Android: aquí no hay, se responde vacío.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
  });

  Future<void> abrir(WidgetTester t, Audit a, {Size tamano = const Size(1200, 2400)}) async {
    db = BaseEnMemoria([CenterRef.fromDto(centroDeMentira())]);
    db.audits[a.id] = a;
    final srv = ServidorFalso();
    final auth = AuthService(almacen: AlmacenEnMemoria(), dio: srv.dio(), google: ExternoFalso());
    final media = EvidenciasSinPlugin(auth.api);
    final template = TemplateService(db: db, api: auth.api)
      ..template = QuestionnaireTemplate(code: 't', title: 'T', sections: []);
    final sync = AuditSyncService(db: db, api: auth.api, masters: MasterSyncService(db: db, api: auth.api), media: media);
    t.view.physicalSize = tamano;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<TemplateService>.value(value: template),
        ChangeNotifierProvider<AuditSyncService>.value(value: sync),
        Provider<MediaService>.value(value: media),
      ],
      child: MaterialApp(home: AuditEditScreen(auditId: a.id)),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('Sistemas: por tipo, con su ficha y sin «Dulce»', (t) async {
    await abrir(t, evaluacion());
    await t.tap(find.text('Sistemas'));
    await t.pumpAndSettle();
    final orden = ['AFLUENTE', 'TRATAMIENTO DE AGUA', 'PROCESO DE SALMÓN', 'TRATAMIENTO DE SALMÓN', 'EFLUENTE'];
    final ys = [for (final o in orden) t.getTopLeft(find.text(o)).dy];
    expect([...ys]..sort(), ys);
    expect(find.text('Hatchery'), findsOneWidget);
    expect(find.text('Noria'), findsWidgets);
    expect(find.text('Dulce'), findsNothing);
  });

  testWidgets('un punto de nivel: el tipo debajo, la posición y «+ Otro rack»', (t) async {
    await abrir(t, evaluacion());
    await t.tap(find.text('Sistemas'));
    await t.pumpAndSettle();
    // Marcar el sistema y el punto de nivel.
    Finder casilla(String texto) =>
        find.descendant(of: find.ancestor(of: find.text(texto), matching: find.byType(Row)).first, matching: find.byType(Checkbox));
    await t.tap(casilla('Incubación A'));
    await t.pumpAndSettle();
    expect(find.text('POST Manifold'), findsOneWidget);
    expect(find.text('Estanque Cabecera'), findsOneWidget); // el tipo de su equipo, debajo
    await t.tap(casilla('Racks · Rack · Salida'));
    await t.pumpAndSettle();
    expect(find.text('Falta la posición del rack: principio, medio o final.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('nivel-pos-1-final')).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Otro rack'));
    await t.pumpAndSettle();
    // Se guardó: la evaluación tiene dos muestras del mismo punto, la primera con su posición.
    await t.pump(const Duration(seconds: 1));
    final doc = db.audits['e1']!.document;
    final muestras = doc.salas.single.puntosControl.where((p) => p.masterId == 'p-rack-s' && !p.isDeleted).toList();
    expect(muestras, hasLength(2));
    expect(muestras.first.nivelesEtiqueta, 'Rack (final)');
    expect(muestras.first.nivelesLocal, isTrue);
  });

  testWidgets('una evaluación compartida con el cliente se edita, pero se finaliza en la web', (t) async {
    await abrir(t, evaluacion(compartida: true));
    expect(find.text('Finalizar'), findsNothing);
    expect(find.text('Compartida con el cliente: se finaliza en la web'), findsOneWidget);
  });

  testWidgets('una no compartida se puede finalizar', (t) async {
    await abrir(t, evaluacion());
    expect(find.text('Finalizar'), findsOneWidget);
  });

  testWidgets('en un teléfono angosto nada se desborda (sistemas, muestras, RPN y muestreo)', (t) async {
    await abrir(t, evaluacion(), tamano: const Size(360, 780));
    await t.tap(find.text('Sistemas'));
    await t.pumpAndSettle();
    Finder casilla(String texto) =>
        find.descendant(of: find.ancestor(of: find.text(texto), matching: find.byType(Row)).first, matching: find.byType(Checkbox));
    await t.tap(casilla('Incubación A'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('Racks · Balde · Entrada'), 300, scrollable: find.byType(Scrollable).last);
    await t.tap(casilla('Racks · Balde · Entrada'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.text('Muestreo'));
    await t.pumpAndSettle();
    expect(find.textContaining('Racks · Balde · Entrada'), findsWidgets);
    expect(t.takeException(), isNull);
    await t.tap(find.text('Evaluación RPN'));
    await t.pumpAndSettle();
    expect(find.text('Racks · Balde · Entrada'), findsWidgets);
    expect(t.takeException(), isNull);
  });
}
