// On-device Gemma 4 E2B via Cactus.
//
// First app launch downloads Cactus's pre-quantized Gemma 4 E2B build
// (~1-2 GB) from HuggingFace via the Cactus model registry. Subsequent
// launches reuse the cached model from local storage.
//
// All Q&A is grounded in the lecture transcript injected as system context
// — the model answers about *this* lecture, not its general knowledge.

import 'package:cactus/cactus.dart';

/// Status of the on-device model.
enum GemmaStatus { notReady, downloading, ready, error }

class GemmaService {
  static const String modelId = 'google/gemma-4-E2B-it';

  final CactusLM _lm = CactusLM();
  GemmaStatus _status = GemmaStatus.notReady;
  GemmaStatus get status => _status;

  double? _progress; // 0..1 while downloading
  double? get downloadProgress => _progress;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  /// Ensure the model is downloaded and initialized. Idempotent — safe to
  /// call from multiple screens; subsequent calls return immediately if
  /// the model is already loaded.
  Future<void> ensureReady({void Function(double? progress, String status)? onProgress}) async {
    if (_status == GemmaStatus.ready) return;
    _status = GemmaStatus.downloading;
    try {
      await _lm.downloadModel(
        model: modelId,
        downloadProcessCallback: (progress, status, isError) {
          _progress = progress;
          _statusMessage = status;
          onProgress?.call(progress, status);
          if (isError) _status = GemmaStatus.error;
        },
      );
      await _lm.initializeModel();
      _status = GemmaStatus.ready;
      _statusMessage = 'Model ready';
    } catch (e) {
      _status = GemmaStatus.error;
      _statusMessage = 'Failed to load model: $e';
      rethrow;
    }
  }

  /// Ask a question grounded in the lecture transcript.
  /// Returns the full answer (Cactus's generateCompletion is non-streaming;
  /// we surface it all at once when the model finishes generating).
  Future<String> ask({required String lectureContext, required String question}) async {
    if (_status != GemmaStatus.ready) {
      throw StateError('Gemma model not ready (status=$_status)');
    }
    final trimmedContext = _trimContext(lectureContext);
    final messages = <ChatMessage>[
      ChatMessage(
        role: 'system',
        content:
            'You are a tutor helping a student review a lecture they attended. '
            'Answer using only what is in the transcript below. If the answer '
            'is not in the transcript, say so plainly. Reply in the same '
            'language the student used.\n\n'
            '--- LECTURE TRANSCRIPT ---\n$trimmedContext\n--- END TRANSCRIPT ---',
      ),
      ChatMessage(role: 'user', content: question),
    ];
    final result = await _lm.generateCompletion(messages: messages);
    if (!result.success) {
      throw Exception('Gemma generation failed');
    }
    return result.response.trim();
  }

  void unload() => _lm.unload();

  String _trimContext(String ctx) {
    if (ctx.length <= 6000) return ctx;
    return ctx.substring(0, 3000) +
        '\n[…middle of lecture omitted…]\n' +
        ctx.substring(ctx.length - 3000);
  }
}
