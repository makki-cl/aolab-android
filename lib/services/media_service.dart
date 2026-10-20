import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/audit.dart';
import 'api_client.dart';

/// Gestión de evidencias (fotos/audio) offline-first en Android: guarda el binario en
/// archivos locales del dispositivo y lo sube a /api/evidencias/{id} cuando hay conexión.
/// El documento de la auditoría solo lleva la referencia (Evidencia).
class MediaService {
  final ApiClient api;
  final ImagePicker _picker = ImagePicker();
  late final AudioRecorder _recorder = AudioRecorder(); // se crea al grabar por primera vez
  StreamSubscription<Amplitude>? _ampSub;
  double _peakDb = -160;
  String? _recId;
  String? _dirPath;

  /// [carpeta] fija la carpeta de las evidencias (las pruebas); si no, es la de la app.
  MediaService({required this.api, String? carpeta}) : _dirPath = carpeta;

  /// Inicializa (y devuelve) la carpeta local de evidencias. Debe llamarse antes de [fileFor].
  Future<String> dirPath() async {
    if (_dirPath != null) return _dirPath!;
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'media'));
    if (!await d.exists()) await d.create(recursive: true);
    return _dirPath = d.path;
  }

  /// Ruta local del binario de una evidencia (sincrónica; requiere [dirPath] previo).
  File fileFor(String id) => File(p.join(_dirPath ?? '', id));

  bool get grabando => _recId != null;

  bool hasLocal(String id) => _dirPath != null && fileFor(id).existsSync();

  /// Borra los archivos locales de evidencias (al cambiar de usuario, cuando ya todo subió).
  Future<void> borrarArchivosLocales() async {
    final d = Directory(await dirPath());
    if (!await d.exists()) return;
    await for (final f in d.list()) {
      try {
        await f.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Captura una foto (cámara o galería), la guarda local y crea la Evidencia sin subirla: aparece al tiro aunque no
  /// haya señal, y la sube la sincronización (o [subir], en segundo plano).
  Future<Evidencia?> capturePhoto({required ImageSource source}) async {
    await dirPath();
    final x = await _picker.pickImage(source: source, maxWidth: 2000, imageQuality: 82);
    if (x == null) return null;
    return guardarFoto(x.path);
  }

  /// Copia una foto a la carpeta de evidencias y crea su Evidencia (pendiente de subir).
  Future<Evidencia> guardarFoto(String origen) async {
    await dirPath();
    final id = const Uuid().v4();
    await File(origen).copy(fileFor(id).path);
    return Evidencia(id: id, contentType: 'image/jpeg', capturedAtUtc: DateTime.now().toUtc(), uploaded: false);
  }

  /// Android puede cerrar la app mientras la cámara está abierta (tablets con poca memoria). Al volver, la foto que se
  /// tomó queda guardada aparte: esto la recupera (null si no hay ninguna). Solo existe en Android.
  Future<String?> fotoPerdida() async {
    if (!Platform.isAndroid) return null;
    final r = await _picker.retrieveLostData();
    if (r.isEmpty) return null;
    final f = r.file ?? (r.files?.isNotEmpty ?? false ? r.files!.first : null);
    return f?.path;
  }

  /// Sube una evidencia ya guardada. true si quedó en el servidor; sin señal, false (la sube la sincronización).
  Future<bool> subir(Evidencia ev) async {
    await dirPath();
    final f = fileFor(ev.id);
    if (!f.existsSync()) return false;
    return await _upload(ev.id, f, ev.contentType ?? 'application/octet-stream') ?? false;
  }

  // Con mala señal, el envío del archivo se reintenta dos veces (el PUT por id no duplica nada). null si la red no
  // dejó subirlo.
  Future<bool?> _upload(String id, File f, String contentType) async {
    for (var intento = 0; intento < 3; intento++) {
      if (intento > 0) await Future<void>.delayed(pausaEntreIntentos * intento);
      final r = await _subirUnaVez(id, f, contentType);
      if (r != null) return r;
    }
    return null;
  }

  /// La pausa antes de reintentar un envío (las pruebas la acortan).
  Duration pausaEntreIntentos = const Duration(seconds: 2);

  // true subió; false el servidor no la aceptó; null la red falló (se puede reintentar).
  Future<bool?> _subirUnaVez(String id, File f, String contentType) async {
    try {
      final bytes = await f.readAsBytes();
      final res = await api.dio.put(
        '/api/evidencias/$id',
        data: Stream.fromIterable([bytes]),
        options: Options(
          contentType: contentType,
          headers: {Headers.contentLengthHeader: bytes.length},
        ),
      );
      final code = res.statusCode ?? 0;
      return code >= 200 && code < 300;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) rethrow; // la sesión venció: lo maneja la sincronización
      return Reintentos.esDeRed(e) ? null : false;
    } catch (_) {
      return false;
    }
  }

  /// Sube las evidencias pendientes (uploaded=false) que tengan archivo local. Devuelve los ids de las que subieron
  /// (para marcarlas sobre la fila recién leída: ver AppDatabase.marcarEvidenciasSubidas). Si la red no deja subir una,
  /// no se insiste con las demás en este ciclo: quedan para el siguiente.
  Future<Set<String>> uploadPending(List<Evidencia> evidencias) async {
    await dirPath();
    final subidas = <String>{};
    for (final ev in evidencias) {
      if (ev.uploaded) continue;
      final f = fileFor(ev.id);
      if (!f.existsSync()) continue;
      final r = await _upload(ev.id, f, ev.contentType ?? 'application/octet-stream');
      if (r == null) {
        sinRed = true;
        break;
      }
      if (r) {
        ev.uploaded = true;
        subidas.add(ev.id);
      }
    }
    return subidas;
  }

  /// La última subida se cortó por la red (la sincronización lo dice en palabras del evaluador).
  bool sinRed = false;

  /// Borra el archivo local de una evidencia (la papelera que se vacía al finalizar). El del servidor se borra después,
  /// cuando la evaluación ya subió sin ella (AuditSyncService).
  Future<void> removeLocal(String id) async {
    await dirPath();
    final f = fileFor(id);
    if (f.existsSync()) await f.delete();
  }

  /// Borra la evidencia en el servidor. true si quedó borrada (o ya no estaba). El servidor no borra una evidencia
  /// que siga viva en alguna evaluación (responde 204 igual).
  Future<bool> removeRemote(String id) async {
    try {
      final res = await api.dio.delete('/api/evidencias/$id');
      final code = res.statusCode ?? 0;
      return code >= 200 && code < 300;
    } on DioException catch (e) {
      return e.response?.statusCode == 404;
    } catch (_) {
      return false;
    }
  }

  // ── Audio: grabación con nivel (VU) para validar micrófono ──

  Future<bool> hasMicPermission() => _recorder.hasPermission();

  /// Inicia la grabación; [onLevel] recibe el nivel 0..1 para el VU meter. false si no hay permiso.
  Future<bool> startRecording({required void Function(double level) onLevel}) async {
    if (!await _recorder.hasPermission()) return false;
    await dirPath();
    final id = const Uuid().v4();
    _recId = id;
    _peakDb = -160;
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: fileFor(id).path);
    _ampSub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 150)).listen((a) {
      if (a.current > _peakDb) _peakDb = a.current;
      onLevel(((a.current + 50) / 50).clamp(0.0, 1.0)); // -50 dBFS..0 -> 0..1
    });
    return true;
  }

  /// Detiene y devuelve la evidencia (pendiente de subir, como la foto) + si quedó en silencio (posible problema de
  /// micrófono / sin voz).
  Future<({Evidencia? ev, bool silent})> stopRecording() async {
    await _ampSub?.cancel();
    _ampSub = null;
    final path = await _recorder.stop();
    final id = _recId;
    _recId = null;
    if (path == null || id == null) return (ev: null, silent: false);
    final silent = _peakDb < -40; // casi sin señal captada
    final ev = Evidencia(id: id, contentType: 'audio/mp4', capturedAtUtc: DateTime.now().toUtc(), uploaded: false);
    return (ev: ev, silent: silent);
  }

  Future<void> cancelRecording() async {
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      final path = await _recorder.stop();
      if (path != null) { final f = File(path); if (f.existsSync()) await f.delete(); }
    } catch (_) {}
    _recId = null;
  }
}
