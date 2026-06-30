import 'package:dio/dio.dart';

import '../config.dart';

/// Cliente HTTP hacia el backend Aolab. Adjunta el JWT (si existe) en cada request.
class ApiClient {
  final Dio dio;

  /// [getToken] devuelve el JWT actual (o null si no hay sesión iniciada).
  ApiClient({required String? Function() getToken})
      : dio = Dio(BaseOptions(
          baseUrl: AppConfig.apiBaseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        )) {
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = getToken();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));
  }
}
