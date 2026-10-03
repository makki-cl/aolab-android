// Plan §8.2, «App nueva»: la auditoría conserva las llaves que la app no conoce, en todos los
// niveles (cabecera, documento, sistema, respuesta, punto y evidencia), en su copia local. Antes la
// copia de la app perdía el informe, los comentarios y todo campo que la web agregara después.
// Lo ajeno NO se sube: la copia de la app puede estar vieja (por ejemplo, el informe que la web llenó
// después de que la tablet bajó la auditoría) y el servidor aplica toda llave que viene; lo que no
// viene, lo conserva (fusión de F0).
import 'dart:convert';

import 'package:aolab_android/models/audit.dart';
import 'package:flutter_test/flutter_test.dart';

/// Una auditoría como la entrega `/api/audits/pull` (AuditDto del servidor, JSON Web), de un centro
/// con el modelo con equipos, con campos que la app ya conoce, campos del servidor que la app no
/// edita (informe, comentarios, comparativa, asignado…) y llaves inventadas de una versión futura.
Map<String, dynamic> pullDelServidor() => jsonDecode('''
{
  "id": "6a1d1f3e-0b2a-4f7e-9f00-000000000f31",
  "status": 0,
  "folio": 4321,
  "type": 0,
  "centerName": "DEMO SEGUIMIENTO",
  "auditor": "Auditor de Ejemplo",
  "sampledAtUtc": "2026-10-01T12:00:00.000Z",
  "centerId": "3fc66827-61f7-4c75-99b1-22e986e063a9",
  "clientId": "11111111-2222-3333-4444-555555555555",
  "clientName": "Cliente Prueba",
  "createdByName": "Ana",
  "ownerUserId": "user-ana",
  "assignedToUserId": "user-beto",
  "muestreoId": "9b2c0d7e-0000-0000-0000-00000000f5f5",
  "scheduledForUtc": null,
  "previousAuditId": null,
  "createdAtUtc": "2026-10-01T11:00:00.000Z",
  "updatedAtUtc": "2026-10-01T13:00:00.000Z",
  "isDeleted": false,
  "serverVersion": 2401,
  "document": {
    "center": {
      "ID-02": {"respuesta": "Jefa de centro", "comentario": null, "titulo": null, "adjuntoFuturo": "x.pdf"}
    },
    "centerOperator": "Operador SpA",
    "centerCode": "DEMO-1",
    "tipoSistemaAgua": "ras",
    "entrevistaDesactivada": false,
    "rpnDesactivado": false,
    "comparativa": [{"auditId": "0f0f0f0f-0000-0000-0000-000000000001", "emparejamiento": {"p1": "q1", "p2": ""}, "congelados": ["p2"]}],
    "informe": {"firma": "Firmante", "limiteDeteccionBq": 57, "mostrarRpn": true},
    "comentarios": [{"id": "c1", "texto": "Muestras tomadas por AOLAB."}],
    "seccionFutura": {"version": 7, "items": [1, 2, 3]},
    "salas": [
      {
        "id": "sala-1",
        "name": "SMOLT - 1",
        "tipo": "SMOLT",
        "fromMaster": true,
        "masterId": "4c1d6c8e-sala",
        "afluente": null,
        "etapa": "SMOLT",
        "isDeleted": false,
        "icaFutura": true,
        "answers": {
          "OP-01": {"respuesta": "Sí", "comentario": "ok", "titulo": null, "puntaje": 3}
        },
        "puntosControl": [
          {
            "id": "pc-1",
            "nombre": "POST UV",
            "correlativo": 7,
            "tipo": "Post UV",
            "fromMaster": true,
            "masterId": "tramo-uv",
            "isDeleted": false,
            "equipoId": "eq-uv-2",
            "equipoAlias": "UV 2",
            "equipoTipo": "UV",
            "grupo": "tramo",
            "ubicacion": "tramo",
            "referencia": "post",
            "estadoOperacional": 2,
            "limpiezaBiofilm": 3,
            "impactoPeces": 1,
            "detectabilidad": 4,
            "comentario": "Lámpara con biofilm",
            "bacti": {"valor": 1234.5, "fuente": "csv", "muestreadaUtc": "2026-10-01T12:30:00Z"},
            "bactiHongos": null,
            "muestreoPuntoId": "mp-77",
            "fotos": [
              {"id": "f1", "contentType": "image/jpeg", "capturedAtUtc": "2026-10-01T12:31:00.000Z",
               "uploaded": true, "transcripcion": null, "isDeleted": false, "ancho": 4032, "exif": {"iso": 100}}
            ],
            "audios": []
          },
          {
            "id": "pc-2",
            "nombre": "Punto ad hoc",
            "correlativo": null,
            "tipo": null,
            "fromMaster": false,
            "masterId": null,
            "isDeleted": false,
            "equipoId": null,
            "equipoAlias": null,
            "equipoTipo": null,
            "grupo": null,
            "ubicacion": null,
            "referencia": null,
            "estadoOperacional": null,
            "limpiezaBiofilm": null,
            "impactoPeces": null,
            "detectabilidad": null,
            "comentario": null,
            "bacti": null,
            "bactiHongos": null,
            "fotos": [],
            "audios": []
          }
        ]
      }
    ]
  }
}
''') as Map<String, dynamic>;

/// Compara lo que salió con lo que entró: toda llave que entró sale con el mismo valor, en todos los
/// niveles. Los null que la app omite (la foto del modelo vacía) cuentan como iguales: el servidor
/// conserva lo que no viene.
void expectSinPerdidas(Object? entro, Object? salio, [String ruta = r'$']) {
  if (entro is Map) {
    expect(salio, isA<Map>(), reason: ruta);
    final s = salio as Map;
    for (final e in entro.entries) {
      if (e.value == null && !s.containsKey(e.key)) continue;
      expect(s.containsKey(e.key), isTrue, reason: '$ruta.${e.key} se perdió');
      expectSinPerdidas(e.value, s[e.key], '$ruta.${e.key}');
    }
  } else if (entro is List) {
    expect(salio, isA<List>(), reason: ruta);
    final s = salio as List;
    expect(s.length, entro.length, reason: ruta);
    for (var i = 0; i < entro.length; i++) {
      expectSinPerdidas(entro[i], s[i], '$ruta[$i]');
    }
  } else if (entro is String && salio is String && DateTime.tryParse(entro) != null && entro.contains('T')) {
    // Las fechas las normaliza la app a UTC ISO-8601: mismo instante, otra escritura posible.
    expect(DateTime.parse(salio).isAtSameMomentAs(DateTime.parse(entro)), isTrue, reason: ruta);
  } else {
    expect(salio, entro, reason: ruta);
  }
}

/// Las llaves que la app conoce en cada nivel (las únicas que puede subir).
const _propiasCabecera = {
  'id', 'status', 'folio', 'type', 'centerName', 'auditor', 'sampledAtUtc', 'centerId', 'clientId', //
  'clientName', 'createdByName', 'scheduledForUtc', 'previousAuditId', 'document', 'createdAtUtc', //
  'updatedAtUtc', 'isDeleted', 'serverVersion',
};
const _propiasDocumento = {'center', 'salas'};
const _propiasRespuesta = {'respuesta', 'comentario', 'titulo'};
const _propiasSala = {'id', 'name', 'tipo', 'fromMaster', 'masterId', 'afluente', 'etapa', 'isDeleted', 'answers', 'puntosControl'};
const _propiasPunto = {
  'id', 'nombre', 'correlativo', 'tipo', 'fromMaster', 'masterId', 'isDeleted', 'estadoOperacional', //
  'limpiezaBiofilm', 'impactoPeces', 'detectabilidad', 'comentario', 'fotos', 'audios', 'bacti', 'bactiHongos', //
  'equipoId', 'equipoAlias', 'equipoTipo', 'grupo', 'ubicacion', 'referencia',
};
const _propiasEvidencia = {'id', 'contentType', 'capturedAtUtc', 'uploaded', 'transcripcion', 'isDeleted'};

Map<String, dynamic> _solo(Map<String, dynamic> m, Set<String> llaves) => {
      for (final e in m.entries)
        if (llaves.contains(e.key)) e.key: e.value,
    };

/// Lo que trajo el pull sin lo que la app no conoce, en todos los niveles: es exactamente lo que
/// tiene que subir.
Map<String, dynamic> soloPropias(Map<String, dynamic> pull) {
  Map<String, dynamic> respuestas(Object? m) => {
        for (final e in (m as Map<String, dynamic>).entries)
          e.key: _solo(e.value as Map<String, dynamic>, _propiasRespuesta),
      };
  List evidencias(Object? l) => [for (final e in l as List) _solo(e as Map<String, dynamic>, _propiasEvidencia)];
  final doc = pull['document'] as Map<String, dynamic>;
  return {
    ..._solo(pull, _propiasCabecera),
    'document': {
      'center': respuestas(doc['center']),
      'salas': [
        for (final s in doc['salas'] as List)
          {
            ..._solo(s as Map<String, dynamic>, _propiasSala),
            'answers': respuestas(s['answers']),
            'puntosControl': [
              for (final p in s['puntosControl'] as List)
                {
                  ..._solo(p as Map<String, dynamic>, _propiasPunto),
                  'fotos': evidencias(p['fotos']),
                  'audios': evidencias(p['audios']),
                },
            ],
          },
      ],
    },
  };
}

void main() {
  group('Llaves que la app no conoce', () {
    test('la copia local (SQLite) no pierde ninguna llave en ningún nivel', () {
      final pull = pullDelServidor();
      final fila = Audit.fromDto(pull).toRow();
      // SQLite guarda texto y números: se simula pasando la fila por JSON.
      final leida = Audit.fromRow((jsonDecode(jsonEncode(fila)) as Map).cast<String, Object?>());
      // El documento completo, con el informe, la comparativa y lo de versiones futuras.
      expectSinPerdidas(pull['document'], jsonDecode(leida.toRow()['document'] as String), r'$.document');
      // La cabecera desconocida vive en la columna 'extra', y vuelve a quedar ahí al guardar de nuevo.
      const cabeceraAjena = {
        'ownerUserId': 'user-ana',
        'assignedToUserId': 'user-beto',
        'muestreoId': '9b2c0d7e-0000-0000-0000-00000000f5f5',
      };
      expect(jsonDecode(fila['extra'] as String), cabeceraAjena);
      expect(leida.extra, cabeceraAjena);
      expect(jsonDecode(leida.toRow()['extra'] as String), cabeceraAjena);
    });

    test('el push lleva todo lo propio y nada ajeno, en ningún nivel', () {
      // Caso de la revisión de F3: la tablet bajó un borrador; mientras, en la web se llenó el
      // informe, se activó «solo laboratorio» o se asignó otro auditor. Si la app reenviara su copia
      // de esas llaves, el servidor las devolvería a lo que eran. Sin ellas, las conserva.
      final pull = pullDelServidor();
      final fila = Audit.fromDto(pull).toRow();
      final leida = Audit.fromRow((jsonDecode(jsonEncode(fila)) as Map).cast<String, Object?>());
      for (final a in [Audit.fromDto(pull), leida]) {
        // El JSON real que sube la app (pasa por jsonEncode, como dio).
        final subido = jsonDecode(jsonEncode(a.toDto())) as Map<String, dynamic>;
        final esperado = soloPropias(pull);
        expectSinPerdidas(esperado, subido); // todo lo propio va
        expectSinPerdidas(subido, esperado); // y nada más
        for (final k in ['ownerUserId', 'assignedToUserId', 'muestreoId']) {
          expect(subido.containsKey(k), isFalse, reason: k);
        }
        final doc = subido['document'] as Map<String, dynamic>;
        expect(doc.keys.toSet(), _propiasDocumento);
      }
    });

    test('cada nivel guarda lo ajeno en su mapa extra', () {
      final a = Audit.fromDto(pullDelServidor());
      expect(a.extra.keys, containsAll(['ownerUserId', 'assignedToUserId', 'muestreoId']));
      expect(a.document.extra.keys, containsAll(
          ['informe', 'comentarios', 'comparativa', 'rpnDesactivado', 'entrevistaDesactivada', 'tipoSistemaAgua',
           'centerOperator', 'centerCode', 'seccionFutura']));
      expect(a.document.center['ID-02']!.extra, {'adjuntoFuturo': 'x.pdf'});
      final sala = a.document.salas.single;
      expect(sala.extra, {'icaFutura': true});
      expect(sala.etapa, 'SMOLT');
      expect(sala.answers['OP-01']!.extra, {'puntaje': 3});
      final p = sala.puntosControl.first;
      expect(p.extra, {'muestreoPuntoId': 'mp-77'});
      expect(p.fotos.single.extra, {'ancho': 4032, 'exif': {'iso': 100}});
      // La foto del modelo con equipos ya no es ajena: es un campo propio.
      expect((p.equipoId, p.equipoAlias, p.equipoTipo, p.grupo, p.ubicacion, p.referencia),
          ('eq-uv-2', 'UV 2', 'UV', 'tramo', 'tramo', 'post'));
    });

    test('lo que edita la app se sube; lo ajeno sigue en la copia local', () {
      final a = Audit.fromDto(pullDelServidor());
      final p = a.document.salas.single.puntosControl.first;
      p.estadoOperacional = 5;
      p.comentario = 'corregido';
      a.document.center['ID-02']!.respuesta = 'Otra jefa';
      final dto = jsonDecode(jsonEncode(a.toDto())) as Map<String, dynamic>;
      final pd = (dto['document']['salas'] as List).single['puntosControl'][0] as Map<String, dynamic>;
      expect(pd['estadoOperacional'], 5);
      expect(pd['comentario'], 'corregido');
      expect(pd.containsKey('muestreoPuntoId'), isFalse);
      expect(dto['document']['center']['ID-02']['respuesta'], 'Otra jefa');
      expect((dto['document']['center']['ID-02'] as Map).containsKey('adjuntoFuturo'), isFalse);
      // La copia local tiene las dos cosas: lo editado y lo ajeno.
      final local = jsonDecode(a.toRow()['document'] as String) as Map<String, dynamic>;
      final pl = (local['salas'] as List).single['puntosControl'][0] as Map<String, dynamic>;
      expect(pl['estadoOperacional'], 5);
      expect(pl['muestreoPuntoId'], 'mp-77');
      expect(local['center']['ID-02']['respuesta'], 'Otra jefa');
      expect(local['center']['ID-02']['adjuntoFuturo'], 'x.pdf');
      expect(local['informe'], {'firma': 'Firmante', 'limiteDeteccionBq': 57, 'mostrarRpn': true});
    });

    test('la foto del modelo vacía no se manda: nunca pisa con null lo que el servidor tiene', () {
      // Una auditoría que bajó la versión anterior de la app quedó guardada sin la foto (la descartaba).
      // Al subirla con esta versión, la foto no viaja y el servidor conserva la suya (fusión de F0).
      final a = Audit.fromDto(pullDelServidor());
      final adHoc = jsonDecode(jsonEncode(a.document.salas.single.puntosControl[1].toJson())) as Map<String, dynamic>;
      for (final k in ['equipoId', 'equipoAlias', 'equipoTipo', 'grupo', 'ubicacion', 'referencia']) {
        expect(adHoc.containsKey(k), isFalse, reason: k);
      }
      final sinEtapa = AuditSala(id: 's', name: 'SF', tipo: 'SF');
      expect(sinEtapa.toJson().containsKey('etapa'), isFalse);
      // Los campos de siempre se siguen mandando aunque sean null, como antes.
      expect(adHoc.containsKey('correlativo'), isTrue);
      expect(adHoc.containsKey('bacti'), isTrue);
    });

    test('una auditoría creada en la app no inventa llaves', () {
      final a = Audit(
        id: 'nueva',
        createdAtUtc: DateTime.utc(2026, 10, 2),
        updatedAtUtc: DateTime.utc(2026, 10, 2),
      );
      final dto = a.toDto();
      expect(dto.keys.toSet(), {
        'id', 'status', 'folio', 'type', 'centerName', 'auditor', 'sampledAtUtc', 'centerId', 'clientId',
        'clientName', 'createdByName', 'scheduledForUtc', 'previousAuditId', 'document', 'createdAtUtc',
        'updatedAtUtc', 'isDeleted', 'serverVersion',
      });
      expect((dto['document'] as Map).keys.toSet(), {'center', 'salas'});
      expect(a.toRow()['extra'], isNull);
    });

    test('una fila guardada por la versión anterior (sin columna extra) se lee igual', () {
      final fila = Audit.fromDto(pullDelServidor()).toRow()..remove('extra');
      final a = Audit.fromRow(fila);
      expect(a.extra, isEmpty);
      expect(a.folio, 4321);
      // Y una columna extra ilegible no bota la lista de auditorías.
      expect(Audit.fromRow({...fila, 'extra': 'no es json'}).extra, isEmpty);
    });

    test('una llave que solo cambia de mayúsculas no se duplica', () {
      final ans = Answer.fromJson({'respuesta': 'a', 'Respuesta': 'b', 'nueva': 1});
      expect(ans.extra, {'nueva': 1});
      expect(ans.toJson().keys.where((k) => k.toLowerCase() == 'respuesta').length, 1);
    });
  });
}
