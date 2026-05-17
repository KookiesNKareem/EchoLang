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

class GemmaBenchResult {
  final Duration firstTokenLatency;
  final Duration totalDuration;
  final int approxTokens;
  final double tokensPerSec;
  final String output;
  const GemmaBenchResult({
    required this.firstTokenLatency,
    required this.totalDuration,
    required this.approxTokens,
    required this.tokensPerSec,
    required this.output,
  });
}

class GemmaService {
  /// Public, ungated MTP-enabled mirror of Gemma 4 E2B (LiteRT). MTP =
  /// Multi-Token Prediction (Google blog post 2026-05): a tiny drafter
  /// model rides along with the main weights and predicts 2-4 future
  /// tokens at once, then the target verifies them in parallel. ~2x speedup
  /// on Q&A + study-pack generation, zero accuracy loss because the target
  /// model still does final verification.
  ///
  /// Same file size (~2.58 GB) as the non-MTP variant since the drafter is
  /// tiny. 64k context is more than enough for our lecture transcripts.
  /// Plain (non-MTP) fallback if this disappears:
  /// samirsayyed/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm
  static const String modelUrl = String.fromEnvironment(
    'MODEL_URL',
    defaultValue:
        'https://huggingface.co/metricspace/gemma4-E2B-it-litert-64k-mtp/resolve/main/model.litertlm',
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
  // Identity of the transcript currently primed into [_chat], so we know
  // when a fresh prime is needed vs. when we can reuse the existing chat
  // session and skip prefilling the lecture transcript again.
  int? _primedContextHash;

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
      // fileType MUST be litertlm for our .litertlm file — flutter_gemma
      // defaults to .task and routes through MediaPipe's parser, which
      // would crash on init when it sees the litertlm container.
      final builder = FlutterGemma.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      );
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
      // Download is done but model isn't usable yet — getActiveModel maps a
      // 2.6 GB file into memory, can take 10-30s on iPhone. Broadcast a
      // distinct status so the banner doesn't sit at 100% silently.
      _statusMessage = 'Loading Gemma 4 into memory…';
      for (final l in _listeners) {
        l(null, _statusMessage!);
      }
      _model = await FlutterGemma.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );
      _chat = await _model!.createChat();
      _status = GemmaStatus.ready;
      _statusMessage = 'Gemma 4 ready';
      for (final l in _listeners) {
        l(1.0, _statusMessage!);
      }
    } catch (e) {
      _status = GemmaStatus.error;
      _statusMessage = 'Failed to load Gemma 4: $e';
      _readyFuture = null;
      rethrow;
    }
  }

  /// Prime the chat with a lecture transcript so the ~6000-char prefill is
  /// paid once instead of on every question. No-op if the same transcript is
  /// already primed.
  ///
  /// Internally we still need to actually push the preamble through the
  /// model to fill the KV cache — `addQueryChunk` alone just buffers
  /// client-side, MediaPipe defers prefill until the first generate call.
  /// We force prefill by appending a trivial "Reply with the single word
  /// ready." prompt and discarding the answer.
  Future<void> primeContext(String lectureContext) async {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final trimmed = _trimContext(lectureContext);
    final hash = trimmed.hashCode;
    if (_primedContextHash == hash && _chat != null) return;
    final preamble =
        'You are a tutor helping a student review a lecture they attended. '
        'Use only what is in the transcript below. If the answer is not in '
        'the transcript, say so plainly. Reply in the same language the '
        'student used.\n\n--- LECTURE TRANSCRIPT ---\n$trimmed\n--- END ---\n\n'
        'Reply with the single word ready.';
    _chat = await _model!.createChat();
    await _chat!.addQueryChunk(Message.text(text: preamble, isUser: true));
    await _chat!.generateChatResponse();
    _primedContextHash = hash;
  }

  /// Ask a question and stream the answer token-by-token. The first call for
  /// a given transcript pays the prefill cost; subsequent calls within the
  /// same session reuse the primed chat and skip re-encoding the transcript.
  Stream<String> askStream({
    required String lectureContext,
    required String question,
  }) async* {
    await primeContext(lectureContext);
    await _chat!.addQueryChunk(Message.text(text: question, isUser: true));
    await for (final chunk in _chat!.generateChatResponseAsync()) {
      switch (chunk) {
        case TextResponse(:final token):
          yield token;
        case ThinkingResponse(:final content):
          yield content;
        default:
          // Function-call responses aren't used in plain lecture Q&A; ignore.
          break;
      }
    }
  }

  /// Convenience wrapper for callers that only need the full answer.
  Future<String> ask({required String lectureContext, required String question}) async {
    final buf = StringBuffer();
    await for (final t in askStream(lectureContext: lectureContext, question: question)) {
      buf.write(t);
    }
    return buf.toString().trim();
  }

  /// Streaming benchmark variant of [ask].
  ///
  /// When [freshChat] is true (legacy baseline): re-seeds a brand new chat
  /// with the full preamble each call, which re-pays prefill of the
  /// transcript every question. Used to A/B against the primed-chat path.
  ///
  /// When [freshChat] is false (default, prod path): primes the lecture
  /// context once via [primeContext] and reuses the persistent chat session
  /// for every subsequent benchAsk on the same transcript.
  Future<GemmaBenchResult> benchAsk({
    required String lectureContext,
    required String question,
    bool freshChat = false,
  }) async {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final InferenceChat chat;
    if (freshChat) {
      final trimmed = _trimContext(lectureContext);
      final preamble =
          'You are a tutor helping a student review a lecture they attended. '
          'Use only what is in the transcript below. If the answer is not in '
          'the transcript, say so plainly.\n\n--- LECTURE TRANSCRIPT ---\n$trimmed\n--- END ---';
      chat = await _model!.createChat();
      await chat.addQueryChunk(Message.text(text: preamble, isUser: true));
      await chat.addQueryChunk(Message.text(text: question, isUser: true));
    } else {
      await primeContext(lectureContext);
      chat = _chat!;
      await chat.addQueryChunk(Message.text(text: question, isUser: true));
    }

    final sw = Stopwatch()..start();
    Duration? firstChunkAt;
    final buf = StringBuffer();
    var tokenCount = 0;
    await for (final chunk in chat.generateChatResponseAsync()) {
      firstChunkAt ??= sw.elapsed;
      // Each streamed event is one decoded token (TextResponse) or a thinking
      // fragment we still want to time. Counting events = real token count;
      // the chars/4 heuristic in the previous version was inflated 5-10×.
      switch (chunk) {
        case TextResponse(:final token):
          buf.write(token);
          tokenCount += 1;
        case ThinkingResponse(:final content):
          buf.write(content);
          tokenCount += 1;
        default:
          // Function calls etc. — rare in plain Q&A; still count as one event.
          tokenCount += 1;
      }
    }
    sw.stop();
    final total = sw.elapsed;
    final decodeDur = (total - (firstChunkAt ?? total));
    final decodeSecs = decodeDur.inMicroseconds / 1e6;
    final tps = decodeSecs > 0 ? tokenCount / decodeSecs : 0.0;
    return GemmaBenchResult(
      firstTokenLatency: firstChunkAt ?? Duration.zero,
      totalDuration: total,
      approxTokens: tokenCount,
      tokensPerSec: tps,
      output: buf.toString(),
    );
  }

  /// On-device translation. Streams the translated text token-by-token.
  /// Runs in a fresh chat session so it doesn't clobber the primed Q&A chat
  /// for whichever lecture is currently open.
  Stream<String> translateStream({
    required String text,
    required String targetLanguageName,
  }) async* {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final prompt =
        'Translate the following English text into $targetLanguageName. '
        'Preserve sentence boundaries and paragraph breaks. Output ONLY the '
        'translated text — no preface, no commentary, no "Sure, here is...".'
        '\n\nEnglish:\n$text\n\n$targetLanguageName:';
    final chat = await _model!.createChat();
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    await for (final chunk in chat.generateChatResponseAsync()) {
      switch (chunk) {
        case TextResponse(:final token):
          yield token;
        case ThinkingResponse(:final content):
          yield content;
        default:
          break;
      }
    }
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
    _primedContextHash = null;
    _model?.close();
    _model = null;
    _readyFuture = null;
    _status = GemmaStatus.notReady;
  }

  /// Drop the current chat session but keep the loaded model. Forces the
  /// next ask/benchAsk to re-prime its context from scratch.
  void unloadChat() {
    _chat = null;
    _primedContextHash = null;
  }

  // ---- helpers ----

  String _extractText(dynamic response) {
    if (response is String) return response.trim();
    if (response is TextResponse) return response.token.trim();
    if (response is ThinkingResponse) return response.content.trim();
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
