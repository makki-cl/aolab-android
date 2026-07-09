import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
  bool _outdated = false;
  String _outdatedMsg = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await context.read<TemplateService>().load(); // plantilla (cache + red)
    await _reload();
    if (mounted) _sync();
    _checkVersion();
  }

  // Correlación de versión Web↔App: si el build es menor al mínimo del servidor, avisa.
  Future<void> _checkVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final build = int.tryParse(info.buildNumber) ?? 0;
      final res = await context.read<AuthService>().api.dio.get('/api/app/version');
      final minBuild = (res.data['minBuild'] ?? 0) as int;
      if (build < minBuild && mounted) {
        setState(() {
          _outdated = true;
          _outdatedMsg = (res.data['message'] ?? 'Tu aplicación está desactualizada. Actualízala.') as String;
        });
      }
    } catch (_) {/* sin red o error: no bloquear */}
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
          child: _StatusBar(status: sync.status, pending: _pending, lastError: sync.lastError),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Nueva'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              if (_outdated)
                Material(
                  color: const Color(0xFFD13438),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(children: [
                      const Icon(Icons.system_update, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_outdatedMsg, style: const TextStyle(color: Colors.white, fontSize: 13))),
                    ]),
                  ),
                ),
              Expanded(child: _body()),
            ]),
    );
  }

  Widget _body() => RefreshIndicator(
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
                        final date = a.scheduledForUtc ?? a.sampledAtUtc;
                        final dateStr = date != null
                            ? '${date.toLocal().day.toString().padLeft(2, '0')}-${date.toLocal().month.toString().padLeft(2, '0')}-${date.toLocal().year}'
                            : 'sin fecha';
                        return ListTile(
                          leading: _StatusChip(a.statusEnum),
                          title: Text('${a.clientName ?? 'Sin cliente'} · ${a.centerName}'),
                          subtitle: Text('$dateStr · ${a.auditor ?? 'sin auditor'} · ${a.typeEnum.label}'),
                          trailing: a.dirty
                              ? const Icon(Icons.cloud_upload_outlined, size: 18, color: Colors.orange)
                              : const Icon(Icons.cloud_done_outlined, size: 18, color: Colors.green),
                          onTap: () => _open(a.id),
                        );
                      },
                    ),
          );
}

class _StatusChip extends StatelessWidget {
  final AuditStatus status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      AuditStatus.scheduled => Colors.blue,
      AuditStatus.draft => Colors.orange,
      AuditStatus.submitted => Colors.green,
      AuditStatus.reviewed => Colors.teal,
    };
    return Container(
      width: 44,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        switch (status) {
          AuditStatus.scheduled => Icons.event,
          AuditStatus.draft => Icons.edit_note,
          AuditStatus.submitted => Icons.lock_outline,
          AuditStatus.reviewed => Icons.verified_outlined,
        },
        color: color,
        size: 20,
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final SyncStatus status;
  final int pending;
  final String? lastError;
  const _StatusBar({required this.status, required this.pending, this.lastError});

  @override
  Widget build(BuildContext context) {
    final hasError = status == SyncStatus.error;
    final (text, color) = switch (status) {
      SyncStatus.syncing => ('Sincronizando…', Colors.blue),
      SyncStatus.offline => ('Sin conexión — se guarda localmente', Colors.grey),
      SyncStatus.error => (
          lastError == null ? 'Error de sincronización' : 'Error: $lastError',
          Colors.red
        ),
      SyncStatus.idle => (
          pending == 0 ? 'Todo sincronizado' : '$pending pendiente(s) por subir',
          pending == 0 ? Colors.green : Colors.orange
        ),
    };
    return InkWell(
      // En error, tocar la barra muestra el detalle completo (para diagnosticar/copiar).
      onTap: hasError
          ? () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Detalle del error de sincronización'),
                  content: SelectableText(lastError ?? 'Sin detalle disponible.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
                  ],
                ),
              )
          : null,
      child: Container(
        width: double.infinity,
        color: color.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 12)),
            ),
            if (hasError) const Icon(Icons.info_outline, size: 14, color: Colors.red),
          ],
        ),
      ),
    );
  }
}
