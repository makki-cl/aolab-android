// Lo que necesitan las pruebas de pantalla: una base en memoria (sin SQLite), evidencias sin cámara ni micrófono, y la
// app montada con sus servicios contra el servidor falso.
import 'dart:convert';
import 'dart:io';

import 'package:aolab_android/data/app_database.dart';
import 'package:aolab_android/data/reglas_sync.dart';
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/questionnaire.dart';
import 'package:aolab_android/services/api_client.dart';
import 'package:aolab_android/services/audit_sync_service.dart';
import 'package:aolab_android/services/auth_service.dart';
import 'package:aolab_android/services/master_sync_service.dart';
import 'package:aolab_android/services/media_service.dart';
import 'package:aolab_android/services/template_service.dart';
import 'package:aolab_android/ui/tema.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'servidor_falso.dart';

class BaseEnMemoria extends AppDatabase {
  final Map<String, Audit> audits = {};
  final Map<String, String> kv = {};
  final List<CenterRef> centros;
  int guardados = 0;
  BaseEnMemoria(this.centros);

  Audit _copia(Audit a) => Audit.fromRow(a.toRow());

  @override
  Future<Audit?> findById(String id) async => audits[id] == null ? null : _copia(audits[id]!);
  @override
  Future<List<Audit>> visibleAudits() async {
    final l = audits.values.where((a) => !a.isDeleted).map(_copia).toList();
    l.sort((a, b) => b.updatedAtUtc.compareTo(a.updatedAtUtc));
    return l;
  }

  @override
  Future<List<ClientRef>> activeClients() async => [];
  @override
  Future<List<CenterRef>> activeCenters() async => centros;
  @override
  Future<List<UserRef>> allUsers() async => [];
  @override
  Future<Map<String, List<String>>> getCatalogs() async => {};
  @override
  Future<String?> getValue(String key) async => kv[key];
  @override
  Future<void> setValue(String key, String value) async => kv[key] = value;
  @override
  Future<List<String>> getAvisos() async => [];
  @override
  Future<void> setAvisos(List<String> avisos) async {}

  @override
  Future<void> upsertLocal(Audit a, {bool markDirty = true}) async {
    if (markDirty) a.dirty = true;
    final fila = audits[a.id];
    if (fila != null) conservarSubidas(a.document, fila.document);
    a.localRev = (fila?.localRev ?? 0) + 1;
    audits[a.id] = _copia(a);
    guardados++;
  }

  @override
  Future<void> softDelete(String id) async {
    final a = audits[id];
    if (a == null) return;
    a.isDeleted = true;
    a.dirty = true;
    a.localRev++;
  }

  @override
  Future<void> marcarEvidenciasSubidas(String auditId, Set<String> ids) async {
    final a = audits[auditId];
    if (a == null || ids.isEmpty) return;
    if (marcarSubidas(a.document, ids) > 0) a.dirty = true;
  }

  @override
  Future<int> pendientesDeSubir() async => audits.values
      .where((a) => a.dirty || evidenciasDe(a.document).any((e) => !e.uploaded && !e.isDeleted))
      .length;
}

/// Evidencias sin cámara ni micrófono: la «cámara» devuelve un archivo de prueba, el micrófono graba al tiro y lo que
/// Android haya dejado perdido se configura.
class EvidenciasFalsas extends MediaService {
  final Directory dir;
  bool grabandoAhora = false;
  String? perdida;
  int fotosTomadas = 0;

  EvidenciasFalsas(ApiClient api, Directory dir) : dir = dir, super(api: api, carpeta: dir.path) {
    pausaEntreIntentos = Duration.zero;
  }

  factory EvidenciasFalsas.nueva(ApiClient api) => EvidenciasFalsas(api, Directory.systemTemp.createTempSync('evidencias'));

  /// Un archivo cualquiera que hace de foto.
  String archivoDePrueba() {
    final f = File('${dir.path}/origen-${DateTime.now().microsecondsSinceEpoch}.jpg')..writeAsBytesSync([1, 2, 3]);
    return f.path;
  }

  // Sin entrada/salida real: en una prueba de pantalla (reloj falso) un archivo que se copia de verdad no termina.
  @override
  Future<Evidencia?> capturePhoto({required ImageSource source}) async {
    fotosTomadas++;
    final ev = Evidencia(id: 'foto-${DateTime.now().microsecondsSinceEpoch}', contentType: 'image/jpeg', uploaded: false);
    fileFor(ev.id).writeAsBytesSync([1, 2, 3]);
    return ev;
  }

  @override
  Future<String?> fotoPerdida() async => perdida;

  @override
  Future<bool> startRecording({required void Function(double level) onLevel}) async => grabandoAhora = true;

  @override
  Future<({Evidencia? ev, bool silent})> stopRecording() async {
    if (!grabandoAhora) return (ev: null, silent: false);
    grabandoAhora = false;
    final ev = Evidencia(id: 'audio-${DateTime.now().microsecondsSinceEpoch}', contentType: 'audio/mp4', uploaded: false);
    File('${dir.path}/${ev.id}').writeAsBytesSync([4, 5, 6]);
    return (ev: ev, silent: false);
  }

  @override
  Future<void> cancelRecording() async => grabandoAhora = false;
}

/// Los servicios de la app contra el servidor falso, con la base en memoria.
class AppDePrueba {
  final BaseEnMemoria db;
  final ServidorFalso srv;
  late final AuthService auth;
  late final EvidenciasFalsas media;
  late final TemplateService template;
  late final AuditSyncService sync;

  AppDePrueba(this.db, this.srv, {bool conPlantilla = true}) {
    auth = AuthService(almacen: AlmacenEnMemoria(), dio: srv.dio(), google: ExternoFalso());
    media = EvidenciasFalsas.nueva(auth.api);
    template = TemplateService(db: db, api: auth.api);
    if (conPlantilla) template.template = QuestionnaireTemplate(code: 't', title: 'T', sections: []);
    sync = AuditSyncService(db: db, api: auth.api, masters: MasterSyncService(db: db, api: auth.api), media: media);
  }

  Widget montar(Widget home) => MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: db),
          ChangeNotifierProvider<AuthService>.value(value: auth),
          ChangeNotifierProvider<TemplateService>.value(value: template),
          ChangeNotifierProvider<AuditSyncService>.value(value: sync),
          Provider<MediaService>.value(value: media),
        ],
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: temaAolab(), home: home),
      );
}

/// Los plugins que no hay en las pruebas: audioplayers responde vacío y la conectividad dice [red] («none» = sin señal).
void sinPlugins({String red = 'none'}) {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'), (_) async => null);
  m.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
  m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (c) async => [red]);
  m.setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);
  m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/package_info'), (_) async => {
        'appName': 'Aolab',
        'packageName': 'cl.makki.aolab',
        'version': '1.0.6',
        'buildNumber': '6',
      });
}

/// Una evaluación de prueba en el centro de mentira (datos inventados).
Audit evaluacion({String id = 'e1', bool compartida = false, int status = 0, int serverVersion = 4, String? doc}) {
  final now = DateTime.utc(2026, 10, 20, 12);
  final d = jsonDecode('''{
    "id": "$id", "status": $status, "type": 0, "centerName": "Centro Demo", "centerId": "c0000000-0000-0000-0000-000000000001",
    "createdAtUtc": "${now.toIso8601String()}", "updatedAtUtc": "${now.toIso8601String()}", "serverVersion": $serverVersion,
    ${compartida ? '"sharedWithClientUtc": "2026-10-18T14:03:11.123456+00:00",' : ''}
    "document": ${doc ?? '{"center": {}, "salas": [], "entrevistaDesactivada": true, "rpnDesactivado": false, "labDesactivado": false}'}
  }''') as Map<String, dynamic>;
  return Audit.fromDto(d);
}
