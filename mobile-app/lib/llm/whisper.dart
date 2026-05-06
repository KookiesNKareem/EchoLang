// On-device speech-to-text via Cactus's CactusSTT (Whisper under the hood).
//
// Used in personal record mode: phone records audio, this transcribes it
// fully locally so the user gets a transcript + study pack + Q&A even with
// no Pi and no internet.

import 'dart:typed_data';

import 'package:cactus/cactus.dart';

enum WhisperStatus { notReady, downloading, ready, error }

class WhisperService {
  /// Cactus's voice-model registry indexes by bare slug, not by HuggingFace
  /// org/name. The full set as of v1.3 (verified against the SDK's
  /// /api/voice-models response): whisper-tiny (30MB), whisper-base (57MB),
  /// whisper-small (192MB), whisper-medium (615MB), and *-pro variants with
  /// slightly higher accuracy at ~25% larger size. Tiny keeps the first-
  /// install download under a minute on a phone connection.
  static const String modelId = 'whisper-tiny';

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
      // initializeModel() without params defaults to "qwen3-0.6" (CactusInitParams
      // default) and tries to load that — which doesn't exist as a voice model.
      // Have to pass the model id explicitly here.
      await _stt!.initializeModel(params: CactusInitParams(model: modelId));
      _status = WhisperStatus.ready;
      _statusMessage = 'Whisper ready';
      for (final l in _listeners) {
        l(1.0, _statusMessage!);
      }
    } catch (e) {
      _status = WhisperStatus.error;
      _statusMessage = 'Failed to load Whisper: $e';
      _readyFuture = null; // allow retries
      rethrow;
    }
  }

  /// Transcribe raw 16-bit PCM audio (mono, 16kHz) from a [Uint8List].
  ///
  /// The Cactus iOS pipeline expects *streamed* raw PCM, not a WAV file.
  /// Passing a WAV file via transcribe(audioFilePath:) errors with
  /// "transcription failed code -1" — the underlying engine doesn't parse
  /// the WAV header. Use AudioRecorder.startStream(AudioEncoder.pcm16bits)
  /// to feed this method.
  Future<String> transcribeBytes(Uint8List audio) async {
    if (_status != WhisperStatus.ready || _stt == null) {
      throw StateError('Whisper not ready (status=$_status)');
    }
    if (audio.length < 16000 * 2) {
      // <1 second of mono PCM16 at 16kHz = 32 KB. Anything less is silence.
      throw Exception(
        'Audio too short (${audio.length} bytes) — microphone may have been '
        'muted or no sound captured.',
      );
    }
    final streamed = await _stt!.transcribeStream(audioStream: Stream.value(audio));
    // Drain the token stream so the result completer fires.
    final tokens = StringBuffer();
    streamed.stream.listen((t) => tokens.write(t));
    final result = await streamed.result;
    if (!result.success) {
      throw Exception('Whisper failed: ${result.errorMessage ?? "unknown error"}');
    }
    final text = (result.text.isNotEmpty ? result.text : tokens.toString()).trim();
    if (text.isEmpty) {
      throw Exception(
        'Whisper produced an empty transcript. The audio probably had no '
        'recognizable speech, or whisper-tiny missed it. Try recording '
        'closer to the speaker, or upgrade to whisper-base.',
      );
    }
    return text;
  }

  void unload() {
    _stt?.unload();
    _stt = null;
    _status = WhisperStatus.notReady;
  }
}
