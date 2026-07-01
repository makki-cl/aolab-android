import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_database.dart';
import 'services/audit_sync_service.dart';
import 'services/auth_service.dart';
import 'services/master_sync_service.dart';
import 'services/template_service.dart';
import 'ui/audit_list_screen.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase();
  final auth = AuthService();
  await auth.loadSession(); // restaura sesión previa si existe
  final template = TemplateService(db: db, api: auth.api);
  final masters = MasterSyncService(db: db, api: auth.api);
  final sync = AuditSyncService(db: db, api: auth.api, masters: masters);

  runApp(AolabApp(db: db, auth: auth, template: template, sync: sync));
}

class AolabApp extends StatelessWidget {
  final AppDatabase db;
  final AuthService auth;
  final TemplateService template;
  final AuditSyncService sync;

  const AolabApp({
    super.key,
    required this.db,
    required this.auth,
    required this.template,
    required this.sync,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<TemplateService>.value(value: template),
        ChangeNotifierProvider<AuditSyncService>.value(value: sync),
      ],
      child: MaterialApp(
        title: 'Aolab',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF238ACC),
          useMaterial3: true,
        ),
        // La UI raíz reacciona al estado de autenticación.
        home: Consumer<AuthService>(
          builder: (_, a, __) =>
              a.isAuthenticated ? const AuditListScreen() : const LoginScreen(),
        ),
      ),
    );
  }
}
