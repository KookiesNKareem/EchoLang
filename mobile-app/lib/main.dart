import 'package:flutter/material.dart';

import 'data/bundle_store.dart';
import 'llm/gemma.dart';
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

  @override
  void dispose() {
    _gemma.unload();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'LocalLearning',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      routerConfig: buildRouter(store: _store, gemma: _gemma),
    );
  }
}
