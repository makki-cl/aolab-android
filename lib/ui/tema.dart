import 'package:flutter/material.dart';

/// Los colores de la app en un solo lugar. La app se usa al sol: los textos secundarios son grises oscuros (contraste de
/// 6:1 o más sobre blanco), nunca el gris claro de Material.
abstract final class Colores {
  static const Color marca = Color(0xFF2D58FF);
  static const Color tinta = Color(0xFF0F172A); // títulos
  static const Color texto2 = Color(0xFF475569); // rótulos y texto secundario
  static const Color borde = Color(0xFFDDE3EE);
  static const Color fondoSuave = Color(0xFFF7F9FC);
  static const Color fondoBloqueada = Color(0xFFEFF3F6);

  static const Color ok = Color(0xFF15803D);
  static const Color peligro = Color(0xFFB91C1C);

  // Avisos (ámbar): fondo, ícono y texto.
  static const Color avisoFondo = Color(0xFFFFF4E5);
  static const Color avisoIcono = Color(0xFFB7791F);
  static const Color avisoTexto = Color(0xFF5C3D00);

  // Información (azul suave).
  static const Color infoFondo = Color(0xFFEFF6FF);

  // Lo que todavía no sube a la nube.
  static const Color pendiente = Color(0xFFB45309);
}

/// El tema de la app: Material 3 con el azul de AOLAB, tamaño táctil de 48 dp y rótulos legibles.
ThemeData temaAolab() {
  final base = ThemeData(colorSchemeSeed: Colores.marca, useMaterial3: true);
  return base.copyWith(
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    textTheme: base.textTheme.copyWith(
      bodySmall: base.textTheme.bodySmall?.copyWith(fontSize: 13, color: Colores.texto2),
      labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 13),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
