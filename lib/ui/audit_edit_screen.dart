import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../data/app_database.dart';
import '../models/audit.dart';
import '../models/master.dart';
import '../models/questionnaire.dart';
import '../services/auth_service.dart';
import '../services/media_service.dart';
import '../services/template_service.dart';

class AuditEditScreen extends StatefulWidget {
  final String auditId;
  const AuditEditScreen({super.key, required this.auditId});

  @override
  State<AuditEditScreen> createState() => _AuditEditScreenState();
}

class _AuditEditScreenState extends State<AuditEditScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final MediaService _media;
  Audit? _audit;
  QuestionnaireTemplate? _tpl;
  List<ClientRef> _clients = [];
  List<CenterRef> _centers = [];
  List<UserRef> _users = [];
  bool _loading = true;
  Timer? _saveTimer;
  bool _saving = false;
  final Set<Answer> _showComment = {};

  // Grabación de audio
  PuntoControl? _recPunto;
  double _recLevel = 0;
  int _recSeconds = 0;
  Timer? _recTimer;
  final Set<String> _silentAudios = {};
  final AudioPlayer _player = AudioPlayer();

  // Formulario de "sistema adicional" (pestaña Sistemas).
  final TextEditingController _newSalaName = TextEditingController();
  String? _newSalaTipo;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(_onTabChanged);
    _media = context.read<MediaService>();
    _load();
  }

  // Gating: Entrevista (2) y Auditoría RPN (3) requieren centro asignado.
  void _onTabChanged() {
    if (_tab.indexIsChanging && _tab.index >= 2 && (_audit?.centerId == null)) {
      _tab.animateTo(1); // vuelve a Sistemas
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Selecciona el centro en Identificación')));
      }
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _recTimer?.cancel();
    if (_recPunto != null) _media.cancelRecording();
    _player.dispose();
    _newSalaName.dispose();
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.read<AppDatabase>();
    _tpl = context.read<TemplateService>().template;
    _audit = await db.findById(widget.auditId);
    _clients = await db.activeClients();
    _centers = await db.activeCenters();
    _users = await db.allUsers();
    await _media.dirPath(); // inicializa la carpeta local de evidencias
    if (mounted) setState(() => _loading = false);
  }

  bool get _locked => _audit?.isLocked ?? false;

  // Secciones de centro SIN IDENTIFICACIÓN (esa vive en la cabecera).
  List<TemplateSection> get _centerSections =>
      _tpl!.centerSections.where((s) => s.code != 'IDENTIFICACION').toList();

  Answer _ans(Map<String, Answer> map, String code) => map.putIfAbsent(code, () => Answer());

  // ── Auto-guardado local inmediato (debounce corto) ──
  void _scheduleSave() {
    if (_locked) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveNow);
    if (!_saving) setState(() => _saving = true);
  }

  Future<void> _saveNow() async {
    final a = _audit;
    if (a == null || _locked) return;
    a.updatedAtUtc = DateTime.now().toUtc();
    await context.read<AppDatabase>().upsertLocal(a);
    if (mounted) setState(() => _saving = false);
  }

  // ── Cabecera ──
  void _pickClient(String? id) {
    final a = _audit!;
    a.clientId = id;
    a.clientName = id == null ? null : _clients.firstWhere((c) => c.id == id).name;
    setState(() {});
    _scheduleSave();
  }

  void _pickCenter(String? id) {
    final a = _audit!;
    a.centerId = id;
    if (id != null) a.centerName = _centers.firstWhere((x) => x.id == id).name;
    _ensureDefaultSistemas();
    setState(() {});
    _scheduleSave();
  }

  // Centro (CenterRef) actualmente asignado, si sigue en el maestro.
  CenterRef? get _center {
    final id = _audit?.centerId;
    if (id == null) return null;
    for (final c in _centers) {
      if (c.id == id) return c;
    }
    return null;
  }

  // Sistemas del maestro del centro asignado (para marcar cuáles se auditan).
  List<Sistema> get _masterSistemas =>
      (_center?.sistemas ?? []).where((s) => s.nombre.trim().isNotEmpty).toList();

  void _pickType(int? t) {
    _audit!.type = t ?? 0;
    setState(() {});
    _scheduleSave();
  }

  void _pickAuditor(String? display) {
    _audit!.auditor = display; // se guarda el nombre a mostrar
    setState(() {});
    _scheduleSave();
  }

  Future<void> _pickDate() async {
    final a = _audit!;
    final base = (a.scheduledForUtc ?? a.sampledAtUtc ?? DateTime.now()).toLocal();
    final picked = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    final utc = DateTime.utc(picked.year, picked.month, picked.day, 12);
    a.sampledAtUtc = utc;
    if (a.statusEnum == AuditStatus.scheduled) a.scheduledForUtc = utc;
    setState(() {});
    _scheduleSave();
  }

  // ── Sistemas (salas) ──
  // Crea un AuditSala e inicializa sus respuestas por sección.
  AuditSala _newSala(String name, {String? tipo, bool fromMaster = false}) {
    final sala = AuditSala(id: const Uuid().v4(), name: name, tipo: tipo, fromMaster: fromMaster);
    for (final sec in _tpl!.salaSections) {
      for (final q in sec.questions) {
        sala.answers.putIfAbsent(q.code, () => Answer());
      }
    }
    _audit!.document.salas.add(sala);
    _scheduleSave();
    return sala;
  }

  // Afluente del sistema al auditar: por sistema si el centro es "multi", si no el del centro (snapshot).
  String? _afluenteSnapshot(Sistema m) =>
      _center?.afluenteMode == 'multi' ? m.afluente : _center?.afluente;

  // Agrega un sistema del maestro: copia tipo, afluente (snapshot) y sus puntos (fromMaster, past-proof).
  AuditSala _addSalaFromMaster(Sistema m) {
    final sala = _newSala(m.nombre, tipo: m.tipo, fromMaster: true);
    sala.afluente = _afluenteSnapshot(m);
    for (final pd in m.puntosControl) {
      sala.puntosControl.add(PuntoControl(
        id: const Uuid().v4(),
        nombre: pd.alias,
        tipo: pd.tipo,
        fromMaster: true,
      ));
    }
    return sala;
  }

  // AuditSala del maestro que corresponde a un sistema del maestro por nombre (activa o en papelera).
  AuditSala? _masterSalaFor(String nombre) {
    for (final s in _audit!.document.salas) {
      if (s.fromMaster && s.name.trim().toLowerCase() == nombre.trim().toLowerCase()) return s;
    }
    return null;
  }

  // Marca/desmarca un sistema del maestro. Desmarcar hace soft-delete (conserva respuestas/puntos).
  void _toggleMaster(Sistema m, bool include) {
    final existing = _masterSalaFor(m.nombre);
    setState(() {
      if (include) {
        if (existing == null) {
          _addSalaFromMaster(m);
        } else {
          existing.isDeleted = false;
          existing.name = m.nombre;
          existing.tipo = m.tipo;
          existing.afluente = _afluenteSnapshot(m);
        }
      } else if (existing != null) {
        existing.isDeleted = true;
      }
    });
    _scheduleSave();
  }

  // Sistema ad-hoc (no viene del maestro): nombre y tipo editables en la auditoría.
  void _addSalaNew() {
    final name = _newSalaName.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _newSala(name, tipo: _newSalaTipo, fromMaster: false);
      _newSalaName.clear();
      _newSalaTipo = null;
    });
    _scheduleSave();
  }

  // Al asignar centro y si la auditoría aún no tiene sistemas: marca TODOS los del maestro por
  // defecto; si el centro no tiene ninguno, crea un "Sistema 1" ad-hoc. No pisa selecciones previas.
  void _ensureDefaultSistemas() {
    final a = _audit;
    if (a == null || a.centerId == null || a.document.salas.isNotEmpty) return;
    final master = _masterSistemas;
    if (master.isNotEmpty) {
      for (final m in master) {
        _addSalaFromMaster(m);
      }
    } else {
      _newSala('Sistema 1', fromMaster: false);
    }
  }

  Future<void> _removeSala(AuditSala s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: Colors.red),
        title: const Text('Eliminar sistema'),
        content: Text('¿Eliminar el sistema «${s.name.isEmpty ? 'Sistema' : s.name}»?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => s.isDeleted = true); // soft-delete recuperable
    _scheduleSave();
  }

  void _restoreSala(AuditSala s) {
    setState(() => s.isDeleted = false);
    _scheduleSave();
  }

  Future<void> _setStatus(int newStatus, String msg) async {
    _saveTimer?.cancel();
    final a = _audit!;
    await _saveNow();
    a.status = newStatus;
    a.updatedAtUtc = DateTime.now().toUtc();
    await context.read<AppDatabase>().upsertLocal(a);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Correlativos (llave con Bactiquant): 1..N por auditoría al iniciar el muestreo ──
  bool get _hasCorrelativos =>
      _audit?.document.salas.any((s) => s.puntosControl.any((p) => p.correlativo != null)) ?? false;

  // Numera 1..N los puntos no borrados sin correlativo, en orden (sistema, punto), continuando
  // desde el máximo ya asignado. Inmutable lo ya numerado (past-proof).
  void _assignCorrelativos() {
    final a = _audit;
    if (a == null) return;
    var maxC = 0;
    for (final s in a.document.salas) {
      for (final p in s.puntosControl) {
        if (p.correlativo != null && p.correlativo! > maxC) maxC = p.correlativo!;
      }
    }
    var next = maxC + 1;
    for (final s in a.document.salas.where((s) => !s.isDeleted)) {
      for (final p in s.puntosControl.where((p) => !p.isDeleted && p.correlativo == null)) {
        p.correlativo = next++;
      }
    }
  }

  // Agendada → Borrador + numera los puntos (arranca el muestreo).
  Future<void> _startAudit() async {
    _assignCorrelativos();
    await _setStatus(AuditStatus.draft.value, 'Auditoría iniciada');
  }

  // Inicia el muestreo de un borrador (spot): numera los puntos. El folio lo asigna el servidor al sincronizar.
  Future<void> _startSampling() async {
    setState(_assignCorrelativos);
    await _saveNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Muestreo iniciado — los puntos quedaron numerados')));
  }

  // ── Consultas adicionales ──
  bool _isOtro(TemplateQuestion q) => q.text.trim().toLowerCase() == 'otro';
  bool _sectionHasOtro(TemplateSection s) => s.questions.any(_isOtro);
  String _extraPrefix(TemplateSection s) => '${s.code}~EX~';
  List<String> _extraKeys(Map<String, Answer> map, TemplateSection s) =>
      (map.keys.where((k) => k.startsWith(_extraPrefix(s))).toList()..sort());
  void _addExtra(Map<String, Answer> map, TemplateSection s) {
    map['${_extraPrefix(s)}${const Uuid().v4()}'] = Answer(titulo: '');
    setState(() {});
    _scheduleSave();
  }
  void _removeExtra(Map<String, Answer> map, String key) {
    map.remove(key);
    setState(() {});
    _scheduleSave();
  }

  // ── Comentarios ──
  bool _commentVisible(Answer a) => (a.comentario?.isNotEmpty ?? false) || _showComment.contains(a);
  void _toggleComment(Answer a) {
    setState(() {
      if (_commentVisible(a)) {
        a.comentario = null;
        _showComment.remove(a);
      } else {
        _showComment.add(a);
      }
    });
    _scheduleSave();
  }

  // ── Colores/badges (espejo de la web) ──
  Color _badgeColor(String code) {
    switch (code.split('-').first) {
      case 'ID': return const Color(0xFF3949AB);
      case 'AF': return const Color(0xFF2D58FF);
      case 'IN': return const Color(0xFF1C7293);
      case 'PR': return const Color(0xFFC2410C);
      case 'HI': return const Color(0xFF0891B2);
      case 'DE': return const Color(0xFF7C3AED);
      case 'BF': return const Color(0xFF0F7A52);
      case 'OX': return const Color(0xFF0369A1);
      case 'OP': return const Color(0xFFB7791F);
      case 'SA': return const Color(0xFFBE123C);
      default: return const Color(0xFF566873);
    }
  }

  Color _sectionColor(TemplateSection s) =>
      _badgeColor(s.questions.isNotEmpty ? s.questions.first.code : s.code);

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          border: Border.all(color: c.withValues(alpha: 0.34)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
      );

  // Chip de afluente (con gota). Null/vacío = no muestra nada.
  Widget _afluenteChip(String? afluente) {
    if (afluente == null || afluente.isEmpty) return const SizedBox.shrink();
    const c = Color(0xFF0E7490);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.10),
        border: Border.all(color: c.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.water_drop_outlined, size: 11, color: c),
        const SizedBox(width: 3),
        Text(afluente,
            style: const TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_audit == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('No se encontró la auditoría.')));
    }
    if (_tpl == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Auditoría')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('Plantilla no disponible. Conéctate una vez para descargarla.')),
        ),
      );
    }

    final a = _audit!;
    final date = a.scheduledForUtc ?? a.sampledAtUtc;
    final title = date != null ? '${a.centerName} · ${_fmt(date)}' : a.centerName;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16)),
            Text('${a.clientName ?? 'Sin cliente'} · ${a.statusEnum.label}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
        actions: [
          if (_locked)
            const Padding(padding: EdgeInsets.only(right: 12), child: Icon(Icons.lock_outline))
          else
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: Text(_saving ? 'Guardando…' : 'Guardado', style: const TextStyle(fontSize: 12))),
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(icon: Icon(Icons.badge_outlined), text: 'Identificación'),
            const Tab(icon: Icon(Icons.warehouse_outlined), text: 'Sistemas'),
            // Entrevista y RPN quedan atenuadas hasta que haya centro.
            _gatedTab(Icons.question_answer_outlined, 'Entrevista', a.centerId != null),
            _gatedTab(Icons.fact_check_outlined, 'Auditoría RPN', a.centerId != null),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!_locked) _topActions(a),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [_identificacionTab(a), _sistemasTab(a), _entrevistaTab(a), _rpnTab(a)],
            ),
          ),
        ],
      ),
    );
  }

  // Tab con etiqueta atenuada cuando está deshabilitado (gating por centro).
  Widget _gatedTab(IconData icon, String label, bool enabled) => Tab(
        icon: Icon(icon, color: enabled ? null : Colors.grey.withValues(alpha: 0.5)),
        child: Text(label, style: TextStyle(color: enabled ? null : Colors.grey.withValues(alpha: 0.5))),
      );

  // Acciones al inicio: guardar + iniciar/finalizar.
  Widget _topActions(Audit a) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(children: [
          FilledButton.tonalIcon(
              onPressed: _saveNow, icon: const Icon(Icons.save_outlined, size: 18), label: const Text('Guardar')),
          const SizedBox(width: 8),
          if (a.statusEnum == AuditStatus.scheduled)
            OutlinedButton.icon(
                onPressed: _startAudit,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Iniciar'))
          else if (a.statusEnum == AuditStatus.draft && !_hasCorrelativos)
            OutlinedButton.icon(
                onPressed: _startSampling,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Iniciar muestreo'))
          else if (a.statusEnum == AuditStatus.draft)
            OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.green),
                onPressed: _confirmFinalize,
                icon: const Icon(Icons.check_circle, size: 18),
                label: const Text('Finalizar')),
        ]),
      );

  // ── Pestaña 1: IDENTIFICACIÓN (data general de la auditoría) ──
  Widget _identificacionTab(Audit a) => ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_locked)
            const Card(
              color: Color(0xFFEFF3F6),
              child: ListTile(
                leading: Icon(Icons.lock_outline),
                title: Text('Auditoría finalizada'),
                subtitle: Text('Los datos quedan fijos (solo lectura).'),
              ),
            ),
          _headerCard(a),
          const SizedBox(height: 40),
        ],
      );

  // ── Pestaña 3: ENTREVISTA (el cuestionario) ──
  Widget _entrevistaTab(Audit a) {
    if (a.centerId == null) return _needCenterNotice();
    final activas = a.document.salas.where((s) => !s.isDeleted).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_locked)
          const Card(
            color: Color(0xFFEFF3F6),
            child: ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Auditoría finalizada'),
              subtitle: Text('Los datos quedan fijos (solo lectura).'),
            ),
          ),
        for (final sec in _centerSections) _sectionCard(sec, a.document.center),
        const SizedBox(height: 8),
        if (activas.isEmpty)
          const Card(
            color: Color(0xFFEFF6FF),
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Color(0xFF2D58FF)),
              title: Text('Define los sistemas a auditar en la pestaña Sistemas.'),
            ),
          ),
        for (final sala in activas) _salaCard(sala),
        const SizedBox(height: 40),
      ],
    );
  }

  // Aviso cuando aún no hay centro: Entrevista/RPN dependen de él.
  Widget _needCenterNotice() => ListView(
        padding: const EdgeInsets.all(12),
        children: const [
          Card(
            color: Color(0xFFFFF7E6),
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Color(0xFFB7791F)),
              title: Text('Define el centro en la pestaña Identificación'),
              subtitle: Text('Los sistemas y su cuestionario dependen del centro asignado.'),
            ),
          ),
        ],
      );

  // ── Pestaña 2: SISTEMAS (define los sistemas transversales a Entrevista y RPN) ──
  Widget _sistemasTab(Audit a) {
    final activos = a.document.salas.where((s) => !s.isDeleted).toList();
    // Bloqueada: solo lectura de los sistemas auditados.
    if (_locked) {
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sistemas auditados',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (activos.isEmpty)
                    const Text('Sin sistemas.', style: TextStyle(color: Colors.grey))
                  else
                    for (final s in activos) _sistemaReadonlyRow(s),
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      );
    }

    final master = _masterSistemas;
    final adhoc = activos.where((s) => !s.fromMaster).toList();
    final eliminados = a.document.salas.where((s) => s.isDeleted && !s.fromMaster).toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('Sistemas a auditar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const Padding(
          padding: EdgeInsets.only(top: 2, bottom: 12),
          child: Text('Los sistemas son transversales: alimentan tanto la Entrevista como la Auditoría RPN.',
              style: TextStyle(fontSize: 13, color: Color(0xFF556173))),
        ),
        if (a.centerId == null)
          const Card(
            color: Color(0xFFFFF7E6),
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Color(0xFFB7791F)),
              title: Text('Selecciona primero el centro en la pestaña Identificación.'),
            ),
          ),
        // Sistemas del maestro del centro: marcar cuáles se auditan (nombre/tipo se editan en el centro).
        if (master.isNotEmpty) _masterSistemasCard(master),
        // Sistemas ad-hoc.
        _adhocSistemasCard(adhoc),
        if (activos.isEmpty)
          const Card(
            color: Color(0xFFEFF6FF),
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Color(0xFF2D58FF)),
              title: Text('Aún no hay sistemas seleccionados para esta auditoría.'),
            ),
          ),
        // Papelera de sistemas ad-hoc eliminados.
        if (eliminados.isNotEmpty) _deletedSalas(a),
        const SizedBox(height: 40),
      ],
    );
  }

  // Fila de solo lectura de un sistema auditado (past-proof / bloqueada).
  Widget _sistemaReadonlyRow(AuditSala s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const Icon(Icons.warehouse_outlined, size: 20, color: Color(0xFF2D58FF)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(s.name.isEmpty ? 'Sistema' : s.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          _tipoChip(s.tipo),
          if (s.afluente != null && s.afluente!.isNotEmpty) ...[
            const SizedBox(width: 6),
            _afluenteChip(s.afluente),
          ],
          const SizedBox(width: 6),
          if (s.fromMaster)
            const Tooltip(message: 'Sistema del maestro', child: Icon(Icons.lock, size: 16, color: Colors.grey))
          else
            _badge('adicional', const Color(0xFF566873)),
        ]),
      );

  // Chip del tipo (o "Sin Tipo").
  Widget _tipoChip(String? tipo) {
    final hasTipo = tipo != null && tipo.isNotEmpty;
    final c = hasTipo ? const Color(0xFF2D58FF) : const Color(0xFF566873);
    return _badge(hasTipo ? tipo : 'Sin Tipo', c);
  }

  // Bloque "Sistemas del centro" (maestro): checkbox por cada uno, nombre/tipo de solo lectura.
  Widget _masterSistemasCard(List<Sistema> master) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('Sistemas del centro', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(width: 8),
                _badge('maestro', const Color(0xFF566873)),
              ]),
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 6),
                child: Text('Marca los que se auditan. El nombre y el tipo solo se editan en el centro.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF556173))),
              ),
              for (final m in master) _masterSistemaRow(m),
            ],
          ),
        ),
      );

  Widget _masterSistemaRow(Sistema m) {
    final current = _masterSalaFor(m.nombre);
    final included = current != null && !current.isDeleted;
    final af = _afluenteSnapshot(m);
    return Row(children: [
      Checkbox(
        value: included,
        visualDensity: VisualDensity.compact,
        onChanged: (v) => _toggleMaster(m, v ?? false),
      ),
      Icon(Icons.warehouse_outlined, size: 20, color: included ? const Color(0xFF2D58FF) : Colors.grey),
      const SizedBox(width: 8),
      Flexible(
        child: Text(m.nombre,
            style: TextStyle(
                fontWeight: included ? FontWeight.w600 : FontWeight.w400,
                color: included ? null : const Color(0xFF8A93A2))),
      ),
      const SizedBox(width: 8),
      _tipoChip(m.tipo),
      if (af != null && af.isNotEmpty) ...[
        const SizedBox(width: 6),
        _afluenteChip(af),
      ],
      if (m.puntosControl.isNotEmpty) ...[
        const SizedBox(width: 6),
        _badge('${m.puntosControl.length} pts', const Color(0xFF566873)),
      ],
    ]);
  }

  // Bloque "Sistemas adicionales" (ad-hoc): agregar + lista editable + papelera.
  Widget _adhocSistemasCard(List<AuditSala> adhoc) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Sistemas adicionales', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 10),
                child: Text('Sistemas que no están en el centro. Estos sí puedes renombrar y retipar.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF556173))),
              ),
              // Formulario de alta.
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: TextField(
                    controller: _newSalaName,
                    decoration: _dec().copyWith(hintText: 'Nombre del sistema'),
                    onChanged: (_) => setState(() {}), // habilita/inhabilita Agregar
                    onSubmitted: (_) => _addSalaNew(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<String?>(
                    value: _newSalaTipo,
                    isExpanded: true,
                    decoration: _dec(),
                    onChanged: (v) => setState(() => _newSalaTipo = v),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Sin Tipo')),
                      for (final t in kSistemaTipos) DropdownMenuItem<String?>(value: t, child: Text(t)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _newSalaName.text.trim().isEmpty ? null : _addSalaNew,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Agregar'),
                ),
              ),
              const SizedBox(height: 8),
              if (adhoc.isEmpty)
                const Text('Sin sistemas adicionales.', style: TextStyle(color: Colors.grey))
              else
                for (final sala in adhoc) _adhocSistemaRow(sala),
            ],
          ),
        ),
      );

  Widget _adhocSistemaRow(AuditSala sala) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Icon(Icons.warehouse_outlined, size: 20, color: Color(0xFF2D58FF)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextFormField(
              key: ValueKey('adhocname-${sala.id}'),
              initialValue: sala.name,
              decoration: _dec().copyWith(hintText: 'Nombre del sistema'),
              onChanged: (v) { sala.name = v; _scheduleSave(); },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<String?>(
              value: kSistemaTipos.contains(sala.tipo) ? sala.tipo : null,
              isExpanded: true,
              decoration: _dec(),
              onChanged: (v) { setState(() => sala.tipo = v); _scheduleSave(); },
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Sin Tipo')),
                for (final t in kSistemaTipos) DropdownMenuItem<String?>(value: t, child: Text(t)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: () => _removeSala(sala),
          ),
        ]),
      );

  // ── Pestaña 4: AUDITORÍA RPN (puntos de control por sistema) ──
  Widget _rpnTab(Audit a) {
    if (a.centerId == null) return _needCenterNotice();
    final sistemas = a.document.salas.where((s) => !s.isDeleted).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (sistemas.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('Define los sistemas en la pestaña Sistemas para inspeccionar sus puntos de control.'),
            ),
          ),
        for (final sistema in sistemas) _sistemaRpnCard(sistema),
        const SizedBox(height: 40),
      ],
    );
  }

  // Título de un sistema (nombre + chip de tipo + candado si viene del maestro).
  Widget _sistemaTitle(AuditSala sistema) {
    final hasTipo = sistema.tipo != null && sistema.tipo!.isNotEmpty;
    return Row(children: [
      Flexible(
        child: Text(sistema.name.isEmpty ? 'Sistema' : sistema.name,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      if (hasTipo) ...[
        const SizedBox(width: 8),
        _badge(sistema.tipo!, const Color(0xFF2D58FF)),
      ],
      if (sistema.afluente != null && sistema.afluente!.isNotEmpty) ...[
        const SizedBox(width: 6),
        _afluenteChip(sistema.afluente),
      ],
      if (sistema.fromMaster) ...[
        const SizedBox(width: 6),
        const Tooltip(message: 'Sistema del maestro', child: Icon(Icons.lock, size: 16, color: Colors.grey)),
      ],
    ]);
  }

  Widget _sistemaRpnCard(AuditSala sistema) {
    final c = _badgeColor('IN-01');
    final puntos = sistema.puntosControl.where((x) => !x.isDeleted).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: c, width: 4))),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: const Icon(Icons.warehouse_outlined),
            title: _sistemaTitle(sistema),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            children: [
              for (final p in puntos) _puntoCard(sistema, p),
              if (puntos.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('Sin puntos de control aún.', style: TextStyle(color: Colors.grey))),
              if (!_locked)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                      onPressed: () => _addPunto(sistema),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Agregar punto de control')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _puntoCard(AuditSala sistema, PuntoControl p) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE1E6F0)),
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xFFFCFDFF),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Encabezado del punto: chip de tipo (si tiene) + candado si viene del maestro.
            if ((p.tipo != null && p.tipo!.isNotEmpty) || p.fromMaster) ...[
              Row(children: [
                if (p.tipo != null && p.tipo!.isNotEmpty) _badge(p.tipo!, const Color(0xFF2D58FF)),
                if (p.fromMaster) ...[
                  const SizedBox(width: 6),
                  const Tooltip(
                      message: 'Punto del maestro (nombre y tipo fijos)',
                      child: Icon(Icons.lock, size: 15, color: Colors.grey)),
                ],
              ]),
              const SizedBox(height: 6),
            ],
            Row(children: [
              if (p.correlativo != null) ...[
                Tooltip(
                  message: 'Correlativo (Sample ID en Bactiquant)',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFF2D58FF), borderRadius: BorderRadius.circular(6)),
                    child: Text('${p.correlativo}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: TextFormField(
                  key: ValueKey('pn-${p.id}'),
                  initialValue: p.nombre,
                  readOnly: _locked || p.fromMaster,
                  decoration: _dec().copyWith(hintText: 'Punto de muestreo (equipo / componente)'),
                  onChanged: (v) { p.nombre = v; _scheduleSave(); },
                ),
              ),
              if (!_locked)
                IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _removePunto(sistema, p)),
            ]),
            // Ad-hoc: selector de tipo estándar (el maestro define el de sus puntos).
            if (!p.fromMaster && !_locked) ...[
              const SizedBox(height: 6),
              DropdownButtonFormField<String?>(
                key: ValueKey('pt-${p.id}'),
                value: kPuntoControlTipos.contains(p.tipo) ? p.tipo : null,
                isExpanded: true,
                decoration: _dec().copyWith(labelText: 'Tipo'),
                onChanged: (v) { setState(() => p.tipo = v); _scheduleSave(); },
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Sin Tipo')),
                  for (final t in kPuntoControlTipos) DropdownMenuItem<String?>(value: t, child: Text(t)),
                ],
              ),
            ],
            const SizedBox(height: 6),
            _evalBlock(p),
            const SizedBox(height: 6),
            TextFormField(
              key: ValueKey('pc-${p.id}'),
              initialValue: p.comentario,
              readOnly: _locked,
              minLines: 1,
              maxLines: 3,
              decoration: _dec().copyWith(
                  labelText: 'Comentario / observación',
                  prefixIcon: const Icon(Icons.comment_outlined, size: 18)),
              onChanged: (v) { p.comentario = v; _scheduleSave(); },
            ),
            _fotosRow(p),
            _audioRow(p),
            _trashRow(p),
          ],
        ),
      );

  // ── Audio del punto: grabación con VU meter + validación de micrófono ──
  Widget _audioRow(PuntoControl p) {
    final recording = _recPunto == p;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recording)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF5F5),
                border: Border.all(color: const Color(0xFFF0C0C0)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.mic, color: Colors.red, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _recLevel,
                      minHeight: 8,
                      backgroundColor: const Color(0xFFE6E9F0),
                      color: _recLevel < 0.12 ? Colors.red : (_recLevel < 0.3 ? Colors.orange : Colors.green),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${_recSeconds}s', style: const TextStyle(fontSize: 12, color: Color(0xFF556173))),
                const SizedBox(width: 4),
                IconButton(
                    icon: const Icon(Icons.stop_circle, color: Colors.red),
                    tooltip: 'Detener',
                    onPressed: _stopRec),
                IconButton(icon: const Icon(Icons.close, size: 20), tooltip: 'Cancelar', onPressed: _cancelRec),
              ]),
            )
          else if (!_locked)
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: _recPunto == null ? () => _startRec(p) : null,
                  icon: const Icon(Icons.mic, size: 18),
                  label: const Text('Audio')),
              OutlinedButton.icon(
                  onPressed: _testMic,
                  icon: const Icon(Icons.graphic_eq, size: 18),
                  label: const Text('Probar micrófono')),
            ]),
          for (final ev in p.audios.where((a) => !a.isDeleted)) _audioItem(p, ev),
        ],
      ),
    );
  }

  Widget _audioItem(PuntoControl p, Evidencia ev) {
    final local = _media.fileFor(ev.id).existsSync();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.play_circle_outline, color: Color(0xFF2D58FF)),
          tooltip: local ? 'Reproducir' : 'Disponible en el servidor',
          onPressed: local ? () => _playAudio(ev) : null,
        ),
        const Icon(Icons.graphic_eq, size: 18, color: Color(0xFF556173)),
        const SizedBox(width: 6),
        if (_silentAudios.contains(ev.id))
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(6)),
            child: const Text('sin voz detectada', style: TextStyle(fontSize: 11, color: Color(0xFFB7791F), fontWeight: FontWeight.w600)),
          ),
        const Spacer(),
        if (!ev.uploaded) const Icon(Icons.cloud_upload_outlined, size: 16, color: Color(0xFFE0A030)),
        if (!_locked)
          IconButton(
              icon: const Icon(Icons.auto_awesome, size: 20, color: Color(0xFF7C4DFF)),
              tooltip: 'Transcribir con IA',
              onPressed: () => _transcribirIA(p, ev)),
        if (!_locked)
          IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _removeAudio(p, ev)),
      ]),
    );
  }

  /// Transcripción del audio con IA (Claude). Aún no conectada: deja el texto
  /// preparado para compilarse en el comentario del punto cuando se habilite Fase 6.
  Future<void> _transcribirIA(PuntoControl p, Evidencia ev) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transcripción con IA: disponible próximamente')),
    );
  }

  Future<void> _startRec(PuntoControl p) async {
    final ok = await _media.startRecording(onLevel: (l) {
      if (mounted) setState(() => _recLevel = l);
    });
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se pudo acceder al micrófono. Revisa los permisos.')));
      }
      return;
    }
    setState(() { _recPunto = p; _recSeconds = 0; _recLevel = 0; });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recSeconds++);
    });
  }

  Future<void> _stopRec() async {
    _recTimer?.cancel();
    final p = _recPunto;
    setState(() => _recPunto = null);
    final res = await _media.stopRecording();
    if (res.ev != null && p != null) {
      setState(() {
        p.audios.add(res.ev!);
        if (res.silent) _silentAudios.add(res.ev!.id);
      });
      _scheduleSave();
      if (res.silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            backgroundColor: Colors.orange,
            content: Text('No se detectó voz. Revisa el micrófono y regraba si es necesario.')));
      }
    }
  }

  Future<void> _cancelRec() async {
    _recTimer?.cancel();
    await _media.cancelRecording();
    if (mounted) setState(() => _recPunto = null);
  }

  Future<void> _testMic() async {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Probando micrófono…'), duration: Duration(milliseconds: 2300)));
    final r = await _media.testMic();
    if (!mounted) return;
    final msg = r == null
        ? 'Sin permiso de micrófono.'
        : (r ? '✓ Micrófono OK, se detectó señal.' : '⚠ No se detectó señal. Revisa el micrófono.');
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: r == true ? Colors.green : Colors.orange));
  }

  Future<void> _playAudio(Evidencia ev) async {
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(_media.fileFor(ev.id).path));
    } catch (_) {}
  }

  // Soft-delete a la papelera del punto (con confirmación). Se restaura o se purga al finalizar.
  Future<bool> _confirmDelete(String tipo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Eliminar $tipo'),
        content: Text('¿Enviar $tipo a la papelera del punto? Podrás restaurarla hasta que finalices la auditoría.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _removeAudio(PuntoControl p, Evidencia ev) async {
    if (!await _confirmDelete('audio')) return;
    setState(() => ev.isDeleted = true);
    _scheduleSave();
  }

  void _restoreEvidencia(Evidencia ev) { setState(() => ev.isDeleted = false); _scheduleSave(); }

  // ── Fotos del punto (cámara/galería, offline) ──
  Map<String, String> _authHeaders() {
    final t = context.read<AuthService>().token;
    return t != null && t.isNotEmpty ? {'Authorization': 'Bearer $t'} : {};
  }

  Widget _fotosRow(PuntoControl p) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final ev in p.fotos.where((f) => !f.isDeleted)) _thumb(p, ev),
          if (!_locked)
            InkWell(
              onTap: () => _addFoto(p),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 72, height: 72,
                decoration: BoxDecoration(border: Border.all(color: const Color(0xFFDDE2EC)), borderRadius: BorderRadius.circular(8)),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.add_a_photo_outlined, color: Color(0xFF556173)),
                  SizedBox(height: 2),
                  Text('Foto', style: TextStyle(fontSize: 11, color: Color(0xFF556173))),
                ]),
              ),
            ),
        ]),
      );

  Widget _thumb(PuntoControl p, Evidencia ev) {
    final f = _media.fileFor(ev.id);
    final local = f.existsSync();
    final Widget img = local
        ? Image.file(f, width: 72, height: 72, fit: BoxFit.cover)
        : Image.network(
            '${AppConfig.apiBaseUrl}/api/evidencias/${ev.id}',
            width: 72, height: 72, fit: BoxFit.cover, headers: _authHeaders(),
            errorBuilder: (_, __, ___) => Container(
                width: 72, height: 72, color: const Color(0xFFF4F6FB),
                child: const Icon(Icons.image_not_supported_outlined, color: Colors.grey)),
          );
    return SizedBox(
      width: 72, height: 72,
      child: Stack(clipBehavior: Clip.none, children: [
        GestureDetector(
          onTap: () => _openViewer(p, ev),
          child: ClipRRect(borderRadius: BorderRadius.circular(8), child: img),
        ),
        if (!ev.uploaded)
          const Positioned(bottom: 2, left: 2, child: Icon(Icons.cloud_upload_outlined, size: 16, color: Color(0xFFE0A030))),
        if (!_locked)
          Positioned(
            top: -6, right: -6,
            child: GestureDetector(
              onTap: () => _removeFoto(p, ev),
              child: Container(
                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                padding: const EdgeInsets.all(3),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> _addFoto(PuntoControl p) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Tomar foto'),
              onTap: () => Navigator.pop(context, ImageSource.camera)),
          ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Elegir de galería'),
              onTap: () => Navigator.pop(context, ImageSource.gallery)),
        ]),
      ),
    );
    if (source == null) return;
    try {
      final ev = await _media.capturePhoto(source: source);
      if (ev == null) return;
      setState(() => p.fotos.add(ev));
      _scheduleSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No se pudo capturar la foto: $e')));
      }
    }
  }

  Future<void> _removeFoto(PuntoControl p, Evidencia ev) async {
    if (!await _confirmDelete('foto')) return;
    setState(() => ev.isDeleted = true);
    _scheduleSave();
  }

  // Imagen de una evidencia foto (archivo local o servidor con auth).
  Widget _photoImage(Evidencia ev, {BoxFit fit = BoxFit.cover, double? size}) {
    final f = _media.fileFor(ev.id);
    if (f.existsSync()) return Image.file(f, width: size, height: size, fit: fit);
    return Image.network(
      '${AppConfig.apiBaseUrl}/api/evidencias/${ev.id}',
      width: size, height: size, fit: fit, headers: _authHeaders(),
      errorBuilder: (_, __, ___) => Container(
          width: size, height: size, color: const Color(0xFFF4F6FB),
          child: const Icon(Icons.image_not_supported_outlined, color: Colors.grey)),
    );
  }

  // Visor a pantalla completa con pinch-zoom (InteractiveViewer) y swipe/flechas entre fotos.
  void _openViewer(PuntoControl p, Evidencia ev) {
    final fotos = p.fotos.where((f) => !f.isDeleted).toList();
    final idx = fotos.indexWhere((f) => f.id == ev.id);
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (_) => _PhotoViewerDialog(
        fotos: fotos,
        initialIndex: idx < 0 ? 0 : idx,
        imageBuilder: (e) => _photoImage(e, fit: BoxFit.contain),
      ),
    );
  }

  // Papelera del punto: fotos/audios eliminados, con restaurar. Se purga al finalizar.
  Widget _trashRow(PuntoControl p) {
    final delFotos = p.fotos.where((f) => f.isDeleted).toList();
    final delAudios = p.audios.where((a) => a.isDeleted).toList();
    if (delFotos.isEmpty && delAudios.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          leading: const Icon(Icons.delete_outline, size: 20, color: Color(0xFF556173)),
          title: Text('Papelera (${delFotos.length + delAudios.length})',
              style: const TextStyle(fontSize: 13, color: Color(0xFF556173), fontWeight: FontWeight.w600)),
          children: [
            for (final ev in delFotos) _trashItem(ev, isFoto: true),
            for (final ev in delAudios) _trashItem(ev, isFoto: false),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('La papelera se vacía al finalizar la auditoría.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8A93A2), fontStyle: FontStyle.italic)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trashItem(Evidencia ev, {required bool isFoto}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        if (isFoto)
          ClipRRect(borderRadius: BorderRadius.circular(4), child: SizedBox(width: 34, height: 34, child: _photoImage(ev, fit: BoxFit.cover, size: 34)))
        else
          const Icon(Icons.graphic_eq, size: 20, color: Color(0xFF556173)),
        const SizedBox(width: 8),
        Text(isFoto ? 'Foto' : 'Audio', style: const TextStyle(fontSize: 13)),
        const Spacer(),
        if (!_locked)
          TextButton.icon(
              onPressed: () => _restoreEvidencia(ev),
              icon: const Icon(Icons.restore_from_trash, size: 18),
              label: const Text('Restaurar')),
      ]),
    );
  }

  // ── Evaluación de terreno (matriz RPN): 4 dimensiones 1–5 con la escala descrita ──
  static const List<Map<String, dynamic>> _dims = [
    {'l': 'O', 'n': 'Estado operacional', 'sub': null, 'e': ['Óptimo, en parámetros', 'Desviación leve', 'Desviación moderada', 'Fuera de rango', 'Crítico / falla']},
    {'l': 'L', 'n': 'Limpieza / biofilm', 'sub': null, 'e': ['Impecable, sin biofilm', 'Suciedad leve', 'Biofilm incipiente', 'Biofilm extendido', 'Biofilm maduro']},
    {'l': 'I', 'n': 'Impacto en peces', 'sub': null, 'e': ['Sin impacto', 'Estrés leve posible', 'Impacto moderado', 'Daño probable', 'Mortalidad probable']},
    {'l': 'D', 'n': 'Detectabilidad', 'sub': 'dificultad de detectar a tiempo', 'e': ['Muy evidente', 'Detectable con rutina', 'Requiere control dirigido', 'Difícil / tardío', 'Oculto / latente']},
  ];

  int? _getDim(PuntoControl p, int i) => switch (i) {
        0 => p.estadoOperacional,
        1 => p.limpiezaBiofilm,
        2 => p.impactoPeces,
        3 => p.detectabilidad,
        _ => null,
      };

  void _setDim(PuntoControl p, int i, int? v) {
    setState(() {
      switch (i) {
        case 0: p.estadoOperacional = v; break;
        case 1: p.limpiezaBiofilm = v; break;
        case 2: p.impactoPeces = v; break;
        case 3: p.detectabilidad = v; break;
      }
    });
    _scheduleSave();
  }

  Widget _evalBlock(PuntoControl p) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2, bottom: 4),
            child: Text('EVALUACIÓN DE TERRENO  (1 = MEJOR · 5 = PEOR)',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.3, color: Color(0xFF000E3F))),
          ),
          for (var i = 0; i < _dims.length; i++) _dimRow(p, i),
          _legend(),
        ],
      );

  Widget _dimRow(PuntoControl p, int i) {
    final d = _dims[i];
    final e = (d['e'] as List).cast<String>();
    final val = _getDim(p, i);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            RichText(
              text: TextSpan(style: const TextStyle(fontSize: 14), children: [
                TextSpan(text: d['l'] as String, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1C7293))),
                TextSpan(text: ' · ${d['n']}', style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF000E3F))),
              ]),
            ),
            const Spacer(),
            Flexible(
              child: Text(val != null ? e[val - 1] : 'Selecciona',
                  textAlign: TextAlign.right, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF556173))),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            for (final n in const [1, 2, 3, 4, 5]) ...[
              Expanded(child: _dimBtn(n, val == n, () => _setDim(p, i, val == n ? null : n))),
              if (n < 5) const SizedBox(width: 8),
            ],
          ]),
        ],
      ),
    );
  }

  Widget _dimBtn(int n, bool sel, VoidCallback onTap) {
    final color = _riskColor(n);
    return InkWell(
      onTap: _locked ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 42, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? color : Colors.white,
          border: Border.all(color: sel ? color : const Color(0xFFDDE2EC)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('$n',
            style: TextStyle(color: sel ? Colors.white : const Color(0xFF000E3F), fontWeight: FontWeight.w700, fontSize: 16)),
      ),
    );
  }

  Widget _legend() => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('¿Qué significa cada escala?',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF2D58FF))),
          children: [
            for (final d in _dims)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d['sub'] == null ? '${d['l']} — ${d['n']}' : '${d['l']} — ${d['n']} (${d['sub']})',
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: Color(0xFF000E3F))),
                    const SizedBox(height: 2),
                    Text([for (var i = 0; i < 5; i++) '${i + 1}: ${(d['e'] as List)[i]}'].join(' · '),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF556173), height: 1.35)),
                  ],
                ),
              ),
          ],
        ),
      );

  Color _riskColor(int v) => switch (v) {
        1 => const Color(0xFF2E7D32),
        2 => const Color(0xFF7CB342),
        3 => const Color(0xFFF9A825),
        4 => const Color(0xFFEF6C00),
        5 => const Color(0xFFC62828),
        _ => const Color(0xFF556173),
      };

  void _addPunto(AuditSala sistema) {
    setState(() => sistema.puntosControl.add(PuntoControl(id: const Uuid().v4())));
    _scheduleSave();
  }

  void _removePunto(AuditSala sistema, PuntoControl p) {
    setState(() => sistema.puntosControl.remove(p));
    _scheduleSave();
  }

  String _fmt(DateTime utc) {
    final d = utc.toLocal();
    return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
  }

  Future<void> _confirmFinalize() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.check_circle, color: Colors.green),
        title: const Text('Finalizar auditoría'),
        content: const Text('Una vez finalizada, la auditoría queda INMUTABLE: no podrás editar ningún dato. ¿Confirmas que está completa?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, finalizar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _assignCorrelativos(); // seguridad: numera lo que quedó sin correlativo antes de cerrar
      await _purgePapelera();
      await _setStatus(AuditStatus.submitted.value, 'Auditoría finalizada');
    }
  }

  // Vacía la papelera de evidencias (isDeleted): las quita del documento y borra el binario
  // local y del servidor (_media.remove hace ambos). Se llama al finalizar.
  Future<void> _purgePapelera() async {
    final a = _audit;
    if (a == null) return;
    for (final s in a.document.salas) {
      for (final pc in s.puntosControl) {
        for (final ev in [...pc.fotos.where((f) => f.isDeleted), ...pc.audios.where((x) => x.isDeleted)]) {
          await _media.remove(ev.id);
        }
        pc.fotos.removeWhere((f) => f.isDeleted);
        pc.audios.removeWhere((x) => x.isDeleted);
      }
    }
  }

  // ── Cabecera = IDENTIFICACIÓN ──
  Widget _headerCard(Audit a) {
    final idc = _badgeColor('ID-01');
    final date = a.scheduledForUtc ?? a.sampledAtUtc;
    final dateStr = date != null ? _fmt(date) : 'Sin fecha';
    final clientVal = _clients.any((c) => c.id == a.clientId) ? a.clientId : null;
    final centerVal = _centers.any((c) => c.id == a.centerId) ? a.centerId : null;
    final jefe = _ans(a.document.center, 'ID-02');

    final auditorVal = _users.any((u) => u.display == a.auditor) ? a.auditor : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: idc.withValues(alpha: 0.4)),
      ),
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: idc, width: 4))),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            shape: const Border(),
            collapsedShape: const Border(),
            title: Row(children: [
              _badge('IDENTIFICACIÓN', idc),
              const Spacer(),
              if (a.folio != null)
                _badge('Folio ${a.folio}', const Color(0xFF2D58FF))
              else if (_hasCorrelativos)
                _badge('Folio pendiente', const Color(0xFF566873)),
            ]),
            children: [
            // Tipo de auditoría
            _labeled(null, 'Tipo de auditoría',
                DropdownButtonFormField<int>(
                  value: a.type,
                  isExpanded: true,
                  decoration: _dec(),
                  onChanged: _locked ? null : _pickType,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Spot')),
                    DropdownMenuItem(value: 1, child: Text('Seguimiento')),
                  ],
                )),
            // Cliente mandante
            _labeled(null, 'Cliente mandante',
                DropdownButtonFormField<String?>(
                  value: clientVal,
                  isExpanded: true,
                  decoration: _dec(),
                  onChanged: _locked ? null : _pickClient,
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— Sin cliente —')),
                    for (final c in _clients) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
                  ],
                )),
            // Auditor (desde los usuarios del sistema)
            _labeled('ID-04', 'Auditor',
                DropdownButtonFormField<String?>(
                  value: auditorVal,
                  isExpanded: true,
                  decoration: _dec(),
                  onChanged: _locked ? null : _pickAuditor,
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— Sin auditor —')),
                    for (final u in _users) DropdownMenuItem<String?>(value: u.display, child: Text(u.display)),
                  ],
                )),
            // Fecha
            _labeled('ID-03', 'Fecha de auditoría',
                InkWell(
                  onTap: _locked ? null : _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: _dec(),
                    child: Row(children: [
                      Icon(Icons.event, size: 18, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(dateStr),
                    ]),
                  ),
                )),
            // Centro (bloqueada: snapshot past-proof, no el maestro en vivo)
            _labeled('ID-01', 'Centro',
                _locked
                    ? TextFormField(
                        key: ValueKey('centro-${a.id}'),
                        initialValue: a.centerName,
                        readOnly: true,
                        decoration: _dec(),
                      )
                    : DropdownButtonFormField<String?>(
                        value: centerVal,
                        isExpanded: true,
                        decoration: _dec(),
                        onChanged: _pickCenter,
                        items: [
                          const DropdownMenuItem<String?>(value: null, child: Text('— Sin centro —')),
                          for (final c in _centers) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
                        ],
                      )),
            // Jefe de centro / responsable (ID-02)
            _labeled('ID-02', 'Jefe de centro / responsable',
                TextFormField(
                  key: ValueKey('jefe-${a.id}'),
                  initialValue: jefe.respuesta,
                  readOnly: _locked,
                  decoration: _dec(),
                  onChanged: (v) { jefe.respuesta = v; _scheduleSave(); },
                )),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _dec() => InputDecoration(
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  Widget _labeled(String? code, String label, Widget field) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              if (code != null) ...[_badge(code, _badgeColor(code)), const SizedBox(width: 6)],
              Flexible(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
            ]),
            const SizedBox(height: 4),
            field,
          ],
        ),
      );

  // ── Sección (centro o sala) ──
  Widget _sectionCard(TemplateSection sec, Map<String, Answer> map, {bool nested = false}) {
    final c = _sectionColor(sec);
    final tile = Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        initiallyExpanded: !nested,
        shape: const Border(),
        collapsedShape: const Border(),
        title: _badge(sec.name, c),
        children: [
          for (final q in sec.questions)
            if (!_isOtro(q)) _questionField(q, _ans(map, q.code)),
          if (_sectionHasOtro(sec)) _extras(sec, map, c),
        ],
      ),
    );
    return Card(
      margin: EdgeInsets.only(bottom: nested ? 8 : 10),
      clipBehavior: Clip.antiAlias, // clippea el acento al borde redondeado
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: c, width: 4))),
        child: tile,
      ),
    );
  }

  // ── Papelera de sistemas ad-hoc (los del maestro se recuperan re-marcando el checkbox) ──
  Widget _deletedSalas(Audit a) {
    final deleted = a.document.salas.where((s) => s.isDeleted && !s.fromMaster).toList();
    if (deleted.isEmpty || _locked) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(top: 6, bottom: 12),
      color: const Color(0xFFF4F6F8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.delete_outline),
          title: Text('Sistemas eliminados (${deleted.length})',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          children: [
            for (final sala in deleted)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warehouse_outlined, size: 20),
                title: Text(sala.name.isEmpty ? 'Sistema' : sala.name),
                trailing: TextButton.icon(
                  icon: const Icon(Icons.restore_from_trash, size: 18),
                  label: const Text('Restaurar'),
                  onPressed: () => _restoreSala(sala),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Sala colapsable completa (Entrevista). El nombre/tipo se gestionan en la pestaña Sistemas. ──
  Widget _salaCard(AuditSala sala) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: const Icon(Icons.warehouse_outlined),
          title: _sistemaTitle(sala),
          childrenPadding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          children: [
            for (final sec in _tpl!.salaSections) _sectionCard(sec, sala.answers, nested: true),
          ],
        ),
      ),
    );
  }

  // ── Pregunta ──
  Widget _questionField(TemplateQuestion q, Answer a) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _badge(q.code, _badgeColor(q.code)),
              const SizedBox(width: 8),
              Expanded(child: Text(q.text, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (!_locked) _commentMenu(a),
            ],
          ),
          if (q.help.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(q.help, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
          const SizedBox(height: 4),
          _answerBody(a),
        ],
      ),
    );
  }

  // Menú contextual del comentario (equivalente móvil del clic derecho).
  Widget _commentMenu(Answer a) => PopupMenuButton<String>(
        icon: Icon(Icons.more_vert, size: 20, color: Colors.grey.shade600),
        tooltip: 'Opciones',
        onSelected: (_) => _toggleComment(a),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'c',
            child: Row(children: [
              Icon(_commentVisible(a) ? Icons.comments_disabled_outlined : Icons.add_comment_outlined, size: 18),
              const SizedBox(width: 8),
              Text(_commentVisible(a) ? 'Quitar comentario' : 'Agregar comentario'),
            ]),
          ),
        ],
      );

  Widget _answerBody(Answer a) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: ValueKey('r-${identityHashCode(a)}'),
            initialValue: a.respuesta,
            readOnly: _locked,
            minLines: 1,
            maxLines: 4,
            decoration: _dec().copyWith(labelText: 'Respuesta'),
            onChanged: (v) { a.respuesta = v; _scheduleSave(); },
          ),
          if (_commentVisible(a))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: TextFormField(
                key: ValueKey('cmt-${identityHashCode(a)}'),
                initialValue: a.comentario,
                readOnly: _locked,
                minLines: 1,
                maxLines: 3,
                decoration: _dec().copyWith(
                  labelText: 'Comentario',
                  prefixIcon: const Icon(Icons.comment_outlined, size: 18),
                ),
                onChanged: (v) { a.comentario = v; _scheduleSave(); },
              ),
            ),
        ],
      );

  // ── Consultas adicionales de una sección ──
  Widget _extras(TemplateSection sec, Map<String, Answer> map, Color c) {
    final keys = _extraKeys(map, sec);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final key in keys)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: c.withValues(alpha: 0.4), width: 2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _badge('EXTRA', c),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      key: ValueKey('xt-$key'),
                      initialValue: map[key]!.titulo,
                      readOnly: _locked,
                      decoration: const InputDecoration(isDense: true, hintText: 'Título de la consulta adicional', border: UnderlineInputBorder()),
                      onChanged: (v) { map[key]!.titulo = v; _scheduleSave(); },
                    ),
                  ),
                  if (!_locked) _commentMenu(map[key]!),
                  if (!_locked)
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: Colors.red),
                      onPressed: () => _removeExtra(map, key),
                    ),
                ]),
                const SizedBox(height: 4),
                _answerBody(map[key]!),
              ],
            ),
          ),
        if (!_locked)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _addExtra(map, sec),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Agregar consulta adicional'),
            ),
          ),
      ],
    );
  }
}

/// Visor de fotos a pantalla completa: pinch-zoom (InteractiveViewer), swipe entre fotos,
/// flechas ‹ › (y teclado ← → / Esc), contador.
class _PhotoViewerDialog extends StatefulWidget {
  final List<Evidencia> fotos;
  final int initialIndex;
  final Widget Function(Evidencia) imageBuilder;
  const _PhotoViewerDialog({required this.fotos, required this.initialIndex, required this.imageBuilder});

  @override
  State<_PhotoViewerDialog> createState() => _PhotoViewerDialogState();
}

class _PhotoViewerDialogState extends State<_PhotoViewerDialog> {
  late final PageController _pc;
  late int _i;

  @override
  void initState() {
    super.initState();
    _i = widget.initialIndex;
    _pc = PageController(initialPage: _i);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i < 0 || i >= widget.fotos.length) return;
    _pc.animateToPage(i, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, e) {
          if (e is KeyDownEvent) {
            if (e.logicalKey == LogicalKeyboardKey.arrowRight) { _go(_i + 1); return KeyEventResult.handled; }
            if (e.logicalKey == LogicalKeyboardKey.arrowLeft) { _go(_i - 1); return KeyEventResult.handled; }
            if (e.logicalKey == LogicalKeyboardKey.escape) { Navigator.pop(context); return KeyEventResult.handled; }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(children: [
          PageView.builder(
            controller: _pc,
            itemCount: widget.fotos.length,
            onPageChanged: (i) => setState(() => _i = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Center(child: widget.imageBuilder(widget.fotos[i])),
            ),
          ),
          Positioned(
              top: 36, right: 8,
              child: IconButton(icon: const Icon(Icons.close, color: Colors.white, size: 28), onPressed: () => Navigator.pop(context))),
          if (_i > 0)
            Positioned(
                left: 4, top: 0, bottom: 0,
                child: Center(child: IconButton(icon: const Icon(Icons.chevron_left, color: Colors.white70, size: 42), onPressed: () => _go(_i - 1)))),
          if (_i < widget.fotos.length - 1)
            Positioned(
                right: 4, top: 0, bottom: 0,
                child: Center(child: IconButton(icon: const Icon(Icons.chevron_right, color: Colors.white70, size: 42), onPressed: () => _go(_i + 1)))),
          Positioned(
            bottom: 28, left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                child: Text('${_i + 1} / ${widget.fotos.length}', style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
