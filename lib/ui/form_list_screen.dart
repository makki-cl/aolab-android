import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_database.dart';
import '../data/form_entry.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import 'form_edit_screen.dart';

class FormListScreen extends StatefulWidget {
  const FormListScreen({super.key});

  @override
  State<FormListScreen> createState() => _FormListScreenState();
}

class _FormListScreenState extends State<FormListScreen> {
  List<FormEntry> _entries = [];
  int _pending = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
    // Intento de sincronización al abrir (si hay conexión).
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  Future<void> _reload() async {
    final db = context.read<AppDatabase>();
    final entries = await db.visibleEntries();
    final pending = await db.pendingCount();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _pending = pending;
      _loading = false;
    });
  }

  Future<void> _sync() async {
    await context.read<SyncService>().sync();
    await _reload();
  }

  Future<void> _openEditor([FormEntry? entry]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => FormEditScreen(entry: entry),
    ));
    await _reload();
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Formularios'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar',
            onPressed: sync.status == SyncStatus.syncing ? null : _sync,
            icon: sync.status == SyncStatus.syncing
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: () => context.read<AuthService>().logout(),
            icon: const Icon(Icons.logout),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: _StatusBar(status: sync.status, pending: _pending),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _sync,
              child: _entries.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      Center(child: Text('Sin formularios. Toca + para crear uno.')),
                    ])
                  : ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final e = _entries[i];
                        return ListTile(
                          title: Text(e.title),
                          subtitle: Text(e.notes ?? ''),
                          trailing: e.dirty
                              ? const Icon(Icons.cloud_upload_outlined,
                                  size: 18, color: Colors.orange)
                              : const Icon(Icons.cloud_done_outlined,
                                  size: 18, color: Colors.green),
                          onTap: () => _openEditor(e),
                        );
                      },
                    ),
            ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final SyncStatus status;
  final int pending;
  const _StatusBar({required this.status, required this.pending});

  @override
  Widget build(BuildContext context) {
    final (text, color) = switch (status) {
      SyncStatus.syncing => ('Sincronizando…', Colors.blue),
      SyncStatus.offline => ('Sin conexión — los cambios se guardan localmente', Colors.grey),
      SyncStatus.error => ('Error de sincronización', Colors.red),
      SyncStatus.idle => (
          pending == 0 ? 'Todo sincronizado' : '$pending pendiente(s) por subir',
          pending == 0 ? Colors.green : Colors.orange
        ),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}
