// Un servidor falso para las pruebas: responde a las rutas de la API con lo que se le diga, sin red.
import 'dart:convert';
import 'dart:typed_data';

import 'package:aolab_android/services/auth_service.dart';
import 'package:dio/dio.dart';

typedef Respuesta = ({int status, Object? body});

class ServidorFalso implements HttpClientAdapter {
  /// Ruta («POST /api/auth/login») → respuesta, o una excepción para simular la red caída.
  final Map<String, Object Function(RequestOptions)> rutas = {};
  final List<RequestOptions> pedidos = [];

  /// Rutas que tardan en responder (mala señal).
  final Map<String, Duration> demoras = {};

  void responder(String ruta, int status, Object? body) => rutas[ruta] = (_) => (status: status, body: body);

  void fallar(String ruta, DioExceptionType tipo) =>
      rutas[ruta] = (o) => DioException(requestOptions: o, type: tipo, message: 'texto interno de Dio');

  Dio dio() => Dio(BaseOptions(baseUrl: 'http://servidor.falso'))..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    pedidos.add(options);
    final demora = demoras['${options.method} ${options.path}'];
    if (demora != null) await Future<void>.delayed(demora);
    final r = rutas['${options.method} ${options.path}'];
    if (r == null) return ResponseBody.fromString('', 404);
    final x = r(options);
    if (x is DioException) throw x;
    final resp = x as Respuesta;
    return ResponseBody.fromString(
      resp.body == null ? '' : jsonEncode(resp.body),
      resp.status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class AlmacenEnMemoria implements AlmacenSesion {
  final Map<String, String> datos = {};
  @override
  Future<String?> leer(String llave) async => datos[llave];
  @override
  Future<void> escribir(String llave, String valor) async => datos[llave] = valor;
  @override
  Future<void> borrar(String llave) async => datos.remove(llave);
}

class ExternoFalso implements InicioExterno {
  String? token;
  Object? error;
  int salidas = 0;
  String? ultimoCorreo;
  ExternoFalso({this.token, this.error});

  @override
  Future<String?> idToken({String? correo}) async {
    ultimoCorreo = correo;
    if (error != null) throw error!;
    return token;
  }

  @override
  Future<void> salir() async => salidas++;
}

class DatosFalsos implements DatosLocales {
  int pendientesHoy;
  int borrados = 0;
  DatosFalsos([this.pendientesHoy = 0]);

  @override
  Future<int> pendientes() async => pendientesHoy;

  @override
  Future<void> borrarTodo() async => borrados++;
}

Map<String, dynamic> tokenDe(String correo) => {'accessToken': 'jwt-$correo', 'email': correo, 'expiresAtUtc': '2026-10-27T00:00:00Z'};
