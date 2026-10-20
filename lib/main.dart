import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'data/app_database.dart';
import 'services/audit_sync_service.dart';
import 'services/auth_service.dart';
import 'services/master_sync_service.dart';
import 'services/media_service.dart';
import 'services/template_service.dart';
import 'ui/audit_list_screen.dart';
import 'ui/login_screen.dart';

/// Lo local de la tablet para el cambio de usuario: la base y los archivos de las evidencias.
class _DatosDeLaTablet implements DatosLocales {
  final AppDatabase db;
  final MediaService media;
  _DatosDeLaTablet(this.db, this.media);

  @override
  Future<int> pendientes() => db.pendientesDeSubir();

  @override
  Future<void> borrarTodo() async {
    await db.borrarDatosDeUsuario();
    await media.borrarArchivosLocales();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? paquete;
  try {
    paquete = (await PackageInfo.fromPlatform()).packageName;
  } catch (_) {}
  final msRedirect = AppConfig.microsoftRedirect(paquete);

  final db = AppDatabase();
  final auth = AuthService(microsoft: msRedirect == null ? null : InicioMicrosoft(msRedirect));
  await auth.loadSession(); // restaura sesión previa si existe
  final template = TemplateService(db: db, api: auth.api);
  final masters = MasterSyncService(db: db, api: auth.api);
  final media = MediaService(api: auth.api);
  auth.datosLocales = _DatosDeLaTablet(db, media);
  final sync = AuditSyncService(
    db: db,
    api: auth.api,
    masters: masters,
    media: media,
    alVencerSesion: auth.marcarVencida,
    sesionVencida: () => auth.sesionVencida,
  );
  try {
    await sync.cargarAvisos(); // los avisos del servidor que quedaron sin cerrar
  } catch (_) {}

  runApp(AolabApp(db: db, auth: auth, template: template, sync: sync, media: media));
}

class AolabApp extends StatelessWidget {
  final AppDatabase db;
  final AuthService auth;
  final TemplateService template;
  final AuditSyncService sync;
  final MediaService media;

  const AolabApp({
    super.key,
    required this.db,
    required this.auth,
    required this.template,
    required this.sync,
    required this.media,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<TemplateService>.value(value: template),
        ChangeNotifierProvider<AuditSyncService>.value(value: sync),
        Provider<MediaService>.value(value: media),
      ],
      child: MaterialApp(
        title: 'AOLAB',
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es'), Locale('en')],
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2D58FF),
          useMaterial3: true,
        ),
        // La UI raíz reacciona al estado de autenticación. Una sesión vencida sigue en la lista (con lo local) y pide
        // entrar de nuevo desde ahí.
        home: Consumer<AuthService>(
          builder: (_, a, __) => a.isAuthenticated ? const AuditListScreen() : const LoginScreen(),
        ),
      ),
    );
  }
}
