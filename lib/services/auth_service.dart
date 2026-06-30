import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// Maneja la sesión: login contra /api/auth/login, guarda el JWT en almacenamiento
/// seguro y lo expone para que ApiClient lo adjunte. Es un ChangeNotifier para que
/// la UI reaccione a iniciar/cerrar sesión.
class AuthService extends ChangeNotifier {
  static const _tokenKey = 'aolab_jwt';
  static const _emailKey = 'aolab_email';

  final FlutterSecureStorage _storage;
  late final ApiClient api;

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

  /// Inicia sesión y persiste el token. Devuelve null si OK, o un mensaje de error.
  Future<String?> login(String email, String password) async {
    try {
      final res = await api.dio.post('/api/auth/login', data: {
        'email': email,
        'password': password,
      });
      final data = res.data as Map<String, dynamic>;
      _token = data['accessToken'] as String;
      _email = (data['email'] as String?) ?? email;
      await _storage.write(key: _tokenKey, value: _token);
      await _storage.write(key: _emailKey, value: _email);
      notifyListeners();
      return null;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        return 'Correo o contraseña incorrectos.';
      }
      return 'No se pudo conectar con el servidor (${e.message}).';
    } catch (e) {
      return 'Error inesperado: $e';
    }
  }

  Future<void> logout() async {
    _token = null;
    _email = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _emailKey);
    notifyListeners();
  }
}
