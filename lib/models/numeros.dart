/// Números como se escriben en Chile: punto para los miles y coma para los decimales («1.234,5»). Es como los muestran
/// la web y los informes, y como los escribe el evaluador en la tablet.
library;

/// Lee un número escrito a mano. Acepta «1.234,5», «1234,5», «1234.5», «12,5», «57». Un punto solo, seguido de
/// exactamente tres cifras y con algo distinto de 0 antes («1.234», «12.500»), es de miles, como se escribe en Chile;
/// en otro caso el punto es el decimal («12.5», «0.125»). Null si no se entiende o está vacío.
double? leerNumero(String texto) {
  var t = texto.trim().replaceAll(' ', '');
  if (t.isEmpty) return null;
  final conComa = t.contains(',');
  final puntos = '.'.allMatches(t).length;
  if (conComa) {
    // La coma es el decimal; los puntos, de miles.
    t = t.replaceAll('.', '').replaceAll(',', '.');
  } else if (puntos > 1) {
    t = t.replaceAll('.', '');
  } else if (puntos == 1) {
    final partes = t.split('.');
    final entero = partes[0].replaceFirst('-', '');
    if (partes[1].length == 3 && entero.isNotEmpty && entero != '0') t = t.replaceAll('.', '');
  }
  if (','.allMatches(t).isNotEmpty) return null;
  return double.tryParse(t);
}

/// El número para mostrarlo: miles con punto y hasta [decimales] decimales con coma, sin ceros de más («1.234,5»,
/// «57»).
String formatoNumero(double v, {int decimales = 2}) {
  final negativo = v < 0;
  final texto = v.abs().toStringAsFixed(decimales);
  final partes = texto.split('.');
  var entero = partes[0];
  var dec = partes.length > 1 ? partes[1] : '';
  while (dec.endsWith('0')) {
    dec = dec.substring(0, dec.length - 1);
  }
  final b = StringBuffer();
  for (var i = 0; i < entero.length; i++) {
    if (i > 0 && (entero.length - i) % 3 == 0) b.write('.');
    b.write(entero[i]);
  }
  entero = b.toString();
  return '${negativo ? '-' : ''}$entero${dec.isEmpty ? '' : ',$dec'}';
}
