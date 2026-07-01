import 'dart:convert';

/// Estados de la auditoría (0/1/2/3 — coinciden con el backend; scheduled AL FINAL).
enum AuditStatus { draft, submitted, reviewed, scheduled }

AuditStatus auditStatusFromInt(int v) => switch (v) {
      1 => AuditStatus.submitted,
      2 => AuditStatus.reviewed,
      3 => AuditStatus.scheduled,
      _ => AuditStatus.draft,
    };

extension AuditStatusX on AuditStatus {
  int get value => index;
  String get label => switch (this) {
        AuditStatus.submitted => 'Finalizada',
        AuditStatus.reviewed => 'Revisada',
        AuditStatus.scheduled => 'Agendada',
        AuditStatus.draft => 'Borrador',
      };

  /// Una auditoría finalizada/revisada es inmutable.
  bool get isLocked => this == AuditStatus.submitted || this == AuditStatus.reviewed;
}

enum AuditType { spot, followup }

AuditType auditTypeFromInt(int v) => v == 1 ? AuditType.followup : AuditType.spot;

extension AuditTypeX on AuditType {
  int get value => index;
  String get label => this == AuditType.followup ? 'Seguimiento' : 'Spot';
}

/// Respuesta a una pregunta: texto + comentario opcional.
class Answer {
  String? respuesta;
  String? comentario;

  Answer({this.respuesta, this.comentario});

  Map<String, dynamic> toJson() => {'respuesta': respuesta, 'comentario': comentario};

  factory Answer.fromJson(Map<String, dynamic> j) =>
      Answer(respuesta: j['respuesta'] as String?, comentario: j['comentario'] as String?);
}

/// Una sala evaluada dentro del centro.
class AuditSala {
  String id;
  String name;
  Map<String, Answer> answers;

  AuditSala({required this.id, this.name = '', Map<String, Answer>? answers})
      : answers = answers ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'answers': answers.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory AuditSala.fromJson(Map<String, dynamic> j) => AuditSala(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        answers: ((j['answers'] ?? {}) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, Answer.fromJson((v ?? {}) as Map<String, dynamic>))),
      );
}

/// Contenido de la auditoría: respuestas de centro + salas repetibles.
class AuditDocument {
  Map<String, Answer> center;
  List<AuditSala> salas;

  AuditDocument({Map<String, Answer>? center, List<AuditSala>? salas})
      : center = center ?? {},
        salas = salas ?? [];

  Map<String, dynamic> toJson() => {
        'center': center.map((k, v) => MapEntry(k, v.toJson())),
        'salas': salas.map((s) => s.toJson()).toList(),
      };

  factory AuditDocument.fromJson(Map<String, dynamic> j) => AuditDocument(
        center: ((j['center'] ?? {}) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, Answer.fromJson((v ?? {}) as Map<String, dynamic>))),
        salas: ((j['salas'] ?? []) as List)
            .map((s) => AuditSala.fromJson(s as Map<String, dynamic>))
            .toList(),
      );

  static AuditDocument decode(String? raw) =>
      (raw == null || raw.isEmpty) ? AuditDocument() : AuditDocument.fromJson(jsonDecode(raw));

  String encode() => jsonEncode(toJson());
}

/// Auditoría local (fuente de verdad en el dispositivo).
class Audit {
  final String id; // GUID generado en el cliente (offline-safe)
  int status;
  int type; // 0=spot, 1=seguimiento
  String centerName;
  String? auditor;
  DateTime? sampledAtUtc;
  String? centerId;
  String? clientId;
  String? clientName;
  String? createdByName;
  DateTime? scheduledForUtc;
  AuditDocument document;
  DateTime createdAtUtc;
  DateTime updatedAtUtc;
  bool isDeleted;
  int serverVersion;
  bool dirty; // pendiente de subir

  Audit({
    required this.id,
    this.status = 0,
    this.type = 0,
    this.centerName = '(sin nombre)',
    this.auditor,
    this.sampledAtUtc,
    this.centerId,
    this.clientId,
    this.clientName,
    this.createdByName,
    this.scheduledForUtc,
    AuditDocument? document,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.isDeleted = false,
    this.serverVersion = 0,
    this.dirty = true,
  }) : document = document ?? AuditDocument();

  AuditStatus get statusEnum => auditStatusFromInt(status);
  AuditType get typeEnum => auditTypeFromInt(type);
  bool get isLocked => statusEnum.isLocked;

  // ---- SQLite ----
  Map<String, Object?> toRow() => {
        'id': id,
        'status': status,
        'type': type,
        'center_name': centerName,
        'auditor': auditor,
        'sampled_at': sampledAtUtc?.toUtc().toIso8601String(),
        'center_id': centerId,
        'client_id': clientId,
        'client_name': clientName,
        'created_by_name': createdByName,
        'scheduled_for': scheduledForUtc?.toUtc().toIso8601String(),
        'document': document.encode(),
        'created_at': createdAtUtc.toUtc().toIso8601String(),
        'updated_at': updatedAtUtc.toUtc().toIso8601String(),
        'is_deleted': isDeleted ? 1 : 0,
        'server_version': serverVersion,
        'dirty': dirty ? 1 : 0,
      };

  factory Audit.fromRow(Map<String, Object?> r) => Audit(
        id: r['id'] as String,
        status: r['status'] as int,
        type: (r['type'] as int?) ?? 0,
        centerName: r['center_name'] as String,
        auditor: r['auditor'] as String?,
        sampledAtUtc: (r['sampled_at'] as String?) != null ? DateTime.parse(r['sampled_at'] as String) : null,
        centerId: r['center_id'] as String?,
        clientId: r['client_id'] as String?,
        clientName: r['client_name'] as String?,
        createdByName: r['created_by_name'] as String?,
        scheduledForUtc: (r['scheduled_for'] as String?) != null ? DateTime.parse(r['scheduled_for'] as String) : null,
        document: AuditDocument.decode(r['document'] as String?),
        createdAtUtc: DateTime.parse(r['created_at'] as String),
        updatedAtUtc: DateTime.parse(r['updated_at'] as String),
        isDeleted: (r['is_deleted'] as int) == 1,
        serverVersion: r['server_version'] as int,
        dirty: (r['dirty'] as int) == 1,
      );

  // ---- API (DTO) ----
  Map<String, dynamic> toDto() => {
        'id': id,
        'status': status,
        'type': type,
        'centerName': centerName,
        'auditor': auditor,
        'sampledAtUtc': sampledAtUtc?.toUtc().toIso8601String(),
        'centerId': centerId,
        'clientId': clientId,
        'clientName': clientName,
        'createdByName': createdByName,
        'scheduledForUtc': scheduledForUtc?.toUtc().toIso8601String(),
        'document': document.toJson(),
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
        'isDeleted': isDeleted,
        'serverVersion': serverVersion,
      };

  factory Audit.fromDto(Map<String, dynamic> d) => Audit(
        id: d['id'] as String,
        status: (d['status'] ?? 0) as int,
        type: (d['type'] ?? 0) as int,
        centerName: (d['centerName'] ?? '(sin nombre)') as String,
        auditor: d['auditor'] as String?,
        sampledAtUtc: d['sampledAtUtc'] != null ? DateTime.parse(d['sampledAtUtc'] as String) : null,
        centerId: d['centerId'] as String?,
        clientId: d['clientId'] as String?,
        clientName: d['clientName'] as String?,
        createdByName: d['createdByName'] as String?,
        scheduledForUtc: d['scheduledForUtc'] != null ? DateTime.parse(d['scheduledForUtc'] as String) : null,
        document: AuditDocument.fromJson((d['document'] ?? {}) as Map<String, dynamic>),
        createdAtUtc: DateTime.parse(d['createdAtUtc'] as String),
        updatedAtUtc: DateTime.parse(d['updatedAtUtc'] as String),
        isDeleted: (d['isDeleted'] ?? false) as bool,
        serverVersion: (d['serverVersion'] ?? 0) as int,
        dirty: false,
      );
}
