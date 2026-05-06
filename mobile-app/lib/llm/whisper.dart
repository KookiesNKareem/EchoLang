// On-device speech-to-text via Cactus's CactusSTT (Whisper under the hood).
//
// Used in personal record mode: phone records audio, this transcribes it
// fully locally so the user gets a transcript + study pack + Q&A even with
// no Pi and no internet.

import 'package:cactus/cactus.dart';

enum WhisperStatus { notReady, downloading, ready, error }

class WhisperService {
  /// Cactus catalog model id. Full HuggingFace org/name form is most
  /// resilient across SDK versions — the short alias "whisper-tiny" failed
  /// at runtime with a "voice model not found" error on iOS. The pre-
  /// quantized weights live at huggingface.co/Cactus-Compute/whisper-tiny.
  /// Tiny is ~75MB and English-best, multilingual ok.
  static const String modelId = 'Cactus-Compute/whisper-tiny';

  // Lazy: same reasoning as GemmaService — instantiating CactusSTT runs
  // native-side init that can crash a release-mode iOS build at launch.
  // Defer until the user enters the Record screen.
  CactusSTT? _stt;
  WhisperStatus _status = WhisperStatus.notReady;
  WhisperStatus get status => _status;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  // Memoize the in-flight load so background pre-load + on-demand calls
  // from screens share a single download/init pass.
  Future<void>? _readyFuture;
  final List<void Function(double? progress, String status)> _listeners = [];

  Future<void> ensureReady({void Function(double? progress, String status)? onProgress}) {
    if (onProgress != null) _listeners.add(onProgress);
    return _readyFuture ??= _load();
  }

  Future<void> _load() async {
    if (_status == WhisperStatus.ready) return;
    _status = WhisperStatus.downloading;
    try {
      _stt ??= CactusSTT();
      await _stt!.downloadModel(
        model: modelId,
        downloadProcessCallback: (progress, status, isError) {
          _statusMessage = status;
          for (final l in _listeners) {
            l(progress, status);
          }
          if (isError) _status = WhisperStatus.error;
        },
      );
      await _stt!.initializeModel();
      _status = WhisperStatus.ready;
      _statusMessage = 'Whisper ready';
    } catch (e) {
      _status = WhisperStatus.error;
      _statusMessage = 'Failed to load Whisper: $e';
      _readyFuture = null; // allow retries
      rethrow;
    }
  }

  /// Transcribe a WAV file at [audioFilePath]. Returns the full transcript.
  Future<String> transcribeFile(String audioFilePath) async {
    if (_status != WhisperStatus.ready || _stt == null) {
      throw StateError('Whisper not ready (status=$_status)');
    }
    final result = await _stt!.transcribe(audioFilePath: audioFilePath);
    return _extractText(result);
  }

  /// Some Cactus versions return a typed result with .text, others a String.
  /// Handle both shapes defensively.
  String _extractText(dynamic result) {
    if (result is String) return result.trim();
    try {
      final t = (result as dynamic).text;
      if (t is String) return t.trim();
    } catch (_) {}
    return result.toString().trim();
  }

  void unload() {
    _stt?.unload();
    _stt = null;
    _status = WhisperStatus.notReady;
  }
}
