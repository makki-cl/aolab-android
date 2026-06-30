import 'dart:convert';

/// Modelo de un formulario capturado. Refleja el `FormEntryDto` del backend
/// (claves camelCase, fechas ISO-8601 UTC) y añade campos locales de sincronización.
class FormEntry {
  final String id; // GUID generado en el cliente (offline-safe)
  String title;
  String? notes;
  DateTime capturedAtUtc;
  Map<String, dynamic> data; // payload flexible (se envía como string JSON)
  DateTime createdAtUtc;
  DateTime updatedAtUtc;
  bool isDeleted;
  int serverVersion; // cursor asignado por el servidor (0 = nunca sincronizado)

  /// Local: true si tiene cambios pendientes de subir (push).
  bool dirty;

  FormEntry({
    required this.id,
    required this.title,
    this.notes,
    required this.capturedAtUtc,
    required this.data,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.isDeleted = false,
    this.serverVersion = 0,
    this.dirty = true,
  });

  /// Fila local (sqflite). `data` se guarda como texto JSON; los bool como 0/1.
  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'notes': notes,
        'captured_at': capturedAtUtc.toUtc().toIso8601String(),
        'data': jsonEncode(data),
        'created_at': createdAtUtc.toUtc().toIso8601String(),
        'updated_at': updatedAtUtc.toUtc().toIso8601String(),
        'is_deleted': isDeleted ? 1 : 0,
        'server_version': serverVersion,
        'dirty': dirty ? 1 : 0,
      };

  factory FormEntry.fromRow(Map<String, Object?> r) => FormEntry(
        id: r['id'] as String,
        title: r['title'] as String,
        notes: r['notes'] as String?,
        capturedAtUtc: DateTime.parse(r['captured_at'] as String).toUtc(),
        data: _decode(r['data'] as String?),
        createdAtUtc: DateTime.parse(r['created_at'] as String).toUtc(),
        updatedAtUtc: DateTime.parse(r['updated_at'] as String).toUtc(),
        isDeleted: (r['is_deleted'] as int) == 1,
        serverVersion: r['server_version'] as int,
        dirty: (r['dirty'] as int) == 1,
      );

  /// Cuerpo que viaja al backend en /api/sync/push (igual que FormEntryDto).
  Map<String, dynamic> toDto() => {
        'id': id,
        'title': title,
        'notes': notes,
        'capturedAtUtc': capturedAtUtc.toUtc().toIso8601String(),
        'data': jsonEncode(data),
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
        'isDeleted': isDeleted,
        'serverVersion': serverVersion,
      };

  /// Construye desde lo que devuelve /api/sync/pull. Lo que llega del servidor
  /// ya está sincronizado, por eso dirty = false.
  factory FormEntry.fromDto(Map<String, dynamic> d) => FormEntry(
        id: d['id'] as String,
        title: (d['title'] ?? '') as String,
        notes: d['notes'] as String?,
        capturedAtUtc: DateTime.parse(d['capturedAtUtc'] as String).toUtc(),
        data: _decode(d['data'] as String?),
        createdAtUtc: DateTime.parse(d['createdAtUtc'] as String).toUtc(),
        updatedAtUtc: DateTime.parse(d['updatedAtUtc'] as String).toUtc(),
        isDeleted: (d['isDeleted'] ?? false) as bool,
        serverVersion: (d['serverVersion'] ?? 0) as int,
        dirty: false,
      );

  static Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : {};
  }
}
