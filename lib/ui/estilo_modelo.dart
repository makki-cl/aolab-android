import 'package:flutter/material.dart';

import '../models/clases_sistema.dart';

/// Cómo se ve cada tipo de sistema en la app: el mismo ícono y el mismo color que en el editor de modelos de la web
/// (`TiposSistemaUi`, app.css «ao-t-…»): Afluente verde agua con la gota, Tratamiento de Agua rosado con el embudo,
/// Proceso de Salmón azul con el pez, Tratamiento de Salmón lima con la vacuna y Efluente violeta.
///
/// La web usa esos colores sobre fondo oscuro. La app es clara y se usa al sol, así que cada tipo tiene además un tono
/// oscuro del mismo color para los textos y los íconos (con contraste sobre blanco); el color de la web va en la franja.
class EstiloClase {
  final Color franja; // el color de la web
  final Color tinta; // texto e ícono sobre fondo claro
  final Color fondo; // fondo suave de la ficha
  final IconData icono;

  const EstiloClase({required this.franja, required this.tinta, required this.fondo, required this.icono});
}

const Map<String, EstiloClase> _estilos = {
  kClaseAfluente: EstiloClase(
      franja: Color(0xFF2DC4A0), tinta: Color(0xFF0B7A62), fondo: Color(0xFFE3F7F2), icono: Icons.water_drop),
  kClaseTratamiento: EstiloClase(
      franja: Color(0xFFF472B6), tinta: Color(0xFFB0185E), fondo: Color(0xFFFDEAF4), icono: Icons.filter_alt),
  kClaseCultivo: EstiloClase(
      franja: Color(0xFF38B8E0), tinta: Color(0xFF0B6E91), fondo: Color(0xFFE3F4FA), icono: Icons.set_meal),
  kClaseTratamientoSalmon: EstiloClase(
      franja: Color(0xFFA3E635), tinta: Color(0xFF4A7310), fondo: Color(0xFFF0FADF), icono: Icons.vaccines),
  kClaseEfluente: EstiloClase(
      franja: Color(0xFFA78BFA), tinta: Color(0xFF5B3CC4), fondo: Color(0xFFEFEAFE), icono: Icons.output),
};

/// Un sistema adicional (o que el maestro ya no trae): gris, como el nodo del editor.
const EstiloClase estiloSinClase =
    EstiloClase(franja: Color(0xFFCBD5E1), tinta: Color(0xFF475569), fondo: Color(0xFFF1F5F9), icono: Icons.warehouse_outlined);

/// El estilo de una clase; null (adicional) es gris.
EstiloClase estiloDe(String? clase) => clase == null ? estiloSinClase : _estilos[claseDe(clase)]!;

/// Encabezado de un grupo de sistemas: ícono, «Proceso de Salmón» y cuántos hay (como la lista lateral del editor).
class EncabezadoClase extends StatelessWidget {
  final String clase;
  final int cantidad;

  const EncabezadoClase({super.key, required this.clase, required this.cantidad});

  @override
  Widget build(BuildContext context) {
    final e = estiloDe(clase);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Row(children: [
        Icon(e.icono, size: 18, color: e.tinta),
        const SizedBox(width: 6),
        Flexible(
          child: Text(etiquetaClase(clase).toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: e.tinta)),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
          decoration: BoxDecoration(color: e.fondo, borderRadius: BorderRadius.circular(999)),
          child: Text('$cantidad', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: e.tinta)),
        ),
      ]),
    );
  }
}

/// La ficha de un sistema (su etapa, el tipo de su agua), en el color de su tipo.
class FichaClase extends StatelessWidget {
  final String texto;
  final String? clase;

  const FichaClase({super.key, required this.texto, this.clase});

  @override
  Widget build(BuildContext context) {
    final e = estiloDe(clase);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: e.fondo,
        border: Border.all(color: e.tinta.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(texto, style: TextStyle(color: e.tinta, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// Un bloque con la franja de color de su tipo a la izquierda (la caja del sistema en el circuito de la web).
class ConFranja extends StatelessWidget {
  final String? clase;
  final Widget child;
  final EdgeInsetsGeometry margin;
  final Color? color;

  const ConFranja({super.key, required this.clase, required this.child, this.margin = const EdgeInsets.only(bottom: 8), this.color});

  @override
  Widget build(BuildContext context) {
    final e = estiloDe(clase);
    return Card(
      margin: margin,
      color: color,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE1E6F0)),
      ),
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: e.franja, width: 5))),
        child: child,
      ),
    );
  }
}
