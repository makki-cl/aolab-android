/// Maestros read-only sincronizados desde la web (solo pull). Se usan para poblar
/// los selectores de cliente/centro/auditor al crear/editar una auditoría en terreno.
import 'dart:convert';

import 'llaves_ajenas.dart';
import 'niveles.dart';

/// Tipos de sistema estándar (lista fija; "Sin Tipo" se representa como null). Es el RESPALDO del
/// catálogo `sistema-tipo` mientras la app no sincroniza: la misma lista que la semilla del
/// servidor (`SistemaTipos.All`), que incluye SF porque hay centros que la usan como tipo.
// Orden del proceso: agua de entrada → etapas de cultivo → agua de salida.
const List<String> kSistemaTipos = ['AFLUENTE', 'HATCHERY', 'FF', 'SF', 'FRY', 'PRE-SMOLT', 'SMOLT', 'EFLUENTE'];

/// Etapas de un sistema de cultivo (código → etiqueta), en el orden del ciclo. Es una lista cerrada
/// en el servidor (`EtapasSistema`): informes, comparativas e ICA agrupan por etapa. El catálogo
/// `sistema-etapa` solo trae los códigos; las etiquetas viven aquí. «SF» NO es etapa: es un alias.
const Map<String, String> kEtapasSistema = {
  'HATCHERY': 'Hatchery',
  'FF': 'First Feeding',
  'FRY': 'Fry',
  'PRE-SMOLT': 'Pre Smolt',
  'SMOLT': 'Smolt',
};

/// ¿Es un código de etapa conocido?
bool esEtapa(String? codigo) => codigo != null && kEtapasSistema.containsKey(codigo);

/// Etiqueta de una etapa: «First Feeding», «Pre Smolt»… Un código desconocido se muestra tal cual y
/// null es «Etapa por definir» (igual que `EtapasSistema.Etiqueta` del servidor).
String etiquetaEtapa(String? codigo) =>
    (codigo == null || codigo.isEmpty) ? 'Etapa por definir' : (kEtapasSistema[codigo] ?? codigo);

/// En qué parte del sistema está un punto del modelo con equipos (`GruposPunto` del servidor), en
/// el orden en que se muestran: el del agua.
const String kGrupoAfluente = 'afluente';
const String kGrupoEquipo = 'equipo';
const String kGrupoTramo = 'tramo';
const String kGrupoEfluente = 'efluente';
const List<String> kGruposPunto = [kGrupoAfluente, kGrupoEquipo, kGrupoTramo, kGrupoEfluente];

/// Rótulo de un grupo de puntos. Uno que esta versión no conoce (de un servidor más nuevo) se rotula
/// «Puntos», igual que en el servidor, para no perder esos puntos.
String etiquetaGrupo(String? grupo) => switch (grupo) {
      kGrupoAfluente => 'Afluentes',
      kGrupoEquipo => 'Equipos',
      kGrupoTramo => 'Tramos (PRE / POST)',
      kGrupoEfluente => 'Efluente',
      _ => 'Puntos',
    };

/// Afluentes estándar (lista fija, no editable por el usuario).
const List<String> kAfluenteTipos = ['Dulce', 'Mar', 'Mixta'];

/// Tipos estándar de punto de control (lista fija; "Sin Tipo" = null).
const List<String> kPuntoControlTipos = [
  'Make Up / Ingreso Afluente',
  'Pre Rotatorio',
  'Post Rotatorio',
  'Pre UV',
  'Post UV',
  'Pre Filtro Arena',
  'Post Filtro Arena',
  'Ozono',
  'Biofiltro',
  'Trickling',
  'Desgasificador',
  'LHO / Oxigenación',
  'Microfiltro',
  'Estanque Cabecera',
  'Estanque Acumulación / Reservorio',
  'Interior Estanque',
  'Cono',
  'Efluente',
  'Batea / Incubación',
  'Pozo / Bomba',
  'Chiller / Enfriamiento',
  'Otro',
];

/// Definición de un punto de control en el maestro del centro: alias + tipo estándar.
///
/// En un centro con el modelo con equipos activo (F3), el servidor manda aquí la lista APLANADA de
/// ese modelo: `alias` es el nombre (el alias del punto o el automático, «POST UV», «Estanque 4 ·
/// Entrada») y `tipo` el del modelo plano que le corresponde, así el RPN sigue funcionando. Además
/// trae el equipo, el grupo y la ubicación del punto. En el modelo plano esos campos vienen en null.
class PuntoControlDef {
  String id; // PK estable en el maestro (permite renombrar sin perder el vínculo)
  String alias;
  String? tipo;
  // ── Modelo con equipos (F3). Null en el modelo plano. ──
  String? equipoId; // equipo del punto (en un tramo, el equipo con que se nombra)
  String? equipoAlias; // cómo se llama ese equipo en el centro
  String? equipoTipo; // tipo estándar del equipo (o tipo de afluente)
  String? grupo; // afluente | equipo | tramo | efluente (kGruposPunto)
  String? ubicacion; // entrada | salida | interior | tramo
  String? referencia; // solo tramos: pre | post
  int? orden; // orden del agua dentro del sistema
  // ── Posición por nivel (19-10-2026): solo en un punto de nivel de un grupo efímero. ──
  int? nivelGrupo; // hasta qué nivel del grupo se anota la posición (1 = «Rack», 2 = «Balde»)
  List<NivelGrupoDef> nivelesGrupo; // los niveles del grupo hasta el del punto
  /// Llaves que esta versión no conoce: se guardan y se reemiten tal cual.
  Map<String, dynamic> extra;

  PuntoControlDef({
    this.id = '',
    this.alias = '',
    this.tipo,
    this.equipoId,
    this.equipoAlias,
    this.equipoTipo,
    this.grupo,
    this.ubicacion,
    this.referencia,
    this.orden,
    this.nivelGrupo,
    List<NivelGrupoDef>? nivelesGrupo,
    Map<String, dynamic>? extra,
  })  : nivelesGrupo = nivelesGrupo ?? [],
        extra = extra ?? {};

  static final _llaves = LlavesPropias([
    'id', 'alias', 'tipo', 'equipoId', 'equipoAlias', 'equipoTipo', 'grupo', 'ubicacion', 'referencia', 'orden', //
    'nivelGrupo', 'nivelesGrupo',
  ]);

  /// Si es un punto de nivel de un grupo efímero, lo que hace falta para anotar su posición (null si no lo es). El grupo
  /// es su equipo: el aplanado entrega el punto de un nivel como punto del equipo-grupo.
  NivelPunto? get nivelPunto {
    final n = nivelGrupo;
    if (n == null || n < 1 || nivelesGrupo.isEmpty) return null;
    final niveles = [...nivelesGrupo]..sort((a, b) => a.nivel.compareTo(b.nivel));
    return NivelPunto(grupoId: equipoId ?? id, nivel: n > niveles.length ? niveles.length : n, niveles: niveles);
  }

  // Los campos nuevos solo se escriben si tienen valor: el blob de un centro en el modelo plano
  // queda igual que antes.
  Map<String, dynamic> toJson() => conAjenas({
        'id': id,
        'alias': alias,
        'tipo': tipo,
        if (equipoId != null) 'equipoId': equipoId,
        if (equipoAlias != null) 'equipoAlias': equipoAlias,
        if (equipoTipo != null) 'equipoTipo': equipoTipo,
        if (grupo != null) 'grupo': grupo,
        if (ubicacion != null) 'ubicacion': ubicacion,
        if (referencia != null) 'referencia': referencia,
        if (orden != null) 'orden': orden,
        if (nivelGrupo != null) 'nivelGrupo': nivelGrupo,
        if (nivelesGrupo.isNotEmpty) 'nivelesGrupo': nivelesGrupo.map((n) => n.toJson()).toList(),
      }, extra);

  factory PuntoControlDef.fromJson(Map<String, dynamic> j) => PuntoControlDef(
        id: (j['id'] ?? '') as String,
        alias: (j['alias'] ?? '') as String,
        tipo: j['tipo'] as String?,
        equipoId: textoOpcional(j['equipoId']),
        equipoAlias: textoOpcional(j['equipoAlias']),
        equipoTipo: textoOpcional(j['equipoTipo']),
        grupo: textoOpcional(j['grupo']),
        ubicacion: textoOpcional(j['ubicacion']),
        referencia: textoOpcional(j['referencia']),
        orden: enteroOpcional(j['orden']),
        nivelGrupo: enteroOpcional(j['nivelGrupo']),
        nivelesGrupo: (j['nivelesGrupo'] is List ? j['nivelesGrupo'] as List : const [])
            .map(NivelGrupoDef.fromJson)
            .whereType<NivelGrupoDef>()
            .toList(),
        extra: _llaves.ajenas(j),
      );
}

/// Un afluente de un sistema del modelo con equipos (de dónde le llega el agua, con su tipo). Sus
/// puntos vienen en `Sistema.puntosControl` con grupo `afluente`.
class AfluenteDef {
  String id;
  String nombre; // su alias o, si no tiene, «Afluente {tipo}»
  String? alias;
  String? tipo; // catálogo afluente-tipo: Agua Dulce, Noria, Pozo, Río, Lago, Agua Mar
  Map<String, dynamic> extra;

  AfluenteDef({this.id = '', this.nombre = '', this.alias, this.tipo, Map<String, dynamic>? extra})
      : extra = extra ?? {};

  static final _llaves = LlavesPropias(['id', 'nombre', 'alias', 'tipo']);

  Map<String, dynamic> toJson() => conAjenas({'id': id, 'nombre': nombre, 'alias': alias, 'tipo': tipo}, extra);

  factory AfluenteDef.fromJson(Map<String, dynamic> j) => AfluenteDef(
        id: textoOpcional(j['id']) ?? '',
        nombre: textoOpcional(j['nombre']) ?? '',
        alias: textoOpcional(j['alias']),
        tipo: textoOpcional(j['tipo']),
        extra: _llaves.ajenas(j),
      );
}

/// Sistema (sala) predefinido de un centro: nombre (alias, jerga del centro) + tipo estándar
/// (null = Sin Tipo), afluente del sistema (si el centro es "multi afluente") y sus puntos de control.
/// Desde F2/F3 trae además la etapa, la clase y, en un centro con el modelo con equipos, sus afluentes.
class Sistema {
  String id; // PK estable en el maestro
  String nombre;
  String? tipo; // en un centro activado: el código de la etapa (o el tipo de siempre si no tiene)
  String? afluente;
  String? etapa; // HATCHERY, FF, FRY, PRE-SMOLT, SMOLT (kEtapasSistema); null = por definir
  String? clase; // cultivo | tratamiento
  List<AfluenteDef> afluentes; // vacía en el modelo plano
  List<PuntoControlDef> puntosControl;
  Map<String, dynamic> extra;

  Sistema({
    this.id = '',
    this.nombre = '',
    this.tipo,
    this.afluente,
    this.etapa,
    this.clase,
    List<AfluenteDef>? afluentes,
    List<PuntoControlDef>? puntosControl,
    Map<String, dynamic>? extra,
  })  : afluentes = afluentes ?? [],
        puntosControl = puntosControl ?? [],
        extra = extra ?? {};

  static final _llaves =
      LlavesPropias(['id', 'nombre', 'tipo', 'afluente', 'etapa', 'clase', 'afluentes', 'puntosControl']);

  Map<String, dynamic> toJson() => conAjenas({
        'id': id,
        'nombre': nombre,
        'tipo': tipo,
        'afluente': afluente,
        if (etapa != null) 'etapa': etapa,
        if (clase != null) 'clase': clase,
        if (afluentes.isNotEmpty) 'afluentes': afluentes.map((a) => a.toJson()).toList(),
        'puntosControl': puntosControl.map((p) => p.toJson()).toList(),
      }, extra);

  factory Sistema.fromJson(Map<String, dynamic> j) => Sistema(
        id: (j['id'] ?? '') as String,
        nombre: (j['nombre'] ?? '') as String,
        tipo: j['tipo'] as String?,
        afluente: j['afluente'] as String?,
        etapa: textoOpcional(j['etapa']),
        clase: textoOpcional(j['clase']),
        afluentes: (j['afluentes'] is List ? j['afluentes'] as List : const [])
            .map(objetoOpcional)
            .whereType<Map<String, dynamic>>()
            .map(AfluenteDef.fromJson)
            .toList(),
        puntosControl: ((j['puntosControl'] ?? []) as List)
            .map((e) => PuntoControlDef.fromJson((e ?? {}) as Map<String, dynamic>))
            .toList(),
        extra: _llaves.ajenas(j),
      );
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
  String? afluenteMode; // 'single' | 'multi' (null = single)
  String? afluente; // afluente del centro cuando es "single"
  List<Sistema> sistemas; // sistemas del maestro (nombre + tipo + afluente + puntos)
  // Versión del modelo del centro: 1 = plano, 2 = con equipos (F2). Un servidor anterior no la
  // manda: se lee como 1, que es lo que esos centros eran.
  int modeloVersion;
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
    this.afluenteMode,
    this.afluente,
    List<Sistema>? sistemas,
    this.modeloVersion = 1,
    this.isActive = true,
    this.isDeleted = false,
    this.serverVersion = 0,
  }) : sistemas = sistemas ?? [];

  /// ¿Tiene activo el modelo con equipos? Ahí los puntos llegan agrupados y con su equipo.
  bool get conEquipos => modeloVersion >= 2;

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'code': code,
        'latitude': latitude,
        'longitude': longitude,
        'owner_client_id': ownerClientId,
        'operator_name': operatorName,
        'afluente_mode': afluenteMode,
        'afluente': afluente,
        'sistemas': jsonEncode(sistemas.map((s) => s.toJson()).toList()),
        'modelo_version': modeloVersion,
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
        afluenteMode: r['afluente_mode'] as String?,
        afluente: r['afluente'] as String?,
        sistemas: _decodeSistemas(r['sistemas'] as String?),
        modeloVersion: enteroOpcional(r['modelo_version']) ?? 1,
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
        afluenteMode: d['afluenteMode'] as String?,
        afluente: d['afluente'] as String?,
        sistemas: ((d['sistemas'] ?? []) as List)
            .map((e) => Sistema.fromJson((e ?? {}) as Map<String, dynamic>))
            .toList(),
        modeloVersion: enteroOpcional(d['modeloVersion']) ?? 1,
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
