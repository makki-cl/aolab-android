/// Maestros read-only sincronizados desde la web (solo pull). Se usan para poblar
/// los selectores de cliente/centro/auditor al crear/editar una auditoría en terreno.
import 'dart:convert';

/// Tipos de sistema estándar (lista fija; "Sin Tipo" se representa como null).
const List<String> kSistemaTipos = ['FF', 'FRY', 'SMOLT'];

/// Sistema (sala) predefinido de un centro: nombre + tipo estándar (null = Sin Tipo).
class Sistema {
  String nombre;
  String? tipo;
  Sistema({this.nombre = '', this.tipo});

  Map<String, dynamic> toJson() => {'nombre': nombre, 'tipo': tipo};
  factory Sistema.fromJson(Map<String, dynamic> j) =>
      Sistema(nombre: (j['nombre'] ?? '') as String, tipo: j['tipo'] as String?);
}

/// Usuario del sistema (para elegir auditor).
class UserRef {
  final String id;
  final String email;
  final String? fullName;

  UserRef({required this.id, required this.email, this.fullName});

  String get display => (fullName != null && fullName!.trim().isNotEmpty) ? fullName! : email;

  Map<String, Object?> toRow() => {'id': id, 'email': email, 'full_name': fullName};

  factory UserRef.fromRow(Map<String, Object?> r) =>
      UserRef(id: r['id'] as String, email: (r['email'] ?? '') as String, fullName: r['full_name'] as String?);

  factory UserRef.fromDto(Map<String, dynamic> d) => UserRef(
        id: (d['id'] ?? '') as String,
        email: (d['email'] ?? '') as String,
        fullName: d['fullName'] as String?,
      );
}

class ClientRef {
  final String id;
  String name;
  String? legalId;
  bool hasLogo;
  bool isActive;
  bool isDeleted;
  int serverVersion;

  ClientRef({
    required this.id,
    this.name = '',
    this.legalId,
    this.hasLogo = false,
    this.isActive = true,
    this.isDeleted = false,
    this.serverVersion = 0,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'legal_id': legalId,
        'has_logo': hasLogo ? 1 : 0,
        'is_active': isActive ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'server_version': serverVersion,
      };

  factory ClientRef.fromRow(Map<String, Object?> r) => ClientRef(
        id: r['id'] as String,
        name: (r['name'] ?? '') as String,
        legalId: r['legal_id'] as String?,
        hasLogo: (r['has_logo'] as int? ?? 0) == 1,
        isActive: (r['is_active'] as int? ?? 1) == 1,
        isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
        serverVersion: (r['server_version'] as int?) ?? 0,
      );

  factory ClientRef.fromDto(Map<String, dynamic> d) => ClientRef(
        id: d['id'] as String,
        name: (d['name'] ?? '') as String,
        legalId: d['legalId'] as String?,
        hasLogo: (d['hasLogo'] ?? false) as bool,
        isActive: (d['isActive'] ?? true) as bool,
        isDeleted: (d['isDeleted'] ?? false) as bool,
        serverVersion: (d['serverVersion'] ?? 0) as int,
      );
}

class CenterRef {
  final String id;
  String name;
  String? code;
  double? latitude;
  double? longitude;
  String? ownerClientId;
  String? operatorName;
  List<Sistema> sistemas; // sistemas del maestro (nombre + tipo)
  bool isActive;
  bool isDeleted;
  int serverVersion;

  CenterRef({
    required this.id,
    this.name = '',
    this.code,
    this.latitude,
    this.longitude,
    this.ownerClientId,
    this.operatorName,
    List<Sistema>? sistemas,
    this.isActive = true,
    this.isDeleted = false,
    this.serverVersion = 0,
  }) : sistemas = sistemas ?? [];

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'code': code,
        'latitude': latitude,
        'longitude': longitude,
        'owner_client_id': ownerClientId,
        'operator_name': operatorName,
        'sistemas': jsonEncode(sistemas.map((s) => s.toJson()).toList()),
        'is_active': isActive ? 1 : 0,
        'is_deleted': isDeleted ? 1 : 0,
        'server_version': serverVersion,
      };

  factory CenterRef.fromRow(Map<String, Object?> r) => CenterRef(
        id: r['id'] as String,
        name: (r['name'] ?? '') as String,
        code: r['code'] as String?,
        latitude: (r['latitude'] as num?)?.toDouble(),
        longitude: (r['longitude'] as num?)?.toDouble(),
        ownerClientId: r['owner_client_id'] as String?,
        operatorName: r['operator_name'] as String?,
        sistemas: _decodeSistemas(r['sistemas'] as String?),
        isActive: (r['is_active'] as int? ?? 1) == 1,
        isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
        serverVersion: (r['server_version'] as int?) ?? 0,
      );

  factory CenterRef.fromDto(Map<String, dynamic> d) => CenterRef(
        id: d['id'] as String,
        name: (d['name'] ?? '') as String,
        code: d['code'] as String?,
        latitude: (d['latitude'] as num?)?.toDouble(),
        longitude: (d['longitude'] as num?)?.toDouble(),
        ownerClientId: d['ownerClientId'] as String?,
        operatorName: d['operatorName'] as String?,
        sistemas: ((d['sistemas'] ?? []) as List)
            .map((e) => Sistema.fromJson((e ?? {}) as Map<String, dynamic>))
            .toList(),
        isActive: (d['isActive'] ?? true) as bool,
        isDeleted: (d['isDeleted'] ?? false) as bool,
        serverVersion: (d['serverVersion'] ?? 0) as int,
      );

  static List<Sistema> _decodeSistemas(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Sistema.fromJson((e ?? {}) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
