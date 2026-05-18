import 'dart:async';
import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';

import '../data/models.dart';

enum GemmaStatus { notReady, downloading, ready, error }

/// Localized Q&A starter content for whatever language the lecture is in.
/// One multiple-choice quiz question grounded in the lecture transcript.
class QuizItem {
  final String question;
  final List<String> options;
  final int correctIndex;
  final String explanation;
  const QuizItem({
    required this.question,
    required this.options,
    required this.correctIndex,
    required this.explanation,
  });
}

class QAStarters {
  final String hint;
  final String subtitle;
  final String welcomeTitle;
  final String welcomeBody;
  final List<String> questions;
  const QAStarters({
    required this.hint,
    required this.subtitle,
    required this.welcomeTitle,
    required this.welcomeBody,
    required this.questions,
  });

  /// Static fallback avoids a known flutter_gemma state-leak on iOS.
  static const QAStarters fallback = QAStarters(
    hint: 'Ask anything about this lecture…',
    subtitle: 'Gemma 4 · on this phone',
    welcomeTitle: 'Ask anything about this lecture',
    welcomeBody:
        'Gemma 4 runs on this phone. Nothing leaves your device — works anywhere.',
    questions: [
      'Summarize this lecture in three bullet points.',
      'What are the most important concepts?',
      'Give me a quick example from the lecture.',
    ],
  );
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
  /// Transient chats currently mid-generation. Tracked so we can proactively
  /// close them when the app is about to be suspended or torn down — otherwise
  /// the LiteRT-LM worker thread keeps streaming tokens and eventually fires
  /// an FFI callback into a destroyed Dart isolate, crashing the app on
  /// teardown (Dart asserts in GetFfiCallbackMetadata).
  final Set<InferenceChat> _activeChats = {};
  /// Serialization gate to prevent concurrent createChat() calls that leak context on iOS.
  Future<void> _inferenceGate = Future.value();

  Future<T> _serialize<T>(Future<T> Function() op) {
    final prev = _inferenceGate;
    final completer = Completer<void>();
    _inferenceGate = completer.future;
    return prev.then((_) async {
      try {
        return await op();
      } finally {
        completer.complete();
      }
    });
  }

  /// Stream-shaped variant of [_serialize]. Holds the gate for the
  /// entire lifetime of the inner stream so other inference operations
  /// queue up behind it.
  Stream<T> _serializeStream<T>(Stream<T> Function() op) async* {
    final prev = _inferenceGate;
    final completer = Completer<void>();
    _inferenceGate = completer.future;
    try {
      await prev;
      yield* op();
    } finally {
      completer.complete();
    }
  }

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
      // 4096 balances transcript coverage with iOS RAM constraints on lower-end devices.
      _model = await FlutterGemma.getActiveModel(
        maxTokens: 4096,
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
  Future<void> primeContext(String lectureContext) =>
      _serialize(() => _primeContextLocked(lectureContext));

  /// Inner body of primeContext, assumes the inference gate is already held.
  /// Callers in this file that are themselves inside the gate must use this
  /// version instead of the public [primeContext] to avoid a deadlock.
  Future<void> _primeContextLocked(String lectureContext) async {
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
    String answerLanguageName = 'English',
  }) {
    return _serializeStream(() => _askWithToolsStreamInner(
          transcript: transcript,
          keyTerms: keyTerms,
          question: question,
          answerLanguageName: answerLanguageName,
        ));
  }

  Stream<AskEvent> _askWithToolsStreamInner({
    required List<TranscriptLine> transcript,
    required List<KeyTerm> keyTerms,
    required String question,
    required String answerLanguageName,
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
    _activeChats.add(chat);
    try {
      final preamble =
          'You are a tutor helping a student review a lecture they attended. '
          'You have two tools you SHOULD use to ground every factual claim: '
          'quote_from_lecture for direct evidence, look_up_term for term '
          'definitions. After calling tools as needed, write a short, '
          'natural-language answer.\n\n'
          'Write your reply in $answerLanguageName, regardless of which '
          'language the student\'s question is in or which language the '
          'transcript is in. The [OFF-TOPIC] marker below stays in English; '
          'everything after it should be in $answerLanguageName.\n\n'
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
    } finally {
      _activeChats.remove(chat);
      try { await chat.close(); } catch (_) {}
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
  }) {
    return _serializeStream(() => _askStreamInner(
          lectureContext: lectureContext,
          question: question,
        ));
  }

  Stream<String> _askStreamInner({
    required String lectureContext,
    required String question,
  }) async* {
    await _primeContextLocked(lectureContext);
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
  }) {
    return _serialize(() => _benchAskInner(
          lectureContext: lectureContext,
          question: question,
          freshChat: freshChat,
        ));
  }

  Future<GemmaBenchResult> _benchAskInner({
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
      await _primeContextLocked(lectureContext);
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

  /// Returns static starter content (avoids state-leak on iOS).
  Future<QAStarters> generateStarters({
    required String lectureContext,
    required String languageName,
  }) async {
    return QAStarters.fallback;
  }

  /// Translate the fixed English starter strings into [targetLanguageName] in
  /// a SINGLE chat session. Earlier versions ran one createChat per field;
  /// six rapid native allocations right after primeContext spiked iOS memory
  /// past the jetsam threshold on lower-RAM devices ("Translating to…" then
  /// app death). One chat keeps peak memory the same as a normal translation.
  /// Returns [base] unchanged on any model error or parse failure so the UI
  /// degrades gracefully to English instead of crashing or blanking out.
  Future<QAStarters> localizeStarters({
    required QAStarters base,
    required String targetLanguageName,
  }) {
    return _serialize(() async {
      if (_status != GemmaStatus.ready || _model == null) return base;
      final items = <String>[
        base.hint,
        base.welcomeTitle,
        base.welcomeBody,
        ...base.questions,
      ];
      final numbered = items
          .asMap()
          .entries
          .map((e) => '${e.key + 1}. ${e.value}')
          .join('\n');
      final prompt =
          'Translate each numbered item below into $targetLanguageName.\n'
          'Output EXACTLY ${items.length} lines, one per item, in the same '
          'order, each line prefixed with its original number and a period '
          '(e.g. "1. ..."). Do NOT add a preface, commentary, or extra '
          'lines. Keep the numbers as Western Arabic digits.\n\n'
          'Items:\n$numbered\n\nTranslations:';
      final chat = await _model!.createChat();
      _activeChats.add(chat);
      final buf = StringBuffer();
      try {
        await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
        // Cap output at 3x input + slack to bail on repetition loops before
        // they eat the token budget and trigger a memory-pressure crash.
        final maxOutput = numbered.length * 3 + 200;
        var outputLen = 0;
        await for (final piece in chat.generateChatResponseAsync()) {
          switch (piece) {
            case TextResponse(:final token):
              buf.write(token);
              outputLen += token.length;
            case ThinkingResponse(:final content):
              buf.write(content);
              outputLen += content.length;
            default:
              break;
          }
          if (outputLen > maxOutput) break;
        }
      } catch (_) {
        return base;
      } finally {
        _activeChats.remove(chat);
        try { await chat.close(); } catch (_) {}
      }
      final parsed = _parseNumberedTranslations(buf.toString(), items.length);
      if (parsed == null) return base;
      return QAStarters(
        hint: parsed[0],
        subtitle: base.subtitle,
        welcomeTitle: parsed[1],
        welcomeBody: parsed[2],
        questions: parsed.sublist(3, 3 + base.questions.length),
      );
    });
  }

  /// Parse a numbered-list response into [expected] strings indexed 1..N.
  /// Tolerates leading preface and intermixed blank lines, but requires every
  /// number 1..[expected] to be present — otherwise returns null so the caller
  /// can fall back to the source strings instead of showing a half-translated
  /// UI.
  List<String>? _parseNumberedTranslations(String raw, int expected) {
    final markerRe = RegExp(r'(?:^|\n)\s*(\d+)\.\s*');
    final matches = markerRe.allMatches(raw).toList();
    if (matches.length < expected) return null;
    final byNum = <int, String>{};
    for (var i = 0; i < matches.length; i++) {
      final n = int.tryParse(matches[i].group(1)!);
      if (n == null || n < 1 || n > expected) continue;
      final start = matches[i].end;
      final end = i + 1 < matches.length ? matches[i + 1].start : raw.length;
      final value = raw.substring(start, end).trim();
      if (value.isNotEmpty) byNum.putIfAbsent(n, () => value);
    }
    final out = <String>[];
    for (var n = 1; n <= expected; n++) {
      final v = byNum[n];
      if (v == null) return null;
      out.add(v);
    }
    return out;
  }

  /// On-device translation. Streams the translated text token-by-token.
  /// Runs in a fresh chat session so it doesn't clobber the primed Q&A chat
  /// for whichever lecture is currently open.
  Stream<String> translateStream({
    required String text,
    required String targetLanguageName,
  }) {
    return _serializeStream(() => _translateStreamInner(
          text: text,
          targetLanguageName: targetLanguageName,
        ));
  }

  Stream<String> _translateStreamInner({
    required String text,
    required String targetLanguageName,
  }) async* {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final chunks = _chunkForTranslation(text);
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final prompt =
          'Translate the following English text into $targetLanguageName. '
          'Preserve sentence boundaries and paragraph breaks. Output ONLY the '
          'translated text — no preface, no commentary, no "Sure, here is...".'
          '\n\nEnglish:\n$chunk\n\n$targetLanguageName:';
      final chat = await _model!.createChat();
      _activeChats.add(chat);
      try {
        await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
        // Translation output should be roughly the size of the input.
        // 1.8x cap catches obvious runaways; a sliding-window repetition
        // detector below catches the subtler "aula aula aula" loops that
        // stay under the size cap but produce visibly broken text.
        final maxChunkOutput = (chunk.length * 1.8).round() + 120;
        var chunkOutput = 0;
        final loopBuf = StringBuffer();
        await for (final piece in chat.generateChatResponseAsync()) {
          String? out;
          switch (piece) {
            case TextResponse(:final token):
              out = token;
            case ThinkingResponse(:final content):
              out = content;
            default:
              break;
          }
          if (out == null) continue;
          yield out;
          chunkOutput += out.length;
          loopBuf.write(out);
          if (chunkOutput > maxChunkOutput) break;
          if (_isRepetitionLoop(loopBuf.toString())) break;
        }
      } finally {
        _activeChats.remove(chat);
        try { await chat.close(); } catch (_) {}
      }
      if (i < chunks.length - 1) yield '\n\n';
    }
  }

  /// Detect Gemma's repetition-loop failure mode (a short token sequence
  /// emitted four or more times back-to-back). Looks at the tail of the
  /// chunk output; cheap enough to run on every streamed token.
  static bool _isRepetitionLoop(String s) {
    if (s.length < 60) return false;
    final tail = s.substring(s.length - 80);
    // Try ngram lengths from 4 to 20 chars. If the same ngram appears 4+
    // times consecutively at the tail, we're stuck in a loop.
    for (var n = 4; n <= 20; n++) {
      if (tail.length < n * 4) continue;
      final candidate = tail.substring(tail.length - n);
      var matches = 1;
      var pos = tail.length - n * 2;
      while (pos >= 0 && tail.substring(pos, pos + n) == candidate) {
        matches += 1;
        pos -= n;
      }
      if (matches >= 4) return true;
    }
    return false;
  }

  /// Split a transcript into chunks that fit comfortably under the 4096-token
  /// context window once prompt + output are accounted for. ~1800 chars input
  /// leaves room for a similarly-sized translation in the same window.
  static List<String> _chunkForTranslation(String text, {int maxChars = 1800}) {
    if (text.length <= maxChars) return [text];
    final out = <String>[];
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    final buf = StringBuffer();
    void flush() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    }
    for (final p in paragraphs) {
      if (p.length > maxChars) {
        flush();
        for (final sentence in p.split(RegExp(r'(?<=[.!?])\s+'))) {
          if (buf.length + sentence.length + 1 > maxChars) flush();
          if (buf.isNotEmpty) buf.write(' ');
          buf.write(sentence);
        }
        flush();
        continue;
      }
      if (buf.length + p.length + 2 > maxChars) flush();
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(p);
    }
    flush();
    return out;
  }

  Future<StudyPack> generateStudyPack({
    required String transcript,
    String lang = 'en',
    String languageName = 'English',
  }) {
    return _serialize(() async {
      if (_status != GemmaStatus.ready || _model == null) {
        throw StateError('Gemma not ready (status=$_status)');
      }
      final prompt = _studyPackPrompt(_trimContext(transcript), languageName);
      final chat = await _model!.createChat();
      _activeChats.add(chat);
      final String raw;
      try {
        await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
        final response = await chat.generateChatResponse();
        raw = _extractText(response);
      } finally {
        _activeChats.remove(chat);
        try { await chat.close(); } catch (_) {}
      }
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
    });
  }

  /// Streaming variant: yields partial packs section-by-section for progressive UI updates.
  Stream<StudyPack> generateStudyPackStream({
    required String transcript,
    String lang = 'en',
    String languageName = 'English',
  }) {
    return _serializeStream(() => _generateStudyPackStreamInner(
          transcript: transcript,
          lang: lang,
          languageName: languageName,
        ));
  }

  Stream<StudyPack> _generateStudyPackStreamInner({
    required String transcript,
    String lang = 'en',
    String languageName = 'English',
  }) async* {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final prompt = _studyPackPrompt(_trimContext(transcript), languageName);
    final chat = await _model!.createChat();
    _activeChats.add(chat);
    final buf = StringBuffer();
    StudyPack lastEmitted = StudyPack(
      lang: lang, summary: '', keyTerms: const [], practiceQuestions: const [],
    );
    try {
      await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
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
    } finally {
      _activeChats.remove(chat);
      try { await chat.close(); } catch (_) {}
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

  /// Streams quiz items as they parse, allowing progressive UI rendering.
  Stream<QuizItem> generateQuizStream({
    required String transcript,
    String languageName = 'English',
    int count = 5,
  }) {
    return _serializeStream(() => _generateQuizStreamInner(
          transcript: transcript,
          languageName: languageName,
          count: count,
        ));
  }

  Stream<QuizItem> _generateQuizStreamInner({
    required String transcript,
    String languageName = 'English',
    int count = 5,
  }) async* {
    if (_status != GemmaStatus.ready || _model == null) {
      throw StateError('Gemma not ready (status=$_status)');
    }
    final trimmed = _trimContext(transcript);
    final prompt =
        'You will be shown a lecture transcript. Produce a multiple-choice '
        'quiz with exactly $count items that test understanding of the '
        'material. All string values must be written in $languageName.\n\n'
        'Output STRICT JSON in this exact shape, no commentary, no code '
        'fence:\n'
        '{\n'
        '  "items": [\n'
        '    {\n'
        '      "question": "...",\n'
        '      "options": ["A choice", "B choice", "C choice", "D choice"],\n'
        '      "correct": 0,\n'
        '      "explanation": "one short sentence citing the lecture"\n'
        '    }\n'
        '  ]\n'
        '}\n\n'
        'Rules:\n'
        '- Each "options" array has exactly 4 strings.\n'
        '- "correct" is the index 0-3 of the right option.\n'
        '- Questions must be answerable directly from the transcript. No '
        'outside trivia.\n'
        '- Emit "items" in order so partial decoding can show questions as '
        'they land.\n\n'
        'Transcript:\n"""\n$trimmed\n"""\n\nJSON:';
    final chat = await _model!.createChat();
    _activeChats.add(chat);
    final buf = StringBuffer();
    var lastYielded = 0;
    try {
      await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
      await for (final chunk in chat.generateChatResponseAsync()) {
        switch (chunk) {
          case TextResponse(:final token):
            buf.write(token);
          case ThinkingResponse(:final content):
            buf.write(content);
          default:
            break;
        }
        final parsed = _parseQuizItems(buf.toString());
        while (lastYielded < parsed.length) {
          yield parsed[lastYielded];
          lastYielded += 1;
        }
      }
    } finally {
      _activeChats.remove(chat);
      try { await chat.close(); } catch (_) {}
    }
    final finalItems = _parseQuizItems(buf.toString());
    while (lastYielded < finalItems.length) {
      yield finalItems[lastYielded];
      lastYielded += 1;
    }
  }

  /// Pull every fully-formed quiz object out of an in-progress JSON blob.
  /// Tolerates trailing garbage / unclosed arrays — used to surface items
  /// to the UI as soon as each one is complete.
  List<QuizItem> _parseQuizItems(String raw) {
    final out = <QuizItem>[];
    final objRe = RegExp(
      r'"question"\s*:\s*"((?:[^"\\]|\\.)*)"'
      r'[^}]*?"options"\s*:\s*\[((?:[^\[\]]|"(?:[^"\\]|\\.)*")*)\]'
      r'[^}]*?"correct"\s*:\s*(\d+)'
      r'[^}]*?"explanation"\s*:\s*"((?:[^"\\]|\\.)*)"',
      dotAll: true,
    );
    for (final m in objRe.allMatches(raw)) {
      final question = _unescape(m.group(1)!);
      final optsRaw = m.group(2)!;
      final correct = int.tryParse(m.group(3)!) ?? 0;
      final explanation = _unescape(m.group(4)!);
      final options = RegExp(r'"((?:[^"\\]|\\.)*)"')
          .allMatches(optsRaw)
          .map((m) => _unescape(m.group(1)!))
          .toList();
      if (options.length < 4) continue;
      out.add(QuizItem(
        question: question,
        options: options.take(4).toList(),
        correctIndex: correct.clamp(0, 3),
        explanation: explanation,
      ));
    }
    return out;
  }

  void unload() {
    _chat = null;
    _primedContextHash = null;
    _activeChats.clear();
    _model?.close();
    _model = null;
    _readyFuture = null;
    _status = GemmaStatus.notReady;
  }

  /// Close every transient chat currently mid-generation. Call this from an
  /// app-lifecycle observer when the app is about to be backgrounded or
  /// torn down — closing the chat tells the LiteRT-LM worker thread to stop
  /// emitting tokens, closing the window in which it could fire a Dart FFI
  /// callback into a destroyed isolate (crash mode observed in TestFlight on
  /// tester devices: dart::Assert::Fail inside DLRT_GetFfiCallbackMetadata).
  /// Streams whose chats get closed externally observe the chat-side stream
  /// completing naturally, then run their normal finally cleanup.
  Future<void> cancelAllInflight() async {
    if (_activeChats.isEmpty) return;
    final chats = List.of(_activeChats);
    _activeChats.clear();
    for (final c in chats) {
      try { await c.close(); } catch (_) {}
    }
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
