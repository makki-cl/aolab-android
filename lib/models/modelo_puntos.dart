/// Cómo la app ofrece los puntos de un sistema del maestro y cómo nombra sistemas y puntos.
///
/// Son las mismas reglas del editor web y del editor offline (`MaestroAuditoria` y
/// `PresentacionAuditoria` en el servidor), para que una auditoría hecha en terreno quede igual que
/// una hecha en la web. Viven aparte de la pantalla para poder probarlas sin interfaz.
library;

import 'audit.dart';
import 'master.dart';

/// Un bloque de puntos dentro de una sección. En la sección «Equipos» hay un bloque por equipo, con
/// su alias como título (un equipo tiene entradas, interiores y salidas); en las demás, un solo
/// bloque sin título, porque el nombre de cada punto ya dice de qué es («Afluente Pozo», «POST UV»).
class BloquePuntos {
  final String? equipoId;
  final String? titulo;
  final String? equipoTipo;
  final List<PuntoControlDef> puntos;

  BloquePuntos({this.equipoId, this.titulo, this.equipoTipo, required this.puntos});
}

/// Una sección de la lista: afluentes, equipos, tramos, efluente. En el modelo plano hay una sola
/// sección con `grupo` null, que se muestra sin encabezado: la lista sale igual que siempre.
class SeccionPuntos {
  final String? grupo;
  final List<BloquePuntos> bloques;

  SeccionPuntos({this.grupo, required this.bloques});

  String get titulo => etiquetaGrupo(grupo);

  Iterable<PuntoControlDef> get puntos => bloques.expand((b) => b.puntos);
}

/// Agrupa los puntos de un sistema del maestro como se recorre el agua: afluentes, equipos (uno por
/// uno), tramos PRE/POST y efluente. Dentro de cada grupo se respeta el orden en que los mandó el
/// servidor, que es el del agua.
///
/// Nunca pierde un punto: los de un grupo que esta versión no conoce (un servidor más nuevo) van al
/// final con el rótulo «Puntos», igual que los que no traen grupo en una lista mezclada.
List<SeccionPuntos> agruparPuntos(List<PuntoControlDef> puntos) {
  final presentes = <String?>[];
  for (final p in puntos) {
    if (!presentes.contains(p.grupo)) presentes.add(p.grupo);
  }
  final orden = <String?>[
    for (final g in kGruposPunto)
      if (presentes.contains(g)) g,
    for (final g in presentes)
      if (!kGruposPunto.contains(g)) g,
  ];
  return [
    for (final g in orden)
      SeccionPuntos(
        grupo: g,
        bloques: g == kGrupoEquipo
            ? _porEquipo(puntos.where((p) => p.grupo == g).toList())
            : [BloquePuntos(puntos: puntos.where((p) => p.grupo == g).toList())],
      ),
  ];
}

// Un bloque por equipo, en el orden en que aparece cada uno.
List<BloquePuntos> _porEquipo(List<PuntoControlDef> puntos) {
  final bloques = <String, BloquePuntos>{};
  for (final p in puntos) {
    final llave = p.equipoId ?? '';
    bloques
        .putIfAbsent(
          llave,
          () => BloquePuntos(
            equipoId: p.equipoId,
            titulo: (p.equipoAlias?.trim().isNotEmpty ?? false) ? p.equipoAlias!.trim() : 'Equipo',
            equipoTipo: p.equipoTipo,
            puntos: [],
          ),
        )
        .puntos
        .add(p);
  }
  return bloques.values.toList();
}

/// El equipo de un punto de equipo o de tramo, si su nombre no lo dice ya: «POST UV» · «UV 2» cuando
/// hay dos UV en la sala. Null en el modelo plano.
String? equipoAMostrar(PuntoControlDef pd) {
  final equipo = pd.equipoAlias?.trim() ?? '';
  if (pd.grupo != kGrupoEquipo && pd.grupo != kGrupoTramo) return null;
  if (equipo.isEmpty || pd.alias.toLowerCase().contains(equipo.toLowerCase())) return null;
  return equipo;
}

/// Cómo se rotula un sistema del maestro al elegirlo: en un centro activado, la etiqueta de su etapa
/// («Smolt»); si no, o si la etapa está por definir, su tipo de siempre.
String? rotuloSistema(Sistema m, {required bool conEquipos}) =>
    conEquipos && esEtapa(m.etapa) ? etiquetaEtapa(m.etapa) : m.tipo;

/// El tipo de un sistema de la auditoría: la etapa con su etiqueta si la auditoría la guardó (centro
/// activado); si no, el tipo de siempre (SF, AFLUENTE…).
String? tipoUnidad(AuditSala s) => esEtapa(s.etapa) ? etiquetaEtapa(s.etapa) : s.tipo;

/// El equipo de un punto de la auditoría para mostrar junto a su nombre, si la foto lo trae y el
/// nombre no lo dice ya. Null en los puntos del modelo plano y en los ad hoc.
String? equipoDelPunto(PuntoControl p) {
  final equipo = p.equipoAlias?.trim() ?? '';
  if (equipo.isEmpty || p.nombre.toLowerCase().contains(equipo.toLowerCase())) return null;
  return equipo;
}

/// ¿Este punto de la auditoría es ese punto del maestro? Por Id. Los puntos guardados antes de que
/// existiera el Id se reconocen por alias + tipo (un sistema puede tener dos puntos con el mismo
/// alias, Pre y Post), pero solo contra el modelo plano: en el modelo con equipos el nombre es
/// automático y cambia con la topología, así que podría marcar el punto equivocado.
bool esMismoPunto(PuntoControl p, PuntoControlDef pd) {
  if (pd.id.isNotEmpty && p.masterId == pd.id) return true;
  if (p.masterId != null && p.masterId!.isNotEmpty) return false;
  if (pd.grupo != null) return false;
  return p.nombre.trim().toLowerCase() == pd.alias.trim().toLowerCase() &&
      (p.tipo ?? '').trim().toLowerCase() == (pd.tipo ?? '').trim().toLowerCase();
}

/// ¿Este sistema de la auditoría es ese sistema del maestro? Por Id; los guardados antes del Id, por
/// nombre (la misma regla con que la pantalla los marca).
bool esMismoSistema(AuditSala s, Sistema m) {
  if (!s.fromMaster) return false;
  if (m.id.isNotEmpty && s.masterId == m.id) return true;
  return (s.masterId == null || s.masterId!.isEmpty) && s.name.trim().toLowerCase() == m.nombre.trim().toLowerCase();
}

/// Los sistemas del maestro que la auditoría tiene marcados (o en la papelera, con [eliminados]) y
/// que el maestro ya no trae: en un centro activado el servidor no manda lo retirado. Sin esto
/// desaparecían de la pestaña Sistemas y no se podían ver ni quitar.
List<AuditSala> sistemasFueraDelMaestro(List<AuditSala> salas, List<Sistema> maestro, {bool eliminados = false}) => [
      for (final s in salas)
        if (s.fromMaster && s.isDeleted == eliminados && !maestro.any((m) => esMismoSistema(s, m))) s,
    ];

/// Los puntos del maestro que la auditoría tiene marcados en un sistema y que el maestro ya no trae
/// (retirados, o del modelo anterior en una auditoría abierta antes de activar el modelo con equipos).
List<PuntoControl> puntosFueraDelMaestro(AuditSala sala, List<PuntoControlDef> maestro) => [
      for (final p in sala.puntosControl)
        if (p.fromMaster && !p.isDeleted && !maestro.any((pd) => esMismoPunto(p, pd))) p,
    ];

/// El punto de la auditoría para un punto del maestro: una FOTO. El nombre y el tipo y, en un centro
/// activado, el equipo, su tipo, el grupo, la ubicación y la referencia PRE/POST al momento de
/// auditar. En un centro en el modelo plano sale exactamente como antes: alias y tipo.
PuntoControl puntoDesdeMaestro(PuntoControlDef pd, {required String id, required bool conEquipos}) => PuntoControl(
      id: id,
      masterId: pd.id,
      nombre: pd.alias,
      tipo: pd.tipo,
      fromMaster: true,
      equipoId: conEquipos ? pd.equipoId : null,
      equipoAlias: conEquipos ? pd.equipoAlias : null,
      equipoTipo: conEquipos ? pd.equipoTipo : null,
      grupo: conEquipos ? pd.grupo : null,
      ubicacion: conEquipos ? pd.ubicacion : null,
      referencia: conEquipos ? pd.referencia : null,
    );
