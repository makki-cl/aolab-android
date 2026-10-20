/// Configuración de la app. La URL base apunta al backend Aolab (Blazor + API).
///
/// Se fija al compilar: `--dart-define=AOLAB_API_BASE_URL=https://app.aolab.cl`. Sin ella, el emulador contra un
/// backend en el mismo PC (`http://10.0.2.2:5080`).
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'AOLAB_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:5080',
  );

  /// Client ID WEB de Google (se usa como serverClientId para que el idToken tenga
  /// esa audiencia; el backend lo valida contra este mismo valor). No es secreto.
  static const String googleWebClientId = String.fromEnvironment(
    'AOLAB_GOOGLE_WEB_CLIENT_ID',
    defaultValue: '923475534238-4dend2rqndcm1b7hbaol2nr82vfpsk91.apps.googleusercontent.com',
  );

  /// Registro de Entra «AOLAB Inicio de sesión» (el mismo de la web). No es secreto: es la audiencia del idToken que el
  /// servidor valida en /api/auth/microsoft.
  static const String microsoftClientId = String.fromEnvironment(
    'AOLAB_MS_CLIENT_ID',
    defaultValue: 'b98f7c67-28c5-41ac-bd76-12f1af8594e6',
  );

  /// Cuentas de organizaciones (sin cuentas personales), igual que la web.
  static const String microsoftDiscoveryUrl =
      'https://login.microsoftonline.com/organizations/v2.0/.well-known/openid-configuration';

  /// El retorno de Microsoft para un paquete firmado con una llave dada: `msauth://<paquete>/<hash de la firma>`, como lo
  /// registra Entra para Android. Solo el canal de producción (cl.makki.aolab, llave de prod) lo tiene registrado; otro
  /// paquete no muestra «Entrar con Microsoft» salvo que el build traiga AOLAB_MS_REDIRECT.
  static const String _msRedirectForzado = String.fromEnvironment('AOLAB_MS_REDIRECT');
  static const Map<String, String> _msRedirects = {
    'cl.makki.aolab': 'msauth://cl.makki.aolab/u1Y69Tkp6EGl3LoG%2BlS1KeYRARA%3D',
  };

  static String? microsoftRedirect(String? paquete) =>
      _msRedirectForzado.isNotEmpty ? _msRedirectForzado : _msRedirects[paquete];
}
