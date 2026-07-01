import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/audit.dart';
import '../services/audit_sync_service.dart';
import '../services/auth_service.dart';
import '../services/template_service.dart';
import 'audit_edit_screen.dart';

class AuditListScreen extends StatefulWidget {
  const AuditListScreen({super.key});

  @override
  State<AuditListScreen> createState() => _AuditListScreenState();
}

class _AuditListScreenState extends State<AuditListScreen> {
  List<Audit> _audits = [];
  int _pending = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await context.read<TemplateService>().load(); // plantilla (cache + red)
    await _reload();
    if (mounted) _sync();
  }

  Future<void> _reload() async {
    final db = context.read<AppDatabase>();
    final audits = await db.visibleAudits();
    final pending = await db.pendingCount();
    if (!mounted) return;
    setState(() {
      _audits = audits;
      _pending = pending;
      _loading = false;
    });
  }

  Future<void> _sync() async {
    await context.read<AuditSyncService>().sync();
    await _reload();
  }

  Future<void> _create() async {
    final db = context.read<AppDatabase>();
    final now = DateTime.now().toUtc();
    final audit = Audit(
      id: const Uuid().v4(),
      createdAtUtc: now,
      updatedAtUtc: now,
      document: AuditDocument(salas: [AuditSala(id: const Uuid().v4(), name: 'Sala 1')]),
    );
    await db.upsertLocal(audit);
    await _open(audit.id);
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AuditEditScreen(auditId: id)));
    await _reload();
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<AuditSyncService>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditorías'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar',
            onPressed: sync.status == SyncStatus.syncing ? null : _sync,
            icon: sync.status == SyncStatus.syncing
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Nueva'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _sync,
              child: _audits.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 140),
                      Center(child: Text('Sin auditorías. Toca «Nueva» para crear una.')),
                    ])
                  : ListView.separated(
                      itemCount: _audits.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final a = _audits[i];
                        return ListTile(
                          title: Text(a.centerName),
                          subtitle: Text('${a.statusEnum.label} · ${a.document.salas.length} sala(s)'),
                          trailing: a.dirty
                              ? const Icon(Icons.cloud_upload_outlined, size: 18, color: Colors.orange)
                              : const Icon(Icons.cloud_done_outlined, size: 18, color: Colors.green),
                          onTap: () => _open(a.id),
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
      SyncStatus.offline => ('Sin conexión — se guarda localmente', Colors.grey),
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
