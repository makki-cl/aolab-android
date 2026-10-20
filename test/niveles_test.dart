// Posición por nivel en los grupos efímeros: las reglas de la web portadas tal cual. Los casos son los mismos de
// Aolab.Tests (GruposTests: vectores de Normalizar; PosicionPorNivelTests: Revisar, Etiqueta, reutilización).
import 'package:aolab_android/models/niveles.dart';
import 'package:flutter_test/flutter_test.dart';

const rackNumero = NivelGrupoDef(nivel: 1, nombre: 'Rack', identifica: kIdentificaNumero);
const baldeCodigo = NivelGrupoDef(nivel: 2, nombre: 'Balde', identifica: kIdentificaCodigo);
const baldeNumero = NivelGrupoDef(nivel: 2, nombre: 'Balde', identifica: kIdentificaNumero);

/// «Racks 8° · Rack · Salida» (nivel 1) y «Racks 8° · Balde · Entrada» (nivel 2).
NivelPunto punto(int nivel, {String grupo = 'g8'}) =>
    NivelPunto(grupoId: grupo, nivel: nivel, niveles: [rackNumero, baldeNumero].take(nivel).toList());

const p = TramosGrupo.principio, m = TramosGrupo.medio, f = TramosGrupo.finalTramo;

void main() {
  group('El código del miembro (GruposTests.Vectores)', () {
    final vectores = <(NivelGrupoDef, String, String?)>[
      // Rack (número)
      (rackNumero, '3', '3'), (rackNumero, 'Rack 3', '3'), (rackNumero, 'rack 03', '3'), (rackNumero, 'N° 3', '3'),
      (rackNumero, 'Nº 3', '3'), (rackNumero, '#3', '3'), (rackNumero, 'no. 3', '3'), (rackNumero, 'Racks 3', '3'),
      (rackNumero, 'RACK3', '3'),
      (rackNumero, 'R3', null), (rackNumero, 'tres', null), (rackNumero, '0', null), (rackNumero, '10000', null),
      // Balde (código)
      (baldeCodigo, 'Balde 1844', '1844'), (baldeCodigo, ' 1844 ', '1844'),
      (baldeCodigo, 'balde 2750', '2750'), (baldeCodigo, 'Incuabador 2750', '2750'), (baldeCodigo, 'incubador 2750', '2750'),
      (baldeCodigo, 'OV 17', 'OV17'), (baldeCodigo, 'ov-17', 'OV17'), (baldeCodigo, 'Incubador OV17', 'OV17'),
      (baldeCodigo, 'Bateas 12', '12'), (baldeCodigo, 'bálde ñ-7', 'N7'),
      // Balde (número)
      (baldeNumero, 'Balde 3', '3'), (baldeNumero, '3', '3'),
      // Cualquiera, vacío
      (rackNumero, '', null), (rackNumero, '---', null), (baldeCodigo, '', null), (baldeCodigo, '---', null),
      (baldeCodigo, 'Balde', null), (baldeCodigo, '123456789012345678901', null),
    ];
    for (final (nivel, texto, clave) in vectores) {
      test('${nivel.nombre}/${nivel.identifica} «$texto» → ${clave ?? 'error'}', () {
        final r = normalizarCodigo(nivel, texto);
        expect(r.clave, clave);
        expect(r.error == null, clave != null);
        // Lo normalizado ya está normalizado (idempotente).
        if (clave != null) expect(normalizarCodigo(nivel, clave).clave, clave);
      });
    }

    test('los errores dicen qué escribir', () {
      expect(normalizarCodigo(rackNumero, 'R3').error, 'En Rack va un número: 1, 2, 3…');
      expect(normalizarCodigo(baldeCodigo, '---').error, 'Escribe el código del Balde.');
      expect(normalizarCodigo(const NivelGrupoDef(nivel: 1, nombre: 'Batea', identifica: kIdentificaCodigo), '').error,
          'Escribe el código de la Batea.');
      expect(normalizarCodigo(baldeCodigo, '7' * 21).error, 'El código del Balde tiene a lo más 20 caracteres.');
      // Un nombre de 1 o 2 letras va pegado a su clave: «E7» es el 7 de los estanques E.
      expect(normalizarCodigo(const NivelGrupoDef(nivel: 1, nombre: 'E'), 'E7').clave, '7');
    });

    test('el nombre de un nivel con número («Rack 8°») también se reconoce', () {
      const rack8 = NivelGrupoDef(nivel: 1, nombre: 'Rack 8°');
      expect(normalizarCodigo(rack8, '17').clave, '17');
      expect(normalizarCodigo(rack8, 'Rack 17').clave, '17');
    });
  });

  group('La posición (PosicionPorNivelTests)', () {
    test('se pide hasta el nivel del punto; el número es opcional y se normaliza', () {
      // Fila 21 del traspaso: «Efluente Rack 1» = salida de un rack, sin balde.
      var r = PosicionesNivel.revisar(punto(1), const NivelesMuestra(posicion1: p, numero1: 'Rack 1'));
      expect(r.error, isNull);
      expect(r.niveles, const NivelesMuestra(posicion1: p, numero1: '1'));
      expect(PosicionesNivel.etiqueta(punto(1).nombres, r.niveles), 'Rack 1 (principio)');
      // Sin número también vale: lo que manda es la posición.
      expect(PosicionesNivel.revisar(punto(1), const NivelesMuestra(posicion1: f)).error, isNull);
      expect(PosicionesNivel.etiqueta(['Rack'], const NivelesMuestra(posicion1: f)), 'Rack (final)');

      // Fila 20: entrada de un balde: nivel 1 y nivel 2.
      r = PosicionesNivel.revisar(
          punto(2), const NivelesMuestra(posicion1: f, numero1: '17', posicion2: p, numero2: 'Balde 1844'));
      expect(r.error, isNull);
      expect(PosicionesNivel.etiqueta(punto(2).nombres, r.niveles), 'Rack 17 (final) › Balde 1844 (principio)');

      // Falta una posición, sobra un nivel o el número no sirve: no se guarda.
      expect(PosicionesNivel.revisar(punto(2), const NivelesMuestra(posicion1: f, numero1: '17', numero2: '1844')).error,
          'Falta la posición del balde: principio, medio o final.');
      expect(PosicionesNivel.revisar(punto(1), const NivelesMuestra(posicion1: f, numero1: '17', posicion2: m)).error,
          'Rack es el último nivel de este punto: no lleva nivel 2.');
      expect(PosicionesNivel.revisar(punto(1), const NivelesMuestra(posicion1: f, numero1: 'OV17')).error,
          'En Rack va un número: 1, 2, 3…');
      expect(PosicionesNivel.revisar(punto(1), const NivelesMuestra(posicion1: 'arriba', numero1: '1')).error, isNotNull);
      // Vacía es «sin posición»: se acepta.
      expect(PosicionesNivel.revisar(punto(2), NivelesMuestra.vacio).error, isNull);
    });

    test('la etiqueta sin nombres usa el número solo y se recorta a 200', () {
      expect(PosicionesNivel.etiqueta(null, const NivelesMuestra(posicion1: f, numero1: '17', posicion2: p, numero2: '1844')),
          '17 (final) › 1844 (principio)');
      expect(PosicionesNivel.etiqueta(['E'], const NivelesMuestra(posicion1: m, numero1: '7')), 'E7 (medio)');
      final larga = PosicionesNivel.foto(['R' * 300], const NivelesMuestra(posicion1: f));
      expect(larga!.length, 200);
    });

    test('en el mismo muestreo la posición de un rack ya anotado se reutiliza y no se acepta otra', () {
      // La 2999: «Efluente Rack 17» ya se anotó como final.
      final reuso = ReusoNiveles([
        (grupoId: 'g8', niveles: const NivelesMuestra(posicion1: f, numero1: '17')),
        (grupoId: 'g8', niveles: const NivelesMuestra(posicion1: p, numero1: '1')),
        (grupoId: 'otro', niveles: const NivelesMuestra(posicion1: m, numero1: '17')),
      ]);
      final n = reuso.completar('g8', const NivelesMuestra(numero1: '17', posicion2: p, numero2: '1844'));
      expect(n, const NivelesMuestra(posicion1: f, numero1: '17', posicion2: p, numero2: '1844'));
      expect(PosicionesNivel.revisar(punto(2), n).error, isNull);
      expect(reuso.chips('g8', NivelesMuestra.vacio, 1), [(numero: '1', posicion: p), (numero: '17', posicion: f)]);
      expect(reuso.chips('otro', NivelesMuestra.vacio, 1), [(numero: '17', posicion: m)]);
      // Sin número no hay identidad: se pide.
      expect(reuso.completar('g8', const NivelesMuestra(posicion2: p)), const NivelesMuestra(posicion2: p));
      // El mismo rack con otra posición en el mismo muestreo no se acepta.
      expect(
          reuso.conflicto('g8', const NivelesMuestra(posicion1: m, numero1: '17'), ['Rack']),
          'Rack 17 ya está anotado como Final en este muestreo: un mismo rack tiene una sola posición. '
          'Cámbiala en todas sus muestras o corrige esta.');
      expect(
          reuso.conflicto('g8', const NivelesMuestra(posicion1: f, numero1: '17', posicion2: m, numero2: '9'), ['Rack', 'Balde']),
          isNull);

      // Un balde ya anotado dentro del Rack 17: lo mismo, dentro de su padre.
      final conBalde =
          ReusoNiveles([(grupoId: 'g8', niveles: const NivelesMuestra(posicion1: f, numero1: '17', posicion2: p, numero2: '1844'))]);
      expect(conBalde.chips('g8', const NivelesMuestra(posicion1: f, numero1: '17'), 2), [(numero: '1844', posicion: p)]);
      expect(conBalde.chips('g8', const NivelesMuestra(posicion1: f, numero1: '3'), 2), isEmpty);
      expect(conBalde.posicion('g8', const NivelesMuestra(numero1: '17', numero2: '1844'), 2), p);

      // Otro muestreo no reutiliza nada.
      expect(ReusoNiveles(const []).posicion('g8', const NivelesMuestra(numero1: '17'), 1), isNull);

      // «Cambiar en todas»: la otra muestra del Rack 17 toma la posición nueva; la de otro rack no cambia.
      const nueva = NivelesMuestra(posicion1: m, numero1: '17');
      expect(ReusoNiveles.alinear(const NivelesMuestra(posicion1: f, numero1: '17', posicion2: p, numero2: '1844'), nueva),
          const NivelesMuestra(posicion1: m, numero1: '17', posicion2: p, numero2: '1844'));
      expect(ReusoNiveles.alinear(const NivelesMuestra(posicion1: p, numero1: '1'), nueva), const NivelesMuestra(posicion1: p, numero1: '1'));
    });

    test('el orden natural pone 2 antes que 10 y los códigos después', () {
      final l = ['10', 'OV1', '2', '1'];
      l.sort(compararClaves);
      expect(l, ['1', '2', '10', 'OV1']);
    });
  });
}
