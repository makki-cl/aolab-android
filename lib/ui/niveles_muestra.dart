import 'package:flutter/material.dart';

import '../models/niveles.dart';

/// La posición de una muestra en un punto de nivel de un grupo efímero, como `NivelesMuestraEditor` de la web: una fila
/// por nivel, del 1 al del punto («Rack», «Balde»), con su posición (Principio · Medio · Final, obligatoria) y su número
/// o código (opcional).
///
/// Reutilización dentro de la MISMA evaluación: si ya se anotó «Rack 17 · Final», al escribir 17 la posición se completa
/// sola, y lo ya anotado se ofrece como chip («Rack 17 · Final»), que llena las dos cosas. Sin número no hay identidad:
/// la posición se pide siempre. Otro número es otro miembro: la posición que se completó sola por el de antes se suelta.
///
/// El número se toma al salir del campo (o con «listo» del teclado), no en cada tecla: «1» y después «17» serían dos
/// racks distintos. Al tocar una posición o un chip, lo escrito se toma primero.
class NivelesMuestraEditor extends StatefulWidget {
  final NivelPunto punto;
  final NivelesMuestra value;

  /// Lo anotado, en cada cambio. Quien lo usa decide cómo guarda (y vuelve a revisar todo).
  final Future<void> Function(NivelesMuestra) onChanged;

  /// Lo ya anotado en la evaluación para el grupo del punto (sin esta muestra).
  final ReusoNiveles? reuso;

  final bool locked;

  /// Lo que va al final de la última fila (la × para quitar la muestra).
  final Widget? accion;

  const NivelesMuestraEditor({
    super.key,
    required this.punto,
    required this.value,
    required this.onChanged,
    this.reuso,
    this.locked = false,
    this.accion,
  });

  @override
  State<NivelesMuestraEditor> createState() => _NivelesMuestraEditorState();
}

class _NivelesMuestraEditorState extends State<NivelesMuestraEditor> {
  static const int _maxChips = 8;

  final Map<int, TextEditingController> _ctrl = {};
  final Map<int, FocusNode> _foco = {};
  final Set<int> _reusada = {};
  final Set<int> _malos = {}; // niveles con un número que no se entendió (queda escrito, con su error)
  String? _error;

  NivelPunto get _p => widget.punto;

  TextEditingController _c(int k) => _ctrl.putIfAbsent(k, () => TextEditingController(text: widget.value.numero(k) ?? ''));

  FocusNode _f(int k) => _foco.putIfAbsent(k, () {
        final f = FocusNode();
        f.addListener(() {
          if (!f.hasFocus) _tomarNumeros();
        });
        return f;
      });

  @override
  void didUpdateWidget(covariant NivelesMuestraEditor old) {
    super.didUpdateWidget(old);
    // Lo que cambió desde afuera (un chip, otra muestra, la recarga) se ve en los campos que no se están escribiendo.
    for (var k = 1; k <= _p.nivel; k++) {
      final c = _c(k);
      final num = widget.value.numero(k) ?? '';
      if (!_f(k).hasFocus && !_malos.contains(k) && c.text != num) c.text = num;
    }
  }

  @override
  void dispose() {
    // Lo escrito y no tomado (se salió de la pantalla con el campo abierto) no se pierde.
    if (!widget.locked) {
      final n = _conTextos(widget.value);
      if (n != widget.value) widget.onChanged(n);
    }
    for (final c in _ctrl.values) {
      c.dispose();
    }
    for (final f in _foco.values) {
      f.dispose();
    }
    super.dispose();
  }

  String _del(String nombre) => femenino(nombre) ? 'de la' : 'del';
  String _anotado(String nombre) => femenino(nombre) ? 'anotada' : 'anotado';

  /// Lo que falta para que la muestra tenga su posición completa, o null.
  String? _falta(NivelesMuestra v) {
    for (var k = 1; k <= _p.nivel; k++) {
      if (v.posicion(k) == null) {
        final nombre = _p.nombreNivel(k);
        return 'Falta la posición ${_del(nombre)} ${enFrase(nombre)}: principio, medio o final.';
      }
    }
    return null;
  }

  /// [n] con los números escritos en los campos (los que cambiaron y se entienden).
  NivelesMuestra _conTextos(NivelesMuestra n) {
    for (var k = 1; k <= _p.nivel; k++) {
      final texto = _ctrl[k]?.text.trim();
      if (texto == null) continue;
      if (texto == (n.numero(k) ?? '')) continue;
      final r = _conNumero(n, k, texto.isEmpty ? null : texto);
      if (r != null) n = r;
    }
    return n;
  }

  /// `CambiarNumero` de la web: normaliza el número; si no se entiende, queda escrito con su error (null). Otro número
  /// suelta lo que se había completado solo por el anterior; un miembro ya anotado completa su posición.
  NivelesMuestra? _conNumero(NivelesMuestra n, int k, String? texto) {
    String? clave;
    if (texto != null) {
      final r = normalizarCodigo(_p.niveles[k - 1], texto);
      if (r.error != null) {
        _malos.add(k);
        _error = r.error;
        return null;
      }
      clave = r.clave;
    }
    _malos.remove(k);
    _error = null;
    n = _soltarReusadas(n, k, clave);
    n = n.con(k, n.posicion(k), clave);
    final conocida = widget.reuso?.posicion(_p.grupoId, n, k);
    if (conocida != null && n.posicion(k) == null) {
      n = n.con(k, conocida, clave);
      _reusada.add(k);
    } else {
      _reusada.remove(k);
    }
    return _completar(n);
  }

  /// Si el número del nivel k cambia, suelta las posiciones desde k hacia abajo que eran de otro miembro: las que se
  /// completaron solas (o con un chip) y, si antes había otro número, todas.
  NivelesMuestra _soltarReusadas(NivelesMuestra n, int k, String? numeroNuevo) {
    if (n.numero(k) == numeroNuevo) return n;
    final otroMiembro = n.numero(k) != null;
    for (var j = k; j <= _p.nivel; j++) {
      final eraReusada = _reusada.remove(j);
      if (eraReusada || otroMiembro) n = n.con(j, null, n.numero(j));
    }
    return n;
  }

  /// Los niveles de abajo con número ya anotado en el mismo padre toman su posición.
  NivelesMuestra _completar(NivelesMuestra n) {
    final reuso = widget.reuso;
    if (reuso == null) return n;
    for (var k = 1; k <= _p.nivel; k++) {
      if (n.posicion(k) == null) {
        final pos = reuso.posicion(_p.grupoId, n, k);
        if (pos != null) {
          n = n.con(k, pos, n.numero(k));
          _reusada.add(k);
        }
      }
    }
    return n;
  }

  Future<void> _emitir(NivelesMuestra n) async {
    if (mounted) setState(() {});
    if (n != widget.value) await widget.onChanged(n);
  }

  void _tomarNumeros() {
    if (widget.locked) return;
    _emitir(_conTextos(widget.value));
  }

  void _elegirPosicion(int k, String posicion) {
    final n = _conTextos(widget.value);
    _reusada.remove(k);
    _emitir(n.con(k, n.posicion(k) == posicion ? null : posicion, n.numero(k)));
  }

  void _elegirChip(int k, String numero, String posicion) {
    var n = _conTextos(widget.value);
    _malos.remove(k);
    _error = null;
    n = _soltarReusadas(n, k, numero).con(k, posicion, numero);
    _reusada.add(k); // vino de lo ya anotado: si después se cambia el número, la posición se suelta
    _c(k).text = numero;
    _emitir(_completar(n));
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final filas = <Widget>[];
    for (var k = 1; k <= _p.nivel; k++) {
      final nombre = _p.nombreNivel(k);
      final pos = v.posicion(k);
      final chips = (widget.locked || widget.reuso == null || (v.numero(k) != null && pos != null))
          ? const <({String numero, String posicion})>[]
          : widget.reuso!.chips(_p.grupoId, v, k);
      final codigo = _p.niveles[k - 1].identifica == kIdentificaCodigo;
      filas.add(Padding(
        padding: EdgeInsets.only(top: k == 1 ? 0 : 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(nombre, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
            SizedBox(
              width: 120,
              child: TextField(
                key: ValueKey('nivel-num-$k'),
                controller: _c(k),
                focusNode: _f(k),
                enabled: !widget.locked,
                maxLength: kLargoClave,
                keyboardType: codigo ? TextInputType.text : TextInputType.number,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _tomarNumeros(),
                style: const TextStyle(fontWeight: FontWeight.w700),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  hintText: codigo ? 'Código' : 'Nº',
                  errorText: _malos.contains(k) ? '' : null,
                  errorStyle: const TextStyle(height: 0, fontSize: 0),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            if (k == _p.nivel && widget.accion != null) widget.accion!,
          ]),
          const SizedBox(height: 6),
          Row(children: [
            for (final t in TramosGrupo.todos) ...[
              Expanded(child: _botonPosicion(k, t, pos == t)),
              if (t != TramosGrupo.todos.last) const SizedBox(width: 6),
            ],
          ]),
          if (chips.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                for (final c in chips.take(_maxChips))
                  ActionChip(
                    label: Text('$nombre ${c.numero} · ${TramosGrupo.nombre(c.posicion)}'),
                    onPressed: () => _elegirChip(k, c.numero, c.posicion),
                  ),
              ]),
            ),
          if (_reusada.contains(k) && pos != null && v.numero(k) != null)
            _mensaje(
                '$nombre ${v.numero(k)} ya estaba ${_anotado(nombre)} como ${TramosGrupo.nombre(pos)} en esta evaluación: se usa esa posición.',
                const Color(0xFF0B6E91)),
        ]),
      ));
    }
    final falta = widget.locked ? null : _falta(v);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      ...filas,
      if (_error != null)
        _mensaje(_error!, Theme.of(context).colorScheme.error)
      else if (falta != null)
        _mensaje(falta, const Color(0xFF8A5A00)),
    ]);
  }

  Widget _botonPosicion(int k, String tramo, bool sel) {
    const azul = Color(0xFF2D58FF);
    return Semantics(
      selected: sel,
      button: true,
      child: InkWell(
        key: ValueKey('nivel-pos-$k-$tramo'),
        onTap: widget.locked ? null : () => _elegirPosicion(k, tramo),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? azul : Colors.white,
            border: Border.all(color: sel ? azul : const Color(0xFFB8C2D3)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(TramosGrupo.nombre(tramo),
              style: TextStyle(color: sel ? Colors.white : const Color(0xFF1F2A44), fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ),
    );
  }

  Widget _mensaje(String texto, Color color) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(texto, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
      );
}
