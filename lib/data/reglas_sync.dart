/// Reglas de la sincronización que no dependen de SQLite, para poder probarlas sin base.
///
/// Son las de `pendientes-app-sync.md` (10-10-2026): el servidor ya mezcla campo por campo contra la copia que tenía
/// cada tablet y no pierde nada de lo que le llega; lo que todavía se podía perder era lo que nunca salía de la tablet,
/// por cómo la app marcaba y pisaba sus filas locales.
library;

import '../models/audit.dart';

/// Qué le queda a una fila local cuando vuelve la respuesta del push.
class MarcaSincronizada {
  /// Sigue pendiente de subir: se editó mientras el envío iba y volvía, y eso no llegó al servidor.
  final bool dirty;

  /// El folio que queda en la fila.
  final int? folio;

  const MarcaSincronizada({required this.dirty, required this.folio});
}

/// La fila se marca sincronizada solo si sigue igual a lo que se mandó ([revEnviada] = [revActual]). Si cambió, queda
/// pendiente: si no, el pull del mismo ciclo la pisaba con la copia del servidor y lo editado se perdía sin aviso.
///
/// El folio lo escribe el evaluador, pero el servidor lo arbitra (otra evaluación puede tenerlo): se copia el de la
/// respuesta tal cual viene, también nulo, salvo que el evaluador lo haya cambiado mientras tanto (ese no llegó al
/// servidor y pisarlo lo perdía). Es lo mismo que hace el editor offline (`SyncService.PushAsync`, «editadaMientras»).
MarcaSincronizada marcaSincronizada({
  required int revEnviada,
  required int revActual,
  required int? folioEnviado,
  required int? folioActual,
  required int? folioRespuesta,
}) {
  final editadaMientras = revActual != revEnviada;
  final folio = editadaMientras && folioActual != folioEnviado ? folioActual : folioRespuesta;
  return MarcaSincronizada(dirty: editadaMientras, folio: folio);
}

/// Todas las evidencias (fotos y audios) del documento.
Iterable<Evidencia> evidenciasDe(AuditDocument doc) sync* {
  for (final s in doc.salas) {
    for (final p in s.puntosControl) {
      yield* p.fotos;
      yield* p.audios;
    }
  }
}

/// Marca como subidas las evidencias [ids] del documento. Devuelve cuántas cambiaron.
int marcarSubidas(AuditDocument doc, Set<String> ids) {
  var cambiadas = 0;
  for (final ev in evidenciasDe(doc)) {
    if (!ev.uploaded && ids.contains(ev.id)) {
      ev.uploaded = true;
      cambiadas++;
    }
  }
  return cambiadas;
}

/// «Subida» solo pasa de no a sí. Lo que la fila guardada ya tiene subido no lo deshace una copia en memoria más vieja
/// (el editor abierto mientras la sincronización subía sus fotos): si lo deshiciera, la foto se volvería a subir entera
/// en cada ciclo.
void conservarSubidas(AuditDocument destino, AuditDocument guardado) {
  final subidas = {
    for (final ev in evidenciasDe(guardado))
      if (ev.uploaded) ev.id,
  };
  if (subidas.isNotEmpty) marcarSubidas(destino, subidas);
}

/// Las muestras de [doc] cuya posición por nivel ya está en el servidor: el envío que la llevaba volvió aplicado (si el
/// servidor no tenía una, quedó esta; si tenía, conservó la suya). Desde ahí se corrige en la web.
Set<String> puntosConNiveles(AuditDocument doc) => {
      for (final s in doc.salas)
        for (final p in s.puntosControl)
          if (p.tieneNiveles) p.id,
    };

/// Marca como ya en el servidor la posición de los puntos [ids]. Devuelve cuántos cambiaron.
int marcarNivelesEnServidor(AuditDocument doc, Set<String> ids) {
  var n = 0;
  for (final s in doc.salas) {
    for (final p in s.puntosControl) {
      if (p.nivelesLocal && ids.contains(p.id)) {
        p.nivelesLocal = false;
        n++;
      }
    }
  }
  return n;
}

/// Lo que la fila guardada ya tiene en el servidor no vuelve a ser «de esta tablet» por una copia en memoria más vieja
/// (el editor abierto mientras subía): si volviera, la tablet dejaría corregir una posición que el servidor ya no acepta.
void conservarNivelesEnServidor(AuditDocument destino, AuditDocument guardado) {
  final enServidor = {
    for (final s in guardado.salas)
      for (final p in s.puntosControl)
        if (p.tieneNiveles && !p.nivelesLocal) p.id,
  };
  if (enServidor.isNotEmpty) marcarNivelesEnServidor(destino, enServidor);
}

/// ¿A esta evaluación le queda algo que ESTA tablet tiene que subir? Cambios sin subir, o una foto o un audio sin subir
/// cuyo archivo está aquí. Una evidencia que llegó «sin subir» en el documento de otro equipo (su foto no alcanzó a subir
/// allá) no es de esta tablet: no la puede subir y no debe dejarla «por subir» para siempre ni impedir el cambio de
/// usuario. Sin [enEstaTablet], cuenta todas (como antes).
bool quedaPorSubir(Audit a, {bool Function(String evidenciaId)? enEstaTablet}) =>
    a.dirty ||
    evidenciasDe(a.document).any((e) => !e.uploaded && !e.isDeleted && (enEstaTablet == null || enEstaTablet(e.id)));

/// El mensaje del servidor (`SeccionesAuditoria.AmbasDesactivadas`): para finalizar hace falta el RPN o el laboratorio.
const String kAmbasDesactivadas =
    'Para finalizar, marca la evaluación de terreno (RPN) o el laboratorio (BQ/FC): sin ninguna de las dos, '
    'la evaluación no tiene nada que informar.';

/// La regla de la web para finalizar: null si vale; si no, el mensaje.
String? validarSecciones(AuditDocument d) => (!d.aplicaRpn && !d.aplicaLab) ? kAmbasDesactivadas : null;
