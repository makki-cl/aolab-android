import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/audit.dart';
import '../models/master.dart';
import '../models/questionnaire.dart';
import '../services/template_service.dart';

class AuditEditScreen extends StatefulWidget {
  final String auditId;
  const AuditEditScreen({super.key, required this.auditId});

  @override
  State<AuditEditScreen> createState() => _AuditEditScreenState();
}

class _AuditEditScreenState extends State<AuditEditScreen> {
  Audit? _audit;
  QuestionnaireTemplate? _tpl;
  List<ClientRef> _clients = [];
  List<CenterRef> _centers = [];
  bool _loading = true;
  Timer? _saveTimer;
  bool _saving = false;
  final Set<Answer> _showComment = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final db = context.read<AppDatabase>();
    _tpl = context.read<TemplateService>().template;
    _audit = await db.findById(widget.auditId);
    _clients = await db.activeClients();
    _centers = await db.activeCenters();
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
    setState(() {});
    _scheduleSave();
  }

  void _pickType(int? t) {
    _audit!.type = t ?? 0;
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

  // ── Salas ──
  void _addSala() {
    setState(() {
      final n = _audit!.document.salas.where((s) => !s.isDeleted).length + 1;
      _audit!.document.salas.add(AuditSala(id: const Uuid().v4(), name: 'Sala $n'));
    });
    _scheduleSave();
  }

  Future<void> _removeSala(AuditSala s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline, color: Colors.red),
        title: const Text('Eliminar sala'),
        content: Text('¿Eliminar la sala «${s.name.isEmpty ? 'Sala' : s.name}»?'),
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
      ),
      body: ListView(
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

          for (final sec in _centerSections) _sectionCard(sec, a.document.center),

          const SizedBox(height: 8),
          Row(
            children: [
              Text('Salas (${a.document.salas.where((s) => !s.isDeleted).length})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (!_locked)
                TextButton.icon(onPressed: _addSala, icon: const Icon(Icons.add_business), label: const Text('Agregar sala')),
            ],
          ),

          for (final sala in a.document.salas.where((s) => !s.isDeleted)) _salaCard(sala),

          _deletedSalas(a),

          const SizedBox(height: 16),
          if (a.statusEnum == AuditStatus.scheduled)
            FilledButton.icon(
              onPressed: () => _setStatus(AuditStatus.draft.value, 'Auditoría iniciada'),
              icon: const Icon(Icons.play_arrow),
              label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Iniciar auditoría')),
            )
          else if (a.statusEnum == AuditStatus.draft)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
              onPressed: _confirmFinalize,
              icon: const Icon(Icons.check_circle),
              label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Finalizar auditoría')),
            ),
          const SizedBox(height: 40),
        ],
      ),
    );
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
    if (ok == true) await _setStatus(AuditStatus.submitted.value, 'Auditoría finalizada');
  }

  // ── Cabecera = IDENTIFICACIÓN ──
  Widget _headerCard(Audit a) {
    final idc = _badgeColor('ID-01');
    final date = a.scheduledForUtc ?? a.sampledAtUtc;
    final dateStr = date != null ? _fmt(date) : 'Sin fecha';
    final clientVal = _clients.any((c) => c.id == a.clientId) ? a.clientId : null;
    final centerVal = _centers.any((c) => c.id == a.centerId) ? a.centerId : null;
    final jefe = _ans(a.document.center, 'ID-02');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: idc.withValues(alpha: 0.5), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _badge('IDENTIFICACIÓN', idc),
            const SizedBox(height: 10),
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
            // Auditor (solo lectura en el celular)
            _labeled('ID-04', 'Auditor',
                InputDecorator(decoration: _dec(), child: Text(a.auditor ?? '—'))),
            // Fecha
            _labeled('ID-03', 'Fecha de auditoría',
                OutlinedButton.icon(
                  onPressed: _locked ? null : _pickDate,
                  icon: const Icon(Icons.event, size: 18),
                  label: Align(alignment: Alignment.centerLeft, child: Text(dateStr)),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                )),
            // Centro
            _labeled('ID-01', 'Centro',
                DropdownButtonFormField<String?>(
                  value: centerVal,
                  isExpanded: true,
                  decoration: _dec(),
                  onChanged: _locked ? null : _pickCenter,
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
    );
  }

  InputDecoration _dec() => const InputDecoration(isDense: true, border: OutlineInputBorder());

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
    return Container(
      margin: EdgeInsets.only(bottom: nested ? 6 : 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.withValues(alpha: 0.7), width: 3)),
      ),
      child: nested
          ? tile
          : Card(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias, child: tile),
    );
  }

  // ── Papelera de salas (recuperación de borrado accidental) ──
  Widget _deletedSalas(Audit a) {
    final deleted = a.document.salas.where((s) => s.isDeleted).toList();
    if (deleted.isEmpty || _locked) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(top: 6, bottom: 12),
      color: const Color(0xFFF4F6F8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.delete_outline),
          title: Text('Salas eliminadas (${deleted.length})',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          children: [
            for (final sala in deleted)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warehouse_outlined, size: 20),
                title: Text(sala.name.isEmpty ? 'Sala' : sala.name),
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

  // ── Sala colapsable completa ──
  Widget _salaCard(AuditSala sala) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: const Icon(Icons.warehouse_outlined),
          title: Text(sala.name.isEmpty ? 'Sala' : sala.name, style: const TextStyle(fontWeight: FontWeight.w700)),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            Row(children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('salaname-${sala.id}'),
                  initialValue: sala.name,
                  readOnly: _locked,
                  decoration: _dec().copyWith(labelText: 'Nombre de la sala'),
                  onChanged: (v) { sala.name = v; _scheduleSave(); },
                ),
              ),
              if (!_locked)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _removeSala(sala),
                ),
            ]),
            const SizedBox(height: 8),
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
