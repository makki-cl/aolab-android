import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config.dart';
import 'api_client.dart';

/// Maneja la sesión: login contra /api/auth/login, guarda el JWT en almacenamiento
/// seguro y lo expone para que ApiClient lo adjunte. Es un ChangeNotifier para que
/// la UI reaccione a iniciar/cerrar sesión.
class AuthService extends ChangeNotifier {
  static const _tokenKey = 'aolab_jwt';
  static const _emailKey = 'aolab_email';

  final FlutterSecureStorage _storage;
  late final ApiClient api;

  // Sign-In nativo de Google. serverClientId = client web (para que el idToken
  // tenga esa audiencia y el backend lo valide).
  final GoogleSignIn _google = GoogleSignIn(
    scopes: const ['email'],
    serverClientId: AppConfig.googleWebClientId,
  );

  String? _token;
  String? _email;

  AuthService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage() {
    // ApiClient lee el token vigente en cada request mediante este callback.
    api = ApiClient(getToken: () => _token);
  }

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;
  String? get email => _email;
  String? get token => _token;

  /// Restaura una sesión previa (token guardado) al iniciar la app.
  Future<void> loadSession() async {
    _token = await _storage.read(key: _tokenKey);
    _email = await _storage.read(key: _emailKey);
    notifyListeners();
  }

  /// Login con correo/contraseña. Devuelve null si OK, o un mensaje de error.
  Future<String?> login(String email, String password) async {
    try {
      final res = await api.dio.post('/api/auth/login', data: {
        'email': email,
        'password': password,
      });
      await _persist(res.data as Map<String, dynamic>, fallbackEmail: email);
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) return 'Correo o contraseña incorrectos.';
      return 'No se pudo conectar con el servidor (${e.message}).';
    } catch (e) {
      return 'Error inesperado: $e';
    }
  }

  /// Login con Google: abre el selector nativo, obtiene el idToken y lo canjea por
  /// nuestro JWT en /api/auth/google. Devuelve null si OK, o un mensaje de error.
  Future<String?> loginWithGoogle() async {
    try {
      final account = await _google.signIn();
      if (account == null) return null; // el usuario canceló
      final gauth = await account.authentication;
      final idToken = gauth.idToken;
      if (idToken == null) return 'No se obtuvo el token de Google.';

      final res = await api.dio.post('/api/auth/google', data: {'idToken': idToken});
      await _persist(res.data as Map<String, dynamic>, fallbackEmail: account.email);
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) return 'Tu correo no está autorizado para ingresar.';
      if (e.response?.statusCode == 401) return 'No se pudo validar la cuenta de Google.';
      return 'No se pudo conectar con el servidor (${e.message}).';
    } catch (e) {
      return 'Error con Google: $e';
    }
  }

  Future<void> _persist(Map<String, dynamic> data, {required String fallbackEmail}) async {
    _token = data['accessToken'] as String;
    _email = (data['email'] as String?) ?? fallbackEmail;
    await _storage.write(key: _tokenKey, value: _token);
    await _storage.write(key: _emailKey, value: _email);
    notifyListeners();
  }

  Future<void> logout() async {
    _token = null;
    _email = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _emailKey);
    try {
      await _google.signOut();
    } catch (_) {}
    notifyListeners();
  }
}
