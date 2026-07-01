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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _tpl = context.read<TemplateService>().template;
    _audit = await context.read<AppDatabase>().findById(widget.auditId);
    if (mounted) setState(() => _loading = false);
  }

  Answer _centerAns(String code) => _audit!.document.center.putIfAbsent(code, () => Answer());
  Answer _salaAns(AuditSala s, String code) => s.answers.putIfAbsent(code, () => Answer());

  void _addSala() {
    setState(() {
      final n = _audit!.document.salas.length + 1;
      _audit!.document.salas.add(AuditSala(id: const Uuid().v4(), name: 'Sala $n'));
    });
  }

  void _removeSala(AuditSala s) => setState(() => _audit!.document.salas.remove(s));

  Future<void> _save({int? newStatus}) async {
    final a = _audit!;
    final c = a.document.center;
    String? val(String code) {
      final r = c[code]?.respuesta?.trim();
      return (r == null || r.isEmpty) ? null : r;
    }

    a.centerName = val('ID-01') ?? '(sin nombre)';
    a.auditor = val('ID-04');
    a.sampledAtUtc = DateTime.tryParse(c['ID-03']?.respuesta ?? '');
    if (newStatus != null) a.status = newStatus;
    a.updatedAtUtc = DateTime.now().toUtc();

    await context.read<AppDatabase>().upsertLocal(a);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(newStatus == AuditStatus.submitted.value ? 'Auditoría enviada' : 'Guardada')),
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
    return Scaffold(
      appBar: AppBar(
        title: Text(a.centerName),
        actions: [
          IconButton(tooltip: 'Guardar', onPressed: () => _save(), icon: const Icon(Icons.save)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(a.statusEnum.label, style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 8),

          // ── Secciones de CENTRO ──
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
              TextButton.icon(onPressed: _addSala, icon: const Icon(Icons.add_business), label: const Text('Agregar sala')),
            ],
          ),

          // ── SALAS (repetibles) ──
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
                      decoration: const InputDecoration(labelText: 'Nombre de la sala', border: InputBorder.none),
                      onChanged: (v) => sala.name = v,
                    ),
                    trailing: IconButton(
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
          if (a.statusEnum == AuditStatus.draft)
            FilledButton.icon(
              onPressed: () => _save(newStatus: AuditStatus.submitted.value),
              icon: const Icon(Icons.send),
              label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Enviar auditoría')),
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
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Respuesta', border: OutlineInputBorder(), isDense: true),
            onChanged: (v) => a.respuesta = v,
          ),
          const SizedBox(height: 6),
          TextFormField(
            key: ValueKey('$scope-${q.code}-c'),
            initialValue: a.comentario,
            decoration: const InputDecoration(
              labelText: 'Comentario (opcional)',
              prefixIcon: Icon(Icons.comment_outlined, size: 18),
              isDense: true,
            ),
            onChanged: (v) => a.comentario = v,
          ),
        ],
      ),
    );
  }
}
