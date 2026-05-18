import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/bundle_store.dart';
import 'data/models.dart';
import 'llm/gemma.dart';
import 'llm/whisper.dart';
import 'routes.dart';
import 'theme.dart';

/// Compile-time flag for the autonomous on-device benchmark.
/// Build with: `flutter run --release --dart-define=AUTOBENCH=1`
const bool kAutoBench = bool.fromEnvironment('AUTOBENCH', defaultValue: false);

/// Compile-time flag for rigorous Gemma test suite (exercise all inference paths).
const bool kRobustTest = bool.fromEnvironment('ROBUST_TEST', defaultValue: false);

void main() {
  // Convert render-time exceptions from a pure black iOS-release screen
  // into a visible fallback so a single bad widget never bricks the app.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Material(
      color: const Color(0xFF101013),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Color(0xFFE57373), size: 32),
              const SizedBox(height: 12),
              const Text(
                'Something broke rendering this screen.',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                details.exceptionAsString(),
                style: const TextStyle(fontSize: 12, height: 1.4, color: Colors.white70),
              ),
              const SizedBox(height: 16),
              const Text(
                'Tap back to recover.',
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  };
  runApp(const LocalLearningApp());
}

class LocalLearningApp extends StatefulWidget {
  const LocalLearningApp({super.key});

  @override
  State<LocalLearningApp> createState() => _LocalLearningAppState();
}

class _LocalLearningAppState extends State<LocalLearningApp>
    with WidgetsBindingObserver {
  final _store = BundleStore();
  final _gemma = GemmaService();
  final _whisper = WhisperService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _whisper.ensureReady().catchError((_) {});
      _gemma.ensureReady().catchError((_) {}).then((_) {
        if (kAutoBench) unawaited(_runAutoBench(_gemma));
        if (kRobustTest) unawaited(_runRobustTest(_gemma));
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gemma.unload();
    _whisper.unload();
    super.dispose();
  }

  /// Close any in-flight Gemma inference before iOS suspends or kills us.
  /// Otherwise the LiteRT-LM worker keeps streaming tokens and fires an FFI
  /// callback into a torn-down Dart isolate, crashing on teardown with
  /// dart::Assert::Fail in GetFfiCallbackMetadata. The loaded model stays in
  /// memory so resuming the app is instant — only mid-generation chats are
  /// closed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_gemma.cancelAllInflight());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'EchoLang',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: buildRouter(store: _store, gemma: _gemma, whisper: _whisper),
    );
  }
}

const _benchContext = '''
Photosynthesis is the process by which green plants, algae, and some bacteria
convert light energy into chemical energy stored in glucose. It happens mainly
in the chloroplasts of plant cells, which contain the pigment chlorophyll.
Chlorophyll absorbs light most efficiently in the red and blue wavelengths and
reflects green, which is why leaves look green.

The overall reaction takes six molecules of carbon dioxide and six molecules of
water and uses light energy to produce one molecule of glucose and six molecules
of oxygen. The process has two main stages. The light-dependent reactions occur
in the thylakoid membranes and split water to release oxygen while making ATP
and NADPH. The light-independent reactions, also called the Calvin cycle, take
place in the stroma and use ATP and NADPH to fix carbon dioxide into glucose.
''';

const _benchQuestions = <String>[
  'In one sentence, what is photosynthesis?',
  'Why do leaves appear green?',
  'What are the two stages of photosynthesis and where in the chloroplast does each happen?',
];

Future<void> _runAutoBench(GemmaService gemma) async {
  final docs = await getApplicationDocumentsDirectory();
  final out = File('${docs.path}/bench_results.json');
  final lines = <String>[];
  final trials = <Map<String, dynamic>>[];
  void log(String line) {
    final stamped = 'BENCH: $line';
    // ignore: avoid_print
    print(stamped);
    lines.add(stamped);
  }

  Future<void> flush() async {
    final payload = {
      'started_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
      'log': lines,
      'trials': trials,
    };
    try {
      await out.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    } catch (_) {}
  }

  Future<void> runMode({required String mode, required bool freshChat}) async {
    log('mode=$mode begin');
    try {
      final warm = await gemma.benchAsk(
        lectureContext: _benchContext,
        question: 'Reply with the single word ok.',
        freshChat: freshChat,
      );
      final w = {
        'phase': 'warmup',
        'mode': mode,
        'first_token_ms': warm.firstTokenLatency.inMilliseconds,
        'total_ms': warm.totalDuration.inMilliseconds,
        'tokens': warm.approxTokens,
        'tps': double.parse(warm.tokensPerSec.toStringAsFixed(2)),
        'output': warm.output,
      };
      trials.add(w);
      log('mode=$mode warmup first_token_ms=${w['first_token_ms']} '
          'total_ms=${w['total_ms']} tokens=${w['tokens']} tps=${w['tps']}');
      await flush();
    } catch (e) {
      log('mode=$mode warmup error: $e');
      await flush();
      return;
    }
    for (var i = 0; i < _benchQuestions.length; i++) {
      final q = _benchQuestions[i];
      try {
        final r = await gemma.benchAsk(
          lectureContext: _benchContext,
          question: q,
          freshChat: freshChat,
        );
        final t = {
          'phase': 'trial',
          'mode': mode,
          'index': i,
          'question': q,
          'first_token_ms': r.firstTokenLatency.inMilliseconds,
          'total_ms': r.totalDuration.inMilliseconds,
          'tokens': r.approxTokens,
          'tps': double.parse(r.tokensPerSec.toStringAsFixed(2)),
          'output': r.output,
        };
        trials.add(t);
        log('mode=$mode trial=$i first_token_ms=${t['first_token_ms']} '
            'total_ms=${t['total_ms']} tokens=${t['tokens']} tps=${t['tps']}');
        await flush();
      } catch (e) {
        log('mode=$mode trial=$i error: $e');
      }
    }
  }

  log('autobench enabled=$kAutoBench');
  log('start');
  await runMode(mode: 'fresh', freshChat: true);
  gemma.unloadChat();
  await runMode(mode: 'primed', freshChat: false);
  log('results_path=${out.path}');
  await flush();
  log('done');
}

const _testTranscript = _benchContext;

Future<void> _runRobustTest(GemmaService gemma) async {
  final docs = await getApplicationDocumentsDirectory();
  final out = File('${docs.path}/gemma_tests.json');
  final results = <Map<String, dynamic>>[];

  Future<void> flush() async {
    try {
      await out.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'started_at_unix_ms': DateTime.now().millisecondsSinceEpoch,
          'results': results,
        }),
      );
    } catch (_) {}
  }

  Future<void> record(String name, Future<Map<String, dynamic>> Function() body) async {
    final sw = Stopwatch()..start();
    // ignore: avoid_print
    print('TEST: $name begin');
    Map<String, dynamic> entry;
    try {
      entry = await body();
      entry['pass'] = entry['pass'] ?? true;
    } catch (e, s) {
      entry = {'pass': false, 'error': '$e', 'stack': s.toString().split('\n').take(4).join('\n')};
    }
    entry['name'] = name;
    entry['elapsed_ms'] = sw.elapsedMilliseconds;
    results.add(entry);
    // ignore: avoid_print
    print('TEST: $name ${entry['pass'] == true ? 'PASS' : 'FAIL'} '
        '(${entry['elapsed_ms']} ms)');
    await flush();
  }

  bool looksLikeStartersJson(String text) {
    final t = text.toLowerCase();
    return t.contains('"hint"') &&
        t.contains('"questions"') &&
        (t.contains('"welcome_title"') || t.contains('"subtitle"'));
  }

  bool looksLikeQuizJson(String text) {
    final t = text.toLowerCase();
    return t.contains('"options"') && t.contains('"correct"');
  }

  // 1. Prime context — must not throw, _chat must be non-null afterwards.
  await record('primeContext', () async {
    await gemma.primeContext(_testTranscript);
    return {'note': 'no exceptions'};
  });

  // 2. generateStarters English — must return non-empty fields, no garbage.
  await record('starters.en', () async {
    final s = await gemma.generateStarters(
      lectureContext: _testTranscript,
      languageName: 'English',
    );
    final ok = s.hint.isNotEmpty &&
        s.welcomeTitle.isNotEmpty &&
        s.welcomeBody.isNotEmpty &&
        s.questions.length >= 2;
    return {
      'pass': ok,
      'hint': s.hint,
      'subtitle': s.subtitle,
      'welcome_title': s.welcomeTitle,
      'questions': s.questions,
    };
  });

  // 3. generateStarters Spanish — different language path, separate cache key.
  await record('starters.es', () async {
    final s = await gemma.generateStarters(
      lectureContext: _testTranscript,
      languageName: 'Spanish',
    );
    final ok = s.hint.isNotEmpty && s.questions.length >= 2;
    return {
      'pass': ok,
      'hint': s.hint,
      'questions': s.questions,
    };
  });

  // 4. askWithToolsStream — on-topic question with tool calls.
  await record('askWithTools.on_topic', () async {
    final transcript = _splitTranscript(_testTranscript);
    final buf = StringBuffer();
    var citationCount = 0;
    String? firstThinkingChunk;
    await for (final ev in gemma.askWithToolsStream(
      transcript: transcript,
      keyTerms: const [],
      question: 'What are the three core claims of cell theory?',
    )) {
      switch (ev) {
        case AskText(:final token):
          buf.write(token);
        case AskCitation():
          citationCount += 1;
        case AskThinking(:final content):
          firstThinkingChunk ??= content;
      }
    }
    final text = buf.toString().trim();
    final contaminated = looksLikeStartersJson(text) || looksLikeQuizJson(text);
    return {
      'pass': text.isNotEmpty && !contaminated,
      'contaminated': contaminated,
      'output_len': text.length,
      'output_preview': text.length > 400 ? '${text.substring(0, 400)}…' : text,
      'citation_count': citationCount,
      'had_thinking': firstThinkingChunk != null,
    };
  });

  // 5. askWithToolsStream — off-topic question.
  await record('askWithTools.off_topic', () async {
    final transcript = _splitTranscript(_testTranscript);
    final buf = StringBuffer();
    await for (final ev in gemma.askWithToolsStream(
      transcript: transcript,
      keyTerms: const [],
      question: 'What is the capital of France?',
    )) {
      if (ev is AskText) buf.write(ev.token);
    }
    final text = buf.toString().trim();
    return {
      'pass': text.isNotEmpty && !looksLikeStartersJson(text),
      'output_preview': text.length > 400 ? '${text.substring(0, 400)}…' : text,
      'has_off_topic_marker': text.toLowerCase().contains('[off-topic]') ||
          text.toLowerCase().contains('off-topic'),
    };
  });

  // 6. translateStream — translation to Spanish.
  await record('translate.es', () async {
    final buf = StringBuffer();
    await for (final t in gemma.translateStream(
      text: 'Photosynthesis converts light energy into chemical energy.',
      targetLanguageName: 'Spanish',
    )) {
      buf.write(t);
    }
    final text = buf.toString().trim();
    return {
      'pass': text.isNotEmpty &&
          !looksLikeStartersJson(text) &&
          !looksLikeQuizJson(text),
      'output': text,
    };
  });

  // 7. Concurrent starters + Q&A (concurrent inference stress test).
  await record('concurrent.starters_and_ask', () async {
    final transcript = _splitTranscript(_testTranscript);
    gemma.unloadChat();
    final startersFuture = gemma.generateStarters(
      lectureContext: _testTranscript,
      languageName: 'French',
    );
    await Future.delayed(const Duration(milliseconds: 50));
    final buf = StringBuffer();
    await for (final ev in gemma.askWithToolsStream(
      transcript: transcript,
      keyTerms: const [],
      question: 'Why do leaves appear green?',
    )) {
      if (ev is AskText) buf.write(ev.token);
    }
    final answer = buf.toString().trim();
    final starters = await startersFuture;
    final contaminated = looksLikeStartersJson(answer) || looksLikeQuizJson(answer);
    return {
      'pass': !contaminated && answer.isNotEmpty,
      'contaminated': contaminated,
      'answer_preview': answer.length > 400 ? '${answer.substring(0, 400)}…' : answer,
      'starters_hint': starters.hint,
      'starters_questions_count': starters.questions.length,
    };
  });

  // 8. Generate quiz stream.
  await record('quiz.stream', () async {
    final items = <Map<String, dynamic>>[];
    await for (final q in gemma.generateQuizStream(
      transcript: _testTranscript,
      languageName: 'English',
      count: 3,
    )) {
      items.add({
        'question': q.question,
        'options': q.options,
        'correct_index': q.correctIndex,
      });
    }
    final allFour = items.every((q) =>
        (q['options'] as List).length == 4 &&
        (q['correct_index'] as int) >= 0 &&
        (q['correct_index'] as int) <= 3);
    return {
      'pass': items.isNotEmpty && allFour,
      'item_count': items.length,
      'first_item': items.isNotEmpty ? items.first : null,
    };
  });

  // 9. Study pack stream.
  await record('study_pack.stream', () async {
    var sawSummary = false;
    var lastTermCount = 0;
    await for (final p in gemma.generateStudyPackStream(
      transcript: _testTranscript,
      lang: 'en',
      languageName: 'English',
    )) {
      if (p.summary.isNotEmpty) sawSummary = true;
      lastTermCount = p.keyTerms.length;
    }
    return {
      'pass': sawSummary,
      'final_key_term_count': lastTermCount,
    };
  });

  // ignore: avoid_print
  print('TEST: ALL DONE — see ${out.path}');
  await flush();
}

List<TranscriptLine> _splitTranscript(String text) {
  final lines = text
      .split(RegExp(r'(?<=[.!?])\s+'))
      .where((s) => s.trim().isNotEmpty)
      .toList();
  return lines.asMap().entries.map((e) {
    final s = e.key * 4;
    final h = (s ~/ 3600).toString().padLeft(2, '0');
    final m = ((s % 3600) ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return TranscriptLine(
      timestamp: '$h:$m:$ss',
      index: e.key,
      text: e.value.trim(),
    );
  }).toList();
}
