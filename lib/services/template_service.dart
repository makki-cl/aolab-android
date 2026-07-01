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

  Future<void> load() async {
    // 1) caché local (offline-first)
    final cached = await db.getValue('template');
    if (cached != null) {
      template = QuestionnaireTemplate.fromJson(jsonDecode(cached) as Map<String, dynamic>);
      notifyListeners();
    }
    // 2) refresco desde la red (si se puede)
    try {
      final res = await api.dio.get('/api/questionnaire/template');
      template = QuestionnaireTemplate.fromJson(res.data as Map<String, dynamic>);
      await db.setValue('template', jsonEncode(res.data));
      notifyListeners();
    } on DioException {
      // sin red: nos quedamos con la caché si existe
    }
  }
}
