/// Cómo la app ofrece los puntos de un sistema del maestro y cómo nombra sistemas y puntos.
///
/// Son las mismas reglas del editor web y del editor offline (`MaestroAuditoria` y
/// `PresentacionAuditoria` en el servidor), para que una auditoría hecha en terreno quede igual que
/// una hecha en la web. Viven aparte de la pantalla para poder probarlas sin interfaz.
library;

import 'audit.dart';
import 'clases_sistema.dart';
import 'master.dart';
import 'niveles.dart';

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

// ════════════════════════════════════════════════════════════════════════
// El punto de la evaluación: su nombre, lo que va debajo y sus muestras
// ════════════════════════════════════════════════════════════════════════

/// El nombre de un punto de la evaluación, como en la web y en el informe (`PresentacionAuditoria.NombrePunto`): el suyo;
/// con la posición de bateas/baldes, «{equipo} · Rack 3 · Batea 7»; con la posición por nivel, «Racks 8° · Rack · Salida —
/// Rack 17 (final)»; y, si trae su equipo y el nombre no lo nombra, «POST UV · UV 2». Con [conPosicion] false, sin la
/// posición (para una pantalla que la muestra en su propio editor).
String nombrePunto(PuntoControl p, {bool conPosicion = true}) {
  final nombre = p.nombre.trim().isEmpty ? 'Punto' : p.nombre.trim();
  final posicion = p.posicionEtiqueta;
  if (conPosicion && posicion != null) {
    final eq = p.equipoAlias?.trim() ?? '';
    return '${eq.isNotEmpty ? eq : nombre} · $posicion';
  }
  if (conPosicion) {
    final niveles = etiquetaNiveles(p);
    if (niveles != null) return '$nombre — $niveles';
  }
  final equipo = p.equipoAlias?.trim() ?? '';
  return equipo.isEmpty || nombre.toLowerCase().contains(equipo.toLowerCase()) ? nombre : '$nombre · $equipo';
}

/// La etiqueta de la posición por nivel de un punto: la foto guardada o, si no vino, «17 (final) › 1844 (principio)».
/// Null sin niveles (`PresentacionAuditoria.EtiquetaNiveles`).
String? etiquetaNiveles(PuntoControl p) {
  final l = p.niveles;
  if (l == null || l.isEmpty) return null;
  final foto = p.nivelesEtiqueta?.trim() ?? '';
  if (foto.isNotEmpty) return foto;
  final orden = l.where((x) => x.nivel >= 1 && x.nivel <= 3).toList()..sort((a, b) => a.nivel.compareTo(b.nivel));
  if (orden.isEmpty) return null;
  return orden
      .map((x) =>
          '${(x.numero == null || x.numero!.trim().isEmpty) ? 'Nivel ${x.nivel}' : x.numero!.trim()} (${x.posicion?.trim() ?? 'sin posición'})')
      .join(' › ');
}

/// Lo que va debajo del nombre de un punto del maestro, chico (la regla vigente del 18-10-2026): en un tramo que se nombra
/// por el alias de su equipo («POST Manifold»), el tipo de ese equipo («Estanque Cabecera»); en los demás, el tipo del
/// punto, salvo que el nombre ya lo diga («POST UV» no repite «Post UV»). Null si no hay nada que agregar.
String? tipoDebajo({required String nombre, String? tipo, String? grupo, String? equipoAlias, String? equipoTipo}) {
  final n = nombre.trim().toLowerCase();
  final alias = equipoAlias?.trim() ?? '';
  final eqTipo = equipoTipo?.trim() ?? '';
  if (grupo == kGrupoTramo && alias.isNotEmpty && eqTipo.isNotEmpty && n.contains(alias.toLowerCase())) {
    final corta = etiquetaCortaTipo(eqTipo);
    final aliasEsTipo = alias.toLowerCase() == eqTipo.toLowerCase() || alias.toLowerCase() == corta.toLowerCase();
    if (!aliasEsTipo) return corta;
  }
  final t = tipo?.trim() ?? '';
  if (t.isEmpty || t.toLowerCase() == n) return null;
  return t;
}

String? tipoDebajoDef(PuntoControlDef pd) =>
    tipoDebajo(nombre: pd.alias, tipo: pd.tipo, grupo: pd.grupo, equipoAlias: pd.equipoAlias, equipoTipo: pd.equipoTipo);

String? tipoDebajoPunto(PuntoControl p) =>
    tipoDebajo(nombre: p.nombre, tipo: p.tipo, grupo: p.grupo, equipoAlias: p.equipoAlias, equipoTipo: p.equipoTipo);

/// Las muestras vigentes de un punto del maestro en un sistema de la evaluación: una por punto del documento con ese
/// masterId (un punto de nivel puede tener varias: «+ Otro rack»).
List<PuntoControl> muestrasDe(AuditSala sala, PuntoControlDef pd) =>
    [for (final p in sala.puntosControl) if (!p.isDeleted && p.fromMaster && esMismoPunto(p, pd)) p];

/// Marca un punto del maestro: si ya tiene una muestra, nada; si tenía una en la papelera, vuelve esa (con lo que tenía);
/// si no, una nueva con la foto del maestro. Igual que la web.
void incluirPunto(AuditSala sala, PuntoControlDef pd, {required bool conEquipos, required String Function() nuevoId}) {
  if (muestrasDe(sala, pd).isNotEmpty) return;
  for (final p in sala.puntosControl) {
    if (p.fromMaster && esMismoPunto(p, pd)) {
      p.isDeleted = false;
      return;
    }
  }
  sala.puntosControl.add(puntoDesdeMaestro(pd, id: nuevoId(), conEquipos: conEquipos));
}

/// Desmarca un punto del maestro: todas sus muestras van a la papelera (cada una conserva lo anotado). Devuelve cuántas.
int quitarPunto(AuditSala sala, PuntoControlDef pd) {
  final l = muestrasDe(sala, pd);
  for (final p in l) {
    p.isDeleted = true;
  }
  return l.length;
}

/// «+ Otro rack»: otra muestra del mismo punto de nivel (otro punto del documento con el mismo masterId), con los niveles
/// de arriba ya llenos como la última (el mismo rack, otro balde). Las posiciones copiadas son de esta tablet: se pueden
/// corregir hasta que suban.
PuntoControl otraMuestra(PuntoControlDef pd, NivelPunto ng, {PuntoControl? ultima, required bool conEquipos, required String id}) {
  final nuevo = puntoDesdeMaestro(pd, id: id, conEquipos: conEquipos);
  if (ng.nivel > 1 && ultima != null) anotarNiveles(nuevo, ng, ultima.nivelesMuestra.hastaNivel(ng.nivel - 1));
  return nuevo;
}

/// Anota (o quita, vacía) la posición por nivel de un punto de nivel, con su etiqueta como foto (`ModeloAuditoria.
/// AnotarNiveles`): los números se normalizan; la posición de un nivel puede faltar mientras se escribe (se avisa al
/// finalizar), pero lo anotado tiene que ser válido. Queda marcada como de esta tablet. Devuelve el error, o null.
String? anotarNiveles(PuntoControl p, NivelPunto ng, NivelesMuestra n) {
  if (n.vacia) {
    p.niveles = null;
    p.nivelesEtiqueta = null;
    p.nivelesLocal = true;
    return null;
  }
  if (n.hasta > ng.nivel) return '${ng.nombreNivel(ng.nivel)} es el último nivel de este punto.';
  final normal = PosicionesNivel.normalizarNumeros(ng, n);
  if (normal.error != null) return normal.error;
  final m = normal.niveles;
  for (var k = 1; k <= m.hasta; k++) {
    final pos = m.posicion(k);
    if (pos != null && !TramosGrupo.valido(pos)) return 'La posición es principio, medio o final.';
  }
  final l = [
    for (var k = 1; k <= ng.nivel; k++)
      if (m.posicion(k) != null || m.numero(k) != null) PosicionNivel(nivel: k, posicion: m.posicion(k), numero: m.numero(k)),
  ];
  p.niveles = l.isEmpty ? null : l;
  p.nivelesEtiqueta = PosicionesNivel.foto(ng.nombres, m);
  p.nivelesLocal = true;
  return null;
}

/// ¿Se puede cambiar la posición de esta muestra en la tablet? Solo si no tiene, o si la anotó esta tablet y todavía no
/// sube: una que el servidor ya tiene la manda la web (un envío no la cambia), así que se corrige allá.
bool posicionEditable(PuntoControl p) => !p.tieneNiveles || p.nivelesLocal;

/// El punto del maestro (de un sistema del maestro) que es este punto de la evaluación, o null.
PuntoControlDef? defDelPunto(PuntoControl p, Sistema? m) {
  if (m == null || !p.fromMaster) return null;
  for (final pd in m.puntosControl) {
    if (esMismoPunto(p, pd)) return pd;
  }
  return null;
}

/// El sistema del maestro que es este sistema de la evaluación, o null.
Sistema? sistemaDelMaestro(AuditSala s, List<Sistema> maestro) {
  for (final m in maestro) {
    if (esMismoSistema(s, m)) return m;
  }
  return null;
}

/// Lo ya anotado en la evaluación (el documento es el muestreo) en los puntos de nivel del grupo, sin [excepto]: con esto
/// se completan solas las posiciones y salen los chips.
ReusoNiveles reusoDelDocumento(AuditDocument doc, String grupoId, {PuntoControl? excepto}) => ReusoNiveles([
      for (final s in doc.salas.where((s) => !s.isDeleted))
        for (final p in s.puntosControl)
          if (!p.isDeleted && !identical(p, excepto) && p.tieneNiveles && (p.equipoId ?? '') == grupoId)
            (grupoId: grupoId, niveles: p.nivelesMuestra),
    ]);

/// Los puntos de nivel de la evaluación a los que les falta la posición de algún nivel (o la tienen mal), para avisar al
/// finalizar. No bloquea: la web la puede completar.
List<({AuditSala sala, PuntoControl punto})> sinPosicion(AuditDocument doc, List<Sistema> maestro) {
  final l = <({AuditSala sala, PuntoControl punto})>[];
  for (final s in doc.salas.where((s) => !s.isDeleted)) {
    final m = sistemaDelMaestro(s, maestro);
    for (final p in s.puntosControl.where((p) => !p.isDeleted)) {
      final ng = defDelPunto(p, m)?.nivelPunto;
      if (ng == null) continue;
      final r = PosicionesNivel.revisar(ng, p.nivelesMuestra);
      if (r.error != null || r.niveles.vacia) l.add((sala: s, punto: p));
    }
  }
  return l;
}

// ════════════════════════════════════════════════════════════════════════
// Orden de los sistemas y de los puntos: como la lista lateral del editor
// ════════════════════════════════════════════════════════════════════════

/// Los sistemas del maestro agrupados por su tipo, en el orden de la lista lateral del editor de modelos (Afluente →
/// Tratamiento de Agua → Proceso de Salmón → Tratamiento de Salmón → Efluente). Dentro de cada tipo, el orden del maestro.
List<({String clase, List<Sistema> sistemas})> sistemasPorClase(List<Sistema> sistemas) => [
      for (final c in kOrdenClases)
        if (sistemas.any((s) => claseDe(s.clase) == c)) (clase: c, sistemas: [for (final s in sistemas) if (claseDe(s.clase) == c) s]),
    ];

/// La clase de un sistema de la evaluación (la de su sistema del maestro), o null si es adicional o el maestro no lo trae.
String? claseDeSala(AuditSala s, List<Sistema> maestro) {
  final m = sistemaDelMaestro(s, maestro);
  return m == null ? null : claseDe(m.clase);
}

/// Los sistemas de la evaluación en el orden de la lista lateral: por tipo y, dentro, como el maestro; los adicionales (y
/// los que el maestro ya no trae) al final, como están.
List<AuditSala> ordenarSalas(List<AuditSala> salas, List<Sistema> maestro) {
  int llave(AuditSala s) {
    for (var i = 0; i < maestro.length; i++) {
      if (esMismoSistema(s, maestro[i])) return kOrdenClases.indexOf(claseDe(maestro[i].clase)) * 100000 + i;
    }
    return 1 << 30;
  }

  final conIndice = [for (var i = 0; i < salas.length; i++) (i: i, s: salas[i], k: llave(salas[i]))];
  conIndice.sort((a, b) => a.k != b.k ? a.k.compareTo(b.k) : a.i.compareTo(b.i));
  return [for (final x in conIndice) x.s];
}

/// Los puntos de un sistema de la evaluación en el orden del agua (el del maestro); las muestras de un mismo punto, juntas
/// y en el orden en que se anotaron; los puntos adicionales y los que el maestro ya no trae, al final.
List<PuntoControl> ordenarPuntos(List<PuntoControl> puntos, Sistema? m) {
  if (m == null) return puntos;
  int llave(PuntoControl p) {
    for (var i = 0; i < m.puntosControl.length; i++) {
      if (p.fromMaster && esMismoPunto(p, m.puntosControl[i])) return i;
    }
    return 1 << 30;
  }

  final conIndice = [for (var i = 0; i < puntos.length; i++) (i: i, p: puntos[i], k: llave(puntos[i]))];
  conIndice.sort((a, b) => a.k != b.k ? a.k.compareTo(b.k) : a.i.compareTo(b.i));
  return [for (final x in conIndice) x.p];
}

/// La ficha de un sistema del maestro (su subtipo): en un Proceso de Salmón, su etapa («Hatchery»); en un Afluente, el
/// tipo de su agua («Noria», «Río»). Los demás tipos no llevan ficha: el grupo ya dice qué son. En un centro con el modelo
/// plano, el tipo de siempre. Nunca el agua «Dulce / Mar / Mixta» del modelo plano.
String? fichaSistema(Sistema m, {required bool conEquipos}) {
  if (!conEquipos) return (m.tipo == null || m.tipo!.trim().isEmpty) ? null : m.tipo;
  return switch (claseDe(m.clase)) {
    kClaseCultivo => esEtapa(m.etapa) ? etiquetaEtapa(m.etapa) : null,
    kClaseAfluente => () {
        final tipos = <String>[];
        for (final a in m.afluentes) {
          final t = a.tipo?.trim() ?? '';
          if (t.isNotEmpty && !tipos.contains(t)) tipos.add(t);
        }
        return tipos.isEmpty ? null : tipos.join(' · ');
      }(),
    _ => null,
  };
}

/// La ficha de un sistema de la evaluación: la de su sistema del maestro si está; si no, su etapa o su tipo guardado.
String? fichaSala(AuditSala s, List<Sistema> maestro, {required bool conEquipos}) {
  final m = sistemaDelMaestro(s, maestro);
  if (m != null) return fichaSistema(m, conEquipos: conEquipos);
  return tipoUnidad(s);
}

// ════════════════════════════════════════════════════════════════════════
// Las muestras de un sistema agrupadas como la lista del maestro (RPN y Muestreo)
// ════════════════════════════════════════════════════════════════════════

/// Un bloque de muestras: las de un equipo (con su alias como título) o, en las demás secciones, todas juntas.
class BloqueMuestras {
  final String? titulo;
  final String? equipoTipo;
  final List<PuntoControl> puntos;

  BloqueMuestras({this.titulo, this.equipoTipo, required this.puntos});
}

/// Una sección de muestras con su título («Afluentes», «Equipos», «Tramos (PRE / POST)», «Efluente», y al final «Fuera
/// del modelo actual» y «Puntos adicionales»). Sin título en el modelo plano.
class SeccionMuestras {
  final String? titulo;
  final List<BloqueMuestras> bloques;

  SeccionMuestras({this.titulo, required this.bloques});

  Iterable<PuntoControl> get puntos => bloques.expand((b) => b.puntos);
}

/// Las muestras vigentes de un sistema de la evaluación agrupadas igual que sus puntos en la pestaña Sistemas (grupo ›
/// equipo › muestra), en el orden del agua; las varias muestras de un punto de nivel, juntas y en el orden en que se
/// anotaron. Las que el maestro ya no trae y las adicionales van al final, cada una en su sección. Nunca pierde una.
List<SeccionMuestras> agruparMuestras(List<PuntoControl> puntos, Sistema? m) {
  if (m == null) return puntos.isEmpty ? [] : [SeccionMuestras(bloques: [BloqueMuestras(puntos: puntos)])];
  final usados = <PuntoControl>{};
  List<PuntoControl> de(PuntoControlDef pd) {
    final l = [for (final p in puntos) if (p.fromMaster && !usados.contains(p) && esMismoPunto(p, pd)) p];
    usados.addAll(l);
    return l;
  }

  final secciones = <SeccionMuestras>[];
  for (final sec in agruparPuntos(m.puntosControl)) {
    final bloques = <BloqueMuestras>[];
    for (final b in sec.bloques) {
      final l = [for (final pd in b.puntos) ...de(pd)];
      if (l.isNotEmpty) bloques.add(BloqueMuestras(titulo: b.titulo, equipoTipo: b.equipoTipo, puntos: l));
    }
    if (bloques.isNotEmpty) secciones.add(SeccionMuestras(titulo: sec.grupo == null ? null : sec.titulo, bloques: bloques));
  }
  final fuera = [for (final p in puntos) if (p.fromMaster && !usados.contains(p)) p];
  final adicionales = [for (final p in puntos) if (!p.fromMaster) p];
  if (fuera.isNotEmpty) {
    secciones.add(SeccionMuestras(titulo: 'Fuera del modelo actual', bloques: [BloqueMuestras(puntos: fuera)]));
  }
  if (adicionales.isNotEmpty) {
    secciones.add(SeccionMuestras(titulo: secciones.isNotEmpty ? 'Puntos adicionales' : null, bloques: [BloqueMuestras(puntos: adicionales)]));
  }
  return secciones;
}
