// Entrar y la sesión (PLAN F3): las tres formas (clave, Google, Microsoft), los errores en español, la sesión vencida que
// no borra nada, cerrar sesión sin perder lo local y el cambio de usuario, que con algo sin subir no deja entrar.
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'apoyo/servidor_falso.dart';

void main() {
  late ServidorFalso srv;
  late AlmacenEnMemoria almacen;
  late ExternoFalso google;
  late ExternoFalso microsoft;
  late DatosFalsos datos;

  AuthService nuevo({bool conMicrosoft = true}) => AuthService(
        almacen: almacen,
        dio: srv.dio(),
        google: google,
        microsoft: conMicrosoft ? microsoft : null,
      )..datosLocales = datos;

  setUp(() {
    srv = ServidorFalso();
    almacen = AlmacenEnMemoria();
    google = ExternoFalso(token: 'id-google');
    microsoft = ExternoFalso(token: 'id-ms');
    datos = DatosFalsos();
  });

  group('Entrar', () {
    test('con clave: guarda la sesión', () async {
      srv.responder('POST /api/auth/login', 200, tokenDe('evaluador.uno@ejemplo.cl'));
      final a = nuevo();
      expect(await a.login(' evaluador.uno@ejemplo.cl ', 'clave-larga'), isNull);
      expect(a.isAuthenticated, isTrue);
      expect(a.email, 'evaluador.uno@ejemplo.cl');
      expect(almacen.datos['aolab_jwt'], 'jwt-evaluador.uno@ejemplo.cl');
      expect(srv.pedidos.single.data, {'email': 'evaluador.uno@ejemplo.cl', 'password': 'clave-larga'});
    });

    test('con Microsoft: el idToken va a /api/auth/microsoft', () async {
      srv.responder('POST /api/auth/microsoft', 200, tokenDe('evaluador@ejemplo.cl'));
      final a = nuevo();
      expect(await a.loginWithMicrosoft(), isNull);
      expect(a.email, 'evaluador@ejemplo.cl');
      expect(srv.pedidos.single.data, {'idToken': 'id-ms'});
    });

    test('con Google: el idToken va a /api/auth/google', () async {
      srv.responder('POST /api/auth/google', 200, tokenDe('cliente@empresa.cl'));
      final a = nuevo();
      expect(await a.loginWithGoogle(), isNull);
      expect(a.email, 'cliente@empresa.cl');
    });

    test('cancelar Google o Microsoft no es un error ni deja sesión', () async {
      google.token = null;
      final a = nuevo();
      expect(await a.loginWithGoogle(), isNull);
      expect(a.isAuthenticated, isFalse);
      expect(srv.pedidos, isEmpty);
    });

    test('los errores salen en español y sin el texto de la librería', () async {
      final a = nuevo();
      srv.responder('POST /api/auth/login', 401, null);
      expect(await a.login('x@ejemplo.cl', 'mala'), 'Correo o contraseña incorrectos.');
      srv.responder('POST /api/auth/login', 403, {'message': 'Tu correo no está en la lista de acceso.'});
      expect(await a.login('x@ejemplo.cl', 'clave'), 'Tu correo no está en la lista de acceso.');
      srv.responder('POST /api/auth/login', 403, null);
      expect(await a.login('x@ejemplo.cl', 'clave'), 'Tu correo no está autorizado para ingresar.');
      srv.responder('POST /api/auth/login', 429, {'message': 'Demasiados intentos fallidos. Prueba de nuevo en unos minutos.'});
      expect(await a.login('x@ejemplo.cl', 'clave'), 'Demasiados intentos fallidos. Prueba de nuevo en unos minutos.');
      srv.responder('POST /api/auth/login', 500, null);
      expect(await a.login('x@ejemplo.cl', 'clave'), 'El servidor tuvo un problema (500). Prueba de nuevo en un rato.');
      srv.fallar('POST /api/auth/login', DioExceptionType.connectionTimeout);
      expect(await a.login('x@ejemplo.cl', 'clave'), 'El servidor no respondió a tiempo. Revisa la señal y prueba de nuevo.');
      srv.fallar('POST /api/auth/login', DioExceptionType.connectionError);
      final sinRed = await a.login('x@ejemplo.cl', 'clave');
      expect(sinRed, 'No se pudo conectar con el servidor. Revisa la conexión.');
      expect(sinRed, isNot(contains('Dio')));
      expect(await a.login('', ''), 'Escribe tu correo y tu contraseña.');
      srv.responder('POST /api/auth/microsoft', 401, null);
      expect(await a.loginWithMicrosoft(), 'No se pudo validar la cuenta de Microsoft.');
      google.error = PlatformException(code: 'sign_in_failed', message: 'ApiException: 10');
      expect(await a.loginWithGoogle(), 'No se pudo entrar con Google.');
      expect(a.isAuthenticated, isFalse);
    });
  });

  group('Con qué se puede entrar', () {
    test('el servidor nuevo dice sus formas; la app muestra solo esas', () async {
      srv.responder('GET /api/app/version', 200, {'minBuild': 0, 'entradas': ['integrado', 'microsoft']});
      final a = nuevo();
      await a.cargarEntradas();
      expect(a.conClave, isTrue);
      expect(a.conMicrosoft, isTrue);
      expect(a.conGoogle, isFalse);
      // Se recuerdan para abrir sin red.
      final otra = nuevo();
      await otra.loadSession();
      expect(otra.conMicrosoft, isTrue);
    });

    test('un servidor anterior no lo dice: clave y Google, como siempre', () async {
      srv.responder('GET /api/app/version', 200, {'minBuild': 0, 'message': 'x'});
      final a = nuevo();
      await a.cargarEntradas();
      expect(a.entradas, ['integrado', 'google']);
      expect(a.conMicrosoft, isFalse);
    });

    test('sin red y sin nada guardado: solo la clave', () async {
      srv.fallar('GET /api/app/version', DioExceptionType.connectionError);
      final a = nuevo();
      await a.cargarEntradas();
      expect(a.entradas, ['integrado']);
    });

    test('Microsoft no se ofrece si este build no tiene su retorno', () async {
      srv.responder('GET /api/app/version', 200, {'entradas': ['integrado', 'google', 'microsoft']});
      final a = nuevo(conMicrosoft: false);
      await a.cargarEntradas();
      expect(a.conMicrosoft, isFalse);
      expect(await a.loginWithMicrosoft(), isNotNull);
    });
  });

  group('Sesión y cambio de usuario', () {
    test('cerrar sesión no borra nada local y recuerda quién era', () async {
      srv.responder('POST /api/auth/login', 200, tokenDe('evaluador.uno@ejemplo.cl'));
      final a = nuevo();
      await a.login('evaluador.uno@ejemplo.cl', 'clave');
      await a.logout();
      expect(a.isAuthenticated, isFalse);
      expect(a.ultimoEmail, 'evaluador.uno@ejemplo.cl');
      expect(datos.borrados, 0);
      // La misma persona vuelve a entrar: nada se borra.
      datos.pendientesHoy = 3;
      expect(await a.login('evaluador.uno@ejemplo.cl', 'clave'), isNull);
      expect(datos.borrados, 0);
    });

    test('otro usuario con algo sin subir: no entra y no se borra nada', () async {
      almacen.datos['aolab_ultimo_email'] = 'evaluador.uno@ejemplo.cl';
      datos.pendientesHoy = 2;
      srv.responder('POST /api/auth/login', 200, tokenDe('evaluadora.dos@ejemplo.cl'));
      final a = nuevo();
      await a.loadSession();
      final err = await a.login('evaluadora.dos@ejemplo.cl', 'clave');
      expect(err, 'En esta tablet hay 2 evaluaciones de evaluador.uno@ejemplo.cl sin subir. '
          'Entra con esa cuenta y sincroniza antes de cambiar de usuario.');
      expect(a.isAuthenticated, isFalse);
      expect(almacen.datos.containsKey('aolab_jwt'), isFalse);
      expect(datos.borrados, 0);
    });

    test('otro usuario sin nada pendiente: la tablet queda limpia para él', () async {
      almacen.datos['aolab_ultimo_email'] = 'evaluador.uno@ejemplo.cl';
      srv.responder('POST /api/auth/microsoft', 200, tokenDe('Evaluadora.Dos@ejemplo.cl'));
      final a = nuevo();
      await a.loadSession();
      expect(await a.loginWithMicrosoft(), isNull);
      expect(datos.borrados, 1);
      expect(a.ultimoEmail, 'Evaluadora.Dos@ejemplo.cl');
      // Mayúsculas distintas son la misma persona.
      srv.responder('POST /api/auth/login', 200, tokenDe('evaluadora.dos@ejemplo.cl'));
      await a.login('evaluadora.dos@ejemplo.cl', 'clave');
      expect(datos.borrados, 1);
    });

    test('la sesión vencida se avisa, no borra nada y se vuelve a entrar con la misma cuenta', () async {
      srv.responder('POST /api/auth/login', 200, tokenDe('evaluador.uno@ejemplo.cl'));
      final a = nuevo();
      await a.login('evaluador.uno@ejemplo.cl', 'clave');
      a.marcarVencida();
      expect(a.sesionVencida, isTrue);
      expect(a.isAuthenticated, isTrue); // sigue en la lista, con lo local
      srv.responder('POST /api/auth/microsoft', 200, tokenDe('evaluador.uno@ejemplo.cl'));
      expect(await a.loginWithMicrosoft(), isNull);
      expect(microsoft.ultimoCorreo, 'evaluador.uno@ejemplo.cl'); // se propone la misma cuenta
      expect(a.sesionVencida, isFalse);
      expect(datos.borrados, 0);
    });
  });

  test('los errores de la sincronización salen en palabras del evaluador', () {
    final o = RequestOptions(path: '/api/audits/pull');
    expect(AuditSyncService.mensajeDeSync('Bajar', DioException(requestOptions: o, type: DioExceptionType.receiveTimeout)),
        'Bajar: el servidor no respondió a tiempo.');
    expect(
        AuditSyncService.mensajeDeSync(
            'Subir', DioException(requestOptions: o, response: Response(requestOptions: o, statusCode: 403))),
        'Tu cuenta no tiene acceso a la sincronización: la app es para el personal de AOLAB.');
    expect(
        AuditSyncService.mensajeDeSync(
            'Subir', DioException(requestOptions: o, response: Response(requestOptions: o, statusCode: 502))),
        'Subir: el servidor tuvo un problema (502).');
  });
}
