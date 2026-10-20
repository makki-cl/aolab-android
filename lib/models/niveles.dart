/// Posición por nivel en los grupos efímeros («Racks 8° › Rack › Balde»), portada tal cual de la web (19-10-2026):
/// `PosicionesNivel`, `NivelesMuestra`, `ReusoNiveles`, `TramosGrupo` y `GruposModelo.Normalizar` del servidor. Así una
/// posición anotada en la tablet se valida, se normaliza y se rotula igual que en el editor web y la maleta.
///
/// La app la valida ANTES de guardar: después de subir, la posición queda de solo lectura (el servidor la trata como suya:
/// un envío solo la llena si allá no hay), y una mal anotada ya no se podría corregir desde la tablet.
library;

/// Principio, medio o final: dónde está un miembro dentro de su padre (`TramosGrupo`). Se guarda en minúscula.
class TramosGrupo {
  static const String principio = 'principio';
  static const String medio = 'medio';
  static const String finalTramo = 'final';

  /// En el orden del agua.
  static const List<String> todos = [principio, medio, finalTramo];

  static bool valido(String? t) => t == principio || t == medio || t == finalTramo;

  /// «Principio», «Medio», «Final» (o «?»).
  static String nombre(String? t) => switch (t) {
        principio => 'Principio',
        medio => 'Medio',
        finalTramo => 'Final',
        _ => '?',
      };
}

/// Cómo se identifica un miembro de un nivel: por número (1 a 9999) o por un código físico («1844», «OV17»).
const String kIdentificaNumero = 'numero';
const String kIdentificaCodigo = 'codigo';

/// Largo máximo del código de un miembro (`GrupoDeEquipos.LargoClave`).
const int kLargoClave = 20;

/// Número más alto de un miembro por número (`GrupoDeEquipos.Tope`).
const int kTopeNumero = 9999;

/// Largo de la foto de la etiqueta (`PosicionesNivel.LargoEtiqueta`).
const int kLargoEtiquetaNiveles = 200;

/// Un nivel de un grupo efímero tal como lo manda el pull de centros (`NivelGrupoDto`): 1, 2 o 3, cómo se le dice a uno
/// («Rack», «Balde») y cómo se identifica. [tipo] no viaja hoy; si algún día viene, la normalización también reconoce su
/// etiqueta corta, como en el servidor.
class NivelGrupoDef {
  final int nivel;
  final String nombre;
  final String identifica;
  final String? tipo;

  const NivelGrupoDef({required this.nivel, required this.nombre, this.identifica = kIdentificaNumero, this.tipo});

  Map<String, dynamic> toJson() => {
        'nivel': nivel,
        'nombre': nombre,
        'identifica': identifica,
        if (tipo != null) 'tipo': tipo,
      };

  static NivelGrupoDef? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['nivel'];
    final nivel = n is int ? n : (n is num ? n.toInt() : null);
    if (nivel == null) return null;
    final nombre = j['nombre'] is String ? (j['nombre'] as String) : '';
    final identifica = j['identifica'] == kIdentificaCodigo ? kIdentificaCodigo : kIdentificaNumero;
    return NivelGrupoDef(nivel: nivel, nombre: nombre, identifica: identifica, tipo: j['tipo'] is String ? j['tipo'] as String : null);
  }

  /// Cómo se le dice a uno de este nivel, nunca vacío (`GruposModelo.NombreNivel`).
  String get nombreVisible => nombre.trim().isNotEmpty ? nombre.trim() : 'Miembro';
}

/// Lo que se sabe de un punto de nivel de un grupo efímero (`NivelPuntoModelo`): de qué grupo es (el equipo-grupo), hasta
/// qué nivel se pide la posición (1 = «Rack», 2 = «Balde») y los niveles del grupo hasta ese.
class NivelPunto {
  final String grupoId;
  final int nivel;
  final List<NivelGrupoDef> niveles;

  const NivelPunto({required this.grupoId, required this.nivel, required this.niveles});

  /// «Rack», «Balde»: cómo se le dice a uno del nivel k (1..[nivel]).
  String nombreNivel(int k) => (k >= 1 && k <= niveles.length) ? niveles[k - 1].nombreVisible : 'Miembro';

  /// Los nombres de los niveles, del 1 al del punto.
  List<String> get nombres => [for (var k = 1; k <= nivel; k++) nombreNivel(k)];

  NivelGrupoDef? definicion(int k) => (k >= 1 && k <= niveles.length) ? niveles[k - 1] : null;
}

/// La posición de una muestra, nivel por nivel (`NivelesMuestra`): en cada nivel, del 1 al del punto, la posición
/// (principio, medio o final) y el número o código. Es un valor: dos con lo mismo son iguales; el vacío es «sin posición».
class NivelesMuestra {
  final String? posicion1, numero1, posicion2, numero2, posicion3, numero3;

  const NivelesMuestra({this.posicion1, this.numero1, this.posicion2, this.numero2, this.posicion3, this.numero3});

  static const NivelesMuestra vacio = NivelesMuestra();

  bool get vacia => hasta == 0;

  /// El último nivel con algo anotado (posición o número); 0 si no hay nada.
  int get hasta => _tiene(3) ? 3 : (_tiene(2) ? 2 : (_tiene(1) ? 1 : 0));

  bool _tiene(int k) => posicion(k) != null || numero(k) != null;

  String? posicion(int k) => switch (k) { 1 => posicion1, 2 => posicion2, 3 => posicion3, _ => null };

  String? numero(int k) => switch (k) { 1 => numero1, 2 => numero2, 3 => numero3, _ => null };

  /// Lo mismo con el nivel k cambiado.
  NivelesMuestra con(int k, String? posicion, String? numero) => switch (k) {
        1 => NivelesMuestra(posicion1: posicion, numero1: numero, posicion2: posicion2, numero2: numero2, posicion3: posicion3, numero3: numero3),
        2 => NivelesMuestra(posicion1: posicion1, numero1: numero1, posicion2: posicion, numero2: numero, posicion3: posicion3, numero3: numero3),
        3 => NivelesMuestra(posicion1: posicion1, numero1: numero1, posicion2: posicion2, numero2: numero2, posicion3: posicion, numero3: numero),
        _ => this,
      };

  /// Solo los niveles 1..k (los de más abajo, vacíos).
  NivelesMuestra hastaNivel(int k) => NivelesMuestra(
        posicion1: k >= 1 ? posicion1 : null,
        numero1: k >= 1 ? numero1 : null,
        posicion2: k >= 2 ? posicion2 : null,
        numero2: k >= 2 ? numero2 : null,
        posicion3: k >= 3 ? posicion3 : null,
        numero3: k >= 3 ? numero3 : null,
      );

  /// Los niveles como lista (1..[hasta]).
  List<({int nivel, String? posicion, String? numero})> get lista =>
      [for (var k = 1; k <= hasta; k++) (nivel: k, posicion: posicion(k), numero: numero(k))];

  /// Desde la lista del documento de una evaluación. Un nivel fuera de 1..3 se salta; los textos vacíos son nada.
  static NivelesMuestra de(Iterable<({int nivel, String? posicion, String? numero})>? l) {
    var n = vacio;
    for (final x in l ?? const <({int nivel, String? posicion, String? numero})>[]) {
      n = n.con(x.nivel, _limpio(x.posicion), _limpio(x.numero));
    }
    return n;
  }

  static String? _limpio(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  @override
  bool operator ==(Object other) =>
      other is NivelesMuestra &&
      other.posicion1 == posicion1 &&
      other.numero1 == numero1 &&
      other.posicion2 == posicion2 &&
      other.numero2 == numero2 &&
      other.posicion3 == posicion3 &&
      other.numero3 == numero3;

  @override
  int get hashCode => Object.hash(posicion1, numero1, posicion2, numero2, posicion3, numero3);

  @override
  String toString() => 'NivelesMuestra(${[for (final x in lista) '${x.nivel}:${x.posicion}:${x.numero}'].join('/')})';
}

// ── Nombres en una frase ──

/// Un nombre de nivel dentro de una frase: en minúsculas («rack», «balde»), salvo uno de 1 o 2 letras («E»).
String enFrase(String nombre) {
  final s = nombre.trim();
  return s.length > 2 ? s.toLowerCase() : s;
}

/// ¿Se le dice «la» a uno de este nivel? Por su primera palabra: «la Batea», «el Estanque Cabecera».
bool femenino(String nombre) {
  final s = nombre.trim();
  if (s.isEmpty) return false;
  final i = s.indexOf(' ');
  final primera = i > 0 ? s.substring(0, i) : s;
  return primera.endsWith('a') || primera.endsWith('A');
}

String _del(String nombre) => femenino(nombre) ? 'de la' : 'del';

// ── El código de un miembro (`GruposModelo.Normalizar`) ──

const Map<String, String> _sinTilde = {
  'Á': 'A', 'À': 'A', 'Ä': 'A', 'Â': 'A', 'Ã': 'A', 'Å': 'A', //
  'É': 'E', 'È': 'E', 'Ë': 'E', 'Ê': 'E', //
  'Í': 'I', 'Ì': 'I', 'Ï': 'I', 'Î': 'I', //
  'Ó': 'O', 'Ò': 'O', 'Ö': 'O', 'Ô': 'O', 'Õ': 'O', //
  'Ú': 'U', 'Ù': 'U', 'Ü': 'U', 'Û': 'U', //
  'Ñ': 'N', 'Ç': 'C', 'Ý': 'Y',
};

/// Sin tildes y en mayúsculas (`GruposModelo.Plano`).
String plano(String? s) {
  if (s == null || s.isEmpty) return '';
  final b = StringBuffer();
  for (final ch in s.toUpperCase().split('')) {
    b.write(_sinTilde[ch] ?? ch);
  }
  return b.toString();
}

final RegExp _prefijos = RegExp(r'(?<![A-Z0-9])(N°|Nº|NO\.|#)');
final RegExp _noAlfanumerico = RegExp(r'[^A-Z0-9]+');

List<String> _palabras(String s) => s.split(_noAlfanumerico).where((x) => x.isNotEmpty).toList();

bool _soloDigitos(String s) => s.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(s);

bool _soloLetras(String s) => s.isNotEmpty && RegExp(r'^[A-Z]+$').hasMatch(s);

/// Etiqueta corta de un tipo de equipo, para reconocerla al comienzo de un código (`EquipoTipos.EtiquetaCorta`).
const Map<String, String> _etiquetasCortas = {
  'Estanque de Cultivo': 'Estanque',
  'LHO / Oxigenación': 'LHO',
  'Batea / Incubación': 'Batea',
  'Bateas / Baldes': 'Bateas',
  'Chiller / Enfriamiento': 'Chiller',
  'Estanque Acumulación / Reservorio': 'Reservorio',
  'Pozo / Bomba': 'Pozo',
};

/// La etiqueta corta de un tipo de equipo («Estanque» para «Estanque de Cultivo»); los tipos cortos, tal cual.
String etiquetaCortaTipo(String tipo) => _etiquetasCortas[tipo.trim()] ?? tipo.trim();

/// El resultado de normalizar un número o código.
typedef Normalizado = ({String? clave, String? error});

/// El código normalizado de un miembro del nivel, con la MISMA regla del servidor: sin tildes y en mayúsculas; sin «N°»,
/// «Nº», «NO.» ni «#»; sin la primera palabra si es el nombre del nivel, su plural o la etiqueta corta de su tipo
/// («BALDE 1844» → 1844; pegada al número: «RACK3» → 3, «E7» → 7), o si es una palabra de 4 letras o más seguida de
/// algo con dígitos («INCUABADOR 2750» → 2750); solo A-Z y 0-9; sin ceros a la izquierda si son solo dígitos; de 1 a
/// 20. En un nivel por número, un entero de 1 a 9999.
Normalizado normalizarCodigo(NivelGrupoDef nivel, String? texto) {
  final nombre = nivel.nombreVisible;
  final palabras = _palabras(plano(texto).replaceAll(_prefijos, ' '));

  final candidatos = <List<String>>[];
  void candidato(String? s) {
    final p = _palabras(plano(s));
    if (p.isEmpty) return;
    candidatos.add(p);
    candidatos.add([...p.sublist(0, p.length - 1), '${p.last}S']);
    candidatos.add([...p.sublist(0, p.length - 1), '${p.last}ES']);
  }

  candidato(nivel.nombre);
  if (nivel.tipo != null && nivel.tipo!.trim().isNotEmpty) candidato(etiquetaCortaTipo(nivel.tipo!));
  var quitado = false;
  for (final c in candidatos) {
    if (palabras.length >= c.length && [for (var i = 0; i < c.length; i++) c[i] == palabras[i]].every((b) => b)) {
      palabras.removeRange(0, c.length);
      quitado = true;
      break;
    }
  }
  if (!quitado && palabras.isNotEmpty) {
    String? pegado;
    for (final c in candidatos.where((c) => c.length == 1).map((c) => c[0])) {
      if (palabras[0].length > c.length && palabras[0].startsWith(c) && _soloDigitos(palabras[0].substring(c.length))) {
        pegado = c;
        break;
      }
    }
    if (pegado != null) {
      palabras[0] = palabras[0].substring(pegado.length);
    } else if (palabras.length > 1 &&
        _soloLetras(palabras[0]) &&
        palabras[0].length >= 4 &&
        palabras.skip(1).any((p) => RegExp(r'[0-9]').hasMatch(p))) {
      palabras.removeAt(0);
    }
  }

  var k = palabras.join();
  if (_soloDigitos(k)) {
    final sinCeros = k.replaceFirst(RegExp(r'^0+'), '');
    k = sinCeros.isNotEmpty ? sinCeros : '0';
  }
  final del = _del(nombre);
  if (k.isEmpty) return (clave: null, error: 'Escribe el código $del $nombre.');
  if (k.length > kLargoClave) return (clave: null, error: 'El código $del $nombre tiene a lo más $kLargoClave caracteres.');
  if (nivel.identifica == kIdentificaNumero) {
    final n = _soloDigitos(k) ? int.tryParse(k) : null;
    if (n == null || n < 1 || n > kTopeNumero) return (clave: null, error: 'En $nombre va un número: 1, 2, 3…');
  }
  return (clave: k, error: null);
}

/// Claves en orden natural: «2» antes que «10»; los números primero y los alfanuméricos después, por texto.
int compararClaves(String? a, String? b) {
  a ??= '';
  b ??= '';
  final na = _soloDigitos(a), nb = _soloDigitos(b);
  if (na && nb) {
    final ta = a.replaceFirst(RegExp(r'^0+'), ''), tb = b.replaceFirst(RegExp(r'^0+'), '');
    var c = ta.length.compareTo(tb.length);
    if (c == 0) c = ta.compareTo(tb);
    return c != 0 ? c : a.compareTo(b);
  }
  if (na != nb) return na ? -1 : 1;
  return a.compareTo(b);
}

// ── Las reglas de la posición (`PosicionesNivel`) ──

typedef Revisado = ({NivelesMuestra niveles, String? error});

class PosicionesNivel {
  /// Revisa y normaliza lo anotado para un punto de nivel: del 1 al nivel del punto, la posición es obligatoria y válida;
  /// el número es opcional y se normaliza según el nivel; de ahí para abajo no va nada. Vacío del todo se acepta (es «sin
  /// posición»: la pantalla la pide).
  static Revisado revisar(NivelPunto punto, NivelesMuestra n) {
    if (n.vacia) return (niveles: n, error: null);
    final normal = normalizarNumeros(punto, n);
    if (normal.error != null) return normal;
    n = normal.niveles;
    if (n.hasta > punto.nivel) {
      final siguiente = punto.nivel + 1 <= punto.niveles.length ? punto.nombreNivel(punto.nivel + 1) : 'nivel ${punto.nivel + 1}';
      return (
        niveles: n,
        error: '${punto.nombreNivel(punto.nivel)} es el último nivel de este punto: no lleva ${enFrase(siguiente)}.',
      );
    }
    var r = NivelesMuestra.vacio;
    for (var k = 1; k <= punto.nivel; k++) {
      final nombre = punto.nombreNivel(k);
      final pos = n.posicion(k);
      if (pos == null) {
        return (niveles: n, error: 'Falta la posición ${_del(nombre)} ${enFrase(nombre)}: principio, medio o final.');
      }
      if (!TramosGrupo.valido(pos)) {
        return (niveles: n, error: 'La posición ${_del(nombre)} ${enFrase(nombre)} es principio, medio o final.');
      }
      r = r.con(k, pos, n.numero(k));
    }
    return (niveles: r, error: null);
  }

  /// Solo los números, normalizados según su nivel («Rack 17» → 17, «OV-17» → OV17); las posiciones como vienen.
  static Revisado normalizarNumeros(NivelPunto punto, NivelesMuestra n) {
    final tope = n.hasta < punto.niveles.length ? n.hasta : punto.niveles.length;
    for (var k = 1; k <= tope; k++) {
      final texto = n.numero(k);
      if (texto == null) continue;
      final r = normalizarCodigo(punto.niveles[k - 1], texto);
      if (r.error != null) return (niveles: n, error: r.error);
      n = n.con(k, n.posicion(k), r.clave);
    }
    return (niveles: n, error: null);
  }

  /// «Rack 17 (final) › Balde 1844 (principio)»; sin número, «Rack (final)». Null sin posición.
  static String? etiqueta(List<String>? nombres, NivelesMuestra n) {
    if (n.vacia) return null;
    return n.lista.map((x) {
      final nombre = (nombres != null && x.nivel <= nombres.length && nombres[x.nivel - 1].trim().isNotEmpty)
          ? nombres[x.nivel - 1].trim()
          : null;
      final parte = nombre == null
          ? (x.numero ?? 'Nivel ${x.nivel}')
          : (x.numero != null ? (nombre.length <= 2 ? '$nombre${x.numero}' : '$nombre ${x.numero}') : nombre);
      return '$parte (${x.posicion != null ? TramosGrupo.nombre(x.posicion).toLowerCase() : 'sin posición'})';
    }).join(' › ');
  }

  /// La etiqueta recortada al largo de su columna en el servidor.
  static String? foto(List<String>? nombres, NivelesMuestra n) {
    final e = etiqueta(nombres, n);
    if (e == null) return null;
    return e.length <= kLargoEtiquetaNiveles ? e : e.substring(0, kLargoEtiquetaNiveles);
  }
}

/// La reutilización de la posición dentro de UN muestreo (el documento de la evaluación): si ya se anotó «Rack 17 ·
/// Final», al escribir 17 en el nivel 1 la posición se completa sola. Lo mismo para cualquier nivel dentro del mismo
/// padre. Sin número no hay identidad (se pide siempre). Es `ReusoNiveles` del servidor.
class ReusoNiveles {
  final Map<String, ({String posicion, int veces})> _conocidas = {};

  ReusoNiveles(Iterable<({String grupoId, NivelesMuestra niveles})> anotadas) {
    for (final a in anotadas) {
      for (final m in _miembros(a.grupoId, a.niveles)) {
        final ya = _conocidas[m.llave];
        if (ya == null) {
          _conocidas[m.llave] = (posicion: m.posicion, veces: 1);
        } else if (ya.posicion == m.posicion) {
          _conocidas[m.llave] = (posicion: m.posicion, veces: ya.veces + 1);
        }
      }
    }
  }

  static Iterable<({int nivel, String llave, String posicion})> _miembros(String grupo, NivelesMuestra n) sync* {
    var ruta = grupo;
    for (var k = 1; k <= n.hasta; k++) {
      final num = n.numero(k);
      if (num == null) return; // sin número no hay identidad, ni para los de abajo
      ruta += '|$num';
      final p = n.posicion(k);
      if (p != null) yield (nivel: k, llave: ruta, posicion: p);
    }
  }

  static String? _llaveDe(String grupo, NivelesMuestra n, int k) {
    var ruta = grupo;
    for (var i = 1; i <= k; i++) {
      final num = n.numero(i);
      if (num == null) return null;
      ruta += '|$num';
    }
    return ruta;
  }

  /// La posición ya anotada del miembro del nivel k con esos números, o null.
  String? posicion(String grupo, NivelesMuestra n, int k) {
    final llave = _llaveDe(grupo, n, k);
    return llave == null ? null : _conocidas[llave]?.posicion;
  }

  /// Completa las posiciones que faltan con las ya anotadas (nivel por nivel, de arriba abajo).
  NivelesMuestra completar(String grupo, NivelesMuestra n) {
    for (var k = 1; k <= n.hasta; k++) {
      if (n.posicion(k) == null) {
        final p = posicion(grupo, n, k);
        if (p != null) n = n.con(k, p, n.numero(k));
      }
    }
    return n;
  }

  /// Los miembros ya anotados del nivel k dentro del mismo padre, para ofrecerlos como chips («Rack 17 · Final»), en
  /// orden natural de número.
  List<({String numero, String posicion})> chips(String grupo, NivelesMuestra padre, int k) {
    var prefijo = k == 1 ? grupo : _llaveDe(grupo, padre, k - 1);
    if (prefijo == null) return const [];
    prefijo += '|';
    final l = [
      for (final e in _conocidas.entries)
        if (e.key.startsWith(prefijo) && !e.key.substring(prefijo.length).contains('|'))
          (numero: e.key.substring(prefijo.length), posicion: e.value.posicion),
    ];
    l.sort((a, b) => compararClaves(a.numero, b.numero));
    return l;
  }

  /// Cuántas muestras del muestreo tienen ya ese miembro con esa posición.
  int veces(String grupo, NivelesMuestra n, int k) {
    final llave = _llaveDe(grupo, n, k);
    return llave == null ? 0 : (_conocidas[llave]?.veces ?? 0);
  }

  /// Lo de [otra] con las posiciones de [nueva] en los miembros que comparten (mismos números de la raíz a ese nivel):
  /// «cambiar en todas» cuando se corrige la posición de un rack ya anotado.
  static NivelesMuestra alinear(NivelesMuestra otra, NivelesMuestra nueva) {
    final tope = otra.hasta < nueva.hasta ? otra.hasta : nueva.hasta;
    for (var k = 1; k <= tope; k++) {
      if (otra.numero(k) == null || otra.numero(k) != nueva.numero(k)) break;
      final p = nueva.posicion(k);
      if (p != null && otra.posicion(k) != p) otra = otra.con(k, p, otra.numero(k));
    }
    return otra;
  }

  /// Si la muestra pone a un miembro ya anotado en OTRA posición, el porqué. Null si es coherente.
  String? conflicto(String grupo, NivelesMuestra n, List<String> nombres) {
    for (final m in _miembros(grupo, n)) {
      final ya = _conocidas[m.llave];
      if (ya != null && ya.posicion != m.posicion) {
        final nombre = m.nivel <= nombres.length ? nombres[m.nivel - 1] : 'Nivel ${m.nivel}';
        final num = n.numero(m.nivel);
        final f = femenino(nombre);
        return '$nombre $num ya está ${f ? 'anotada' : 'anotado'} como ${TramosGrupo.nombre(ya.posicion)} en este muestreo: '
            '${f ? 'una misma' : 'un mismo'} ${enFrase(nombre)} tiene una sola posición. Cámbiala en todas sus muestras o corrige esta.';
      }
    }
    return null;
  }
}
