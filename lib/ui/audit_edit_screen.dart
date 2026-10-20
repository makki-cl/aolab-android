import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../data/app_database.dart';
import '../data/reglas_sync.dart';
import '../models/audit.dart';
import '../models/clases_sistema.dart';
import '../models/master.dart';
import '../models/modelo_puntos.dart';
import '../models/niveles.dart';
import '../models/numeros.dart';
import '../models/questionnaire.dart';
import '../services/audit_sync_service.dart';
import '../services/auth_service.dart';
import '../services/media_service.dart';
import '../services/template_service.dart';
import 'estilo_modelo.dart';
import 'niveles_muestra.dart';

class AuditEditScreen extends StatefulWidget {
  final String auditId;
  const AuditEditScreen({super.key, required this.auditId});

  @override
  State<AuditEditScreen> createState() => _AuditEditScreenState();
}

class _AuditEditScreenState extends State<AuditEditScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tab;
  late final MediaService _media;
  late final AppDatabase _db;
  late final AuditSyncService _sync;
  int _ciclosVistos = 0;
  // Sube cuando la evaluación se recarga desde la fila (el servidor la reemplazó mientras estaba abierta): los campos
  // de texto se vuelven a crear con lo nuevo.
  int _gen = 0;
  Audit? _audit;
  QuestionnaireTemplate? _tpl;
  List<ClientRef> _clients = [];
  List<CenterRef> _centers = [];
  List<UserRef> _users = [];
  // Catálogos del maestro (sincronizados); si aún no sincroniza, se usan las listas embebidas.
  List<String> _sistemaTipos = kSistemaTipos;
  List<String> _puntoTipos = kPuntoControlTipos;
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
    _tab = TabController(length: 5, vsync: this);
    _tab.addListener(_onTabChanged);
    _media = context.read<MediaService>();
    _db = context.read<AppDatabase>();
    _sync = context.read<AuditSyncService>();
    WidgetsBinding.instance.addObserver(this);
    _ciclosVistos = _sync.ciclos;
    _sync.addListener(_onSync);
    _load();
  }

  // Terminó una sincronización mientras la evaluación está abierta: la fila pudo cambiar bajo el editor.
  void _onSync() {
    if (_sync.status == SyncStatus.syncing || _sync.ciclos == _ciclosVistos) return;
    _ciclosVistos = _sync.ciclos;
    _refrescarDesdeFila();
  }

  /// Si el servidor reemplazó la fila (bajó la evaluación mezclada con lo de la web), se recarga: guardar encima la
  /// copia vieja del editor desharía lo de la web. Si no, solo se toma lo que el push le cambió (versión, folio
  /// arbitrado, pendiente). Con un guardado en curso no se toca nada: ese guardado conserva la versión de su copia y
  /// el servidor lo mezcla bien; la próxima sincronización la deja al día.
  Future<void> _refrescarDesdeFila() async {
    final a = _audit;
    // Tampoco mientras graba un audio: el audio se agrega al punto que estaba en pantalla.
    if (a == null || _saving || (_saveTimer?.isActive ?? false) || _recPunto != null) return;
    final db = context.read<AppDatabase>();
    final fila = await db.findById(a.id);
    if (fila == null || !mounted || !identical(a, _audit) || _saving) return;
    if (fila.localRev != a.localRev) {
      setState(() {
        _audit = fila;
        _gen++;
      });
      return;
    }
    final folioCambio = fila.folio != a.folio && a.folio == a.folioLeido;
    a.serverVersion = fila.serverVersion;
    a.dirty = fila.dirty;
    // La posición que acaba de subir ya no se corrige en la tablet.
    conservarNivelesEnServidor(a.document, fila.document);
    if (folioCambio) {
      a.folio = fila.folio;
      a.folioLeido = fila.folio;
    }
    setState(() {
      if (folioCambio) _gen++;
    });
  }

  // Gating: Entrevista (2), Evaluación RPN (3) y Muestreo (4) requieren centro asignado.
  void _onTabChanged() {
    if (_tab.indexIsChanging && _tab.index >= 2 && (_audit?.centerId == null)) {
      _tab.animateTo(1); // vuelve a Sistemas
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Selecciona el centro en Identificación')));
      }
    }
  }

  // Android puede matar la app en segundo plano: lo anotado se guarda al tiro, sin esperar el medio segundo.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) _guardarYa();
  }

  /// Guarda lo pendiente sin esperar (al salir de la pantalla o al pasar a segundo plano).
  void _guardarYa() {
    if (!(_saveTimer?.isActive ?? false)) return;
    _saveTimer?.cancel();
    final a = _audit;
    if (a == null || _locked) return;
    a.updatedAtUtc = DateTime.now().toUtc();
    _db.upsertLocal(a);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync.removeListener(_onSync);
    _guardarYa();
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
    final cats = await db.getCatalogs();
    final st = cats['sistema-tipo'] ?? const [];
    final pt = cats['punto-tipo'] ?? const [];
    if (st.isNotEmpty) _sistemaTipos = st;
    if (pt.isNotEmpty) _puntoTipos = pt;
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
    if (!_saving && mounted) setState(() => _saving = true);
  }

  Future<void> _saveNow() async {
    final a = _audit;
    if (a == null || _locked) return;
    a.updatedAtUtc = DateTime.now().toUtc();
    await _db.upsertLocal(a);
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

  // ¿El centro asignado tiene activo el modelo con equipos? Ahí sus puntos llegan agrupados y con
  // nombre automático, y la auditoría guarda la foto del equipo de cada punto y la etapa del sistema.
  // Un centro guardado por la versión anterior de la app se lee como plano hasta la próxima sincronización.
  bool get _conEquipos => _center?.conEquipos ?? false;

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

  // Agrega un sistema del maestro (sin puntos: se seleccionan individualmente).
  // En un centro activado el tipo que manda el servidor es el código de la etapa, y la etapa queda
  // además como foto para el informe. En el modelo plano todo como antes (sin etapa), igual que la web.
  AuditSala _addSalaFromMaster(Sistema m) {
    final sala = _newSala(m.nombre, tipo: m.tipo, fromMaster: true);
    sala.masterId = m.id;              // vínculo estable con el maestro
    sala.afluente = _afluenteSnapshot(m);
    if (_conEquipos) sala.etapa = m.etapa;
    return sala;
  }

  // Vínculo con el punto del maestro: por Id; para puntos guardados antes del Id, por alias + tipo,
  // y eso solo contra el modelo plano (esMismoPunto, la misma regla de la web y el editor offline).
  // ¿El punto del maestro está seleccionado (presente y no borrado) en el sistema?
  bool _puntoIncluido(AuditSala sala, PuntoControlDef pd) => sala.puntosControl.any((p) =>
      !p.isDeleted && p.fromMaster && esMismoPunto(p, pd));

  // Marca/desmarca un punto del maestro a auditar. Desmarcar = soft-delete de todas sus muestras (un punto de nivel puede
  // tener varias: «+ Otro rack»); con más de una, se pregunta antes. El punto nuevo lleva la foto del maestro: nombre y
  // tipo y, en un centro activado, su equipo, su grupo y su ubicación (puntoDesdeMaestro).
  Future<void> _togglePunto(AuditSala sala, PuntoControlDef pd, bool include) async {
    if (include) {
      setState(() => incluirPunto(sala, pd, conEquipos: _conEquipos, nuevoId: () => const Uuid().v4()));
      _scheduleSave();
      return;
    }
    final n = muestrasDe(sala, pd).length;
    if (n > 1) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Quitar las muestras'),
          content: Text('«${pd.alias}» tiene $n muestras en esta evaluación. ¿Quitarlas todas?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Quitar las $n')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => quitarPunto(sala, pd));
    _scheduleSave();
  }

  // «+ Otro rack»: otra muestra del mismo punto de nivel, con los niveles de arriba como la última.
  void _otraMuestra(AuditSala sala, PuntoControlDef pd, NivelPunto ng) {
    final l = muestrasDe(sala, pd);
    setState(() => sala.puntosControl
        .add(otraMuestra(pd, ng, ultima: l.isEmpty ? null : l.last, conEquipos: _conEquipos, id: const Uuid().v4())));
    _scheduleSave();
  }

  // Quita una muestra de un punto de nivel (a la papelera, como desmarcar).
  void _quitarMuestra(PuntoControl p) {
    setState(() => p.isDeleted = true);
    _scheduleSave();
  }

  /// Anota la posición por nivel de una muestra. Si pone a un rack ya anotado en la evaluación en otra posición, pregunta
  /// si cambiarla en todas sus muestras (las que se pueden cambiar en la tablet); si no, no la cambia: un mismo rack
  /// tiene una sola posición en la visita.
  Future<void> _cambiarNiveles(PuntoControl p, NivelPunto ng, NivelesMuestra n) async {
    final a = _audit;
    if (a == null || _locked || !posicionEditable(p)) return;
    final normal = PosicionesNivel.normalizarNumeros(ng, n).niveles;
    final reuso = reusoDelDocumento(a.document, ng.grupoId, excepto: p);
    final choque = reuso.conflicto(ng.grupoId, normal, ng.nombres);
    if (choque != null) {
      final otros = [
        for (final s in a.document.salas.where((s) => !s.isDeleted))
          for (final x in s.puntosControl)
            if (!x.isDeleted && !identical(x, p) && x.tieneNiveles && (x.equipoId ?? '') == ng.grupoId &&
                ReusoNiveles.alinear(x.nivelesMuestra, normal) != x.nivelesMuestra)
              x,
      ];
      if (otros.any((x) => !posicionEditable(x))) {
        _avisar('$choque Las muestras que ya subieron se corrigen en la web.');
        setState(() {});
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('¿Cambiar en todas?'),
          content: Text('$choque ${otros.length == 1 ? 'Hay 1 muestra más' : 'Hay ${otros.length} muestras más'} '
              'de esta evaluación con ese miembro.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cambiar en todas')),
          ],
        ),
      );
      if (!mounted) return;
      if (ok != true) {
        setState(() {});
        return;
      }
      for (final x in otros) {
        anotarNiveles(x, ng, ReusoNiveles.alinear(x.nivelesMuestra, normal));
      }
    }
    final error = anotarNiveles(p, ng, n);
    if (error != null) {
      _avisar(error);
      if (mounted) setState(() {});
      return;
    }
    if (mounted) setState(() {});
    _scheduleSave();
  }

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(texto)));
  }

  // Agrega un punto adicional (no detectado) al sistema.
  void _addPuntoAdhoc(AuditSala sala) {
    setState(() => sala.puntosControl.add(PuntoControl(id: const Uuid().v4())));
    _scheduleSave();
  }

  // AuditSala del maestro que corresponde a un sistema del maestro por nombre (activa o en papelera).
  // Vínculo con el sistema del maestro: por Id (PK); para data anterior al Id, por nombre.
  AuditSala? _masterSalaFor(Sistema m) {
    if (m.id.isNotEmpty) {
      for (final s in _audit!.document.salas) {
        if (s.fromMaster && s.masterId == m.id) return s;
      }
    }
    for (final s in _audit!.document.salas) {
      if (s.fromMaster && (s.masterId == null || s.masterId!.isEmpty) &&
          s.name.trim().toLowerCase() == m.nombre.trim().toLowerCase()) return s;
    }
    return null;
  }

  // Marca/desmarca un sistema del maestro. Desmarcar hace soft-delete (conserva respuestas/puntos).
  void _toggleMaster(Sistema m, bool include) {
    final existing = _masterSalaFor(m);
    setState(() {
      if (include) {
        if (existing == null) {
          _addSalaFromMaster(m);
        } else {
          // Vuelve tal como estaba: su nombre y su foto son los de la evaluación (un sistema renombrado en la web no se
          // renombra solo por desmarcarlo y volver a marcarlo).
          existing.isDeleted = false;
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

  // Los sistemas ya NO se auto-seleccionan: el auditor elige cuáles sistemas y qué puntos auditar.
  void _ensureDefaultSistemas() {}

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

  // ── Llave con Bactiquant: el "Sample ID" del frasco es {folio}-{correlativo} ──
  // Ambos los imputa el auditor. Antes se numeraban solos 1..N y el folio lo daba el servidor al
  // sincronizar; en terreno sin señal eso dejaba a la auditoría sin ningún número que rotular.

  // Agendada → Borrador.
  Future<void> _startAudit() async {
    await _setStatus(AuditStatus.draft.value, 'Evaluación iniciada');
  }

  // El folio identifica la auditoría en el CSV. La unicidad entre equipos la arbitra el servidor
  // al sincronizar (dos tablets sin señal pueden elegir el mismo): si la rechaza, el aviso llega
  // en el push y el folio vuelve a quedar vacío.
  void _onFolioChanged(String texto) {
    final a = _audit;
    if (a == null) return;
    final v = texto.trim();
    a.folio = v.isEmpty ? null : int.tryParse(v);
    _scheduleSave();
  }

  // Correlativo del punto: único dentro de la auditoría, si no un mismo {folio}-{correlativo}
  // calzaría con dos puntos y el CSV no sabría a cuál aplicar.
  //
  // Lo escrito se guarda SIEMPRE y el duplicado se avisa marcando el campo. Rechazar la tecla
  // sería peor: al escribir "12" donde otro punto tiene el 1, la pulsación intermedia se vería
  // como repetida, y además el número quedaría en pantalla sin haberse guardado.
  void _onCorrelativoChanged(PuntoControl punto, String texto) {
    final v = texto.trim();
    punto.correlativo = v.isEmpty ? null : int.tryParse(v);
    setState(() {});
    _scheduleSave();
  }

  bool _correlativoDuplicado(PuntoControl punto) {
    final n = punto.correlativo;
    final a = _audit;
    if (n == null || a == null) return false;
    return a.document.salas
        .expand((s) => s.puntosControl)
        .any((o) => !identical(o, punto) && !o.isDeleted && o.correlativo == n);
  }

  /// Correlativos repetidos de toda la auditoría, para avisar antes de cerrarla.
  List<int> get _correlativosRepetidos {
    final a = _audit;
    if (a == null) return const [];
    final cuenta = <int, int>{};
    for (final s in a.document.salas.where((s) => !s.isDeleted)) {
      for (final p in s.puntosControl.where((p) => !p.isDeleted && p.correlativo != null)) {
        cuenta[p.correlativo!] = (cuenta[p.correlativo!] ?? 0) + 1;
      }
    }
    return (cuenta.entries.where((e) => e.value > 1).map((e) => e.key).toList()..sort());
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

  // ── Sistemas de la evaluación en el orden de la lista lateral del editor, con su tipo ──

  /// Los sistemas vigentes de la evaluación por tipo (Afluente → Tratamiento → Proceso → Tratamiento de Salmón →
  /// Efluente) y, dentro, como el maestro; los adicionales al final.
  List<AuditSala> _salasOrdenadas(Audit a) => ordenarSalas(a.document.salas.where((s) => !s.isDeleted).toList(), _masterSistemas);

  String? _claseSala(AuditSala s) => _conEquipos ? claseDeSala(s, _masterSistemas) : null;

  /// Las tarjetas de los sistemas con el encabezado de su tipo cuando cambia (solo en un centro con el modelo con equipos).
  List<Widget> _porClase(List<AuditSala> salas, Widget Function(AuditSala) tarjeta) {
    final l = <Widget>[];
    String? anterior = '';
    for (final s in salas) {
      final c = _claseSala(s);
      if (_conEquipos && c != anterior) {
        if (c != null) l.add(EncabezadoClase(clase: c, cantidad: salas.where((x) => _claseSala(x) == c).length));
        anterior = c;
      }
      l.add(tarjeta(s));
    }
    return l;
  }

  /// Los puntos vigentes de un sistema en el orden del agua (el del maestro).
  List<PuntoControl> _puntosOrdenados(AuditSala s) =>
      ordenarPuntos(s.puntosControl.where((p) => !p.isDeleted).toList(), sistemaDelMaestro(s, _masterSistemas));

  /// El punto de nivel del maestro de una muestra (null si no es de nivel o el maestro no lo trae).
  NivelPunto? _nivelDe(AuditSala s, PuntoControl p) => defDelPunto(p, sistemaDelMaestro(s, _masterSistemas))?.nivelPunto;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_audit == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('No se encontró la evaluación.')));
    }
    if (_tpl == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Evaluación')),
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
            _gatedTab(Icons.fact_check_outlined, 'Evaluación RPN', a.centerId != null),
            _gatedTab(Icons.science_outlined, 'Muestreo', a.centerId != null),
          ],
        ),
      ),
      body: Column(
        children: [
          if (!_locked) _topActions(a),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('gen-$_gen'),
              child: TabBarView(
                controller: _tab,
                children: [_identificacionTab(a), _sistemasTab(a), _entrevistaTab(a), _rpnTab(a), _muestreoTab(a)],
              ),
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
          if (a.statusEnum == AuditStatus.scheduled)
            OutlinedButton.icon(
                onPressed: _startAudit,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Iniciar'))
          // Compartida con el cliente: se edita aquí, pero se finaliza en la web (el cliente ya la ve).
          else if (a.statusEnum == AuditStatus.draft && a.compartida)
            const Expanded(
              child: Row(children: [
                Icon(Icons.public, size: 18, color: Color(0xFF475569)),
                SizedBox(width: 6),
                Expanded(
                  child: Text('Compartida con el cliente: se finaliza en la web',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF475569))),
                ),
              ]),
            )
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
                title: Text('Evaluación finalizada'),
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
    final d = a.document;
    final activas = d.salas.where((s) => !s.isDeleted).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_locked)
          const Card(
            color: Color(0xFFEFF3F6),
            child: ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Evaluación finalizada'),
              subtitle: Text('Los datos quedan fijos (solo lectura).'),
            ),
          ),
        _seccionAplicada('la entrevista', d.aplicaEntrevista, (v) => _aplicarSeccion((x) => d.entrevistaDesactivada = x, v)),
        if (d.aplicaEntrevista) ...[
          for (final sec in _centerSections) _sectionCard(sec, d.center),
          const SizedBox(height: 8),
          if (activas.isEmpty) _infoCard('Define los sistemas a evaluar en la pestaña Sistemas.'),
          ..._porClase(_salasOrdenadas(a), _salaCard),
        ],
        const SizedBox(height: 40),
      ],
    );
  }

  // ── Las partes de la visita (como la web): «Se aplica … en esta evaluación». La visita nace con nada activo y el
  // evaluador marca lo que hace. Apagada, esa parte no se hizo y el informe sale sin ella. ──
  Widget _seccionAplicada(String que, bool aplica, ValueChanged<bool> cambiar) {
    const naranjo = Color(0xFFC2410C);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: aplica ? const Color(0xFFF6F8FB) : const Color(0xFFFBEDE7),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: aplica ? const Color(0xFFE1E6F0) : naranjo.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
        child: SwitchListTile(
          value: aplica,
          onChanged: _locked ? null : cambiar,
          contentPadding: const EdgeInsets.only(left: 8),
          title: Text('Se aplica $que en esta evaluación',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ),
      ),
    );
  }

  void _aplicarSeccion(void Function(bool desactivada) marcar, bool aplica) {
    setState(() => marcar(!aplica));
    _scheduleSave();
  }

  Widget _infoCard(String texto) => Card(
        color: const Color(0xFFEFF6FF),
        child: ListTile(
          leading: const Icon(Icons.info_outline, color: Color(0xFF2D58FF)),
          title: Text(texto, style: const TextStyle(fontSize: 14)),
        ),
      );

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
                  const Text('Sistemas evaluados',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (activos.isEmpty)
                    const Text('Sin sistemas.', style: TextStyle(color: Colors.grey))
                  else
                    for (final s in _salasOrdenadas(a)) _sistemaReadonlyRow(s),
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
    final eliminados = _salasEliminadas(a);
    // Marcados que el maestro ya no trae (en un centro activado no llega lo retirado). Solo con el
    // centro en caché: sin maestro no se sabe qué quedó fuera.
    final fuera = _center == null ? <AuditSala>[] : sistemasFueraDelMaestro(a.document.salas, master);

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('Sistemas a evaluar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
        if (fuera.isNotEmpty) _fueraDelMaestroCard(fuera),
        // Sistemas ad-hoc.
        _adhocSistemasCard(adhoc),
        if (activos.isEmpty)
          const Card(
            color: Color(0xFFEFF6FF),
            child: ListTile(
              leading: Icon(Icons.info_outline, color: Color(0xFF2D58FF)),
              title: Text('Aún no hay sistemas seleccionados para esta evaluación.'),
            ),
          ),
        // Papelera de sistemas ad-hoc eliminados.
        if (eliminados.isNotEmpty) _deletedSalas(a),
        const SizedBox(height: 40),
      ],
    );
  }

  // La papelera de sistemas: los ad hoc y los del maestro que el maestro ya no trae (para estos
  // no hay casilla donde volver a marcarlos).
  List<AuditSala> _salasEliminadas(Audit a) => [
        ...a.document.salas.where((s) => s.isDeleted && !s.fromMaster),
        if (_center != null) ...sistemasFueraDelMaestro(a.document.salas, _masterSistemas, eliminados: true),
      ];

  // Bloque «Fuera del maestro»: sistemas marcados que el centro ya no ofrece (se retiraron o son del
  // modelo anterior). Se ven con sus puntos y se pueden quitar; no se pueden volver a marcar.
  Widget _fueraDelMaestroCard(List<AuditSala> fuera) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        color: const Color(0xFFFFF7E6),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Text('Fuera del maestro', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(width: 8),
                _badge('retirados', const Color(0xFF566873)),
              ]),
              const SizedBox(height: 6),
              for (final s in fuera)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    const Icon(Icons.warehouse_outlined, size: 20, color: Color(0xFFB7791F)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(s.name.isEmpty ? 'Sistema' : s.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    _tipoChip(tipoUnidad(s)),
                    const SizedBox(width: 6),
                    _badge('${s.puntosControl.where((p) => !p.isDeleted).length} pts', const Color(0xFF566873)),
                    if (!_locked)
                      IconButton(
                        tooltip: 'Quitar de la evaluación',
                        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                        onPressed: () => _removeSala(s),
                      ),
                  ]),
                ),
            ],
          ),
        ),
      );

  // Fila de solo lectura de un sistema auditado (past-proof / bloqueada).
  Widget _sistemaReadonlyRow(AuditSala s) {
    final clase = _claseSala(s);
    final ficha = fichaSala(s, _masterSistemas, conEquipos: _conEquipos);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(estiloDe(clase).icono, size: 20, color: estiloDe(clase).tinta),
          const SizedBox(width: 8),
          Flexible(
            child: Text(s.name.isEmpty ? 'Sistema' : s.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (ficha != null) ...[const SizedBox(width: 8), FichaClase(texto: ficha, clase: clase)],
          const SizedBox(width: 6),
          if (s.fromMaster)
            const Tooltip(message: 'Sistema del maestro', child: Icon(Icons.lock, size: 16, color: Colors.grey))
          else
            _badge('adicional', const Color(0xFF566873)),
        ]),
      );
  }

  // Chip del tipo (o "Sin Tipo").
  Widget _tipoChip(String? tipo) {
    final hasTipo = tipo != null && tipo.isNotEmpty;
    final c = hasTipo ? const Color(0xFF2D58FF) : const Color(0xFF566873);
    return _badge(hasTipo ? tipo : 'Sin Tipo', c);
  }

  // Bloque «Sistemas del centro» (maestro): agrupados por su tipo y en el orden de la lista lateral del editor de
  // modelos, cada uno con la franja y el ícono de su tipo y su etapa (o el tipo de su agua) como ficha.
  Widget _masterSistemasCard(List<Sistema> master) {
    final grupos = _conEquipos ? sistemasPorClase(master) : [(clase: kClaseCultivo, sistemas: master)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 2),
        child: Text('Sistemas del centro', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ),
      for (final g in grupos) ...[
        if (_conEquipos) EncabezadoClase(clase: g.clase, cantidad: g.sistemas.length),
        for (final m in g.sistemas) _masterSistemaRow(m),
      ],
      const SizedBox(height: 8),
    ]);
  }

  Widget _masterSistemaRow(Sistema m) {
    final current = _masterSalaFor(m);
    final included = current != null && !current.isDeleted;
    final clase = _conEquipos ? claseDe(m.clase) : null;
    final estilo = estiloDe(clase);
    final ficha = fichaSistema(m, conEquipos: _conEquipos);
    // Puntos marcados que el maestro ya no trae: se listan aparte para poder quitarlos.
    final fueraPts = current == null || current.isDeleted ? <PuntoControl>[] : puntosFueraDelMaestro(current, m.puntosControl);
    // Cuántos puntos del maestro están marcados (un punto con varias muestras cuenta una vez).
    final sel = current == null || current.isDeleted
        ? 0
        : m.puntosControl.where((pd) => _puntoIncluido(current, pd)).length + fueraPts.length;
    return ConFranja(
      clase: clase,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 10, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Checkbox(
              value: included,
              onChanged: _locked ? null : (v) => _toggleMaster(m, v ?? false),
            ),
            Icon(estilo.icono, size: 20, color: included ? estilo.tinta : const Color(0xFF8A93A2)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(m.nombre,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: included ? FontWeight.w700 : FontWeight.w500,
                      color: included ? null : const Color(0xFF5A6474))),
            ),
            if (ficha != null) ...[const SizedBox(width: 6), FichaClase(texto: ficha, clase: clase)],
            const SizedBox(width: 6),
            _badge('$sel/${m.puntosControl.length + fueraPts.length}',
                included && sel > 0 ? const Color(0xFF2D58FF) : const Color(0xFF566873)),
          ]),
          if (included)
            Padding(
              padding: const EdgeInsets.only(left: 12, bottom: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ..._puntosMaestro(current, m.puntosControl),
                if (fueraPts.isNotEmpty) ...[
                  _grupoTitulo('Fuera del modelo actual'),
                  for (final p in fueraPts) _fueraPuntoRow(p),
                ],
                for (final p in current.puntosControl.where((p) => !p.isDeleted && !p.fromMaster)) _adhocPuntoRow(current, p),
                if (!_locked)
                  TextButton.icon(
                    onPressed: () => _addPuntoAdhoc(current),
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('Agregar punto adicional'),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }

  // Los puntos del maestro de un sistema para marcar. En el modelo plano, la lista tal cual (como
  // siempre). En un centro activado, agrupados como se recorre el agua: afluentes, cada equipo con
  // sus entradas, interiores y salidas, los tramos PRE/POST y el efluente, con su nombre automático.
  List<Widget> _puntosMaestro(AuditSala sala, List<PuntoControlDef> puntos) {
    final secciones = agruparPuntos(puntos);
    return [
      for (final sec in secciones) ...[
        if (sec.grupo != null) _grupoTitulo(sec.titulo),
        for (final b in sec.bloques) ...[
          if (b.titulo != null) _equipoTitulo(b),
          for (final pd in b.puntos)
            Padding(
              padding: EdgeInsets.only(left: b.titulo != null ? 12 : 0),
              child: _masterPuntoRow(sala, pd),
            ),
        ],
      ],
    ];
  }

  Widget _grupoTitulo(String titulo) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(titulo.toUpperCase(),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: Color(0xFF475569))),
      );

  // Título de un equipo dentro de «Equipos»: su alias y, si no lo dice ya, su tipo estándar.
  Widget _equipoTitulo(BloquePuntos b) {
    final tipo = b.equipoTipo?.trim() ?? '';
    final mostrarTipo = tipo.isNotEmpty && !(b.titulo ?? '').toLowerCase().contains(tipo.toLowerCase());
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Row(children: [
        const Icon(Icons.settings_input_component_outlined, size: 16, color: Color(0xFF475569)),
        const SizedBox(width: 6),
        Flexible(child: Text(b.titulo ?? 'Equipo', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
        if (mostrarTipo) ...[const SizedBox(width: 6), _badge(tipo, const Color(0xFF566873))],
      ]),
    );
  }

  // El nombre de un punto y, debajo y chico, su tipo (la regla vigente: «POST Manifold» con «Estanque Cabecera» debajo).
  Widget _nombreConTipo(String nombre, String? tipo, {bool activo = true, double tamano = 14, FontWeight peso = FontWeight.w600}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(nombre, style: TextStyle(fontSize: tamano, fontWeight: peso, color: activo ? null : const Color(0xFF5A6474))),
        if (tipo != null) Text(tipo, style: const TextStyle(fontSize: 12.5, color: Color(0xFF5A6474))),
      ]);

  Widget _masterPuntoRow(AuditSala sala, PuntoControlDef pd) {
    final chk = _puntoIncluido(sala, pd);
    final equipo = equipoAMostrar(pd);
    final ng = pd.nivelPunto;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Checkbox(
          value: chk,
          onChanged: _locked ? null : (v) => _togglePunto(sala, pd, v ?? false),
        ),
        Expanded(child: _nombreConTipo(pd.alias, tipoDebajoDef(pd), activo: chk)),
        // En un tramo, el equipo por el que se nombra si el nombre no lo dice («POST UV» · «UV 2»).
        if (equipo != null) ...[const SizedBox(width: 4), _badge(equipo, const Color(0xFF566873))],
      ]),
      if (ng != null && chk) _muestrasDeNivel(sala, pd, ng),
    ]);
  }

  // Un punto de nivel de un grupo efímero: una fila por muestra de esta visita (cada una es un punto de la evaluación con
  // su frasco, su evaluación y su posición por nivel) y «+ Otro rack».
  Widget _muestrasDeNivel(AuditSala sala, PuntoControlDef pd, NivelPunto ng) {
    final l = muestrasDe(sala, pd);
    final nombreNivel = ng.nombreNivel(ng.nivel);
    return Padding(
      padding: const EdgeInsets.only(left: 40, bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final p in l) _muestraNivel(p, ng, quitar: l.length > 1),
        if (!_locked)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _otraMuestra(sala, pd, ng),
              icon: const Icon(Icons.add, size: 20),
              label: Text('${femenino(nombreNivel) ? 'Otra' : 'Otro'} ${nombreNivel.toLowerCase()}'),
            ),
          ),
      ]),
    );
  }

  // Una muestra de un punto de nivel: su frasco y su posición. La que ya subió se ve, pero se corrige en la web.
  Widget _muestraNivel(PuntoControl p, NivelPunto ng, {required bool quitar}) {
    final editable = !_locked && posicionEditable(p);
    return Container(
      key: ValueKey('muestra-${p.id}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F9FC),
        border: Border.all(color: const Color(0xFFDDE3EE)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('Frasco ${p.correlativo != null ? 'N° ${p.correlativo}' : '—'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF475569))),
          const Spacer(),
          if (!_locked && quitar)
            IconButton(
              tooltip: 'Quitar esta muestra',
              icon: const Icon(Icons.close, color: Colors.red),
              onPressed: () => _quitarMuestra(p),
            ),
        ]),
        if (editable)
          NivelesMuestraEditor(
            key: ValueKey('niveles-${p.id}'),
            punto: ng,
            value: p.nivelesMuestra,
            reuso: _audit == null ? null : reusoDelDocumento(_audit!.document, ng.grupoId, excepto: p),
            onChanged: (n) => _cambiarNiveles(p, ng, n),
          )
        else
          _posicionSoloLectura(p),
      ]),
    );
  }

  Widget _posicionSoloLectura(PuntoControl p) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(etiquetaNiveles(p) ?? 'Sin posición', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        if (!_locked) const Text('Se corrige en la web', style: TextStyle(fontSize: 12.5, color: Color(0xFF5A6474))),
      ]);

  // Un punto marcado que el maestro ya no trae (retirado o del modelo anterior): se ve marcado y se
  // puede desmarcar (queda en la papelera, como al desmarcar cualquier punto del maestro).
  Widget _fueraPuntoRow(PuntoControl p) => Row(children: [
        SizedBox(
          width: 34, height: 34,
          child: Checkbox(
            value: true,
            visualDensity: VisualDensity.compact,
            onChanged: _locked
                ? null
                : (v) {
                    if (v == false) {
                      setState(() => p.isDeleted = true);
                      _scheduleSave();
                    }
                  },
          ),
        ),
        Expanded(child: Text(p.nombre, style: const TextStyle(fontSize: 13))),
        if (p.tipo != null && p.tipo!.isNotEmpty) ...[_badge(p.tipo!, const Color(0xFF2D58FF)), const SizedBox(width: 4)],
        _badge('fuera del modelo', const Color(0xFF566873)),
      ]);

  Widget _adhocPuntoRow(AuditSala sala, PuntoControl p) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          const Icon(Icons.add_circle_outline, size: 16, color: Color(0xFF556173)),
          const SizedBox(width: 6),
          Expanded(
            child: TextFormField(
              key: ValueKey('adh-${p.id}'),
              initialValue: p.nombre,
              readOnly: _locked,
              style: const TextStyle(fontSize: 13),
              decoration: _dec().copyWith(hintText: 'Alias del punto adicional', isDense: true),
              onChanged: (v) { p.nombre = v; _scheduleSave(); },
            ),
          ),
          if (!_locked)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
              onPressed: () { setState(() => sala.puntosControl.remove(p)); _scheduleSave(); },
            ),
        ]),
      );

  // Bloque "Sistemas adicionales" (ad-hoc): agregar + lista editable + papelera.
  Widget _adhocSistemasCard(List<AuditSala> adhoc) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text('Sistemas adicionales', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
                      for (final t in _sistemaTipos) DropdownMenuItem<String?>(value: t, child: Text(t)),
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
              value: _sistemaTipos.contains(sala.tipo) ? sala.tipo : null,
              isExpanded: true,
              decoration: _dec(),
              onChanged: (v) { setState(() => sala.tipo = v); _scheduleSave(); },
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Sin Tipo')),
                for (final t in _sistemaTipos) DropdownMenuItem<String?>(value: t, child: Text(t)),
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
    final d = a.document;
    final sistemas = _salasOrdenadas(a);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _seccionAplicada('la evaluación de terreno (RPN)', d.aplicaRpn, (v) => _aplicarSeccion((x) => d.rpnDesactivado = x, v)),
        if (d.aplicaRpn) ...[
          if (sistemas.isEmpty) _infoCard('Marca los sistemas y sus puntos en la pestaña Sistemas.'),
          ..._porClase(sistemas, _sistemaRpnCard),
        ],
        const SizedBox(height: 40),
      ],
    );
  }

  // ── Pestaña 5: MUESTREO (laboratorio BQ/FC): el frasco de cada punto ({folio}-{N°}) y, si se mide en terreno con la
  // maleta, su resultado. ──
  Widget _muestreoTab(Audit a) {
    if (a.centerId == null) return _needCenterNotice();
    final d = a.document;
    final sistemas = _salasOrdenadas(a);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _seccionAplicada('el laboratorio (BQ/FC)', d.aplicaLab, (v) => _aplicarSeccion((x) => d.labDesactivado = x, v)),
        if (d.aplicaLab) ...[
          _rotuloCard(a),
          if (sistemas.isEmpty) _infoCard('Marca los sistemas y sus puntos en la pestaña Sistemas.'),
          ..._porClase(sistemas, _sistemaMuestreoCard),
        ],
        const SizedBox(height: 40),
      ],
    );
  }

  Widget _rotuloCard(Audit a) {
    final folio = a.folio;
    return Card(
      color: folio == null ? const Color(0xFFFFF7E6) : const Color(0xFFEFF6FF),
      child: ListTile(
        leading: Icon(Icons.science_outlined, color: folio == null ? const Color(0xFFB7791F) : const Color(0xFF2D58FF)),
        title: Text(folio == null
            ? 'Escribe el folio en Identificación antes de rotular los frascos.'
            : 'Folio $folio · cada frasco se rotula «$folio-N°»'),
      ),
    );
  }

  Widget _sistemaMuestreoCard(AuditSala sistema) {
    final puntos = _puntosOrdenados(sistema);
    return ConFranja(
      clase: _claseSala(sistema),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _sistemaTitle(sistema),
          const SizedBox(height: 4),
          if (puntos.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('Sin puntos marcados.', style: TextStyle(color: Color(0xFF5A6474))),
            ),
          for (final p in puntos) _puntoMuestreoRow(sistema, p),
        ]),
      ),
    );
  }

  Widget _puntoMuestreoRow(AuditSala sala, PuntoControl p) {
    final ng = _nivelDe(sala, p);
    return Container(
        key: ValueKey('mu-${p.id}'),
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE1E6F0)),
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xFFFCFDFF),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _correlativoCampo(p, 'mc'),
            Expanded(child: _nombreConTipo(nombrePunto(p, conPosicion: ng == null), tipoDebajoPunto(p), tamano: 14)),
          ]),
          // Un punto de nivel: su posición, aquí mismo (es donde se rotula el frasco).
          if (ng != null) ...[
            const SizedBox(height: 8),
            if (!_locked && posicionEditable(p))
              NivelesMuestraEditor(
                key: ValueKey('mu-niveles-${p.id}'),
                punto: ng,
                value: p.nivelesMuestra,
                reuso: _audit == null ? null : reusoDelDocumento(_audit!.document, ng.grupoId, excepto: p),
                onChanged: (n) => _cambiarNiveles(p, ng, n),
              )
            else
              _posicionSoloLectura(p),
          ],
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: _labCampo(p, hongos: false)),
            const SizedBox(width: 8),
            Expanded(child: _labCampo(p, hongos: true)),
          ]),
        ]),
      );
  }

  // El N° del frasco (correlativo): campo editable o, cerrada, el número. Repetido en la evaluación = marcado.
  Widget _correlativoCampo(PuntoControl p, String prefijo) {
    if (_locked) {
      if (p.correlativo == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFF2D58FF), borderRadius: BorderRadius.circular(6)),
          child: Text('${p.correlativo}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: 64,
        child: TextFormField(
          key: ValueKey('$prefijo-${p.id}'),
          initialValue: p.correlativo?.toString(),
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          decoration: _dec().copyWith(
            hintText: 'N°',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            errorText: _correlativoDuplicado(p) ? '' : null,
            errorStyle: const TextStyle(height: 0, fontSize: 0),
          ),
          onChanged: (v) => _onCorrelativoChanged(p, v),
        ),
      ),
    );
  }

  // BQ o FC del punto. Se escribe mientras el servidor no tenga ese resultado (vacío, o escrito en esta tablet y sin
  // volver todavía): uno que el servidor ya tiene lo manda la web y se muestra sin editar.
  Widget _labCampo(PuntoControl p, {required bool hongos}) {
    final sigla = hongos ? 'FC' : 'BQ';
    final slot = hongos ? 'fc' : 'bq';
    final res = hongos ? p.bactiHongos : p.bacti;
    final valor = hongos ? p.fc : p.bq;
    final editable = !_locked && (res == null || p.labLocal.contains(slot));
    if (!editable) {
      return InputDecorator(
        decoration: _dec().copyWith(
          labelText: '$sigla value',
          helperText: res == null ? null : _origenLab(res),
        ),
        child: Text(valor == null ? '—' : formatoNumero(valor), style: const TextStyle(fontWeight: FontWeight.w700)),
      );
    }
    return TextFormField(
      key: ValueKey('lab-$slot-${p.id}'),
      initialValue: valor == null ? null : formatoNumero(valor),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _dec().copyWith(
        labelText: '$sigla value',
        hintText: 'ej. 1.234,5',
        helperText: valor == null ? null : '= ${formatoNumero(valor)} · a mano',
      ),
      onChanged: (t) => _setLab(p, hongos, t),
    );
  }

  String _origenLab(Map<String, dynamic> res) => switch (res['fuente']) {
        'csv' => 'importado del CSV',
        'app' => 'calculado con las lecturas',
        'manual' => 'ingresado a mano',
        _ => 'cargado en la web',
      };

  void _setLab(PuntoControl p, bool hongos, String texto) {
    final slot = hongos ? 'fc' : 'bq';
    final anterior = hongos ? p.bactiHongos : p.bacti;
    final v = leerNumero(texto);
    setState(() {
      if (v == null) {
        // Vaciar (o algo que no es número): solo se quita lo que se escribió aquí.
        if (texto.trim().isEmpty && anterior != null && p.labLocal.contains(slot)) {
          if (hongos) {
            p.bactiHongos = null;
          } else {
            p.bacti = null;
          }
          p.labLocal.remove(slot);
        }
      } else {
        final r = resultadoManual(v, hongos: hongos, anterior: anterior);
        if (hongos) {
          p.bactiHongos = r;
        } else {
          p.bacti = r;
        }
        p.labLocal.add(slot);
      }
    });
    _scheduleSave();
  }

  // Título de un sistema (nombre + chip de tipo + candado si viene del maestro). El chip es la etapa
  // con su etiqueta si la auditoría la guardó (centro activado); si no, el tipo de siempre.
  Widget _sistemaTitle(AuditSala sistema) {
    final clase = _claseSala(sistema);
    final estilo = estiloDe(clase);
    final ficha = fichaSala(sistema, _masterSistemas, conEquipos: _conEquipos);
    return Row(children: [
      Icon(estilo.icono, size: 20, color: estilo.tinta),
      const SizedBox(width: 6),
      Flexible(
        child: Text(sistema.name.isEmpty ? 'Sistema' : sistema.name,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
      ),
      if (ficha != null && ficha.isNotEmpty) ...[
        const SizedBox(width: 8),
        FichaClase(texto: ficha, clase: clase),
      ],
      if (sistema.fromMaster) ...[
        const SizedBox(width: 6),
        const Tooltip(message: 'Sistema del maestro', child: Icon(Icons.lock, size: 16, color: Colors.grey)),
      ],
    ]);
  }

  Widget _sistemaRpnCard(AuditSala sistema) {
    final puntos = _puntosOrdenados(sistema);
    return ConFranja(
      clase: _claseSala(sistema),
      margin: const EdgeInsets.only(bottom: 12),
      child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: true,
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
            Row(children: [
              // El N° del frasco, solo si la visita lleva laboratorio (se rotula {folio}-{N°}).
              if (_audit?.document.aplicaLab ?? true) _correlativoCampo(p, 'pc'),
              // Un punto del maestro se nombra como en la web («POST UV · UV 2», «… — Rack 17 (final)») con su tipo
              // debajo; uno adicional se escribe aquí.
              Expanded(
                child: p.fromMaster || _locked
                    ? _nombreConTipo(nombrePunto(p), tipoDebajoPunto(p), tamano: 14.5, peso: FontWeight.w700)
                    : TextFormField(
                        key: ValueKey('pn-${p.id}'),
                        initialValue: p.nombre,
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
                value: _puntoTipos.contains(p.tipo) ? p.tipo : null,
                isExpanded: true,
                decoration: _dec().copyWith(labelText: 'Tipo'),
                onChanged: (v) { setState(() => p.tipo = v); _scheduleSave(); },
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Sin Tipo')),
                  for (final t in _puntoTipos) DropdownMenuItem<String?>(value: t, child: Text(t)),
                ],
              ),
            ],
            const SizedBox(height: 6),
            _evalBlock(p),
            const SizedBox(height: 6),
            TextFormField(
              key: ValueKey('pcom-${p.id}'),
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
            OutlinedButton.icon(
                onPressed: _recPunto == null ? () => _startRec(p) : null,
                icon: const Icon(Icons.mic, size: 18),
                label: const Text('Audio')),
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
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _removeAudio(p, ev)),
      ]),
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
        content: Text('¿Enviar $tipo a la papelera del punto? Podrás restaurarla hasta que finalices la evaluación.'),
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
    final a = _audit;
    if (a == null || a.compartida) return;
    final d = a.document;
    // La regla de la web (y del servidor al finalizar allá): sin RPN ni laboratorio no hay nada que informar.
    final nada = validarSecciones(d);
    if (nada != null) {
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.rule_folder_outlined, color: Colors.orange),
          title: const Text('Todavía no se puede finalizar'),
          content: Text(nada),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Entendido'))],
        ),
      );
      return;
    }
    // Los avisos van ANTES de cerrar: después queda inmutable y ya no se puede arreglar el
    // rotulado. Sin folio o con correlativos repetidos, el CSV del Bactiquant no va a calzar.
    final puntos = [
      for (final s in d.salas.where((s) => !s.isDeleted)) ...s.puntosControl.where((p) => !p.isDeleted),
    ];
    final repetidos = d.aplicaLab ? _correlativosRepetidos : const <int>[];
    final sinFolio = d.aplicaLab && a.folio == null;
    final sinFrasco = d.aplicaLab ? puntos.where((p) => p.correlativo == null).length : 0;
    final sinEvaluar = d.aplicaRpn
        ? puntos
            .where((p) =>
                p.estadoOperacional == null || p.limpiezaBiofilm == null || p.impactoPeces == null || p.detectabilidad == null)
            .length
        : 0;
    final sinPos = sinPosicion(d, _masterSistemas);
    final pendientes = [
      if (puntos.isEmpty) 'La evaluación no tiene puntos de control marcados.',
      if (sinFolio) 'La evaluación no tiene folio: el CSV de Bactiquant no podrá asociarse.',
      if (repetidos.isNotEmpty)
        'Hay correlativos repetidos (${repetidos.join(', ')}): el resultado no sabría a qué punto aplicarse.',
      if (sinFrasco > 0) '$sinFrasco punto(s) sin N° de frasco: su resultado no se podrá asociar.',
      if (sinEvaluar > 0) '$sinEvaluar punto(s) sin evaluar completo (O, L, I, D).',
      if (sinPos.isNotEmpty)
        '${sinPos.length} muestra(s) sin la posición de cada nivel: '
            '${sinPos.take(4).map((x) => nombrePunto(x.punto)).join(', ')}${sinPos.length > 4 ? '…' : ''}. Se puede completar en la web.',
      if (!d.aplicaEntrevista) 'La entrevista queda como no aplicada.',
      if (!d.aplicaRpn) 'La evaluación de terreno (RPN) queda como no aplicada.',
      if (!d.aplicaLab) 'El laboratorio (BQ/FC) queda como no aplicado.',
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(Icons.check_circle, color: pendientes.isEmpty ? Colors.green : Colors.orange),
        title: const Text('Finalizar evaluación'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final aviso in pendientes) ...[
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.warning_amber, color: Colors.orange, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(aviso, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 10),
            ],
            const Text(
                'Una vez finalizada, la evaluación queda INMUTABLE: no podrás editar ningún dato. ¿Confirmas que está completa?'),
          ]),
        ),
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
      await _purgePapelera();
      await _setStatus(AuditStatus.submitted.value, 'Evaluación finalizada');
    }
  }

  // Vacía la papelera de evidencias (isDeleted): las quita del documento y borra el archivo local. El del servidor se
  // borra después de que la evaluación suba sin ellas (AuditSyncService): si mientras tanto la oficina restauró alguna,
  // la mezcla la conserva y el servidor no borra una evidencia que siga viva.
  Future<void> _purgePapelera() async {
    final a = _audit;
    if (a == null) return;
    final db = context.read<AppDatabase>();
    final ids = <String>[];
    for (final s in a.document.salas) {
      for (final pc in s.puntosControl) {
        for (final ev in [...pc.fotos.where((f) => f.isDeleted), ...pc.audios.where((x) => x.isDeleted)]) {
          await _media.removeLocal(ev.id);
          ids.add(ev.id);
        }
        pc.fotos.removeWhere((f) => f.isDeleted);
        pc.audios.removeWhere((x) => x.isDeleted);
      }
    }
    if (ids.isNotEmpty) await db.encolarBorrado(a.id, ids);
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
              Flexible(child: _badge('IDENTIFICACIÓN', idc)),
              const Spacer(),
              if (_locked) ...[
                  if (a.folio != null) _badge('Folio ${a.folio}', const Color(0xFF2D58FF)),
                ] else ...[
                  SizedBox(
                    width: 108,
                    child: TextFormField(
                      key: ValueKey('folio-${a.id}'),
                      initialValue: a.folio?.toString(),
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                      decoration: _dec().copyWith(
                        labelText: 'Folio',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      onChanged: _onFolioChanged,
                    ),
                  ),
                ],
            ]),
            children: [
            // Tipo de auditoría
            _labeled(null, 'Tipo de evaluación',
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
            _labeled('ID-04', 'Evaluador',
                DropdownButtonFormField<String?>(
                  value: auditorVal,
                  isExpanded: true,
                  decoration: _dec(),
                  onChanged: _locked ? null : _pickAuditor,
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('— Sin evaluador —')),
                    for (final u in _users) DropdownMenuItem<String?>(value: u.display, child: Text(u.display)),
                  ],
                )),
            // Fecha
            _labeled('ID-03', 'Fecha de evaluación',
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
    final deleted = _salasEliminadas(a);
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
