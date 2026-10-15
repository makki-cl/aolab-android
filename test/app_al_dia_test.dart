// La app puesta al día con la web del 15-10-2026: las partes de la visita (entrevista, RPN, laboratorio) que el
// evaluador marca en la tablet, el BQ/FC a mano en el muestreo y las reglas de la sincronización que cuidan lo que
// todavía no sale de la tablet (pendientes-app-sync.md, 10-10-2026).
import 'dart:convert';

import 'package:aolab_android/data/reglas_sync.dart';
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/numeros.dart';
import 'package:flutter_test/flutter_test.dart';

/// Una visita como la entrega hoy `/api/audits/pull` cuando se creó en la web: sin nada activo (los tres
/// interruptores en true), con el modelo con equipos (Río Negro, versión 3) y un punto de bateas con posición.
Map<String, dynamic> visitaDeLaWeb() => jsonDecode('''
{
  "id": "0d6b7a52-5f0e-4a43-9a2d-3c1f00000001",
  "status": 3,
  "folio": null,
  "type": 0,
  "centerName": "Río Negro",
  "auditor": null,
  "sampledAtUtc": null,
  "centerId": "94148733-90b0-4b1c-9c19-7d7423208fea",
  "clientId": null,
  "clientName": null,
  "createdByName": "Oficina",
  "ownerUserId": "u1",
  "assignedToUserId": null,
  "scheduledForUtc": "2026-10-20T12:00:00+00:00",
  "previousAuditId": null,
  "createdAtUtc": "2026-10-15T20:01:30.3547128+00:00",
  "updatedAtUtc": "2026-10-15T20:01:30.3547128+00:00",
  "isDeleted": false,
  "serverVersion": 77,
  "document": {
    "center": {},
    "salas": [
      {
        "id": "s1", "name": "Incubación 2°", "tipo": "HATCHERY", "fromMaster": true, "masterId": "m-s1",
        "afluente": null, "etapa": "HATCHERY", "isDeleted": false, "answers": {},
        "puntosControl": [
          {
            "id": "p1", "nombre": "Racks · Entrada", "correlativo": null, "tipo": "Batea / Incubación",
            "fromMaster": true, "masterId": "m-p1", "isDeleted": false, "equipoId": "eq-racks",
            "equipoAlias": "Racks", "equipoTipo": "Batea / Incubación", "grupo": "equipo", "ubicacion": "entrada",
            "posicion": {"rack": 3, "unidad": 7, "etiqueta": "Rack 3 · Batea 7"},
            "estadoOperacional": null, "limpiezaBiofilm": null, "impactoPeces": null, "detectabilidad": null,
            "comentario": null, "bacti": null, "bactiHongos": null, "fotos": [], "audios": []
          }
        ]
      }
    ],
    "centerOperator": null,
    "centerCode": null,
    "tipoSistemaAgua": null,
    "entrevistaDesactivada": true,
    "rpnDesactivado": true,
    "labDesactivado": true,
    "comparativa": [],
    "informe": {"mostrarRpn": true, "mostrarFotos": true},
    "comentarios": []
  }
}
''') as Map<String, dynamic>;

Map<String, dynamic> subir(Audit a) => jsonDecode(jsonEncode(a.toDto())) as Map<String, dynamic>;

Audit pasarPorSqlite(Audit a) => Audit.fromRow((jsonDecode(jsonEncode(a.toRow())) as Map).cast<String, Object?>());

void main() {
  group('Partes de la visita (entrevista, RPN, laboratorio)', () {
    test('la visita de la web baja sin nada activo y la app lo lee', () {
      final a = Audit.fromDto(visitaDeLaWeb());
      expect(a.document.nadaActivo, isTrue);
      expect((a.document.aplicaEntrevista, a.document.aplicaRpn, a.document.aplicaLab), (false, false, false));
      expect(validarSecciones(a.document), kAmbasDesactivadas);
      // Las fechas con 7 decimales del servidor se leen.
      expect(a.createdAtUtc.isUtc, isTrue);
    });

    test('lo que marca el evaluador se sube', () {
      final a = Audit.fromDto(visitaDeLaWeb());
      a.document.rpnDesactivado = false;
      a.document.labDesactivado = false;
      final doc = subir(a)['document'] as Map<String, dynamic>;
      expect(doc['rpnDesactivado'], isFalse);
      expect(doc['labDesactivado'], isFalse);
      expect(doc['entrevistaDesactivada'], isTrue);
      expect(validarSecciones(a.document), isNull);
      // Y queda en la copia local.
      final local = pasarPorSqlite(a);
      expect((local.document.aplicaRpn, local.document.aplicaLab, local.document.aplicaEntrevista), (true, true, false));
    });

    test('una evaluación sin interruptores (anterior o de una app vieja) se lee como «se aplica» y no los inventa', () {
      final d = AuditDocument.fromJson(jsonDecode('{"center": {}, "salas": []}') as Map<String, dynamic>);
      expect((d.aplicaEntrevista, d.aplicaRpn, d.aplicaLab), (true, true, true));
      expect(d.toJson(ajenas: false).keys.toSet(), {'center', 'salas'});
      // Un valor que no es sí/no (servidor futuro) no bota la lectura.
      final raro = jsonDecode('{"center": {}, "salas": [], "rpnDesactivado": "no"}') as Map<String, dynamic>;
      expect(AuditDocument.fromJson(raro).rpnDesactivado, isNull);
    });

    test('la visita nueva de la app nace como en la web: sin nada activo', () {
      final d = AuditDocument.nueva();
      expect(d.nadaActivo, isTrue);
      expect(d.toJson(ajenas: false), {
        'center': <String, dynamic>{},
        'salas': <dynamic>[],
        'entrevistaDesactivada': true,
        'rpnDesactivado': true,
        'labDesactivado': true,
      });
    });

    test('para finalizar hace falta el RPN o el laboratorio', () {
      expect(validarSecciones(AuditDocument(rpnDesactivado: false, labDesactivado: true)), isNull);
      expect(validarSecciones(AuditDocument(rpnDesactivado: true, labDesactivado: false)), isNull);
      expect(validarSecciones(AuditDocument(rpnDesactivado: true, labDesactivado: true, entrevistaDesactivada: false)),
          kAmbasDesactivadas);
    });
  });

  group('Muestreo: BQ/FC a mano', () {
    test('el resultado a mano es el mismo de la web y la marca local no se sube', () {
      final a = Audit.fromDto(visitaDeLaWeb());
      final p = a.document.salas.single.puntosControl.single;
      p.bacti = resultadoManual(1234.5, hongos: false);
      p.labLocal.add('bq');
      final subido = subir(a);
      final ps = ((subido['document']['salas'] as List).single['puntosControl'] as List).single as Map<String, dynamic>;
      expect(ps['bacti'], {'valor': 1234.5, 'organismo': 'bacteria', 'belowThreshold': false, 'fuente': 'manual'});
      expect(ps['bactiHongos'], isNull);
      expect(ps.containsKey(kLlaveLabLocal), isFalse);
      // La posición la anota la web: no se sube, pero se conserva en la copia local y se muestra.
      expect(ps.containsKey('posicion'), isFalse);
      final local = pasarPorSqlite(a).document.salas.single.puntosControl.single;
      expect(local.labLocal, {'bq'});
      expect(local.bq, 1234.5);
      expect(local.posicionEtiqueta, 'Rack 3 · Batea 7');
    });

    test('al volver del servidor la marca local desaparece (el resultado pasa a ser de la web)', () {
      final p = Audit.fromDto(visitaDeLaWeb()).document.salas.single.puntosControl.single;
      expect(p.labLocal, isEmpty);
    });

    test('corregir a mano conserva lo demás del resultado', () {
      final r = resultadoManual(10, hongos: true, anterior: {'valor': 5, 'flu': 120.0, 'fuente': 'csv', 'organismo': 'fungi'});
      expect(r, {'valor': 10.0, 'flu': 120.0, 'fuente': 'manual', 'organismo': 'fungi', 'belowThreshold': false});
    });

    test('números como se escriben en Chile', () {
      expect(leerNumero('1.234,5'), 1234.5);
      expect(leerNumero('1234,5'), 1234.5);
      expect(leerNumero('12,5'), 12.5);
      expect(leerNumero('12.5'), 12.5);
      expect(leerNumero('1.234'), 1234);
      expect(leerNumero('12.500.000'), 12500000);
      expect(leerNumero('0.125'), 0.125);
      expect(leerNumero(' 57 '), 57);
      expect(leerNumero(''), isNull);
      expect(leerNumero('abc'), isNull);
      expect(leerNumero('1,2,3'), isNull);
      expect(formatoNumero(1234.5), '1.234,5');
      expect(formatoNumero(57), '57');
      expect(formatoNumero(1234567), '1.234.567');
      expect(formatoNumero(0.5), '0,5');
      // Lo que se muestra se vuelve a leer igual.
      for (final v in [0.5, 57.0, 1234.5, 98765.25, 1000.0]) {
        expect(leerNumero(formatoNumero(v)), v);
      }
    });
  });

  group('Sincronización: lo que todavía no sale de la tablet', () {
    test('una fila que no cambió mientras el envío iba y volvía queda sincronizada, con el folio del servidor', () {
      final m = marcaSincronizada(revEnviada: 4, revActual: 4, folioEnviado: 3001, folioActual: 3001, folioRespuesta: null);
      expect(m.dirty, isFalse);
      expect(m.folio, isNull); // el servidor lo arbitró (ya lo usaba otra): se copia tal cual, también nulo
    });

    test('una fila que se editó mientras tanto sigue pendiente', () {
      final m = marcaSincronizada(revEnviada: 4, revActual: 5, folioEnviado: 3001, folioActual: 3001, folioRespuesta: 3001);
      expect(m.dirty, isTrue);
      expect(m.folio, 3001);
    });

    test('un folio que el evaluador cambió mientras tanto no se pisa con la respuesta', () {
      final m = marcaSincronizada(revEnviada: 4, revActual: 5, folioEnviado: 3001, folioActual: 3002, folioRespuesta: null);
      expect(m.dirty, isTrue);
      expect(m.folio, 3002);
    });

    test('«subida» solo pasa de no a sí: una copia vieja del editor no la deshace', () {
      Audit conFoto(bool subida) => Audit.fromDto(visitaDeLaWeb())
        ..document.salas.single.puntosControl.single.fotos.add(
            Evidencia(id: 'f1', contentType: 'image/jpeg', uploaded: subida));
      final guardada = conFoto(true);
      final editor = conFoto(false);
      conservarSubidas(editor.document, guardada.document);
      expect(editor.document.salas.single.puntosControl.single.fotos.single.uploaded, isTrue);
      // Y marcar sobre la fila recién leída solo toca las que subieron.
      final fila = conFoto(false);
      fila.document.salas.single.puntosControl.single.fotos.add(Evidencia(id: 'f2'));
      expect(marcarSubidas(fila.document, {'f2'}), 1);
      expect([for (final e in evidenciasDe(fila.document)) (e.id, e.uploaded)], [('f1', false), ('f2', true)]);
    });

    test('la revisión local y el folio leído no viajan', () {
      final a = Audit.fromDto(visitaDeLaWeb())
        ..localRev = 9
        ..folio = 3005;
      final dto = subir(a);
      expect(dto.containsKey('localRev'), isFalse);
      expect(dto.containsKey('local_rev'), isFalse);
      expect(dto['folio'], 3005);
      final local = pasarPorSqlite(a);
      expect(local.localRev, 9);
      expect(local.folioLeido, 3005);
    });
  });
}
