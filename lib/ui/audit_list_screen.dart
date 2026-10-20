import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/audit.dart';
import '../services/audit_sync_service.dart';
import '../services/auth_service.dart';
import '../services/evidencias_en_fila.dart';
import '../services/media_service.dart';
import '../services/template_service.dart';
import 'audit_edit_screen.dart';
import 'login_screen.dart';
import 'tema.dart';

/// Los filtros de la lista, por estado.
enum FiltroLista { todas, agendadas, enCurso, finalizadas }

extension FiltroListaX on FiltroLista {
  String get etiqueta => switch (this) {
        FiltroLista.todas => 'Todas',
        FiltroLista.agendadas => 'Agendadas',
        FiltroLista.enCurso => 'En curso',
        FiltroLista.finalizadas => 'Finalizadas',
      };

  bool incluye(Audit a) => switch (this) {
        FiltroLista.todas => true,
        FiltroLista.agendadas => a.statusEnum == AuditStatus.scheduled,
        FiltroLista.enCurso => a.statusEnum == AuditStatus.draft,
        FiltroLista.finalizadas => a.isLocked,
      };
}

/// ¿Se puede borrar desde la tablet? Solo una Agendada que se creó aquí y nunca llegó al servidor (creada por error).
bool sePuedeBorrar(Audit a) => a.statusEnum == AuditStatus.scheduled && a.serverVersion == 0;

/// La fecha de la evaluación para la lista: la agendada o la de muestreo; una recién creada, la de creación.
DateTime fechaDe(Audit a) => a.scheduledForUtc ?? a.sampledAtUtc ?? a.createdAtUtc;

String fmtFecha(DateTime utc) {
  final d = utc.toLocal();
  return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
}

class AuditListScreen extends StatefulWidget {
  const AuditListScreen({super.key});

  @override
  State<AuditListScreen> createState() => _AuditListScreenState();
}

class _AuditListScreenState extends State<AuditListScreen> {
  List<Audit> _audits = [];
  int _pending = 0;
  bool _loading = true;
  FiltroLista _filtro = FiltroLista.todas;
  bool _outdated = false;
  String _outdatedMsg = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  // La lista sale al tiro desde la tablet; la plantilla se refresca en segundo plano (con mala señal no se espera).
  Future<void> _init() async {
    final tpl = context.read<TemplateService>();
    final db = context.read<AppDatabase>();
    final media = context.read<MediaService>();
    await tpl.cargarLocal();
    await _reload();
    unawaited(tpl.refrescar());
    // Si Android cerró la app con la cámara abierta, la foto se recupera y vuelve a su punto.
    final recuperada = await FotoEnCurso.recuperar(db, media);
    if (recuperada != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Se recuperó la foto de «$recuperada».')));
      await _reload();
    }
    if (mounted) _sync();
    _checkVersion();
  }

  // Correlación de versión Web↔App: si el build es menor al mínimo del servidor, avisa.
  Future<void> _checkVersion() async {
    final api = context.read<AuthService>().api;
    try {
      final info = await PackageInfo.fromPlatform();
      final build = int.tryParse(info.buildNumber) ?? 0;
      final res = await api.dio.get('/api/app/version');
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
    final pending = await db.pendientesDeSubir();
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

  /// La sesión venció: se vuelve a entrar (con la misma cuenta) y se sincroniza. Nada local se pierde.
  Future<void> _reingresar() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const LoginScreen(reingreso: true)));
    if (ok == true && mounted) _sync();
  }

  /// Cerrar sesión no borra nada de la tablet, pero lo que falta subir queda esperando a que vuelva a entrar la misma
  /// persona: se avisa y se ofrece sincronizar antes.
  Future<void> _cerrarSesion() async {
    final auth = context.read<AuthService>();
    final db = context.read<AppDatabase>();
    final pendientes = await db.pendientesDeSubir();
    if (!mounted) return;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: Text(pendientes == 0
            ? '¿Cerrar la sesión de ${auth.email ?? 'esta cuenta'}?'
            : 'Hay ${pendientes == 1 ? '1 evaluación' : '$pendientes evaluaciones'} sin subir. Quedan guardadas en la tablet, '
                'pero solo se suben cuando vuelvas a entrar con ${auth.email ?? 'esta cuenta'}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          if (pendientes > 0 && !auth.sesionVencida)
            TextButton(onPressed: () => Navigator.pop(ctx, 'sync'), child: const Text('Sincronizar primero')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'salir'), child: const Text('Cerrar sesión')),
        ],
      ),
    );
    if (!mounted) return;
    if (r == 'sync') {
      await _sync();
    } else if (r == 'salir') {
      await auth.logout();
    }
  }

  Future<void> _create() async {
    final db = context.read<AppDatabase>();
    final now = DateTime.now().toUtc();
    final audit = Audit(
      id: const Uuid().v4(),
      status: 3, // Agendada: el muestreo (folio/correlativos) se inicia después
      createdAtUtc: now,
      updatedAtUtc: now,
      // createdByName lo resuelve el servidor (nombre completo del usuario) al pushear.
      // Como en la web, la visita nace sin nada activo: el evaluador marca en cada pestaña la entrevista, la
      // evaluación de terreno (RPN) o el laboratorio. Los sistemas se eligen en la pestaña Sistemas.
      document: AuditDocument.nueva(),
    );
    await db.upsertLocal(audit);
    await _open(audit.id);
  }

  /// Borrar una evaluación creada por error (Agendada, nunca subida): con confirmación. Se marca borrada y el próximo
  /// envío lo avisa al servidor, por si alcanzó a llegar.
  Future<void> _borrar(Audit a) async {
    final db = context.read<AppDatabase>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: Colores.peligro),
        title: const Text('Borrar evaluación'),
        content: Text('¿Borrar «${a.tituloCentro} · ${fmtFecha(fechaDe(a))}» de la tablet?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colores.peligro),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await db.softDelete(a.id);
    await _reload();
    if (mounted) _sync();
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
        title: const Text('Evaluaciones'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar',
            onPressed: sync.status == SyncStatus.syncing ? null : _sync,
            icon: sync.status == SyncStatus.syncing
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          // Cerrar sesión va en el menú, con confirmación: en terreno no se cierra por error.
          PopupMenuButton<String>(
            tooltip: 'Más opciones',
            onSelected: (v) {
              if (v == 'salir') _cerrarSesion();
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                enabled: false,
                child: Text(context.read<AuthService>().email ?? '', style: const TextStyle(fontSize: 13)),
              ),
              const PopupMenuItem<String>(
                value: 'salir',
                child: Row(children: [Icon(Icons.logout, size: 20), SizedBox(width: 10), Text('Cerrar sesión')]),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: StatusBarSync(status: sync.status, pending: _pending, lastError: sync.lastError, lastSyncAt: sync.lastSyncAt),
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
              if (context.watch<AuthService>().sesionVencida) _avisoVencida(),
              if (sync.avisos.isNotEmpty) _avisos(sync),
              if (_audits.isNotEmpty) _filtros(),
              Expanded(child: _body()),
            ]),
    );
  }

  Widget _avisoVencida() => Material(
        color: const Color(0xFFFFF4E5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(children: [
            const Icon(Icons.lock_clock, color: Color(0xFFB7791F), size: 22),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Tu sesión venció. Lo anotado sigue en la tablet; entra de nuevo para sincronizar.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF5C3D00))),
            ),
            FilledButton(onPressed: _reingresar, child: const Text('Entrar')),
          ]),
        ),
      );

  // Los avisos del servidor quedan a la vista hasta que el evaluador los cierra (con mala señal, un aviso de 3 s se
  // pierde). Cada uno ya nombra la evaluación (centro y folio).
  Widget _avisos(AuditSyncService sync) => Material(
        color: const Color(0xFFFFF4E5),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Color(0xFFB7791F), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    sync.avisos.length == 1 ? 'Aviso del servidor' : 'Avisos del servidor (${sync.avisos.length})',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF8A5A00))),
              ),
              TextButton(onPressed: sync.cerrarAvisos, child: const Text('Entendido')),
            ]),
            for (final a in sync.avisos)
              Padding(
                padding: const EdgeInsets.only(left: 28, right: 8, bottom: 4),
                child: Text('• $a', style: const TextStyle(fontSize: 13, color: Color(0xFF5C3D00))),
              ),
          ]),
        ),
      );

  Widget _filtros() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          for (final f in FiltroLista.values) ...[
            ChoiceChip(
              key: ValueKey('filtro-${f.name}'),
              label: Text('${f.etiqueta} (${_audits.where(f.incluye).length})', style: const TextStyle(fontSize: 14)),
              selected: _filtro == f,
              onSelected: (_) => setState(() => _filtro = f),
            ),
            const SizedBox(width: 8),
          ],
        ]),
      );

  Widget _body() {
    final lista = _audits.where(_filtro.incluye).toList();
    return RefreshIndicator(
      onRefresh: _sync,
      child: lista.isEmpty
          ? ListView(children: [
              const SizedBox(height: 140),
              Center(
                child: Text(_audits.isEmpty ? 'Sin evaluaciones.' : 'Ninguna ${_filtro.etiqueta.toLowerCase()}.',
                    style: const TextStyle(fontSize: 15, color: Colores.texto2)),
              ),
            ])
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 88), // que el botón «Nueva» no tape la última
              itemCount: lista.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _fila(lista[i]),
            ),
    );
  }

  Widget _fila(Audit a) {
    final detalle = [
      if (a.folio != null) 'Folio ${a.folio}',
      if (a.clientName != null && a.clientName!.trim().isNotEmpty) a.clientName!,
      a.auditor ?? 'sin evaluador',
      a.typeEnum.label,
    ].join(' · ');
    return ListTile(
      key: ValueKey('ev-${a.id}'),
      minVerticalPadding: 10,
      leading: _StatusChip(a.statusEnum),
      title: Text('${a.tituloCentro} · ${fmtFecha(fechaDe(a))}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      subtitle: Text('${a.statusEnum.label} · $detalle', style: const TextStyle(fontSize: 14, color: Colores.texto2)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        a.dirty
            ? const Tooltip(message: 'Falta subir', child: Icon(Icons.cloud_upload_outlined, size: 22, color: Colores.pendiente))
            : const Tooltip(message: 'En el servidor', child: Icon(Icons.cloud_done_outlined, size: 22, color: Colores.ok)),
        if (sePuedeBorrar(a))
          PopupMenuButton<String>(
            key: ValueKey('menu-${a.id}'),
            tooltip: 'Opciones',
            onSelected: (_) => _borrar(a),
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'borrar',
                child: Row(children: [
                  Icon(Icons.delete_outline, size: 20, color: Colores.peligro),
                  SizedBox(width: 10),
                  Text('Borrar'),
                ]),
              ),
            ],
          ),
      ]),
      onTap: () => _open(a.id),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final AuditStatus status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      AuditStatus.scheduled => const Color(0xFF1D4ED8),
      AuditStatus.draft => const Color(0xFFB45309),
      AuditStatus.submitted => Colores.ok,
      AuditStatus.reviewed => const Color(0xFF0F766E),
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

/// La barra del estado de la sincronización, en palabras del evaluador. Si algo falló, tocarla muestra por qué.
class StatusBarSync extends StatelessWidget {
  final SyncStatus status;
  final int pending;
  final String? lastError;
  final DateTime? lastSyncAt;
  const StatusBarSync({super.key, required this.status, required this.pending, this.lastError, this.lastSyncAt});

  static String porSubir(int n) => n == 1 ? '1 evaluación por subir' : '$n evaluaciones por subir';

  static String hora(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  /// El texto y el color de la barra.
  (String, Color) get estado => switch (status) {
        SyncStatus.syncing => ('Sincronizando…', const Color(0xFF1D4ED8)),
        SyncStatus.offline => (
            pending == 0 ? 'Sin señal' : 'Sin señal · ${porSubir(pending)}: quedan guardadas en la tablet',
            Colores.texto2
          ),
        SyncStatus.error => (
            lastError == AuditSyncService.kSesionVencida
                ? 'Sesión vencida: entra de nuevo para sincronizar'
                : 'No se pudo sincronizar todo${pending > 0 ? ' · ${porSubir(pending)}' : ''} · toca para ver por qué',
            Colores.peligro
          ),
        SyncStatus.idle => (
            pending == 0
                ? 'Todo sincronizado${lastSyncAt == null ? '' : ' · ${hora(lastSyncAt!)}'}'
                : porSubir(pending),
            pending == 0 ? Colores.ok : Colores.pendiente
          ),
      };

  @override
  Widget build(BuildContext context) {
    final hasError = status == SyncStatus.error && lastError != AuditSyncService.kSesionVencida;
    final (text, color) = estado;
    final motivos = (lastError ?? '').split(' · ').where((x) => x.trim().isNotEmpty).toList();
    return InkWell(
      onTap: hasError
          ? () => showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Por qué no se sincronizó'),
                  content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final m in motivos.isEmpty ? ['Sin detalle.'] : motivos)
                        Padding(padding: const EdgeInsets.only(bottom: 8), child: SelectableText('• $m')),
                      const Text('Lo anotado sigue guardado en la tablet.', style: TextStyle(color: Colores.texto2)),
                    ]),
                  ),
                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar'))],
                ),
              )
          : null,
      child: Container(
        width: double.infinity,
        color: color.withValues(alpha: 0.10),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  key: const ValueKey('estado-sync'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            if (hasError) Icon(Icons.info_outline, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}
