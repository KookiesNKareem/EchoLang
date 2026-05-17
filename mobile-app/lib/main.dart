import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/bundle_store.dart';
import 'llm/gemma.dart';
import 'llm/whisper.dart';
import 'routes.dart';
import 'theme.dart';

/// Compile-time flag for the autonomous on-device benchmark.
/// Build with: `flutter run --release --dart-define=AUTOBENCH=1`
const bool kAutoBench = bool.fromEnvironment('AUTOBENCH', defaultValue: false);

void main() {
  runApp(const LocalLearningApp());
}

class LocalLearningApp extends StatefulWidget {
  const LocalLearningApp({super.key});

  @override
  State<LocalLearningApp> createState() => _LocalLearningAppState();
}

class _LocalLearningAppState extends State<LocalLearningApp> {
  final _store = BundleStore();
  final _gemma = GemmaService();
  final _whisper = WhisperService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _whisper.ensureReady().catchError((_) {});
      _gemma.ensureReady().catchError((_) {}).then((_) {
        if (kAutoBench) unawaited(_runAutoBench(_gemma));
      });
    });
  }

  @override
  void dispose() {
    _gemma.unload();
    _whisper.unload();
    super.dispose();
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
