import 'package:go_router/go_router.dart';

import 'data/bundle_store.dart';
import 'llm/gemma.dart';
import 'llm/whisper.dart';
import 'screens/connect_screen.dart';
import 'screens/lecture_screen.dart';
import 'screens/lectures_screen.dart';
import 'screens/qa_screen.dart';
import 'screens/quiz_screen.dart';
import 'screens/record_screen.dart';
import 'screens/settings_screen.dart';

GoRouter buildRouter({
  required BundleStore store,
  required GemmaService gemma,
  required WhisperService whisper,
}) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => LecturesScreen(store: store, gemma: gemma, whisper: whisper),
      ),
      GoRoute(
        path: '/connect',
        builder: (_, state) {
          final qp = state.uri.queryParameters;
          return ConnectScreen(
            store: store,
            prefillHost: qp['host'],
            prefillClassId: qp['class'],
            prefillLang: qp['lang'],
          );
        },
      ),
      GoRoute(
        path: '/record',
        builder: (_, __) => RecordScreen(store: store, whisper: whisper, gemma: gemma),
      ),
      GoRoute(
        path: '/lecture/:dirPath',
        builder: (_, state) => LectureScreen(
          store: store,
          gemma: gemma,
          dirPath: Uri.decodeComponent(state.pathParameters['dirPath']!),
        ),
      ),
      GoRoute(
        path: '/qa/:dirPath',
        builder: (_, state) => QAScreen(
          store: store,
          gemma: gemma,
          dirPath: Uri.decodeComponent(state.pathParameters['dirPath']!),
        ),
      ),
      GoRoute(
        path: '/quiz/:dirPath',
        builder: (_, state) => QuizScreen(
          store: store,
          gemma: gemma,
          dirPath: Uri.decodeComponent(state.pathParameters['dirPath']!),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, __) => SettingsScreen(
          store: store,
          gemma: gemma,
          whisper: whisper,
        ),
      ),
    ],
  );
}
