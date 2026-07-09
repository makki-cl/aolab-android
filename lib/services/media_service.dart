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
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Amplitude>? _ampSub;
  double _peakDb = -160;
  String? _recId;
  String? _dirPath;

  MediaService({required this.api});

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

  bool hasLocal(String id) => _dirPath != null && fileFor(id).existsSync();

  /// Captura una foto (cámara o galería), la guarda local y crea la Evidencia.
  /// Intenta subirla; si no hay red, queda pendiente (se sube en el sync).
  Future<Evidencia?> capturePhoto({required ImageSource source}) async {
    await dirPath();
    final x = await _picker.pickImage(source: source, maxWidth: 2000, imageQuality: 82);
    if (x == null) return null;
    final id = const Uuid().v4();
    final dest = fileFor(id);
    await File(x.path).copy(dest.path);
    final ev = Evidencia(id: id, contentType: 'image/jpeg', capturedAtUtc: DateTime.now().toUtc(), uploaded: false);
    ev.uploaded = await _upload(id, dest, ev.contentType!);
    return ev;
  }

  Future<bool> _upload(String id, File f, String contentType) async {
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
    } catch (_) {
      return false;
    }
  }

  /// Sube las evidencias pendientes (uploaded=false) que tengan archivo local.
  /// Devuelve true si alguna cambió su estado (para persistir el flag).
  Future<bool> uploadPending(List<Evidencia> evidencias) async {
    await dirPath();
    var changed = false;
    for (final ev in evidencias) {
      if (ev.uploaded) continue;
      final f = fileFor(ev.id);
      if (!f.existsSync()) continue;
      if (await _upload(ev.id, f, ev.contentType ?? 'application/octet-stream')) {
        ev.uploaded = true;
        changed = true;
      }
    }
    return changed;
  }

  Future<void> remove(String id) async {
    await dirPath();
    final f = fileFor(id);
    if (f.existsSync()) await f.delete();
    try { await api.dio.delete('/api/evidencias/$id'); } catch (_) {}
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

  /// Detiene y devuelve la evidencia + si quedó en silencio (posible problema de micrófono / sin voz).
  Future<({Evidencia? ev, bool silent})> stopRecording() async {
    await _ampSub?.cancel();
    _ampSub = null;
    final path = await _recorder.stop();
    final id = _recId;
    _recId = null;
    if (path == null || id == null) return (ev: null, silent: false);
    final silent = _peakDb < -40; // casi sin señal captada
    final ev = Evidencia(id: id, contentType: 'audio/mp4', capturedAtUtc: DateTime.now().toUtc(), uploaded: false);
    ev.uploaded = await _upload(id, fileFor(id), 'audio/mp4');
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

  /// Prueba de micrófono (~2s): true si detectó señal, false si silencio, null si no hay permiso.
  Future<bool?> testMic() async {
    if (!await _recorder.hasPermission()) return null;
    await dirPath();
    final tmp = fileFor('mic-test').path;
    var peak = -160.0;
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: tmp);
    final sub = _recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
      if (a.current > peak) peak = a.current;
    });
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    await _recorder.stop();
    await sub.cancel();
    try { final f = File(tmp); if (f.existsSync()) await f.delete(); } catch (_) {}
    return peak > -40;
  }
}
