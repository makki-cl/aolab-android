import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/app_database.dart';
import '../data/form_entry.dart';

/// Crea o edita un formulario. Guarda SIEMPRE en la base local (offline); la
/// sincronización con el servidor ocurre después, al volver a la lista.
class FormEditScreen extends StatefulWidget {
  final FormEntry? entry;
  const FormEditScreen({super.key, this.entry});

  @override
  State<FormEditScreen> createState() => _FormEditScreenState();
}

class _FormEditScreenState extends State<FormEditScreen> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  // Campo de ejemplo dentro del payload flexible `data`.
  late final TextEditingController _value;

  bool get _isNew => widget.entry == null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _title = TextEditingController(text: e?.title ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _value = TextEditingController(text: e?.data['valor']?.toString() ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = context.read<AppDatabase>();
    final now = DateTime.now().toUtc();
    final data = {'valor': _value.text};

    if (_isNew) {
      await db.upsertLocal(FormEntry(
        id: const Uuid().v4(), // GUID en el cliente: permite crear offline
        title: _title.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        capturedAtUtc: now,
        data: data,
        createdAtUtc: now,
        updatedAtUtc: now,
      ));
    } else {
      final e = widget.entry!
        ..title = _title.text.trim()
        ..notes = _notes.text.trim().isEmpty ? null : _notes.text.trim()
        ..data = data
        ..updatedAtUtc = now;
      await db.upsertLocal(e);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    await context.read<AppDatabase>().softDelete(widget.entry!.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nuevo formulario' : 'Editar formulario'),
        actions: [
          if (!_isNew)
            IconButton(
                onPressed: _delete,
                tooltip: 'Eliminar',
                icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(
                labelText: 'Título', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            decoration: const InputDecoration(
                labelText: 'Valor (dato del formulario)',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            maxLines: 4,
            decoration: const InputDecoration(
                labelText: 'Notas', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Guardar (offline)'),
            ),
          ),
        ],
      ),
    );
  }
}
