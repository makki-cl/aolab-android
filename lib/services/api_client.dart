import 'package:dio/dio.dart';

import '../config.dart';

/// Cliente HTTP hacia el backend Aolab. Adjunta el JWT (si existe) en cada request.
class ApiClient {
  final Dio dio;

  /// [getToken] devuelve el JWT actual (o null si no hay sesión iniciada). [dio] es para las pruebas.
  ApiClient({required String? Function() getToken, Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.apiBaseUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 60),
              headers: {'Content-Type': 'application/json'},
            )) {
    this.dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = getToken();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ));
    this.dio.interceptors.add(Reintentos(this.dio));
  }
}

/// Con mala señal, una consulta (GET) que no alcanzó a llegar o a volver se reintenta dos veces más, con una pausa
/// corta. Solo las consultas: un envío (POST/PUT) que se cortó a medio camino puede haber llegado, y lo reintenta la
/// sincronización siguiente con lo que haya en la tablet en ese momento.
class Reintentos extends Interceptor {
  final Dio dio;
  final List<Duration> pausas;

  Reintentos(this.dio, {this.pausas = const [Duration(seconds: 1), Duration(seconds: 3)]});

  static bool esDeRed(DioException e) => switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.connectionError =>
          true,
        _ => false,
      };

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final o = err.requestOptions;
    final intento = (o.extra['intento'] as int?) ?? 0;
    if (o.method.toUpperCase() != 'GET' || !esDeRed(err) || intento >= pausas.length) {
      handler.next(err);
      return;
    }
    await Future<void>.delayed(pausas[intento]);
    o.extra['intento'] = intento + 1;
    try {
      handler.resolve(await dio.fetch<dynamic>(o));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}
