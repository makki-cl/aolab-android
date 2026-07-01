import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../models/audit.dart';
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
  bool _loading = true;
  Timer? _saveTimer;
  bool _saving = false;

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
    _tpl = context.read<TemplateService>().template;
    _audit = await context.read<AppDatabase>().findById(widget.auditId);
    if (mounted) setState(() => _loading = false);
  }

  bool get _locked => _audit?.isLocked ?? false;

  Answer _centerAns(String code) => _audit!.document.center.putIfAbsent(code, () => Answer());
  Answer _salaAns(AuditSala s, String code) => s.answers.putIfAbsent(code, () => Answer());

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
    final c = a.document.center;
    String? val(String code) {
      final r = c[code]?.respuesta?.trim();
      return (r == null || r.isEmpty) ? null : r;
    }

    // Denormaliza la cabecera desde IDENTIFICACIÓN si no vino del maestro.
    if (a.centerId == null) a.centerName = val('ID-01') ?? a.centerName;
    a.auditor ??= val('ID-04');
    a.sampledAtUtc ??= DateTime.tryParse(c['ID-03']?.respuesta ?? '');
    a.updatedAtUtc = DateTime.now().toUtc();

    await context.read<AppDatabase>().upsertLocal(a); // marca dirty
    if (mounted) setState(() => _saving = false);
  }

  void _addSala() {
    setState(() {
      final n = _audit!.document.salas.length + 1;
      _audit!.document.salas.add(AuditSala(id: const Uuid().v4(), name: 'Sala $n'));
    });
    _scheduleSave();
  }

  void _removeSala(AuditSala s) {
    setState(() => _audit!.document.salas.remove(s));
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
    final title = date != null
        ? '${a.centerName} · ${date.toLocal().day.toString().padLeft(2, '0')}-${date.toLocal().month.toString().padLeft(2, '0')}-${date.toLocal().year}'
        : a.centerName;

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
              child: Center(child: Text(_saving ? 'Guardando…' : 'Guardado',
                  style: const TextStyle(fontSize: 12))),
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

          for (final sec in _tpl!.centerSections)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ExpansionTile(
                title: Text(sec.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                initiallyExpanded: sec.code == _tpl!.centerSections.first.code,
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [for (final q in sec.questions) _questionField('c', q, _centerAns(q.code))],
              ),
            ),

          const SizedBox(height: 8),
          Row(
            children: [
              Text('Salas (${a.document.salas.length})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (!_locked)
                TextButton.icon(onPressed: _addSala, icon: const Icon(Icons.add_business), label: const Text('Agregar sala')),
            ],
          ),

          for (final sala in a.document.salas)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.warehouse_outlined),
                    title: TextFormField(
                      key: ValueKey('salaname-${sala.id}'),
                      initialValue: sala.name,
                      readOnly: _locked,
                      decoration: const InputDecoration(labelText: 'Nombre de la sala', border: InputBorder.none),
                      onChanged: (v) { sala.name = v; _scheduleSave(); },
                    ),
                    trailing: _locked ? null : IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _removeSala(sala),
                    ),
                  ),
                  for (final sec in _tpl!.salaSections)
                    ExpansionTile(
                      title: Text(sec.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [for (final q in sec.questions) _questionField(sala.id, q, _salaAns(sala, q.code))],
                    ),
                ],
              ),
            ),

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
              onPressed: () => _setStatus(AuditStatus.submitted.value, 'Auditoría finalizada'),
              icon: const Icon(Icons.check_circle),
              label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Finalizar auditoría')),
            ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _questionField(String scope, TemplateQuestion q, Answer a) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(q.text, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (q.help.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(q.help, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ),
          TextFormField(
            key: ValueKey('$scope-${q.code}-r'),
            initialValue: a.respuesta,
            readOnly: _locked,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Respuesta', border: OutlineInputBorder(), isDense: true),
            onChanged: (v) { a.respuesta = v; _scheduleSave(); },
          ),
          const SizedBox(height: 6),
          TextFormField(
            key: ValueKey('$scope-${q.code}-c'),
            initialValue: a.comentario,
            readOnly: _locked,
            decoration: const InputDecoration(
              labelText: 'Comentario (opcional)',
              prefixIcon: Icon(Icons.comment_outlined, size: 18),
              isDense: true,
            ),
            onChanged: (v) { a.comentario = v; _scheduleSave(); },
          ),
        ],
      ),
    );
  }
}
