/// Conservación de las llaves que esta versión de la app no conoce (plan §8.2, «App nueva»).
///
/// Cada modelo que viaja al servidor lee del JSON solo los campos que conoce. Antes, al volver a
/// serializarlo, lo demás se perdía: la copia local de la app instalada quedaba sin el informe, los
/// comentarios ni ningún campo que la web agregara después. Por eso cada modelo guarda en un mapa
/// `extra` lo que no conoce, y la copia en SQLite queda completa.
///
/// Lo ajeno NO se manda en el push. La app no lo edita, así que lo único que tiene es la copia de
/// cuando bajó la auditoría, y puede estar vieja: si mientras tanto en la web se llenó el informe,
/// se activó «solo laboratorio» o se asignó otro auditor, reenviarlo devolvería esos campos a lo que
/// eran (el servidor aplica toda llave que viene). Tampoco hace falta: el servidor conserva, en
/// todos los niveles, lo que el push no trae (fusión JSON de F0).
library;

/// Las llaves que un modelo sabe leer. La comparación no distingue mayúsculas, igual que el
/// servidor (`JsonSerializerDefaults.Web`): una llave que solo cambia de mayúsculas no es ajena, y
/// así nunca se emite dos veces el mismo campo.
class LlavesPropias {
  final Set<String> _minusculas;

  LlavesPropias(Iterable<String> llaves) : _minusculas = {for (final k in llaves) k.toLowerCase()};

  bool contiene(String llave) => _minusculas.contains(llave.toLowerCase());

  /// Lo que trae el JSON y este modelo no conoce, tal cual vino (sin copiar en profundidad: la app
  /// nunca lo modifica, solo lo devuelve).
  Map<String, dynamic> ajenas(Map<String, dynamic> json) => {
        for (final e in json.entries)
          if (!contiene(e.key)) e.key: e.value,
      };
}

/// El JSON de un modelo: sus campos y, después, las llaves ajenas que trajo. Si por algún motivo
/// una llave ajena coincide con un campo propio, manda el propio (es el valor que la app editó).
/// Con [incluir] en false salen solo los campos propios: es lo que va en el push.
Map<String, dynamic> conAjenas(Map<String, dynamic> propias, Map<String, dynamic> extra, {bool incluir = true}) =>
    !incluir
        ? propias
        : {
            ...propias,
            for (final e in extra.entries)
              if (!propias.containsKey(e.key)) e.key: e.value,
          };

/// Lectura tolerante de un texto opcional. Para los campos nuevos: si un servidor futuro cambia
/// el tipo de un campo, se lee como ausente en vez de botar la sincronización completa (los casts
/// estrictos de siempre se dejaron como estaban).
String? textoOpcional(Object? v) => v is String ? v : null;

/// Lectura tolerante de un entero opcional (acepta 3 y 3.0).
int? enteroOpcional(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

/// Un objeto JSON como mapa, o null si no es un objeto.
Map<String, dynamic>? objetoOpcional(Object? v) => v is Map ? v.cast<String, dynamic>() : null;

/// Lectura tolerante de un sí/no opcional: null si falta o no es un booleano.
bool? booleanoOpcional(Object? v) => v is bool ? v : null;
