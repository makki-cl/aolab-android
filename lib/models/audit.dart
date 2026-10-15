import 'dart:convert';

import 'llaves_ajenas.dart';

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
  String? titulo; // solo para "consultas adicionales" agregadas en la web
  /// Llaves que esta versión no conoce: se guardan en la copia local, no se suben (llaves_ajenas.dart).
  Map<String, dynamic> extra;

  Answer({this.respuesta, this.comentario, this.titulo, Map<String, dynamic>? extra}) : extra = extra ?? {};

  static final _llaves = LlavesPropias(['respuesta', 'comentario', 'titulo']);

  /// [ajenas]: incluir lo que la app no conoce (copia local) o no (push). Ver llaves_ajenas.dart.
  Map<String, dynamic> toJson({bool ajenas = true}) =>
      conAjenas({'respuesta': respuesta, 'comentario': comentario, 'titulo': titulo}, extra, incluir: ajenas);

  factory Answer.fromJson(Map<String, dynamic> j) => Answer(
        respuesta: j['respuesta'] as String?,
        comentario: j['comentario'] as String?,
        titulo: j['titulo'] as String?,
        extra: _llaves.ajenas(j),
      );
}

/// Referencia a una evidencia (foto/audio) de un punto de control. El binario vive local
/// y/o en el servidor; aquí solo el id + metadatos.
class Evidencia {
  String id;
  String? contentType;
  DateTime? capturedAtUtc;
  bool uploaded;
  String? transcripcion; // solo audio; se llena luego con la API de Claude
  bool isDeleted; // soft-delete: papelera del punto; se purga al finalizar
  /// Llaves que esta versión no conoce: se guardan en la copia local, no se suben.
  Map<String, dynamic> extra;

  Evidencia({
    required this.id,
    this.contentType,
    this.capturedAtUtc,
    this.uploaded = false,
    this.transcripcion,
    this.isDeleted = false,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  static final _llaves = LlavesPropias(['id', 'contentType', 'capturedAtUtc', 'uploaded', 'transcripcion', 'isDeleted']);

  Map<String, dynamic> toJson({bool ajenas = true}) => conAjenas({
        'id': id,
        'contentType': contentType,
        'capturedAtUtc': capturedAtUtc?.toUtc().toIso8601String(),
        'uploaded': uploaded,
        'transcripcion': transcripcion,
        'isDeleted': isDeleted,
      }, extra, incluir: ajenas);

  factory Evidencia.fromJson(Map<String, dynamic> j) => Evidencia(
        id: (j['id'] ?? '') as String,
        contentType: j['contentType'] as String?,
        capturedAtUtc: j['capturedAtUtc'] != null ? DateTime.parse(j['capturedAtUtc'] as String) : null,
        uploaded: (j['uploaded'] ?? false) as bool,
        transcripcion: j['transcripcion'] as String?,
        isDeleted: (j['isDeleted'] ?? false) as bool,
        extra: _llaves.ajenas(j),
      );
}

/// Llave de la copia local que marca un BQ/FC escrito en la tablet y todavía sin volver del servidor.
const String kLlaveLabLocal = 'appLabLocal';

/// Resultado de laboratorio escrito a mano (BQ o FC): el valor final, sin las lecturas crudas, con fuente «manual».
/// Es lo mismo que guarda el ingreso a mano de la web (`BactiPanel.SetValorManual`), así el informe lo muestra igual
/// («ingresado a mano»). Se parte del resultado que había, para no perder sus otros datos.
Map<String, dynamic> resultadoManual(double valor, {required bool hongos, Map<String, dynamic>? anterior}) => {
      ...?anterior,
      'valor': valor,
      'organismo': hongos ? 'fungi' : 'bacteria',
      'belowThreshold': false,
      'fuente': 'manual',
    };

/// Punto de control (Evaluación RPN): cosa a inspeccionar dentro de un Sistema, medida en 4
/// dimensiones operacionales (1–5) + comentario + evidencias (fotos/audio).
class PuntoControl {
  String id;
  String nombre;
  // Correlativo del punto, imputado por el auditor. Es la parte DESPUÉS del guion del
  // "Sample ID" que se rotula en el frasco: {folio}-{correlativo}. Único dentro de la auditoría.
  int? correlativo;
  String? tipo; // estándar (null = Sin Tipo)
  bool fromMaster; // viene del maestro: nombre y tipo inmutables en la auditoría
  String? masterId; // Id del punto en el maestro (vínculo estable)
  bool isDeleted;
  int? estadoOperacional; // O
  int? limpiezaBiofilm; // L
  int? impactoPeces; // I
  int? detectabilidad; // D
  String? comentario;
  List<Evidencia> fotos;
  List<Evidencia> audios;
  // Resultados de laboratorio (BQ y FC). Se cargan en la web (CSV de Bactiquant o a mano) y, desde la versión del
  // 15-10-2026, también a mano en la tablet, pero solo donde el servidor todavía no tiene uno: un push no cambia un
  // resultado que ya está (lo manda la web). La app los transporta siempre intactos.
  Map<String, dynamic>? bacti;
  Map<String, dynamic>? bactiHongos;
  // Los resultados de este punto que escribió el evaluador en ESTA tablet y todavía no vuelven del servidor: 'bq' y/o
  // 'fc'. Solo viven en la copia local (no se suben). Con ellos la app sabe cuál todavía se puede corregir: un
  // resultado que ya está en el servidor lo manda la web (el push no cambia uno que el servidor tiene), así que se
  // muestra sin editar.
  Set<String> labLocal;
  // ── Foto del modelo con equipos (F3) ──
  // Se llenan al agregar el punto desde un centro con el modelo con equipos activo y quedan como
  // estaban aunque después cambie el modelo (renombrar o mover un equipo no reescribe la historia).
  // Null en las auditorías anteriores, en los centros en el modelo plano y en los puntos ad hoc.
  String? equipoId; // equipo del punto (en un tramo, el equipo con que se nombra)
  String? equipoAlias; // cómo se llamaba ese equipo en el centro al auditar
  String? equipoTipo; // tipo estándar del equipo (o tipo de afluente)
  String? grupo; // afluente | equipo | tramo | efluente
  String? ubicacion; // entrada | salida | interior | tramo
  String? referencia; // solo tramos: pre | post
  /// Llaves que esta versión no conoce: se guardan en la copia local, no se suben.
  Map<String, dynamic> extra;

  PuntoControl({
    required this.id,
    this.nombre = '',
    this.correlativo,
    this.tipo,
    this.fromMaster = false,
    this.masterId,
    this.isDeleted = false,
    this.bacti,
    this.bactiHongos,
    Set<String>? labLocal,
    this.equipoId,
    this.equipoAlias,
    this.equipoTipo,
    this.grupo,
    this.ubicacion,
    this.referencia,
    this.estadoOperacional,
    this.limpiezaBiofilm,
    this.impactoPeces,
    this.detectabilidad,
    this.comentario,
    List<Evidencia>? fotos,
    List<Evidencia>? audios,
    Map<String, dynamic>? extra,
  })  : fotos = fotos ?? [],
        audios = audios ?? [],
        labLocal = labLocal ?? <String>{},
        extra = extra ?? {};

  static final _llaves = LlavesPropias([
    'id', 'nombre', 'correlativo', 'tipo', 'fromMaster', 'masterId', 'isDeleted', //
    'estadoOperacional', 'limpiezaBiofilm', 'impactoPeces', 'detectabilidad', 'comentario', //
    'fotos', 'audios', 'bacti', 'bactiHongos', kLlaveLabLocal, //
    'equipoId', 'equipoAlias', 'equipoTipo', 'grupo', 'ubicacion', 'referencia',
  ]);

  /// Valor final del BQ (bacterias) y del FC (hongos), o null si no hay.
  double? get bq => _valor(bacti);
  double? get fc => _valor(bactiHongos);

  static double? _valor(Map<String, dynamic>? r) {
    final v = r?['valor'];
    return v is num ? v.toDouble() : null;
  }

  /// La posición muestreada en un equipo de bateas / baldes («Rack 3 · Batea 7»). La anota la web; la app solo la
  /// muestra (viaja en `extra` y no se sube).
  String? get posicionEtiqueta {
    final pos = objetoOpcional(extra['posicion']);
    final et = textoOpcional(pos?['etiqueta'])?.trim();
    return (et == null || et.isEmpty) ? null : et;
  }

  // La foto del modelo solo se escribe si tiene valor. Así la app nunca manda un null encima de una
  // foto que el servidor sí tiene: una auditoría bajada por la versión anterior de la app (que no
  // guardaba estos campos) sube sin ellos y el servidor conserva los suyos (fusión de F0). La app
  // nunca borra una foto, así que no necesita mandar null.
  Map<String, dynamic> toJson({bool ajenas = true}) => conAjenas({
        'id': id,
        'nombre': nombre,
        'correlativo': correlativo,
        'tipo': tipo,
        'fromMaster': fromMaster,
        'masterId': masterId,
        'isDeleted': isDeleted,
        'estadoOperacional': estadoOperacional,
        'limpiezaBiofilm': limpiezaBiofilm,
        'impactoPeces': impactoPeces,
        'detectabilidad': detectabilidad,
        'comentario': comentario,
        'fotos': fotos.map((e) => e.toJson(ajenas: ajenas)).toList(),
        'audios': audios.map((e) => e.toJson(ajenas: ajenas)).toList(),
        'bacti': bacti,
        'bactiHongos': bactiHongos,
        // Solo en la copia local: no viaja al servidor.
        if (ajenas && labLocal.isNotEmpty) kLlaveLabLocal: (labLocal.toList()..sort()),
        if (equipoId != null) 'equipoId': equipoId,
        if (equipoAlias != null) 'equipoAlias': equipoAlias,
        if (equipoTipo != null) 'equipoTipo': equipoTipo,
        if (grupo != null) 'grupo': grupo,
        if (ubicacion != null) 'ubicacion': ubicacion,
        if (referencia != null) 'referencia': referencia,
      }, extra, incluir: ajenas);

  factory PuntoControl.fromJson(Map<String, dynamic> j) => PuntoControl(
        id: (j['id'] ?? '') as String,
        nombre: (j['nombre'] ?? '') as String,
        correlativo: j['correlativo'] as int?,
        tipo: j['tipo'] as String?,
        fromMaster: (j['fromMaster'] ?? false) as bool,
        masterId: j['masterId'] as String?,
        isDeleted: (j['isDeleted'] ?? false) as bool,
        estadoOperacional: j['estadoOperacional'] as int?,
        limpiezaBiofilm: j['limpiezaBiofilm'] as int?,
        impactoPeces: j['impactoPeces'] as int?,
        detectabilidad: j['detectabilidad'] as int?,
        comentario: j['comentario'] as String?,
        fotos: ((j['fotos'] ?? []) as List).map((e) => Evidencia.fromJson((e ?? {}) as Map<String, dynamic>)).toList(),
        audios: ((j['audios'] ?? []) as List).map((e) => Evidencia.fromJson((e ?? {}) as Map<String, dynamic>)).toList(),
        bacti: j['bacti'] as Map<String, dynamic>?,
        bactiHongos: j['bactiHongos'] as Map<String, dynamic>?,
        labLocal: {
          for (final x in (j[kLlaveLabLocal] is List ? j[kLlaveLabLocal] as List : const []))
            if (x is String) x,
        },
        equipoId: textoOpcional(j['equipoId']),
        equipoAlias: textoOpcional(j['equipoAlias']),
        equipoTipo: textoOpcional(j['equipoTipo']),
        grupo: textoOpcional(j['grupo']),
        ubicacion: textoOpcional(j['ubicacion']),
        referencia: textoOpcional(j['referencia']),
        extra: _llaves.ajenas(j),
      );
}

/// Un Sistema evaluado dentro del centro (transversal a Entrevista e Inspección/RPN).
class AuditSala {
  String id;
  String name;
  String? tipo; // estándar (null = Sin Tipo)
  bool fromMaster; // viene del maestro del centro: nombre y tipo inmutables en la auditoría
  String? masterId; // Id del sistema en el maestro (vínculo estable)
  String? afluente; // snapshot del afluente del sistema al auditar
  // Etapa del sistema al auditarlo (foto de la etapa del maestro: HATCHERY, FF…). Solo la llenan las
  // auditorías de un centro con el modelo con equipos; null = auditoría anterior o etapa por definir,
  // y ahí se muestra el tipo. Como la foto del punto, solo se escribe si tiene valor.
  String? etapa;
  bool isDeleted; // soft-delete recuperable
  Map<String, Answer> answers; // entrevista
  List<PuntoControl> puntosControl; // inspección RPN
  /// Llaves que esta versión no conoce: se guardan en la copia local, no se suben.
  Map<String, dynamic> extra;

  AuditSala({
    required this.id,
    this.name = '',
    this.tipo,
    this.fromMaster = false,
    this.masterId,
    this.afluente,
    this.etapa,
    this.isDeleted = false,
    Map<String, Answer>? answers,
    List<PuntoControl>? puntosControl,
    Map<String, dynamic>? extra,
  })  : answers = answers ?? {},
        puntosControl = puntosControl ?? [],
        extra = extra ?? {};

  static final _llaves = LlavesPropias(
      ['id', 'name', 'tipo', 'fromMaster', 'masterId', 'afluente', 'etapa', 'isDeleted', 'answers', 'puntosControl']);

  Map<String, dynamic> toJson({bool ajenas = true}) => conAjenas({
        'id': id,
        'name': name,
        'tipo': tipo,
        'fromMaster': fromMaster,
        'masterId': masterId,
        'afluente': afluente,
        if (etapa != null) 'etapa': etapa,
        'isDeleted': isDeleted,
        'answers': answers.map((k, v) => MapEntry(k, v.toJson(ajenas: ajenas))),
        'puntosControl': puntosControl.map((p) => p.toJson(ajenas: ajenas)).toList(),
      }, extra, incluir: ajenas);

  factory AuditSala.fromJson(Map<String, dynamic> j) => AuditSala(
        id: (j['id'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        tipo: j['tipo'] as String?,
        fromMaster: (j['fromMaster'] ?? false) as bool,
        masterId: j['masterId'] as String?,
        afluente: j['afluente'] as String?,
        etapa: textoOpcional(j['etapa']),
        isDeleted: (j['isDeleted'] ?? false) as bool,
        answers: ((j['answers'] ?? {}) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, Answer.fromJson((v ?? {}) as Map<String, dynamic>))),
        puntosControl: ((j['puntosControl'] ?? []) as List)
            .map((p) => PuntoControl.fromJson((p ?? {}) as Map<String, dynamic>))
            .toList(),
        extra: _llaves.ajenas(j),
      );
}

/// Contenido de la evaluación: respuestas de centro + salas repetibles + qué partes se aplican.
///
/// El documento del servidor tiene mucho más que esto (el informe, los comentarios, la comparativa…), que la app no
/// edita. Va en `extra`, que se guarda en la copia local pero NO se sube: la copia de la app puede estar vieja y
/// pisaría lo que se editó en la web; lo que el push no trae, el servidor lo conserva (fusión de F0).
class AuditDocument {
  Map<String, Answer> center;
  List<AuditSala> salas;
  // Las partes de la visita que se aplican (backlog 13-10, punto 18.8): la visita nace con nada activo y el evaluador
  // marca lo que hace, en la web o aquí. true = esa parte NO se hizo. null = el documento no lo trae (una evaluación
  // anterior, o creada por una app vieja): se lee como «se aplica», igual que en el servidor, y no se sube.
  bool? entrevistaDesactivada;
  bool? rpnDesactivado;
  bool? labDesactivado;
  /// Llaves que esta versión no conoce: se guardan en la copia local, no se suben.
  Map<String, dynamic> extra;

  AuditDocument({
    Map<String, Answer>? center,
    List<AuditSala>? salas,
    this.entrevistaDesactivada,
    this.rpnDesactivado,
    this.labDesactivado,
    Map<String, dynamic>? extra,
  })  : center = center ?? {},
        salas = salas ?? [],
        extra = extra ?? {};

  /// Una visita nueva, como la crea la web: sin nada activo.
  factory AuditDocument.nueva() =>
      AuditDocument(entrevistaDesactivada: true, rpnDesactivado: true, labDesactivado: true);

  bool get aplicaEntrevista => !(entrevistaDesactivada ?? false);
  bool get aplicaRpn => !(rpnDesactivado ?? false);
  bool get aplicaLab => !(labDesactivado ?? false);
  bool get nadaActivo => !aplicaEntrevista && !aplicaRpn && !aplicaLab;

  static final _llaves =
      LlavesPropias(['center', 'salas', 'entrevistaDesactivada', 'rpnDesactivado', 'labDesactivado']);

  /// [ajenas]: true para la copia local (SQLite), false para el push.
  ///
  /// Los interruptores sí se suben (los marca el evaluador). Es seguro aunque la copia esté vieja: el servidor mezcla
  /// contra la copia que esta tablet tenía, así que uno que la tablet no cambió no pisa lo que se marcó en la web.
  Map<String, dynamic> toJson({bool ajenas = true}) => conAjenas({
        'center': center.map((k, v) => MapEntry(k, v.toJson(ajenas: ajenas))),
        'salas': salas.map((s) => s.toJson(ajenas: ajenas)).toList(),
        if (entrevistaDesactivada != null) 'entrevistaDesactivada': entrevistaDesactivada,
        if (rpnDesactivado != null) 'rpnDesactivado': rpnDesactivado,
        if (labDesactivado != null) 'labDesactivado': labDesactivado,
      }, extra, incluir: ajenas);

  factory AuditDocument.fromJson(Map<String, dynamic> j) => AuditDocument(
        center: ((j['center'] ?? {}) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, Answer.fromJson((v ?? {}) as Map<String, dynamic>))),
        salas: ((j['salas'] ?? []) as List)
            .map((s) => AuditSala.fromJson(s as Map<String, dynamic>))
            .toList(),
        entrevistaDesactivada: booleanoOpcional(j['entrevistaDesactivada']),
        rpnDesactivado: booleanoOpcional(j['rpnDesactivado']),
        labDesactivado: booleanoOpcional(j['labDesactivado']),
        extra: _llaves.ajenas(j),
      );

  static AuditDocument decode(String? raw) =>
      (raw == null || raw.isEmpty) ? AuditDocument() : AuditDocument.fromJson(jsonDecode(raw));

  String encode() => jsonEncode(toJson());
}

/// Auditoría local (fuente de verdad en el dispositivo).
class Audit {
  final String id; // GUID generado en el cliente (offline-safe)
  int status;
  // Folio del informe, imputado por el auditor ANTES de muestrear (antes lo asignaba el servidor
  // al sincronizar, y en terreno sin señal no había número que rotular en el frasco). El servidor
  // solo arbitra que no se repita entre equipos.
  int? folio;
  int type; // 0=spot, 1=seguimiento
  String centerName;
  String? auditor;
  DateTime? sampledAtUtc;
  String? centerId;
  String? clientId;
  String? clientName;
  String? createdByName;
  DateTime? scheduledForUtc;
  String? previousAuditId; // serie (seguimiento -> auditoría anterior)
  AuditDocument document;
  DateTime createdAtUtc;
  DateTime updatedAtUtc;
  bool isDeleted;
  int serverVersion;
  bool dirty; // pendiente de subir
  /// Contador de escrituras del contenido de la fila local (cada guardado, cada copia que baja del servidor). No viaja.
  /// Con él se sabe si la fila cambió mientras un envío iba y volvía (markSynced) o si el servidor la reemplazó
  /// mientras el editor la tenía abierta (upsertLocal). Ver app_database.dart.
  int localRev;
  /// El folio tal como estaba cuando esta copia se leyó o se guardó por última vez (no se guarda). Si el evaluador no
  /// lo cambió desde entonces, el que manda es el de la fila: el servidor puede haberlo arbitrado (folio repetido).
  int? folioLeido;
  /// Campos de la cabecera que esta versión no conoce (hoy `ownerUserId` y `assignedToUserId`;
  /// mañana, por ejemplo, `muestreoId`): se guardan en SQLite (columna `extra`) para que la copia
  /// local quede completa, pero NO se suben. La app no los edita: reenviar su copia, que puede estar
  /// vieja, devolvería por ejemplo el auditor asignado a quien estaba cuando la tablet la bajó. El
  /// servidor deja como está todo campo de cabecera que el push no trae.
  Map<String, dynamic> extra;

  Audit({
    required this.id,
    this.status = 0,
    this.folio,
    this.type = 0,
    this.centerName = '(sin nombre)',
    this.auditor,
    this.sampledAtUtc,
    this.centerId,
    this.clientId,
    this.clientName,
    this.createdByName,
    this.scheduledForUtc,
    this.previousAuditId,
    AuditDocument? document,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.isDeleted = false,
    this.serverVersion = 0,
    this.dirty = true,
    this.localRev = 0,
    Map<String, dynamic>? extra,
  })  : document = document ?? AuditDocument(),
        extra = extra ?? {},
        folioLeido = folio;

  static final _llaves = LlavesPropias([
    'id', 'status', 'folio', 'type', 'centerName', 'auditor', 'sampledAtUtc', 'centerId', 'clientId', //
    'clientName', 'createdByName', 'scheduledForUtc', 'previousAuditId', 'document', 'createdAtUtc', //
    'updatedAtUtc', 'isDeleted', 'serverVersion',
  ]);

  static Map<String, dynamic> _decodeExtra(Object? raw) {
    if (raw is! String || raw.isEmpty) return {};
    try {
      return objetoOpcional(jsonDecode(raw)) ?? {};
    } catch (_) {
      return {};
    }
  }

  AuditStatus get statusEnum => auditStatusFromInt(status);
  AuditType get typeEnum => auditTypeFromInt(type);
  bool get isLocked => statusEnum.isLocked;

  // ---- SQLite ----
  Map<String, Object?> toRow() => {
        'id': id,
        'status': status,
        'folio': folio,
        'type': type,
        'center_name': centerName,
        'auditor': auditor,
        'sampled_at': sampledAtUtc?.toUtc().toIso8601String(),
        'center_id': centerId,
        'client_id': clientId,
        'client_name': clientName,
        'created_by_name': createdByName,
        'scheduled_for': scheduledForUtc?.toUtc().toIso8601String(),
        'previous_audit_id': previousAuditId,
        'document': document.encode(),
        'created_at': createdAtUtc.toUtc().toIso8601String(),
        'updated_at': updatedAtUtc.toUtc().toIso8601String(),
        'is_deleted': isDeleted ? 1 : 0,
        'server_version': serverVersion,
        'dirty': dirty ? 1 : 0,
        'local_rev': localRev,
        'extra': extra.isEmpty ? null : jsonEncode(extra),
      };

  factory Audit.fromRow(Map<String, Object?> r) => Audit(
        id: r['id'] as String,
        status: r['status'] as int,
        folio: r['folio'] as int?,
        type: (r['type'] as int?) ?? 0,
        centerName: r['center_name'] as String,
        auditor: r['auditor'] as String?,
        sampledAtUtc: (r['sampled_at'] as String?) != null ? DateTime.parse(r['sampled_at'] as String) : null,
        centerId: r['center_id'] as String?,
        clientId: r['client_id'] as String?,
        clientName: r['client_name'] as String?,
        createdByName: r['created_by_name'] as String?,
        scheduledForUtc: (r['scheduled_for'] as String?) != null ? DateTime.parse(r['scheduled_for'] as String) : null,
        previousAuditId: r['previous_audit_id'] as String?,
        document: AuditDocument.decode(r['document'] as String?),
        createdAtUtc: DateTime.parse(r['created_at'] as String),
        updatedAtUtc: DateTime.parse(r['updated_at'] as String),
        isDeleted: (r['is_deleted'] as int) == 1,
        serverVersion: r['server_version'] as int,
        dirty: (r['dirty'] as int) == 1,
        localRev: (r['local_rev'] as int?) ?? 0,
        extra: _decodeExtra(r['extra']),
      );

  // ---- API (DTO) ----
  // Solo los campos que la app conoce y edita, en todos los niveles: lo ajeno se queda en SQLite
  // (ver llaves_ajenas.dart).
  Map<String, dynamic> toDto() => {
        'id': id,
        'status': status,
        'folio': folio,
        'type': type,
        'centerName': centerName,
        'auditor': auditor,
        'sampledAtUtc': sampledAtUtc?.toUtc().toIso8601String(),
        'centerId': centerId,
        'clientId': clientId,
        'clientName': clientName,
        // Sin creador (una evaluación creada en la tablet) no se manda: lo pone el servidor con el nombre de quien la
        // sube. Mandarlo nulo hacía que la copia de la tablet no fuera la del servidor, y el envío siguiente se mezclaba
        // como atrasado (los interruptores recién marcados quedaban «no aplicados»).
        if (createdByName != null) 'createdByName': createdByName,
        'scheduledForUtc': scheduledForUtc?.toUtc().toIso8601String(),
        'previousAuditId': previousAuditId,
        'document': document.toJson(ajenas: false),
        'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
        'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
        'isDeleted': isDeleted,
        'serverVersion': serverVersion,
      };

  factory Audit.fromDto(Map<String, dynamic> d) => Audit(
        id: d['id'] as String,
        status: (d['status'] ?? 0) as int,
        folio: d['folio'] as int?,
        type: (d['type'] ?? 0) as int,
        centerName: (d['centerName'] ?? '(sin nombre)') as String,
        auditor: d['auditor'] as String?,
        sampledAtUtc: d['sampledAtUtc'] != null ? DateTime.parse(d['sampledAtUtc'] as String) : null,
        centerId: d['centerId'] as String?,
        clientId: d['clientId'] as String?,
        clientName: d['clientName'] as String?,
        createdByName: d['createdByName'] as String?,
        scheduledForUtc: d['scheduledForUtc'] != null ? DateTime.parse(d['scheduledForUtc'] as String) : null,
        previousAuditId: d['previousAuditId'] as String?,
        document: AuditDocument.fromJson((d['document'] ?? {}) as Map<String, dynamic>),
        createdAtUtc: DateTime.parse(d['createdAtUtc'] as String),
        updatedAtUtc: DateTime.parse(d['updatedAtUtc'] as String),
        isDeleted: (d['isDeleted'] ?? false) as bool,
        serverVersion: (d['serverVersion'] ?? 0) as int,
        dirty: false,
        extra: _llaves.ajenas(d),
      );
}
