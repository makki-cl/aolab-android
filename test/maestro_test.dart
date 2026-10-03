// F3 en la app: el maestro nuevo (centros con el modelo con equipos) y el viejo se leen sin
// romperse, los puntos se agrupan como se recorre el agua sin perder ninguno, y el punto entra a la
// auditoría con la foto de su equipo solo en un centro activado.
//
// Los fixtures son JSON reales del servidor (MasterSyncService.ADto serializado como la API), sobre la
// foto de solo lectura de aolab_dev que usan las pruebas del backend:
// - maestro_f3.json: lo que manda hoy el servidor. DEMO SEGUIMIENTO (activado), una copia de BERNARDINO
//   activada (como la demostración de F3 en «Centro Test») y RIO NEGRO (modelo plano).
// - maestro_antes_f3.json: lo que mandaba un servidor anterior a F2 para esos mismos centros: solo las
//   llaves de entonces, siempre el modelo plano.
import 'dart:convert';
import 'dart:io';

import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/modelo_puntos.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> centrosDe(String archivo) =>
    ((jsonDecode(File('test/fixtures/$archivo').readAsStringSync()) as Map)['centers'] as List)
        .cast<Map<String, dynamic>>();

/// Como lo guarda y lo vuelve a leer la app: DTO → fila SQLite → CenterRef.
CenterRef guardarYLeer(Map<String, dynamic> dto) {
  final fila = CenterRef.fromDto(dto).toRow();
  return CenterRef.fromRow((jsonDecode(jsonEncode(fila)) as Map).cast<String, Object?>());
}

const demoId = '3fc66827-61f7-4c75-99b1-22e986e063a9';
const bernardinoId = '5b738314-c155-406b-bc5a-56edcb5f9b40';
const rioNegroId = 'cdccb617-e353-4755-95db-8feeaf31ffcb';

void main() {
  group('Maestro nuevo (F3)', () {
    final centros = {for (final d in centrosDe('maestro_f3.json')) d['id'] as String: d};

    test('un centro activado trae versión, etapa, afluentes y la foto de cada punto', () {
      final demo = guardarYLeer(centros[demoId]!);
      expect(demo.modeloVersion, 2);
      expect(demo.conEquipos, isTrue);
      expect(demo.sistemas.map((s) => s.etapa), ['SMOLT', 'SMOLT', 'FF']);
      expect(demo.sistemas.map((s) => rotuloSistema(s, conEquipos: true)), ['Smolt', 'Smolt', 'First Feeding']);
      for (final s in demo.sistemas) {
        expect(s.clase, 'cultivo');
        expect(s.afluentes, isNotEmpty);
        expect(s.afluentes.first.tipo, isNotNull);
        for (final p in s.puntosControl) {
          expect(p.id, isNotEmpty);
          expect(kGruposPunto, contains(p.grupo));
          expect(p.equipoId, isNotNull);
          expect(p.ubicacion, isNotNull);
          expect(p.orden, isNotNull);
          // El tipo es siempre uno del modelo plano: con él sigue funcionando el RPN.
          expect(kPuntoControlTipos, contains(p.tipo));
        }
      }
    });

    test('los puntos se agrupan en el orden del agua y ninguno se pierde', () {
      for (final dto in centros.values) {
        final c = guardarYLeer(dto);
        for (final s in c.sistemas) {
          final secciones = agruparPuntos(s.puntosControl);
          final agrupados = secciones.expand((x) => x.puntos).map((p) => p.id).toList();
          expect(agrupados.toSet(), s.puntosControl.map((p) => p.id).toSet(), reason: '${c.name} · ${s.nombre}');
          expect(agrupados.length, s.puntosControl.length);
          if (!c.conEquipos) {
            // Modelo plano: una sola sección sin encabezado, con la lista tal cual (como siempre).
            expect(secciones.length, lessThanOrEqualTo(1));
            if (secciones.isNotEmpty) {
              expect(secciones.single.grupo, isNull);
              expect(secciones.single.puntos.map((p) => p.id), s.puntosControl.map((p) => p.id));
            }
            continue;
          }
          final grupos = secciones.map((x) => x.grupo).toList();
          expect(grupos, [for (final g in kGruposPunto) if (grupos.contains(g)) g]);
          // Afluentes y efluente se ofrecen siempre (requisito 3.1).
          expect(grupos, containsAll([kGrupoAfluente, kGrupoEfluente]));
          for (final sec in secciones) {
            final orden = sec.puntos.map((p) => p.orden!).toList();
            expect(orden, [...orden]..sort(), reason: 'orden del agua dentro de ${sec.titulo}');
          }
        }
      }
    });

    test('en «Equipos» hay un bloque por equipo con su alias', () {
      final demo = guardarYLeer(centros[demoId]!);
      final s = demo.sistemas.first;
      final equipos = agruparPuntos(s.puntosControl).singleWhere((x) => x.grupo == kGrupoEquipo);
      final ids = s.puntosControl.where((p) => p.grupo == kGrupoEquipo).map((p) => p.equipoId).toSet();
      expect(equipos.bloques.length, ids.length);
      for (final b in equipos.bloques) {
        expect(b.titulo, isNotEmpty);
        expect(b.puntos.every((p) => p.equipoId == b.equipoId), isTrue);
      }
    });

    test('un centro en el modelo plano llega igual que antes', () {
      final rio = guardarYLeer(centros[rioNegroId]!);
      expect(rio.conEquipos, isFalse);
      for (final s in rio.sistemas) {
        expect(s.afluentes, isEmpty);
        expect(rotuloSistema(s, conEquipos: false), s.tipo);
        for (final p in s.puntosControl) {
          expect([p.equipoId, p.equipoAlias, p.equipoTipo, p.grupo, p.ubicacion, p.referencia, p.orden], everyElement(isNull));
          // El blob local de un punto plano no crece.
          expect(p.toJson().keys.toSet(), {'id', 'alias', 'tipo'});
        }
      }
    });

    test('el punto entra a la auditoría con su foto solo en un centro activado', () {
      final bern = guardarYLeer(centros[bernardinoId]!);
      final pd = bern.sistemas.first.puntosControl.firstWhere((p) => p.grupo == kGrupoEquipo);
      final v2 = puntoDesdeMaestro(pd, id: 'x', conEquipos: true);
      expect((v2.masterId, v2.nombre, v2.tipo, v2.fromMaster), (pd.id, pd.alias, pd.tipo, true));
      expect((v2.equipoId, v2.equipoAlias, v2.equipoTipo, v2.grupo, v2.ubicacion, v2.referencia),
          (pd.equipoId, pd.equipoAlias, pd.equipoTipo, pd.grupo, pd.ubicacion, pd.referencia));

      final rio = guardarYLeer(centros[rioNegroId]!);
      final plano = rio.sistemas.first.puntosControl.first;
      final v1 = puntoDesdeMaestro(plano, id: 'y', conEquipos: false);
      expect((v1.masterId, v1.nombre, v1.tipo), (plano.id, plano.alias, plano.tipo));
      // Exactamente las llaves de antes de F3.
      expect(v1.toJson().keys.toSet(), {
        'id', 'nombre', 'correlativo', 'tipo', 'fromMaster', 'masterId', 'isDeleted', 'estadoOperacional',
        'limpiezaBiofilm', 'impactoPeces', 'detectabilidad', 'comentario', 'fotos', 'audios', 'bacti', 'bactiHongos',
      });
    });
  });

  group('Maestro viejo', () {
    test('un servidor anterior (sin versión, etapa ni grupos) se lee como modelo plano', () {
      for (final dto in centrosDe('maestro_antes_f3.json')) {
        final c = guardarYLeer(dto);
        expect(c.modeloVersion, 1);
        expect(c.conEquipos, isFalse);
        for (final s in c.sistemas) {
          expect(s.etapa, isNull);
          expect(s.afluentes, isEmpty);
          expect(agruparPuntos(s.puntosControl).map((x) => x.grupo), s.puntosControl.isEmpty ? isEmpty : [null]);
        }
      }
      final rio = guardarYLeer(centrosDe('maestro_antes_f3.json').firstWhere((d) => d['id'] == rioNegroId));
      expect(rio.sistemas.expand((s) => s.puntosControl).length, 100);
    });

    test('el blob que guardó la versión anterior de la app se sigue leyendo', () {
      // Así guardaba Sistema.toJson antes de F3, y así queda en SQLite hasta la primera sincronización.
      final fila = <String, Object?>{
        'id': rioNegroId,
        'name': 'RIO NEGRO',
        'sistemas': jsonEncode([
          {
            'id': 's1', 'nombre': 'P - 5', 'tipo': 'FRY', 'afluente': null,
            'puntosControl': [{'id': 'p1', 'alias': 'Pre UV 1', 'tipo': 'Pre UV'}],
          }
        ]),
        'is_active': 1,
        'is_deleted': 0,
        'server_version': 2300,
      };
      final c = CenterRef.fromRow(fila);
      expect(c.modeloVersion, 1);
      expect(c.sistemas.single.puntosControl.single.alias, 'Pre UV 1');
      expect(c.sistemas.single.etapa, isNull);
    });
  });

  group('Servidor más nuevo que la app', () {
    final futuro = <String, dynamic>{
      'id': '6a1b8a52-2b48-4a4e-9a51-0c7f3d0d7a01',
      'name': 'Futuro',
      'modeloVersion': 3,
      'llaveNueva': {'x': 1},
      'isActive': true,
      'isDeleted': false,
      'serverVersion': 9000,
      'sistemas': [
        {
          'id': 's1', 'nombre': 'SMOLT - 9', 'tipo': 'SMOLT', 'etapa': 'SMOLT', 'clase': 'cultivo', 'otraLlave': [1, 2],
          'afluentes': [{'id': 'a1', 'nombre': 'Afluente Pozo', 'tipo': 'Pozo', 'caudal': 12.5}],
          'puntosControl': [
            {'id': 'p4', 'alias': 'Efluente SMOLT - 9', 'tipo': 'Efluente', 'grupo': 'efluente', 'orden': 4},
            {'id': 'p3', 'alias': 'Válvula 1', 'tipo': 'Otro', 'grupo': 'valvula', 'orden': 3},
            {'id': 'p1', 'alias': 'Afluente Pozo', 'tipo': 'Make Up / Ingreso Afluente', 'grupo': 'afluente',
             'equipoId': 'a1', 'equipoAlias': 'Afluente Pozo', 'equipoTipo': 'Pozo', 'ubicacion': 'salida', 'orden': 1},
            {'id': 'p2', 'alias': 'POST UV', 'tipo': 'Post UV', 'grupo': 'tramo', 'equipoId': 'uv2',
             'equipoAlias': 'UV 2', 'equipoTipo': 'UV', 'ubicacion': 'tramo', 'referencia': 'post', 'orden': 2.0,
             'sensor': 'x'},
            {'id': 'p5', 'alias': 'Rotatorio · Entrada', 'tipo': 'Pre Rotatorio', 'grupo': 'equipo', 'equipoId': 'r1',
             'equipoAlias': 'Rotatorio', 'equipoTipo': 'Rotatorio', 'ubicacion': 'entrada', 'orden': 5},
          ],
        }
      ],
    };

    test('grupos y llaves desconocidas no rompen la lectura ni se pierden puntos', () {
      final c = guardarYLeer(futuro);
      expect(c.conEquipos, isTrue);
      final s = c.sistemas.single;
      expect(s.afluentes.single.tipo, 'Pozo');
      expect(s.afluentes.single.extra, {'caudal': 12.5});
      expect(s.extra, {'otraLlave': [1, 2]});
      expect(s.puntosControl.firstWhere((p) => p.id == 'p2').extra, {'sensor': 'x'});
      expect(s.puntosControl.firstWhere((p) => p.id == 'p2').orden, 2);

      final secciones = agruparPuntos(s.puntosControl);
      expect(secciones.map((x) => x.grupo), [kGrupoAfluente, kGrupoEquipo, kGrupoTramo, kGrupoEfluente, 'valvula']);
      expect(secciones.last.titulo, 'Puntos');
      expect(secciones.expand((x) => x.puntos).length, 5);
    });

    test('equipo junto al nombre solo cuando el nombre no lo dice', () {
      final s = guardarYLeer(futuro).sistemas.single;
      PuntoControlDef p(String id) => s.puntosControl.firstWhere((x) => x.id == id);
      expect(equipoAMostrar(p('p2')), 'UV 2');
      expect(equipoAMostrar(p('p5')), isNull); // «Rotatorio · Entrada» ya lo dice
      expect(equipoAMostrar(p('p1')), isNull); // los afluentes se nombran solos
    });
  });

  group('Presentación y vínculo', () {
    test('la etapa se muestra con su etiqueta; sin etapa, el tipo de siempre', () {
      expect(tipoUnidad(AuditSala(id: 'a', tipo: 'PRE-SMOLT', etapa: 'PRE-SMOLT')), 'Pre Smolt');
      expect(tipoUnidad(AuditSala(id: 'b', tipo: 'SF')), 'SF');
      expect(tipoUnidad(AuditSala(id: 'c', tipo: 'SMOLT')), 'SMOLT');
      expect(etiquetaEtapa(null), 'Etapa por definir');
      expect(etiquetaEtapa('XYZ'), 'XYZ');
      expect(kSistemaTipos, contains('SF'));
      expect(kEtapasSistema.keys, isNot(contains('SF')));
    });

    test('el equipo del punto auditado se muestra si el nombre no lo dice', () {
      expect(equipoDelPunto(PuntoControl(id: '1', nombre: 'POST UV', equipoAlias: 'UV 2')), 'UV 2');
      expect(equipoDelPunto(PuntoControl(id: '2', nombre: 'UV 2 · Entrada', equipoAlias: 'UV 2')), isNull);
      expect(equipoDelPunto(PuntoControl(id: '3', nombre: 'Pre UV 1')), isNull);
    });

    test('por nombre solo se reconoce contra el modelo plano', () {
      final viejo = PuntoControl(id: 'v', nombre: 'Afluente Pozo', tipo: 'Make Up / Ingreso Afluente', fromMaster: true);
      final plano = PuntoControlDef(id: 'p1', alias: 'Afluente Pozo', tipo: 'Make Up / Ingreso Afluente');
      final conEquipos = PuntoControlDef(
          id: 'p1', alias: 'Afluente Pozo', tipo: 'Make Up / Ingreso Afluente', grupo: kGrupoAfluente);
      expect(esMismoPunto(viejo, plano), isTrue);
      expect(esMismoPunto(viejo, conEquipos), isFalse);
      final conId = PuntoControl(id: 'c', masterId: 'p1', nombre: 'otro');
      expect(esMismoPunto(conId, plano), isTrue);
      expect(esMismoPunto(conId, conEquipos), isTrue);
    });
  });

  group('Lo marcado que el maestro ya no trae', () {
    // En un centro activado el servidor no manda lo retirado. Una auditoría abierta que tenía marcado
    // un sistema o un punto que después se retiró (o un punto del modelo plano, de antes de activar)
    // tiene que seguir mostrándolos para poder quitarlos.
    final maestro = [
      Sistema(id: 'sA', nombre: 'SMOLT - 1', puntosControl: [
        PuntoControlDef(id: 'p1', alias: 'POST UV', tipo: 'Post UV', grupo: kGrupoTramo),
      ]),
    ];

    test('un sistema marcado que se retiró queda fuera del maestro, y en la papelera si se quita', () {
      final vigente = AuditSala(id: 'a1', name: 'SMOLT - 1', fromMaster: true, masterId: 'sA');
      final retirado = AuditSala(id: 'a2', name: 'FF - 1', fromMaster: true, masterId: 'sB');
      final porNombre = AuditSala(id: 'a3', name: 'smolt - 1 ', fromMaster: true); // anterior al Id
      final adHoc = AuditSala(id: 'a4', name: 'Extra');
      final salas = [vigente, retirado, porNombre, adHoc];
      expect(sistemasFueraDelMaestro(salas, maestro), [retirado]);
      expect(sistemasFueraDelMaestro(salas, maestro, eliminados: true), isEmpty);
      retirado.isDeleted = true;
      expect(sistemasFueraDelMaestro(salas, maestro), isEmpty);
      expect(sistemasFueraDelMaestro(salas, maestro, eliminados: true), [retirado]);
    });

    test('un punto marcado que el maestro ya no trae se lista aparte; lo desmarcado y lo ad hoc no', () {
      final sala = AuditSala(id: 'a1', name: 'SMOLT - 1', fromMaster: true, masterId: 'sA', puntosControl: [
        PuntoControl(id: 'x1', masterId: 'p1', nombre: 'POST UV', fromMaster: true),
        PuntoControl(id: 'x2', masterId: 'v1-viejo', nombre: 'Pre UV', tipo: 'Pre UV', fromMaster: true),
        PuntoControl(id: 'x3', masterId: 'retirado', nombre: 'Interior', fromMaster: true, isDeleted: true),
        PuntoControl(id: 'x4', nombre: 'Ad hoc'),
      ]);
      expect(puntosFueraDelMaestro(sala, maestro.single.puntosControl).map((p) => p.id), ['x2']);
    });
  });
}
