/// Plantilla del cuestionario (viene de /api/questionnaire/template).
class QuestionnaireTemplate {
  final String code;
  final String title;
  final List<TemplateSection> sections;

  QuestionnaireTemplate({required this.code, required this.title, required this.sections});

  List<TemplateSection> get centerSections => sections.where((s) => s.isCenter).toList();
  List<TemplateSection> get salaSections => sections.where((s) => !s.isCenter).toList();

  factory QuestionnaireTemplate.fromJson(Map<String, dynamic> j) => QuestionnaireTemplate(
        code: (j['code'] ?? '') as String,
        title: (j['title'] ?? '') as String,
        sections: ((j['sections'] ?? []) as List)
            .map((s) => TemplateSection.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class TemplateSection {
  final String code;
  final String name;
  final String scope; // "center" | "sala"
  final List<TemplateQuestion> questions;

  TemplateSection({required this.code, required this.name, required this.scope, required this.questions});

  bool get isCenter => scope.toLowerCase() == 'center';

  factory TemplateSection.fromJson(Map<String, dynamic> j) => TemplateSection(
        code: (j['code'] ?? '') as String,
        name: (j['name'] ?? '') as String,
        scope: (j['scope'] ?? 'sala') as String,
        questions: ((j['questions'] ?? []) as List)
            .map((q) => TemplateQuestion.fromJson(q as Map<String, dynamic>))
            .toList(),
      );
}

class TemplateQuestion {
  final String code;
  final String text;
  final String help;

  TemplateQuestion({required this.code, required this.text, required this.help});

  factory TemplateQuestion.fromJson(Map<String, dynamic> j) => TemplateQuestion(
        code: (j['code'] ?? '') as String,
        text: (j['text'] ?? '') as String,
        help: (j['help'] ?? '') as String,
      );
}
