import 'package:go_router/go_router.dart';

import 'data/bundle_store.dart';
import 'llm/gemma.dart';
import 'screens/connect_screen.dart';
import 'screens/lecture_screen.dart';
import 'screens/lectures_screen.dart';
import 'screens/qa_screen.dart';

GoRouter buildRouter({required BundleStore store, required GemmaService gemma}) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => LecturesScreen(store: store),
      ),
      GoRoute(
        path: '/connect',
        builder: (_, state) {
          // Optional deep-link prefill: /connect?host=...&class=...&lang=...
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
        path: '/lecture/:dirPath',
        builder: (_, state) => LectureScreen(
          store: store,
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
    ],
  );
}
