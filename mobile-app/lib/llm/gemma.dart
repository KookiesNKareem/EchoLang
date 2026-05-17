import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../data/models.dart';

enum GemmaStatus { notReady, downloading, ready, error }

/// Localized Q&A starter content for whatever language the lecture is in.
class QAStarters {
  final String hint;
  final String subtitle;
  final List<String> questions;
  const QAStarters({
    required this.hint,
    required this.subtitle,
    required this.questions,
  });
}

/// A grounded citation produced when Gemma 4 calls one of our tools while
/// answering a question. Rendered in the UI as a chip under the answer so
/// the user can see *which* transcript line backs the model's claim.
class Citation {
  final String toolName;
  final Map<String, dynamic> args;
  final Map<String, dynamic> result;
  const Citation({required this.toolName, required this.args, required this.result});
}

/// Streamed event from [GemmaService.askWithToolsStream].
sealed class AskEvent {
  const AskEvent();
}
class AskText extends AskEvent {
  final String token;
  const AskText(this.token);
}
class AskCitation extends AskEvent {
  final Citation citation;
  const AskCitation(this.citation);
}
class AskThinking extends AskEvent {
  final String content;
  const AskThinking(this.content);
}

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
  /// MTP-enabled Gemma 4 E2B (Multi-Token Prediction for ~2x speedup).
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
  int? _primedContextHash;
  final Map<String, Future<QAStarters>> _startersCache = {};

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
      await FlutterGemma.initialize(huggingFaceToken: hfToken.isEmpty ? null : hfToken);
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

  /// Prime the chat with a lecture transcript so the prefill is paid once instead of on every question.
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

  /// Native Gemma 4 function-calling Q&A. Hands the model two tools it can
  /// invoke mid-answer to ground itself in the lecture, then streams text
  /// tokens and citation events to the caller. Each tool call surfaces as
  /// an [AskCitation] event so the UI can render an inline chip — the
  /// answer is verifiably backed by the transcript, not invented.
  Stream<AskEvent> askWithToolsStream({
    required List<TranscriptLine> transcript,
    required List<KeyTerm> keyTerms,
    required String question,
  }) async* {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final transcriptText = transcript.map((l) => l.text).join(' ');
    final trimmed = _trimContext(transcriptText);
    final tools = <Tool>[
      const Tool(
        name: 'quote_from_lecture',
        description:
            'Find an exact short quote from the lecture transcript that '
            'supports an answer. Returns the quote and its timestamp. Use '
            'this whenever you make a factual claim about the lecture.',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'A few keywords describing the claim to support.',
            },
          },
          'required': ['query'],
        },
      ),
      const Tool(
        name: 'look_up_term',
        description:
            'Look up the definition of a key term as it was used in the '
            'lecture. Returns the term and its one-sentence definition.',
        parameters: {
          'type': 'object',
          'properties': {
            'term': {
              'type': 'string',
              'description': 'The term to look up.',
            },
          },
          'required': ['term'],
        },
      ),
    ];
    final chat = await _model!.createChat(
      tools: tools,
      supportsFunctionCalls: true,
      modelType: ModelType.gemma4,
      isThinking: true,
    );
    final preamble =
        'You are a tutor helping a student review a lecture they attended. '
        'You have two tools you SHOULD use to ground every factual claim: '
        'quote_from_lecture for direct evidence, look_up_term for term '
        'definitions. After calling tools as needed, write a short, '
        'natural-language answer.\n\n'
        'If the question is not answerable from the lecture transcript, '
        'start your reply with the literal token [OFF-TOPIC] (in brackets) '
        'and then explain in one sentence what the lecture actually covers. '
        'Do not invent answers. Do not pretend the lecture covered something '
        'it did not.\n\n'
        '--- LECTURE TRANSCRIPT ---\n$trimmed\n--- END ---';
    await chat.addQueryChunk(Message.text(text: preamble, isUser: true));
    await chat.addQueryChunk(Message.text(text: question, isUser: true));

    var sawCalls = true;
    while (sawCalls) {
      sawCalls = false;
      await for (final chunk in chat.generateChatResponseAsync()) {
        switch (chunk) {
          case TextResponse(:final token):
            yield AskText(token);
          case ThinkingResponse(:final content):
            yield AskThinking(content);
          case FunctionCallResponse(:final name, :final args):
            sawCalls = true;
            final result = _dispatchTool(name, args, transcript, keyTerms);
            yield AskCitation(Citation(toolName: name, args: args, result: result));
            await chat.addQueryChunk(
              Message.toolResponse(toolName: name, response: result),
            );
          case ParallelFunctionCallResponse(:final calls):
            sawCalls = true;
            for (final c in calls) {
              final result = _dispatchTool(c.name, c.args, transcript, keyTerms);
              yield AskCitation(
                Citation(toolName: c.name, args: c.args, result: result),
              );
              await chat.addQueryChunk(
                Message.toolResponse(toolName: c.name, response: result),
              );
            }
        }
      }
    }
  }

  /// Pure-Dart tool dispatch: lecture transcript + study-pack key terms are
  /// the entire grounding surface. No network, no external lookups — every
  /// citation traces back to in-memory state the user can verify.
  Map<String, dynamic> _dispatchTool(
    String name,
    Map<String, dynamic> args,
    List<TranscriptLine> transcript,
    List<KeyTerm> keyTerms,
  ) {
    switch (name) {
      case 'quote_from_lecture':
        final query = (args['query'] as String? ?? '').toLowerCase().trim();
        if (query.isEmpty) {
          return {'found': false};
        }
        final terms = query.split(RegExp(r'\s+'))
            .where((t) => t.length > 2)
            .toList();
        TranscriptLine? best;
        int bestScore = 0;
        for (final l in transcript) {
          final hay = l.text.toLowerCase();
          var score = 0;
          for (final t in terms) {
            if (hay.contains(t)) score++;
          }
          if (score > bestScore) {
            bestScore = score;
            best = l;
          }
        }
        if (best == null || bestScore == 0) return {'found': false};
        return {
          'found': true,
          'quote': best.text,
          'timestamp': best.timestamp,
        };
      case 'look_up_term':
        final wanted = (args['term'] as String? ?? '').toLowerCase().trim();
        for (final kt in keyTerms) {
          if (kt.term.toLowerCase() == wanted) {
            return {
              'found': true,
              'term': kt.term,
              'definition': kt.definition,
            };
          }
        }
        for (final kt in keyTerms) {
          if (kt.term.toLowerCase().contains(wanted) ||
              wanted.contains(kt.term.toLowerCase())) {
            return {
              'found': true,
              'term': kt.term,
              'definition': kt.definition,
            };
          }
        }
        return {'found': false, 'term': args['term']};
      default:
        return {'error': 'unknown tool: $name'};
    }
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
      switch (chunk) {
        case TextResponse(:final token):
          buf.write(token);
          tokenCount += 1;
        case ThinkingResponse(:final content):
          buf.write(content);
          tokenCount += 1;
        default:
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

  /// Localized Q&A starter content for [languageName]. Cached per
  /// (transcript-hash, language) so lecture_screen can call this to pre-warm
  /// the starters in the background, and qa_screen later gets an instant
  /// cache hit. Runs in a fresh chat so it does not evict the primed
  /// lecture context.
  Future<QAStarters> generateStarters({
    required String lectureContext,
    required String languageName,
  }) {
    final trimmed = _trimContext(lectureContext);
    final key = '${trimmed.hashCode}|$languageName';
    return _startersCache.putIfAbsent(
      key,
      () => _generateStarters(trimmed, languageName).catchError((e) {
        _startersCache.remove(key);
        throw e;
      }),
    );
  }

  Future<QAStarters> _generateStarters(String trimmed, String languageName) async {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final prompt =
        'You will be shown a lecture transcript. Generate study aids for a '
        'student about to review it. Output STRICT JSON in this exact shape, '
        'no commentary, no code fence:\n'
        '{\n'
        '  "hint": "...",\n'
        '  "subtitle": "...",\n'
        '  "questions": ["...", "...", "..."]\n'
        '}\n\n'
        'Rules — all string values must be written in $languageName:\n'
        '- "hint": a short input-field placeholder, 4-8 words. Like "Ask '
        'anything about this lecture…" but in $languageName.\n'
        '- "subtitle": a short status line, 3-6 words. Means "Gemma 4 · on '
        'this phone" — convey that the AI is running locally on the user\'s '
        'device. Keep "Gemma 4" untranslated; translate only the rest.\n'
        '- "questions": exactly 3 short specific questions a student would '
        'ask after this lecture. Each 6-14 words.\n\n'
        'Transcript:\n"""\n$trimmed\n"""\n\nJSON:';
    final chat = await _model!.createChat();
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final response = await chat.generateChatResponse();
    final raw = _extractText(response);
    final json = _extractJson(raw);
    final hint = (json['hint'] as String?)?.trim() ?? 'Ask anything about this lecture…';
    final subtitle = (json['subtitle'] as String?)?.trim() ?? 'Gemma 4 · on this phone';
    final questions = ((json['questions'] as List?) ?? const [])
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return QAStarters(hint: hint, subtitle: subtitle, questions: questions);
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

  Future<StudyPack> generateStudyPack({
    required String transcript,
    String lang = 'en',
    String languageName = 'English',
  }) async {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final prompt = _studyPackPrompt(_trimContext(transcript), languageName);
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

  /// Streaming variant: produces partial [StudyPack] snapshots as each
  /// section (summary → key terms → practice questions) lands. The final
  /// emit contains the complete pack. Lets the UI animate the pack in
  /// section-by-section instead of staring at a spinner.
  Stream<StudyPack> generateStudyPackStream({
    required String transcript,
    String lang = 'en',
    String languageName = 'English',
  }) async* {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final prompt = _studyPackPrompt(_trimContext(transcript), languageName);
    final chat = await _model!.createChat();
    await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
    final buf = StringBuffer();
    StudyPack lastEmitted = StudyPack(
      lang: lang, summary: '', keyTerms: const [], practiceQuestions: const [],
    );
    await for (final chunk in chat.generateChatResponseAsync()) {
      switch (chunk) {
        case TextResponse(:final token):
          buf.write(token);
        case ThinkingResponse(:final content):
          buf.write(content);
        default:
          break;
      }
      final partial = _parsePartialStudyPack(buf.toString(), lang);
      if (partial != null && _packDiffers(partial, lastEmitted)) {
        lastEmitted = partial;
        yield partial;
      }
    }
    final finalJson = _extractJson(buf.toString());
    final finalPack = StudyPack(
      lang: lang,
      summary: (finalJson['summary'] as String?) ?? lastEmitted.summary,
      keyTerms: ((finalJson['key_terms'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => KeyTerm(
                term: (m['term'] as String?) ?? '',
                definition: (m['definition'] as String?) ?? '',
              ))
          .toList(),
      practiceQuestions: ((finalJson['practice_questions'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
    );
    yield finalPack;
  }

  /// Pull whatever can be parsed out of an in-progress JSON blob. The model
  /// emits the summary, key_terms, and practice_questions in order; if a
  /// section's array isn't closed yet we treat what's there as partial and
  /// strip any trailing incomplete object.
  StudyPack? _parsePartialStudyPack(String raw, String lang) {
    final start = raw.indexOf('{');
    if (start < 0) return null;
    final s = raw.substring(start);
    String? summary;
    final summaryMatch = RegExp(r'"summary"\s*:\s*"((?:[^"\\]|\\.)*)"')
        .firstMatch(s);
    if (summaryMatch != null) summary = _unescape(summaryMatch.group(1)!);

    final keyTerms = <KeyTerm>[];
    final ktArrMatch = RegExp(r'"key_terms"\s*:\s*\[').firstMatch(s);
    if (ktArrMatch != null) {
      final after = s.substring(ktArrMatch.end);
      final ktObj = RegExp(
        r'\{\s*"term"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*"definition"\s*:\s*"((?:[^"\\]|\\.)*)"\s*\}',
      );
      for (final m in ktObj.allMatches(after)) {
        keyTerms.add(KeyTerm(
          term: _unescape(m.group(1)!),
          definition: _unescape(m.group(2)!),
        ));
      }
    }

    final pq = <String>[];
    final pqArrMatch = RegExp(r'"practice_questions"\s*:\s*\[').firstMatch(s);
    if (pqArrMatch != null) {
      final after = s.substring(pqArrMatch.end);
      for (final m in RegExp(r'"((?:[^"\\]|\\.)*)"').allMatches(after)) {
        pq.add(_unescape(m.group(1)!));
      }
    }

    if (summary == null && keyTerms.isEmpty && pq.isEmpty) return null;
    return StudyPack(
      lang: lang,
      summary: summary ?? '',
      keyTerms: keyTerms,
      practiceQuestions: pq,
    );
  }

  String _unescape(String s) => s
      .replaceAll(r'\"', '"')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\\', r'\');

  bool _packDiffers(StudyPack a, StudyPack b) =>
      a.summary != b.summary ||
      a.keyTerms.length != b.keyTerms.length ||
      a.practiceQuestions.length != b.practiceQuestions.length;

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

  String _extractText(dynamic response) {
    if (response is String) return response.trim();
    if (response is TextResponse) return response.token.trim();
    if (response is ThinkingResponse) return response.content.trim();
    return response.toString().trim();
  }

  String _studyPackPrompt(String transcript, String languageName) => '''
You are an academic tutor. Below is a transcript of a recorded lecture.
Produce a study pack with three sections, in JSON. All string values must
be written in $languageName.

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

Use 5-8 key_terms and 5-6 practice_questions. Emit sections in this exact
order so the UI can render partial output: summary first, then key_terms,
then practice_questions.

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
