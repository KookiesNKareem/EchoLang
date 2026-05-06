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
    // Background pre-load both models after the first frame renders so by
    // the time the user taps Record now or opens Q&A everything is ready
    // (or actively downloading with a visible progress banner). Whisper is
    // ~30MB; Gemma 4 E2B is ~2.6GB so the user sees real progress before
    // they ever touch a record button. Failures are silent here — surfaced
    // in the screens that actually need the model.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _whisper.ensureReady().catchError((_) {});
      _gemma.ensureReady().catchError((_) {});
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
