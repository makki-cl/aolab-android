import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config.dart';
import 'api_client.dart';

/// Las formas de entrar que puede ofrecer el servidor (`/api/app/version` → `entradas`, desde el 20-10-2026).
const String kEntradaClave = 'integrado';
const String kEntradaGoogle = 'google';
const String kEntradaMicrosoft = 'microsoft';

/// Dónde se guarda la sesión. En la tablet, el almacenamiento seguro de Android; en las pruebas, un mapa.
abstract class AlmacenSesion {
  Future<String?> leer(String llave);
  Future<void> escribir(String llave, String valor);
  Future<void> borrar(String llave);
}

class AlmacenSeguro implements AlmacenSesion {
  final FlutterSecureStorage _s;
  AlmacenSeguro([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  @override
  Future<String?> leer(String llave) => _s.read(key: llave);
  @override
  Future<void> escribir(String llave, String valor) => _s.write(key: llave, value: valor);
  @override
  Future<void> borrar(String llave) => _s.delete(key: llave);
}

/// Un inicio de sesión de afuera (Google, Microsoft) que entrega el idToken que el servidor valida. Null = se canceló.
abstract class InicioExterno {
  Future<String?> idToken({String? correo});
  Future<void> salir();
}

/// Google nativo: el idToken sale con la audiencia del cliente web (serverClientId), que es el que valida el servidor.
class InicioGoogle implements InicioExterno {
  final GoogleSignIn _google = GoogleSignIn(scopes: const ['email'], serverClientId: AppConfig.googleWebClientId);

  @override
  Future<String?> idToken({String? correo}) async {
    final cuenta = await _google.signIn();
    if (cuenta == null) return null;
    final t = (await cuenta.authentication).idToken;
    if (t == null) throw const FalloInicio('No se obtuvo el token de Google.');
    return t;
  }

  @override
  Future<void> salir() => _google.signOut();
}

/// Microsoft (Entra, registro «AOLAB Inicio de sesión»): código con PKCE en el navegador del sistema y retorno
/// msauth://, que recibe la actividad de AppAuth. El idToken tiene la audiencia del registro; el servidor lo valida igual
/// que la web (firma, emisor de la organización, sin cuentas personales).
class InicioMicrosoft implements InicioExterno {
  final String redirect;
  final FlutterAppAuth _appAuth;

  InicioMicrosoft(this.redirect, [FlutterAppAuth? appAuth]) : _appAuth = appAuth ?? const FlutterAppAuth();

  @override
  Future<String?> idToken({String? correo}) async {
    try {
      final r = await _appAuth.authorizeAndExchangeCode(AuthorizationTokenRequest(
        AppConfig.microsoftClientId,
        redirect,
        discoveryUrl: AppConfig.microsoftDiscoveryUrl,
        scopes: const ['openid', 'profile', 'email'],
        loginHint: correo,
        promptValues: const ['select_account'],
      ));
      final t = r.idToken;
      if (t == null || t.isEmpty) throw const FalloInicio('Microsoft no entregó la identidad de la cuenta.');
      return t;
    } on FlutterAppAuthUserCancelledException {
      return null;
    }
  }

  // El navegador del sistema guarda su propia sesión de Microsoft; la de la app es el JWT del servidor.
  @override
  Future<void> salir() async {}
}

/// Lo que hay en la tablet de la sesión anterior: si queda algo sin subir, no se puede cambiar de usuario.
abstract class DatosLocales {
  /// Cuántas evaluaciones tienen algo que todavía no está en el servidor.
  Future<int> pendientes();

  /// Borra lo local del usuario anterior (solo con [pendientes] en 0).
  Future<void> borrarTodo();
}

/// Un error al entrar, ya en palabras del evaluador.
class FalloInicio implements Exception {
  final String mensaje;
  const FalloInicio(this.mensaje);
  @override
  String toString() => mensaje;
}

/// El mensaje para el evaluador de un error al entrar. Null si se canceló (no hay nada que decir).
String? mensajeDeInicio(Object e, {required String forma}) {
  if (e is FalloInicio) return e.mensaje;
  if (e is FlutterAppAuthUserCancelledException) return null;
  if (e is DioException) {
    final code = e.response?.statusCode;
    final msg = _mensajeDelServidor(e);
    if (code == 401) {
      return switch (forma) {
        kEntradaGoogle => 'No se pudo validar la cuenta de Google.',
        kEntradaMicrosoft => 'No se pudo validar la cuenta de Microsoft.',
        _ => 'Correo o contraseña incorrectos.',
      };
    }
    // 403: el correo no está en la lista de acceso (o la cuenta es de otra organización). 429: la cuenta se bloquea
    // unos minutos tras varios intentos fallidos.
    if (code == 403) return msg ?? 'Tu correo no está autorizado para ingresar.';
    if (code == 429) return msg ?? 'Demasiados intentos fallidos. Prueba de nuevo en unos minutos.';
    if (code != null) return 'El servidor tuvo un problema ($code). Prueba de nuevo en un rato.';
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout =>
        'El servidor no respondió a tiempo. Revisa la señal y prueba de nuevo.',
      _ => 'No se pudo conectar con el servidor. Revisa la conexión.',
    };
  }
  if (e is PlatformException) {
    if (e.code == 'sign_in_canceled') return null;
    if (e.code == 'network_error') return 'Sin conexión: no se pudo abrir el inicio de sesión.';
    return switch (forma) {
      kEntradaGoogle => 'No se pudo entrar con Google.',
      kEntradaMicrosoft => 'No se pudo entrar con Microsoft.',
      _ => 'No se pudo iniciar sesión. Prueba de nuevo.',
    };
  }
  return 'No se pudo iniciar sesión. Prueba de nuevo.';
}

String? _mensajeDelServidor(DioException e) {
  final data = e.response?.data;
  if (data is Map && data['message'] is String && (data['message'] as String).trim().isNotEmpty) {
    return (data['message'] as String).trim();
  }
  return null;
}

/// Maneja la sesión: entrar con correo y clave, Google o Microsoft (los que ofrece el servidor), guardar el JWT en el
/// almacenamiento seguro y exponerlo para que ApiClient lo adjunte. Es un ChangeNotifier para que la UI reaccione.
///
/// Reglas de terreno:
/// - Una sesión vencida (401) NO borra nada: la app sigue con lo local y pide entrar de nuevo para sincronizar.
/// - Cerrar sesión no borra nada local.
/// - Entrar con OTRO usuario solo borra lo local si no queda nada sin subir; si queda, no deja entrar (el anterior tiene
///   que sincronizar antes). Así nunca se pierde lo de terreno ni se mezclan los datos de dos personas.
class AuthService extends ChangeNotifier {
  static const _tokenKey = 'aolab_jwt';
  static const _emailKey = 'aolab_email';
  static const _ultimoKey = 'aolab_ultimo_email';
  static const _entradasKey = 'aolab_entradas';

  final AlmacenSesion _almacen;
  late final ApiClient api;
  final InicioExterno? google;
  final InicioExterno? microsoft;

  /// Se asigna al arrancar (necesita la base y las evidencias, que a su vez usan [api]).
  DatosLocales? datosLocales;

  String? _token;
  String? _email;
  String? _ultimoEmail;
  bool _vencida = false;
  List<String> _entradas = const [kEntradaClave];

  AuthService({AlmacenSesion? almacen, Dio? dio, InicioExterno? google, this.microsoft, bool conGoogle = true})
      : _almacen = almacen ?? AlmacenSeguro(),
        google = google ?? (conGoogle ? InicioGoogle() : null) {
    // ApiClient lee el token vigente en cada request mediante este callback.
    api = ApiClient(getToken: () => _token, dio: dio);
  }

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  String? get email => _email;
  String? get token => _token;

  /// El servidor rechazó el token (venció): hay que entrar de nuevo para sincronizar. Lo local sigue intacto.
  bool get sesionVencida => _vencida;

  /// Quién usó la tablet la última vez (también después de cerrar sesión).
  String? get ultimoEmail => _ultimoEmail;

  List<String> get entradas => _entradas;
  bool get conClave => _entradas.contains(kEntradaClave);
  bool get conGoogle => google != null && _entradas.contains(kEntradaGoogle);
  bool get conMicrosoft => microsoft != null && _entradas.contains(kEntradaMicrosoft);

  /// Restaura una sesión previa (token guardado) al iniciar la app.
  Future<void> loadSession() async {
    _token = await _almacen.leer(_tokenKey);
    _email = await _almacen.leer(_emailKey);
    _ultimoEmail = await _almacen.leer(_ultimoKey) ?? _email;
    final e = await _almacen.leer(_entradasKey);
    if (e != null) {
      try {
        _entradas = [for (final x in jsonDecode(e) as List) x.toString()];
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Pregunta al servidor con qué se puede entrar. Un servidor anterior al 20-10 no lo dice: ahí la app ofrece lo de
  /// siempre (clave y Google). Sin red, lo último que se supo.
  Future<void> cargarEntradas() async {
    try {
      final res = await api.dio.get('/api/app/version', options: Options(receiveTimeout: const Duration(seconds: 10)));
      final data = res.data;
      final l = data is Map && data['entradas'] is List
          ? [for (final x in data['entradas'] as List) x.toString()]
          : const [kEntradaClave, kEntradaGoogle];
      _entradas = l;
      await _almacen.escribir(_entradasKey, jsonEncode(l));
      notifyListeners();
    } catch (_) {/* sin red: se queda con lo guardado */}
  }

  /// Login con correo/contraseña. Devuelve null si OK, o un mensaje de error.
  Future<String?> login(String email, String password) => _intentar(kEntradaClave, () async {
        if (email.trim().isEmpty || password.isEmpty) throw const FalloInicio('Escribe tu correo y tu contraseña.');
        final res = await api.dio.post('/api/auth/login', data: {'email': email.trim(), 'password': password});
        return (res.data as Map).cast<String, dynamic>();
      }, correo: email.trim());

  /// Login con Google. Devuelve null si OK (o si se canceló), o un mensaje de error.
  Future<String?> loginWithGoogle() => _externo(kEntradaGoogle, google, '/api/auth/google');

  /// Login con Microsoft. Devuelve null si OK (o si se canceló), o un mensaje de error.
  Future<String?> loginWithMicrosoft() => _externo(kEntradaMicrosoft, microsoft, '/api/auth/microsoft');

  Future<String?> _externo(String forma, InicioExterno? proveedor, String ruta) async {
    if (proveedor == null) return 'Esta versión de la app no tiene esa forma de entrar.';
    final r = await _intentar(forma, () async {
      final t = await proveedor.idToken(correo: _vencida ? _email : null);
      if (t == null) return null; // se canceló
      final res = await api.dio.post(ruta, data: {'idToken': t});
      return (res.data as Map).cast<String, dynamic>();
    });
    // Si no se entró, la cuenta elegida no queda recordada (la próxima vez se vuelve a elegir).
    if (r != null || !isAuthenticated) {
      try {
        await proveedor.salir();
      } catch (_) {}
    }
    return r;
  }

  Future<String?> _intentar(String forma, Future<Map<String, dynamic>?> Function() entrar, {String? correo}) async {
    try {
      final data = await entrar();
      if (data == null) return null; // cancelado
      return await _entrar(data, fallbackEmail: correo ?? '');
    } catch (e) {
      return mensajeDeInicio(e, forma: forma);
    }
  }

  /// Con la respuesta del servidor: revisa el cambio de usuario y guarda la sesión. Devuelve el error, o null.
  Future<String?> _entrar(Map<String, dynamic> data, {required String fallbackEmail}) async {
    final token = data['accessToken'];
    if (token is! String || token.isEmpty) throw const FalloInicio('El servidor no entregó la sesión. Prueba de nuevo.');
    final nuevo = ((data['email'] as String?) ?? fallbackEmail).trim();
    final anterior = _ultimoEmail?.trim();
    if (anterior != null && anterior.isNotEmpty && anterior.toLowerCase() != nuevo.toLowerCase()) {
      final datos = datosLocales;
      if (datos != null) {
        final n = await datos.pendientes();
        if (n > 0) {
          return 'En esta tablet ${n == 1 ? 'hay 1 evaluación' : 'hay $n evaluaciones'} de $anterior sin subir. '
              'Entra con esa cuenta y sincroniza antes de cambiar de usuario.';
        }
        await datos.borrarTodo();
      }
    }
    _token = token;
    _email = nuevo;
    _ultimoEmail = nuevo;
    _vencida = false;
    await _almacen.escribir(_tokenKey, token);
    await _almacen.escribir(_emailKey, nuevo);
    await _almacen.escribir(_ultimoKey, nuevo);
    notifyListeners();
    return null;
  }

  /// El servidor rechazó el token: se avisa y se pide entrar de nuevo. No se borra nada.
  void marcarVencida() {
    if (_vencida) return;
    _vencida = true;
    notifyListeners();
  }

  /// Cierra la sesión de este usuario. Lo local (también lo que falta subir) se queda en la tablet: si vuelve a entrar
  /// la misma persona, sigue donde estaba.
  Future<void> logout() async {
    _token = null;
    _email = null;
    _vencida = false;
    await _almacen.borrar(_tokenKey);
    await _almacen.borrar(_emailKey);
    for (final p in [google, microsoft]) {
      try {
        await p?.salir();
      } catch (_) {}
    }
    notifyListeners();
  }
}
