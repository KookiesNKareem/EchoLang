import 'package:flutter/material.dart';

import 'data/bundle_store.dart';
import 'llm/gemma.dart';
import 'llm/whisper.dart';
import 'routes.dart';
import 'theme.dart';

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
    // Background pre-load: after the first frame renders, kick off the
    // Whisper download so by the time the user taps "Record now" the model
    // is ready (or close to it). Wrapped in Future so we don't block the
    // initial render; failures are silent — the Record screen surfaces them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _whisper.ensureReady().catchError((_) {/* surfaced in Record screen */});
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
      title: 'LocalLearning',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: buildRouter(store: _store, gemma: _gemma, whisper: _whisper),
    );
  }
}
