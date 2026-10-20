// Pruebas de pantalla: la entrada con las formas que ofrece el servidor y el editor de la posición por nivel.
import 'package:aolab_android/models/niveles.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/ui/login_screen.dart';
import 'package:aolab_android/ui/niveles_muestra.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'apoyo/servidor_falso.dart';

void main() {
  group('Entrar', () {
    late ServidorFalso srv;
    late AuthService auth;

    Future<void> abrir(WidgetTester t, {List<String>? entradas, bool conMicrosoft = true}) async {
      srv = ServidorFalso();
      srv.responder('GET /api/app/version', 200, {'minBuild': 0, if (entradas != null) 'entradas': entradas});
      auth = AuthService(
        almacen: AlmacenEnMemoria(),
        dio: srv.dio(),
        google: ExternoFalso(token: 'g'),
        microsoft: conMicrosoft ? ExternoFalso(token: 'm') : null,
      );
      await t.pumpWidget(ChangeNotifierProvider<AuthService>.value(
        value: auth,
        child: const MaterialApp(home: LoginScreen()),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('con las tres formas del servidor se ven los tres botones', (t) async {
      await abrir(t, entradas: ['integrado', 'google', 'microsoft']);
      expect(find.byKey(const ValueKey('entrar-con-clave')), findsOneWidget);
      expect(find.text('Entrar con Google'), findsOneWidget);
      expect(find.text('Entrar con Microsoft'), findsOneWidget);
    });

    testWidgets('sin Google en el servidor (prod hoy) no aparece su botón', (t) async {
      await abrir(t, entradas: ['integrado', 'microsoft']);
      expect(find.text('Entrar con Google'), findsNothing);
      expect(find.text('Entrar con Microsoft'), findsOneWidget);
    });

    testWidgets('un build sin el retorno de Microsoft no lo ofrece', (t) async {
      await abrir(t, entradas: ['integrado', 'google', 'microsoft'], conMicrosoft: false);
      expect(find.text('Entrar con Microsoft'), findsNothing);
    });

    testWidgets('el error del servidor se muestra en español', (t) async {
      await abrir(t, entradas: ['integrado']);
      srv.responder('POST /api/auth/login', 403, {'message': 'Tu correo no está en la lista de acceso.'});
      await t.enterText(find.byKey(const ValueKey('entrar-correo')), 'alguien@ejemplo.cl');
      await t.enterText(find.byKey(const ValueKey('entrar-clave')), 'clave');
      await t.tap(find.byKey(const ValueKey('entrar-con-clave')));
      await t.pumpAndSettle();
      expect(find.text('Tu correo no está en la lista de acceso.'), findsOneWidget);
      expect(auth.isAuthenticated, isFalse);
    });

    testWidgets('con Microsoft se entra', (t) async {
      await abrir(t, entradas: ['integrado', 'microsoft']);
      srv.responder('POST /api/auth/microsoft', 200, tokenDe('evaluador@ejemplo.cl'));
      await t.tap(find.text('Entrar con Microsoft'));
      await t.pumpAndSettle();
      expect(auth.isAuthenticated, isTrue);
      expect(find.byKey(const ValueKey('entrar-error')), findsNothing);
    });
  });

  group('Posición por nivel', () {
    const rack = NivelGrupoDef(nivel: 1, nombre: 'Rack');
    const balde = NivelGrupoDef(nivel: 2, nombre: 'Balde', identifica: kIdentificaCodigo);
    const punto = NivelPunto(grupoId: 'g', nivel: 2, niveles: [rack, balde]);

    Future<List<NivelesMuestra>> abrir(WidgetTester t, {NivelesMuestra valor = NivelesMuestra.vacio, ReusoNiveles? reuso}) async {
      final emitidos = <NivelesMuestra>[];
      var actual = valor;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: NivelesMuestraEditor(
                punto: punto,
                value: actual,
                reuso: reuso,
                onChanged: (n) async {
                  emitidos.add(n);
                  setState(() => actual = n);
                },
              ),
            ),
          ),
        ),
      ));
      return emitidos;
    }

    testWidgets('una fila por nivel: la posición es obligatoria y se avisa la que falta', (t) async {
      final e = await abrir(t);
      expect(find.text('Rack'), findsOneWidget);
      expect(find.text('Balde'), findsOneWidget);
      expect(find.text('Falta la posición del rack: principio, medio o final.'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('nivel-pos-1-final')));
      await t.pump();
      expect(e.last, const NivelesMuestra(posicion1: 'final'));
      expect(find.text('Falta la posición del balde: principio, medio o final.'), findsOneWidget);
      // Tocar la misma la suelta.
      await t.tap(find.byKey(const ValueKey('nivel-pos-1-final')));
      await t.pump();
      expect(e.last, NivelesMuestra.vacio);
    });

    testWidgets('el número se normaliza al terminar de escribirlo; lo que no se entiende queda con su error', (t) async {
      final e = await abrir(t);
      await t.enterText(find.byKey(const ValueKey('nivel-num-1')), 'Rack 17');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(e.last, const NivelesMuestra(numero1: '17'));
      await t.enterText(find.byKey(const ValueKey('nivel-num-1')), 'R3');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(find.text('En Rack va un número: 1, 2, 3…'), findsOneWidget);
      expect(e.last, const NivelesMuestra(numero1: '17')); // no se guardó
    });

    testWidgets('un rack ya anotado en la evaluación completa su posición y sale como chip', (t) async {
      final reuso = ReusoNiveles([(grupoId: 'g', niveles: const NivelesMuestra(posicion1: 'final', numero1: '17'))]);
      final e = await abrir(t, reuso: reuso);
      expect(find.text('Rack 17 · Final'), findsOneWidget);
      await t.enterText(find.byKey(const ValueKey('nivel-num-1')), '17');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(e.last, const NivelesMuestra(posicion1: 'final', numero1: '17'));
      expect(find.textContaining('ya estaba anotado como Final'), findsOneWidget);
      // Otro número es otro rack: la posición que se completó sola se suelta.
      await t.enterText(find.byKey(const ValueKey('nivel-num-1')), '18');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(e.last, const NivelesMuestra(numero1: '18'));
    });

    testWidgets('el chip llena el número y la posición', (t) async {
      final reuso = ReusoNiveles([(grupoId: 'g', niveles: const NivelesMuestra(posicion1: 'medio', numero1: '4'))]);
      final e = await abrir(t, reuso: reuso);
      await t.tap(find.text('Rack 4 · Medio'));
      await t.pump();
      expect(e.last, const NivelesMuestra(posicion1: 'medio', numero1: '4'));
    });
  });
}
