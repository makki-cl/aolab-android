/// Los tipos de sistema del modelo (`ClasesSistema` del servidor): Afluente, Tratamiento de Agua, Proceso de Salmón,
/// Tratamiento de Salmón y Efluente. Llegan en `Sistema.clase`; vacío o desconocido es Proceso de Salmón, como en el
/// servidor (lo que eran todos los sistemas antes del campo).
library;

const String kClaseAfluente = 'afluente';
const String kClaseTratamiento = 'tratamiento';
const String kClaseCultivo = 'cultivo';
const String kClaseTratamientoSalmon = 'tratamiento-salmon';
const String kClaseEfluente = 'efluente';

/// El orden de la lista lateral del editor de modelos (`TiposSistemaUi.Orden`).
const List<String> kOrdenClases = [kClaseAfluente, kClaseTratamiento, kClaseCultivo, kClaseTratamientoSalmon, kClaseEfluente];

/// La clase con que se muestra un sistema: la guardada si es una de las cinco; si no, proceso.
String claseDe(String? clase) => kOrdenClases.contains(clase) ? clase! : kClaseCultivo;

/// «Afluente», «Tratamiento de Agua», «Proceso de Salmón», «Tratamiento de Salmón», «Efluente».
String etiquetaClase(String? clase) => switch (claseDe(clase)) {
      kClaseAfluente => 'Afluente',
      kClaseTratamiento => 'Tratamiento de Agua',
      kClaseTratamientoSalmon => 'Tratamiento de Salmón',
      kClaseEfluente => 'Efluente',
      _ => 'Proceso de Salmón',
    };
