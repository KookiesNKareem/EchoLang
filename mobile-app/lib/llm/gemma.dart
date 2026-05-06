// On-device Gemma 4 E2B via Cactus.
//
// First app launch downloads Cactus's pre-quantized Gemma 4 E2B build
// (~1-2 GB) from HuggingFace via the Cactus model registry. Subsequent
// launches reuse the cached model from local storage.
//
// All Q&A is grounded in the lecture transcript injected as system context
// — the model answers about *this* lecture, not its general knowledge.

import 'dart:convert';

import 'package:cactus/cactus.dart';

import '../data/models.dart';

/// Status of the on-device model.
enum GemmaStatus { notReady, downloading, ready, error }

class GemmaService {
  static const String modelId = 'google/gemma-4-E2B-it';

  final CactusLM _lm = CactusLM();
  GemmaStatus _status = GemmaStatus.notReady;
  GemmaStatus get status => _status;

  double? _progress; // 0..1 while downloading
  double? get downloadProgress => _progress;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  /// Ensure the model is downloaded and initialized. Idempotent — safe to
  /// call from multiple screens; subsequent calls return immediately if
  /// the model is already loaded.
  Future<void> ensureReady({void Function(double? progress, String status)? onProgress}) async {
    if (_status == GemmaStatus.ready) return;
    _status = GemmaStatus.downloading;
    try {
      await _lm.downloadModel(
        model: modelId,
        downloadProcessCallback: (progress, status, isError) {
          _progress = progress;
          _statusMessage = status;
          onProgress?.call(progress, status);
          if (isError) _status = GemmaStatus.error;
        },
      );
      await _lm.initializeModel();
      _status = GemmaStatus.ready;
      _statusMessage = 'Model ready';
    } catch (e) {
      _status = GemmaStatus.error;
      _statusMessage = 'Failed to load model: $e';
      rethrow;
    }
  }

  /// Ask a question grounded in the lecture transcript.
  /// Returns the full answer (Cactus's generateCompletion is non-streaming;
  /// we surface it all at once when the model finishes generating).
  Future<String> ask({required String lectureContext, required String question}) async {
    if (_status != GemmaStatus.ready) {
      throw StateError('Gemma model not ready (status=$_status)');
    }
    final trimmedContext = _trimContext(lectureContext);
    final messages = <ChatMessage>[
      ChatMessage(
        role: 'system',
        content:
            'You are a tutor helping a student review a lecture they attended. '
            'Answer using only what is in the transcript below. If the answer '
            'is not in the transcript, say so plainly. Reply in the same '
            'language the student used.\n\n'
            '--- LECTURE TRANSCRIPT ---\n$trimmedContext\n--- END TRANSCRIPT ---',
      ),
      ChatMessage(role: 'user', content: question),
    ];
    final result = await _lm.generateCompletion(messages: messages);
    if (!result.success) {
      throw Exception('Gemma generation failed');
    }
    return result.response.trim();
  }

  /// Generate a study pack from a transcript, fully on-device.
  ///
  /// Used in personal record mode (no Pi). Asks Gemma for summary +
  /// key terms + practice questions in a single JSON response.
  Future<StudyPack> generateStudyPack({required String transcript, String lang = 'en'}) async {
    if (_status != GemmaStatus.ready) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final trimmed = _trimContext(transcript);
    final prompt = _studyPackPrompt(trimmed);
    final result = await _lm.generateCompletion(messages: [
      ChatMessage(role: 'user', content: prompt),
    ]);
    if (!result.success) {
      throw Exception('Gemma generation failed');
    }
    final json = _extractJson(result.response);
    return StudyPack(
      lang: lang,
      summary: (json['summary'] as String?) ?? result.response.trim(),
      keyTerms: ((json['key_terms'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => KeyTerm(
                term: (m['term'] as String?) ?? '',
                definition: (m['definition'] as String?) ?? '',
              ))
          .toList(),
      practiceQuestions: ((json['practice_questions'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  void unload() => _lm.unload();

  String _studyPackPrompt(String transcript) => '''
You are an academic tutor. Below is a transcript of a recorded lecture.
Produce a study pack with three sections, in JSON.

Transcript:
"""
$transcript
"""

Respond with strict JSON in this exact shape (no commentary, no code fence):
{
  "summary": "3-5 sentences summarizing what was taught",
  "key_terms": [
    {"term": "term name", "definition": "one-sentence definition"}
  ],
  "practice_questions": [
    "first practice question",
    "second practice question"
  ]
}

Use 5-10 key_terms and 5-8 practice_questions.

JSON:
''';

  Map<String, dynamic> _extractJson(String raw) {
    final match = RegExp(r'\{.*\}', dotAll: true).firstMatch(raw);
    if (match == null) return const {};
    try {
      return jsonDecode(match.group(0)!) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  String _trimContext(String ctx) {
    if (ctx.length <= 6000) return ctx;
    return ctx.substring(0, 3000) +
        '\n[…middle of lecture omitted…]\n' +
        ctx.substring(ctx.length - 3000);
  }
}
