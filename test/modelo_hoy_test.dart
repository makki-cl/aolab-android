// La app con el modelo de hoy (PLAN F2 y el agregado del 20-10): puntos de nivel con su posición, varias muestras del
// mismo punto, nombres con la regla vigente, sistemas por tipo como la lista lateral del editor, salas renombradas y las
// evaluaciones compartidas con el cliente. Los datos son de mentira (el repo es público): la forma es la del pull real.
import 'dart:convert';

import 'package:aolab_android/data/reglas_sync.dart';
import 'package:aolab_android/models/audit.dart';
import 'package:aolab_android/models/clases_sistema.dart';
import 'package:aolab_android/models/master.dart';
import 'package:aolab_android/models/modelo_puntos.dart';
import 'package:aolab_android/models/niveles.dart';
import 'package:flutter_test/flutter_test.dart';

/// Un centro como lo manda `/api/masters/centers/pull` con el modelo con equipos y un grupo efímero de racks.
Map<String, dynamic> centroDeMentira() => jsonDecode('''
{
  "id": "c0000000-0000-0000-0000-000000000001", "name": "Centro Demo", "modeloVersion": 10,
  "afluenteMode": "single", "afluente": "Dulce", "isActive": true, "isDeleted": false, "serverVersion": 5,
  "sistemas": [
    {"id": "s-inc", "nombre": "Incubación A", "tipo": "HATCHERY", "etapa": "HATCHERY", "clase": "cultivo", "afluente": "Dulce",
     "afluentes": [{"id": "a1", "nombre": "Entrada de agua · UV", "tipo": "Noria"}],
     "puntosControl": [
       {"id": "p-uv-e", "alias": "UV · Entrada", "tipo": "Pre UV", "equipoId": "e-uv", "equipoAlias": "UV", "equipoTipo": "UV", "grupo": "equipo", "ubicacion": "entrada", "orden": 1},
       {"id": "p-tramo", "alias": "POST Manifold", "tipo": "Estanque Cabecera", "equipoId": "e-man", "equipoAlias": "Manifold", "equipoTipo": "Estanque Cabecera", "grupo": "tramo", "ubicacion": "tramo", "referencia": "post", "orden": 2},
       {"id": "p-rack-s", "alias": "Racks · Rack · Salida", "tipo": "Batea / Incubación", "equipoId": "g-racks", "equipoAlias": "Racks", "equipoTipo": "Rack", "grupo": "equipo", "ubicacion": "salida", "orden": 3,
        "nivelGrupo": 1, "nivelesGrupo": [{"nivel": 1, "nombre": "Rack", "identifica": "numero"}]},
       {"id": "p-balde-e", "alias": "Racks · Balde · Entrada", "tipo": "Batea / Incubación", "equipoId": "g-racks", "equipoAlias": "Racks", "equipoTipo": "Batea / Incubación", "grupo": "equipo", "ubicacion": "entrada", "orden": 4,
        "nivelGrupo": 2, "nivelesGrupo": [{"nivel": 1, "nombre": "Rack", "identifica": "numero"}, {"nivel": 2, "nombre": "Balde", "identifica": "codigo"}]}
     ]},
    {"id": "s-efl", "nombre": "Efluente", "tipo": "EFLUENTE", "clase": "efluente", "afluentes": [],
     "puntosControl": [{"id": "p-efl", "alias": "Efluente Efluente", "tipo": "Efluente", "grupo": "efluente", "ubicacion": "entrada", "orden": 1}]},
    {"id": "s-noria", "nombre": "Noria", "tipo": "AFLUENTE", "clase": "afluente", "afluentes": [{"id": "a0", "nombre": "Afluente Noria", "tipo": "Noria"}],
     "puntosControl": [{"id": "p-noria", "alias": "Afluente Noria", "tipo": "Make Up / Ingreso Afluente", "grupo": "afluente", "ubicacion": "salida", "orden": 1}]},
    {"id": "s-vac", "nombre": "Torre de Vacunación", "clase": "tratamiento-salmon", "afluentes": [], "puntosControl": []},
    {"id": "s-trat", "nombre": "Tratamiento Primario", "clase": "tratamiento", "afluentes": [], "puntosControl": []}
  ]
}''') as Map<String, dynamic>;

void main() {
  final centro = CenterRef.fromDto(centroDeMentira());
  final inc = centro.sistemas.first;
  final rack = inc.puntosControl.firstWhere((p) => p.id == 'p-rack-s');
  final balde = inc.puntosControl.firstWhere((p) => p.id == 'p-balde-e');

  AuditSala salaDe(Sistema m) => AuditSala(id: 'sala-${m.id}', name: m.nombre, tipo: m.tipo, fromMaster: true, masterId: m.id);

  group('Puntos de nivel del maestro', () {
    test('se leen el nivel y los niveles del grupo, y sobreviven a la copia local', () {
      expect(rack.nivelGrupo, 1);
      final ng = balde.nivelPunto!;
      expect(ng.grupoId, 'g-racks');
      expect(ng.nivel, 2);
      expect(ng.nombres, ['Rack', 'Balde']);
      expect(ng.niveles[1].identifica, kIdentificaCodigo);
      expect(rack.extra.containsKey('nivelGrupo'), isFalse);
      // La copia guardada en SQLite (blob de sistemas) se vuelve a leer igual.
      final otra = CenterRef.fromRow(centro.toRow());
      expect(otra.sistemas.first.puntosControl[3].nivelPunto!.nombres, ['Rack', 'Balde']);
      // Un punto sin nivel no es de nivel.
      expect(inc.puntosControl.first.nivelPunto, isNull);
    });
  });

  group('La posición de una muestra en el documento', () {
    test('ida y vuelta: viaja en el envío y la marca «de esta tablet» solo en la copia local', () {
      final p = puntoDesdeMaestro(balde, id: 'm1', conEquipos: true);
      expect(anotarNiveles(p, balde.nivelPunto!, const NivelesMuestra(posicion1: 'final', numero1: 'Rack 17', posicion2: 'principio', numero2: 'ov-17')), isNull);
      expect(p.niveles!.map((x) => x.toJson()).toList(), [
        {'nivel': 1, 'posicion': 'final', 'numero': '17'},
        {'nivel': 2, 'posicion': 'principio', 'numero': 'OV17'},
      ]);
      expect(p.nivelesEtiqueta, 'Rack 17 (final) › Balde OV17 (principio)');
      expect(p.nivelesLocal, isTrue);

      final local = PuntoControl.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(local.nivelesMuestra, p.nivelesMuestra);
      expect(local.nivelesLocal, isTrue);
      final envio = p.toJson(ajenas: false);
      expect(envio['niveles'], isNotNull);
      expect(envio['nivelesEtiqueta'], 'Rack 17 (final) › Balde OV17 (principio)');
      expect(envio.containsKey(kLlaveNivelesLocal), isFalse);
      // Sin posición, las llaves no se escriben.
      final sin = puntoDesdeMaestro(rack, id: 'm2', conEquipos: true).toJson(ajenas: false);
      expect(sin.containsKey('niveles'), isFalse);
      expect(sin.containsKey('nivelesEtiqueta'), isFalse);
    });

    test('una copia de la versión anterior (posición en las llaves ajenas) se lee como propia', () {
      final p = PuntoControl.fromJson({
        'id': 'x', 'nombre': 'Racks · Rack · Salida', 'fromMaster': true, 'masterId': 'p-rack-s',
        'niveles': [{'nivel': 1, 'posicion': 'final', 'numero': '17'}], 'nivelesEtiqueta': 'Rack 17 (final)',
      });
      expect(p.extra, isEmpty);
      expect(p.tieneNiveles, isTrue);
      // Viene del servidor: ya no se corrige en la tablet.
      expect(posicionEditable(p), isFalse);
    });

    test('lo que no se entiende no se anota', () {
      final p = puntoDesdeMaestro(rack, id: 'm3', conEquipos: true);
      expect(anotarNiveles(p, rack.nivelPunto!, const NivelesMuestra(posicion1: 'final', numero1: 'R3')), 'En Rack va un número: 1, 2, 3…');
      expect(p.tieneNiveles, isFalse);
      expect(anotarNiveles(p, rack.nivelPunto!, const NivelesMuestra(posicion1: 'final', posicion2: 'medio')),
          'Rack es el último nivel de este punto.');
    });

    test('después de subir, la posición queda de solo lectura (y una copia vieja no la reabre)', () {
      final doc = AuditDocument(salas: [salaDe(inc)]);
      final p = puntoDesdeMaestro(rack, id: 'm4', conEquipos: true);
      doc.salas.first.puntosControl.add(p);
      anotarNiveles(p, rack.nivelPunto!, const NivelesMuestra(posicion1: 'medio', numero1: '3'));
      expect(posicionEditable(p), isTrue);
      final enviada = AuditDocument.fromJson(jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>);
      expect(marcarNivelesEnServidor(enviada, puntosConNiveles(enviada)), 1);
      expect(posicionEditable(enviada.salas.first.puntosControl.first), isFalse);
      // El editor tenía la copia de antes de subir: al guardar, la fila manda.
      conservarNivelesEnServidor(doc, enviada);
      expect(posicionEditable(p), isFalse);
    });
  });

  group('Varias muestras del mismo punto', () {
    test('marcar, «+ Otro rack» con los niveles de arriba y desmarcar todas', () {
      final sala = salaDe(inc);
      var n = 0;
      String id() => 'id${n++}';
      incluirPunto(sala, balde, conEquipos: true, nuevoId: id);
      incluirPunto(sala, balde, conEquipos: true, nuevoId: id); // ya está: no se duplica
      expect(muestrasDe(sala, balde), hasLength(1));
      final primera = muestrasDe(sala, balde).first;
      anotarNiveles(primera, balde.nivelPunto!, const NivelesMuestra(posicion1: 'final', numero1: '17', posicion2: 'principio', numero2: '1844'));
      sala.puntosControl.add(otraMuestra(balde, balde.nivelPunto!, ultima: primera, conEquipos: true, id: id()));
      final l = muestrasDe(sala, balde);
      expect(l, hasLength(2));
      expect(l[1].masterId, 'p-balde-e');
      expect(l[1].nivelesMuestra, const NivelesMuestra(posicion1: 'final', numero1: '17')); // el mismo rack, otro balde
      expect(l[1].nivelesEtiqueta, 'Rack 17 (final)');

      // Quitar la 2.ª deja la 1.ª.
      l[1].isDeleted = true;
      expect(muestrasDe(sala, balde).single, same(primera));
      l[1].isDeleted = false;
      // Desmarcar las quita todas; volver a marcar recupera una (con lo que tenía).
      expect(quitarPunto(sala, balde), 2);
      expect(muestrasDe(sala, balde), isEmpty);
      incluirPunto(sala, balde, conEquipos: true, nuevoId: id);
      expect(muestrasDe(sala, balde).single, same(primera));
      expect(primera.nivelesEtiqueta, 'Rack 17 (final) › Balde 1844 (principio)');
    });

    test('la posición se reutiliza dentro de la evaluación y se avisa la que falta', () {
      final sala = salaDe(inc);
      final doc = AuditDocument(salas: [sala]);
      final a = puntoDesdeMaestro(rack, id: 'r1', conEquipos: true);
      final b = puntoDesdeMaestro(balde, id: 'b1', conEquipos: true);
      sala.puntosControl.addAll([a, b]);
      anotarNiveles(a, rack.nivelPunto!, const NivelesMuestra(posicion1: 'final', numero1: '17'));
      final reuso = reusoDelDocumento(doc, 'g-racks', excepto: b);
      expect(reuso.posicion('g-racks', const NivelesMuestra(numero1: '17'), 1), 'final');
      expect(reuso.chips('g-racks', NivelesMuestra.vacio, 1), [(numero: '17', posicion: 'final')]);
      final faltan = sinPosicion(doc, centro.sistemas);
      expect(faltan.map((x) => x.punto.id), ['b1']);
    });
  });

  group('Nombres con la regla vigente', () {
    test('el tipo va debajo; un tramo por el alias de su equipo lleva el tipo del equipo', () {
      final tramo = inc.puntosControl[1];
      expect(tipoDebajoDef(tramo), 'Estanque Cabecera');
      expect(tipoDebajo(nombre: 'POST UV', tipo: 'Post UV', grupo: 'tramo', equipoAlias: 'UV', equipoTipo: 'UV'), isNull);
      expect(tipoDebajo(nombre: 'POST Bucco', tipo: 'Chiller / Enfriamiento', grupo: 'tramo', equipoAlias: 'Bucco', equipoTipo: 'Chiller / Enfriamiento'),
          'Chiller');
      expect(tipoDebajoDef(inc.puntosControl.first), 'Pre UV');
    });

    test('el nombre de una muestra lleva su posición, como en el informe', () {
      final p = puntoDesdeMaestro(rack, id: 'n1', conEquipos: true);
      expect(nombrePunto(p), 'Racks · Rack · Salida');
      anotarNiveles(p, rack.nivelPunto!, const NivelesMuestra(posicion1: 'final', numero1: '17'));
      expect(nombrePunto(p), 'Racks · Rack · Salida — Rack 17 (final)');
      expect(nombrePunto(p, conPosicion: false), 'Racks · Rack · Salida');
      // Sin foto de la etiqueta (la subió una app vieja), con los números solos.
      p.nivelesEtiqueta = null;
      expect(nombrePunto(p), 'Racks · Rack · Salida — 17 (final)');
      // Un tramo cuyo nombre no dice su equipo.
      expect(nombrePunto(PuntoControl(id: 't', nombre: 'Pre Sala 2°', equipoAlias: 'UV 2')), 'Pre Sala 2° · UV 2');
    });
  });

  group('Sistemas como la lista lateral del editor', () {
    test('por tipo: Afluente, Tratamiento, Proceso, Tratamiento de Salmón, Efluente', () {
      final g = sistemasPorClase(centro.sistemas);
      expect(g.map((x) => x.clase), [kClaseAfluente, kClaseTratamiento, kClaseCultivo, kClaseTratamientoSalmon, kClaseEfluente]);
      expect(g.map((x) => x.sistemas.single.nombre),
          ['Noria', 'Tratamiento Primario', 'Incubación A', 'Torre de Vacunación', 'Efluente']);
      expect(etiquetaClase(null), 'Proceso de Salmón');
    });

    test('la ficha es la etapa o el tipo de agua, nunca «Dulce»', () {
      expect(fichaSistema(inc, conEquipos: true), 'Hatchery');
      expect(fichaSistema(centro.sistemas[2], conEquipos: true), 'Noria');
      expect(fichaSistema(centro.sistemas[1], conEquipos: true), isNull);
      for (final s in centro.sistemas) {
        expect(fichaSistema(s, conEquipos: true), isNot('Dulce'));
      }
    });

    test('los sistemas y los puntos de la evaluación se ordenan como el maestro; los adicionales al final', () {
      final salas = [
        AuditSala(id: 'x', name: 'Adicional'),
        salaDe(centro.sistemas[1]), // efluente
        salaDe(inc),
        salaDe(centro.sistemas[2]), // noria
      ];
      expect(ordenarSalas(salas, centro.sistemas).map((s) => s.name), ['Noria', 'Incubación A', 'Efluente', 'Adicional']);
      final pts = [
        PuntoControl(id: 'adhoc', nombre: 'Algo'),
        puntoDesdeMaestro(balde, id: 'b', conEquipos: true),
        puntoDesdeMaestro(inc.puntosControl.first, id: 'u', conEquipos: true),
        puntoDesdeMaestro(balde, id: 'b2', conEquipos: true),
      ];
      expect(ordenarPuntos(pts, inc).map((p) => p.id), ['u', 'b', 'b2', 'adhoc']);
    });
  });

  test('una evaluación compartida con el cliente lo dice (se finaliza en la web)', () {
    final base = jsonDecode('{"id": "a1", "status": 0, "type": 0, "centerName": "Centro Demo", '
        '"document": {"center": {}, "salas": []}, "createdAtUtc": "2026-10-01T10:00:00Z", '
        '"updatedAtUtc": "2026-10-01T10:00:00Z", "serverVersion": 3}') as Map<String, dynamic>;
    expect(Audit.fromDto(base).compartida, isFalse);
    final compartida = Audit.fromDto({...base, 'sharedWithClientUtc': '2026-10-18T14:03:11.123456+00:00'});
    expect(compartida.compartida, isTrue);
    expect(compartida.compartidaConClienteUtc, isNotNull);
    // No se sube (lo maneja la web) y sobrevive a la copia local.
    expect(compartida.toDto().containsKey('sharedWithClientUtc'), isFalse);
    expect(Audit.fromRow(compartida.toRow()).compartida, isTrue);
  });
}
