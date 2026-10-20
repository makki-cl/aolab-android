// Capturas de las pantallas principales con datos inventados, para revisar a ojo en el CT (no van al CI ni al repo: los
// PNG dependen de las fuentes y del render de cada máquina). Se generan con:
//   flutter test capturas_local --update-goldens
// y quedan en capturas_local/capturas/.
import 'dart:io';

import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/questionnaire.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/ui/audit_edit_screen.dart';
import 'package:aolab_android/ui/audit_list_screen.dart';
import 'package:aolab_android/ui/login_screen.dart';
import 'package:aolab_android/ui/tema.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../test/apoyo/base_falsa.dart';
import '../test/apoyo/servidor_falso.dart';
import '../test/modelo_hoy_test.dart' show centroDeMentira;
import '../test/terreno_test.dart' show docConPuntos;

Future<void> _fuentes() async {
  final dir = '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())));
  }
  await roboto.load();
  final iconos = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await iconos.load();
}

void main() {
  final centro = CenterRef.fromDto(centroDeMentira());
  setUpAll(_fuentes);
  setUp(sinPlugins);

  Future<AppDePrueba> montar(WidgetTester t, Widget pantalla, BaseEnMemoria db, {Size tamano = const Size(800, 1280)}) async {
    debugDisableShadows = false; // se vuelve a poner en captura()
    final app = AppDePrueba(db, ServidorFalso());
    app.template.template = QuestionnaireTemplate(code: 't', title: 'T', sections: []);
    t.view.physicalSize = tamano * 1.5;
    t.view.devicePixelRatio = 1.5;
    addTearDown(t.view.reset);
    await t.pumpWidget(app.montar(pantalla));
    await t.pumpAndSettle();
    return app;
  }

  BaseEnMemoria base() {
    final db = BaseEnMemoria([centro]);
    db.audits['e1'] = evaluacion(doc: docConPuntos())
      ..folio = 3021
      ..clientName = 'Cliente Demo';
    db.audits['nueva'] = evaluacion(id: 'nueva', status: 3, serverVersion: 0)
      ..centerName = '(sin nombre)'
      ..centerId = null
      ..dirty = true;
    db.audits['fin'] = evaluacion(id: 'fin', status: 1)
      ..folio = 3014
      ..clientName = 'Cliente Demo'
      ..dirty = false;
    db.audits['comp'] = evaluacion(id: 'comp', compartida: true)
      ..folio = 3002
      ..clientName = 'Cliente Demo'
      ..dirty = false;
    return db;
  }

  Future<void> pestana(WidgetTester t, String nombre) async {
    await t.tap(find.text(nombre));
    await t.pumpAndSettle();
  }

  // Con sombras de verdad (las pruebas las cambian por un borde negro) y sin la cinta de depuración.
  Future<void> captura(String nombre) async {
    final app = find.byType(MaterialApp).evaluate().single.widget as MaterialApp;
    expect(app.debugShowCheckedModeBanner, isFalse);
    try {
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('capturas/$nombre.png'));
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('01 lista', (t) async {
    await montar(t, const AuditListScreen(), base());
    await captura('01-lista');
  });

  testWidgets('02 sistemas', (t) async {
    await montar(t, const AuditEditScreen(auditId: 'e1'), base(), tamano: const Size(800, 1700));
    await pestana(t, 'Sistemas');
    await captura('02-sistemas');
  });

  testWidgets('03 muestreo', (t) async {
    await montar(t, const AuditEditScreen(auditId: 'e1'), base(), tamano: const Size(800, 1900));
    await pestana(t, 'Muestreo');
    await captura('03-muestreo');
  });

  testWidgets('04 rpn', (t) async {
    await montar(t, const AuditEditScreen(auditId: 'e1'), base(), tamano: const Size(800, 1600));
    await pestana(t, 'Evaluación RPN');
    await captura('04-rpn');
  });

  testWidgets('05 entrar', (t) async {
    final srv = ServidorFalso()..responder('GET /api/app/version', 200, {'minBuild': 0, 'entradas': ['integrado', 'google', 'microsoft']});
    final auth = AuthService(almacen: AlmacenEnMemoria(), dio: srv.dio(), google: ExternoFalso(), microsoft: ExternoFalso());
    t.view.physicalSize = const Size(800, 1280) * 1.5;
    t.view.devicePixelRatio = 1.5;
    addTearDown(t.view.reset);
    debugDisableShadows = false;
    await t.pumpWidget(ChangeNotifierProvider<AuthService>.value(
      value: auth,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: temaAolab(), home: const LoginScreen()),
    ));
    await t.pumpAndSettle();
    await captura('05-entrar');
  });
}
