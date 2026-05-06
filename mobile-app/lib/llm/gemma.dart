// On-device Gemma 4 E2B via flutter_gemma (MediaPipe GenAI / LiteRT).
//
// Why flutter_gemma instead of cactus: Cactus 1.3.0's published model
// catalog tops out at Gemma 3 — their Gemma 4 support is in an internal
// v1.12 build that hasn't reached pub.dev. The hackathon is *Gemma 4
// Good Hackathon*, so Gemma 3 disqualifies us. flutter_gemma 0.14.5
// supports ModelType.gemma4 against the official litert-community
// Gemma 4 E2B/E4B builds and runs on iOS via MediaPipe GenAI's LiteRT
// runtime — which also makes us a clean fit for the LiteRT $10k prize.

import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../data/models.dart';

enum GemmaStatus { notReady, downloading, ready, error }

class GemmaService {
  /// Public, ungated mirror of Google's Gemma 4 E2B LiteRT model. We use a
  /// community mirror so end-users don't need a HuggingFace account, license
  /// acceptance, or read token — the original litert-community repo is
  /// gated. Override at build time with --dart-define=MODEL_URL=... to point
  /// to your own mirror (e.g. for production reliability).
  ///
  /// Verified ungated 2026-05-05 with 11k+ downloads. If this URL ever
  /// disappears, equivalent files exist at huggingworld/, guoziwei93/, and
  /// the gated upstream litert-community/gemma-4-E2B-it-litert-lm.
  static const String modelUrl = String.fromEnvironment(
    'MODEL_URL',
    defaultValue:
        'https://huggingface.co/samirsayyed/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
  );

  /// Optional HF token. Only needed if MODEL_URL points to a gated repo.
  /// Default mirror is public, so no token required for normal use.
  static const String hfToken = String.fromEnvironment('HF_TOKEN');

  GemmaStatus _status = GemmaStatus.notReady;
  GemmaStatus get status => _status;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  double? _progress;
  double? get downloadProgress => _progress;

  InferenceModel? _model;
  InferenceChat? _chat;

  Future<void>? _readyFuture;
  final List<void Function(double? progress, String status)> _listeners = [];

  Future<void> ensureReady({void Function(double? progress, String status)? onProgress}) {
    if (onProgress != null) _listeners.add(onProgress);
    return _readyFuture ??= _load();
  }

  Future<void> _load() async {
    if (_status == GemmaStatus.ready) return;
    _status = GemmaStatus.downloading;
    try {
      // Initialize is required even without a token — flutter_gemma uses it
      // to set up its service registry. Pass an empty string when public.
      await FlutterGemma.initialize(huggingFaceToken: hfToken.isEmpty ? null : hfToken);
      // installModel is a no-op if the model is already on disk.
      final builder = FlutterGemma.installModel(modelType: ModelType.gemma4);
      final fromNetwork = hfToken.isEmpty
          ? builder.fromNetwork(modelUrl)
          : builder.fromNetwork(modelUrl, token: hfToken);
      await fromNetwork
          .withProgress((p) {
            final fraction = p / 100.0;
            _progress = fraction;
            _statusMessage = 'Downloading Gemma 4 E2B ($p%)';
            for (final l in _listeners) {
              l(fraction, _statusMessage!);
            }
          })
          .install();
      _model = await FlutterGemma.getActiveModel(maxTokens: 2048);
      _chat = await _model!.createChat();
      _status = GemmaStatus.ready;
      _statusMessage = 'Gemma 4 ready';
    } catch (e) {
      _status = GemmaStatus.error;
      _statusMessage = 'Failed to load Gemma 4: $e';
      _readyFuture = null;
      rethrow;
    }
  }

  /// Ask a question grounded in the lecture transcript. We seed a fresh chat
  /// with a system-style instruction + transcript, then send the user
  /// question — Gemma's chat session keeps history across calls within a
  /// single Q&A flow.
  Future<String> ask({required String lectureContext, required String question}) async {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final trimmed = _trimContext(lectureContext);
    final preamble =
        'You are a tutor helping a student review a lecture they attended. '
        'Use only what is in the transcript below. If the answer is not in '
        'the transcript, say so plainly. Reply in the same language the '
        'student used.\n\n--- LECTURE TRANSCRIPT ---\n$trimmed\n--- END ---';
    // Fresh chat per question keeps memory bounded; the transcript fits in
    // context easily for typical lecture lengths.
    _chat = await _model!.createChat();
    await _chat!.addQueryChunk(Message.text(text: preamble, isUser: true));
    await _chat!.addQueryChunk(Message.text(text: question, isUser: true));
    final response = await _chat!.generateChatResponse();
    return _extractText(response);
  }

  Future<StudyPack> generateStudyPack({required String transcript, String lang = 'en'}) async {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final prompt = _studyPackPrompt(_trimContext(transcript));
    final chat = await _model!.createChat();
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final response = await chat.generateChatResponse();
    final raw = _extractText(response);
    final json = _extractJson(raw);
    return StudyPack(
      lang: lang,
      summary: (json['summary'] as String?) ?? raw,
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

  void unload() {
    _chat = null;
    _model?.close();
    _model = null;
    _readyFuture = null;
    _status = GemmaStatus.notReady;
  }

  // ---- helpers ----

  String _extractText(dynamic response) {
    if (response is String) return response.trim();
    try {
      final t = (response as dynamic).text;
      if (t is String) return t.trim();
    } catch (_) {}
    return response.toString().trim();
  }

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
    return '${ctx.substring(0, 3000)}\n[…middle of lecture omitted…]\n${ctx.substring(ctx.length - 3000)}';
  }
}
