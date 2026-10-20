import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/app_database.dart';
import '../models/questionnaire.dart';
import 'api_client.dart';

/// Provee la plantilla del cuestionario: la cachea localmente para poder llenar
/// auditorías sin conexión, y la refresca desde la API cuando hay red.
class TemplateService extends ChangeNotifier {
  final AppDatabase db;
  final ApiClient api;

  QuestionnaireTemplate? template;

  TemplateService({required this.db, required this.api});

  bool get isLoaded => template != null;

  /// La caché y después la red (para quien necesita la plantilla al día antes de seguir).
  Future<void> load() async {
    await cargarLocal();
    await refrescar();
  }

  /// Solo la caché local: es al tiro y no depende de la señal.
  Future<void> cargarLocal() async {
    final cached = await db.getValue('template');
    if (cached == null) return;
    try {
      template = QuestionnaireTemplate.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      notifyListeners();
    } catch (_) {/* una caché ilegible se reemplaza en el próximo refresco */}
  }

  /// La plantilla del servidor, si hay red. Sin señal se queda la de la caché.
  Future<void> refrescar() async {
    try {
      final res = await api.dio.get('/api/questionnaire/template');
      template = QuestionnaireTemplate.fromJson(res.data as Map<String, dynamic>);
      await db.setValue('template', jsonEncode(res.data));
      notifyListeners();
    } on DioException {
      // sin red: nos quedamos con la caché si existe
    } catch (_) {
      // una respuesta que no se entiende tampoco borra la caché
    }
  }
}
