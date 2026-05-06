// On-device speech-to-text via Cactus's CactusSTT (Whisper under the hood).
//
// Used in personal record mode: phone records audio, this transcribes it
// fully locally so the user gets a transcript + study pack + Q&A even with
// no Pi and no internet.

import 'package:cactus/cactus.dart';

enum WhisperStatus { notReady, downloading, ready, error }

class WhisperService {
  /// `whisper-tiny` is ~75MB — fast download, English-best, multilingual ok.
  /// `whisper-base` is ~150MB — slower but more accurate. Bump later if needed.
  static const String modelId = 'whisper-tiny';

  final CactusSTT _stt = CactusSTT();
  WhisperStatus _status = WhisperStatus.notReady;
  WhisperStatus get status => _status;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  Future<void> ensureReady({void Function(double? progress, String status)? onProgress}) async {
    if (_status == WhisperStatus.ready) return;
    _status = WhisperStatus.downloading;
    try {
      await _stt.downloadModel(
        model: modelId,
        downloadProcessCallback: (progress, status, isError) {
          _statusMessage = status;
          onProgress?.call(progress, status);
          if (isError) _status = WhisperStatus.error;
        },
      );
      await _stt.initializeModel();
      _status = WhisperStatus.ready;
      _statusMessage = 'Whisper ready';
    } catch (e) {
      _status = WhisperStatus.error;
      _statusMessage = 'Failed to load Whisper: $e';
      rethrow;
    }
  }

  /// Transcribe a WAV file at [audioFilePath]. Returns the full transcript.
  Future<String> transcribeFile(String audioFilePath) async {
    if (_status != WhisperStatus.ready) {
      throw StateError('Whisper not ready (status=$_status)');
    }
    final result = await _stt.transcribe(audioFilePath: audioFilePath);
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

  void unload() => _stt.unload();
}
