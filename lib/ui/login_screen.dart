import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// Entrar con las formas que ofrece el servidor: correo y clave, Google y Microsoft (la app la puede usar un cliente).
/// La lista de acceso y los roles son los mismos de la web en las tres. Con [reingreso], la sesión venció: se vuelve a
/// entrar sin perder nada de lo local, y al entrar se cierra esta pantalla.
class LoginScreen extends StatefulWidget {
  final bool reingreso;
  const LoginScreen({super.key, this.reingreso = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _ocupado; // la forma que se está intentando
  String? _error;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _email.text = auth.email ?? auth.ultimoEmail ?? '';
    auth.cargarEntradas();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _con(String forma, Future<String?> Function(AuthService) entrar) async {
    if (_ocupado != null) return;
    setState(() {
      _ocupado = forma;
      _error = null;
    });
    final auth = context.read<AuthService>();
    final err = await entrar(auth);
    if (!mounted) return;
    setState(() {
      _ocupado = null;
      _error = err;
    });
    if (err == null && widget.reingreso && auth.isAuthenticated && !auth.sesionVencida) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final botonesExternos = [
      if (auth.conMicrosoft)
        _BotonExterno(
          key: const ValueKey('entrar-microsoft'),
          texto: 'Entrar con Microsoft',
          icono: Icons.window,
          ocupado: _ocupado == kEntradaMicrosoft,
          onPressed: _ocupado == null ? () => _con(kEntradaMicrosoft, (a) => a.loginWithMicrosoft()) : null,
        ),
      if (auth.conGoogle)
        _BotonExterno(
          key: const ValueKey('entrar-google'),
          texto: 'Entrar con Google',
          icono: Icons.g_mobiledata,
          ocupado: _ocupado == kEntradaGoogle,
          onPressed: _ocupado == null ? () => _con(kEntradaGoogle, (a) => a.loginWithGoogle()) : null,
        ),
    ];
    return Scaffold(
      appBar: widget.reingreso ? AppBar(title: const Text('Volver a entrar')) : null,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF050450), Color(0xFF16205E), Color(0xFF238ACC)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.reingreso) ...[
                    Image.asset('assets/aolab-logo.webp', height: 46),
                    const SizedBox(height: 28),
                  ],
                  Card(
                    elevation: 6,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(widget.reingreso ? 'Tu sesión venció' : 'Iniciar sesión',
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                          if (widget.reingreso) ...[
                            const SizedBox(height: 6),
                            const Text('Lo anotado sigue guardado en la tablet.', style: TextStyle(fontSize: 14)),
                          ],
                          const SizedBox(height: 20),
                          if (auth.conClave) ...[
                            TextField(
                              key: const ValueKey('entrar-correo'),
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              decoration: const InputDecoration(labelText: 'Correo', border: OutlineInputBorder()),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              key: const ValueKey('entrar-clave'),
                              controller: _password,
                              obscureText: true,
                              onSubmitted: (_) => _con(kEntradaClave, (a) => a.login(_email.text, _password.text)),
                              decoration: const InputDecoration(labelText: 'Contraseña', border: OutlineInputBorder()),
                            ),
                            const SizedBox(height: 18),
                            FilledButton(
                              key: const ValueKey('entrar-con-clave'),
                              onPressed: _ocupado == null
                                  ? () => _con(kEntradaClave, (a) => a.login(_email.text, _password.text))
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: _ocupado == kEntradaClave
                                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Text('Iniciar sesión', style: TextStyle(fontSize: 16)),
                              ),
                            ),
                          ],
                          if (auth.conClave && botonesExternos.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            const Row(children: [
                              Expanded(child: Divider()),
                              Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('o')),
                              Expanded(child: Divider()),
                            ]),
                          ],
                          for (final b in botonesExternos) ...[const SizedBox(height: 12), b],
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Text(_error!,
                                key: const ValueKey('entrar-error'),
                                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 14)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BotonExterno extends StatelessWidget {
  final String texto;
  final IconData icono;
  final bool ocupado;
  final VoidCallback? onPressed;

  const _BotonExterno({super.key, required this.texto, required this.icono, required this.ocupado, this.onPressed});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: onPressed,
        icon: ocupado
            ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(icono, size: 26),
        label: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(texto, style: const TextStyle(fontSize: 16)),
        ),
      );
}
