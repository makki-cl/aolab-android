/// Configuración de la app. La URL base apunta al backend Aolab (Blazor + API).
///
/// IMPORTANTE: ajusta [apiBaseUrl] según dónde corras:
/// - Emulador Android contra un backend en TU PC:   http://10.0.2.2:5080
/// - Dispositivo físico / backend en la VM de test:  http://<IP_o_dominio_de_la_VM>:5080
/// - Producción:                                     https://<dominio>
///
/// Puedes sobrescribirla en tiempo de compilación:
///   flutter run --dart-define=AOLAB_API_BASE_URL=http://192.168.1.50:5080
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'AOLAB_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:5080',
  );
}
