import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/app_database.dart';
import 'services/auth_service.dart';
import 'services/sync_service.dart';
import 'ui/form_list_screen.dart';
import 'ui/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase();
  final auth = AuthService();
  await auth.loadSession(); // restaura sesión previa si existe
  final sync = SyncService(db: db, api: auth.api);

  runApp(AolabApp(db: db, auth: auth, sync: sync));
}

class AolabApp extends StatelessWidget {
  final AppDatabase db;
  final AuthService auth;
  final SyncService sync;

  const AolabApp({
    super.key,
    required this.db,
    required this.auth,
    required this.sync,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider<AuthService>.value(value: auth),
        ChangeNotifierProvider<SyncService>.value(value: sync),
      ],
      child: MaterialApp(
        title: 'Aolab',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
        ),
        // La UI raíz reacciona al estado de autenticación.
        home: Consumer<AuthService>(
          builder: (_, a, __) =>
              a.isAuthenticated ? const FormListScreen() : const LoginScreen(),
        ),
      ),
    );
  }
}
