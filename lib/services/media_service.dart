import 'dart:io';

import 'package:dio/dio.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/audit.dart';
import 'api_client.dart';

/// Gestión de evidencias (fotos/audio) offline-first en Android: guarda el binario en
/// archivos locales del dispositivo y lo sube a /api/evidencias/{id} cuando hay conexión.
/// El documento de la auditoría solo lleva la referencia (Evidencia).
class MediaService {
  final ApiClient api;
  final ImagePicker _picker = ImagePicker();
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
}
