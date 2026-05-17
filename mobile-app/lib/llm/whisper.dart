// On-device speech-to-text with native backend (preferred) and Whisper fallback.

import 'dart:async';
import 'dart:typed_data';

import 'package:cactus/cactus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum WhisperStatus { notReady, downloading, ready, error }

enum SpeechBackend { native, cactus }

class WhisperService {
  WhisperStatus _status = WhisperStatus.notReady;
  WhisperStatus get status => _status;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  SpeechBackend? _backend;
  SpeechBackend? get backend => _backend;
  bool get supportsLiveCaptions => _backend == SpeechBackend.native;

  // Native (preferred) backend
  final stt.SpeechToText _native = stt.SpeechToText();
  // Cactus (fallback) backend — only constructed if native fails
  CactusSTT? _cactus;

  /// Cactus model id, used only by the fallback path.
  static const String _cactusModelId = 'whisper-base';

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
      final available = await _native.initialize(debugLogging: false);
      if (available) {
        _backend = SpeechBackend.native;
        _status = WhisperStatus.ready;
        _statusMessage = 'Speech recognition ready';
        for (final l in _listeners) {
          l(1.0, _statusMessage!);
        }
        return;
      }
      _statusMessage = 'Native STT unavailable; downloading Whisper fallback…';
      for (final l in _listeners) {
        l(null, _statusMessage!);
      }
      _cactus = CactusSTT();
      await _cactus!.downloadModel(
        model: _cactusModelId,
        downloadProcessCallback: (p, status, isError) {
          _statusMessage = status;
          for (final l in _listeners) {
            l(p, status);
          }
          if (isError) _status = WhisperStatus.error;
        },
      );
      await _cactus!.initializeModel(params: CactusInitParams(model: _cactusModelId));
      _backend = SpeechBackend.cactus;
      _status = WhisperStatus.ready;
      _statusMessage = 'Whisper ready (fallback)';
      for (final l in _listeners) {
        l(1.0, _statusMessage!);
      }
    } catch (e) {
      _status = WhisperStatus.error;
      _statusMessage = 'Failed to set up speech recognition: $e';
      _readyFuture = null;
      rethrow;
    }
  }

  /// Start listening. With the native backend, [onPartial] fires every
  /// time the engine refines its guess (live captions). With Cactus, no
  /// partials arrive until [stopListening] is called.
  Future<void> startListening({
    required void Function(String partial) onPartial,
    String localeId = 'en_US',
    Stream<Uint8List> Function()? cactusAudioStreamFactory,
  }) async {
    if (_status != WhisperStatus.ready) {
      throw StateError('Speech recognizer not ready (status=$_status)');
    }
    if (_backend == SpeechBackend.native) {
      _wantListening = true;
      _accumulated = '';
      _liveLocale = localeId;
      _liveOnPartial = onPartial;
      // iOS Speech.framework auto-stops on ~3 s of silence and after ~30 s
      // wall-clock regardless of what the user is doing. Pass aggressive
      // durations AND wire a status listener that re-arms the session as
      // soon as iOS stops it, so a full lecture's audio actually lands in
      // the transcript instead of getting clipped on every pause.
      _native.statusListener = _onNativeStatusChanged;
      await _startNativeSession();
      return;
    }
    if (cactusAudioStreamFactory == null) {
      throw StateError('Cactus backend needs cactusAudioStreamFactory');
    }
    _pendingAudio = cactusAudioStreamFactory();
  }

  // Native-backend continuous-listening state.
  bool _wantListening = false;
  String _accumulated = '';
  String _liveLocale = 'en_US';
  void Function(String)? _liveOnPartial;

  Future<void> _startNativeSession() async {
    await _native.listen(
      onResult: (r) {
        final text = r.recognizedWords;
        if (r.finalResult) {
          // Lock this chunk into the accumulator; iOS will spin up the next
          // session from a fresh recognizer state.
          if (text.trim().isNotEmpty) {
            _accumulated = _accumulated.isEmpty ? text : '$_accumulated $text';
          }
          _liveOnPartial?.call(_accumulated);
        } else {
          // In-flight partial: show accumulated + current guess without
          // committing it yet.
          final preview = _accumulated.isEmpty
              ? text
              : (text.isEmpty ? _accumulated : '$_accumulated $text');
          _liveOnPartial?.call(preview);
        }
      },
      localeId: _liveLocale,
      listenFor: const Duration(hours: 1),
      pauseFor: const Duration(minutes: 5),
      listenOptions: stt.SpeechListenOptions(
        partialResults: true,
        onDevice: true,
        cancelOnError: false,
        listenMode: stt.ListenMode.dictation,
      ),
    );
  }

  void _onNativeStatusChanged(String status) {
    if (!_wantListening) return;
    // 'notListening' / 'done' both indicate iOS stopped the session. Restart
    // immediately so the user's continued speech isn't lost. A small delay
    // gives the underlying recognizer a beat to release resources.
    if (status == 'notListening' || status == 'done') {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_wantListening && _backend == SpeechBackend.native) {
          _startNativeSession().catchError((_) {});
        }
      });
    }
  }

  Stream<Uint8List>? _pendingAudio;
  String _cactusFinal = '';

  /// Returns the final transcript. Throws if nothing was captured.
  Future<String> stopListening() async {
    if (_backend == SpeechBackend.native) {
      _wantListening = false;
      if (_native.isListening) await _native.stop();
      // Splice any in-flight partial that hadn't yet been finalized.
      final tail = _native.lastRecognizedWords.trim();
      final combined = (_accumulated.isEmpty
              ? tail
              : (tail.isEmpty || _accumulated.endsWith(tail)
                  ? _accumulated
                  : '$_accumulated $tail'))
          .trim();
      _liveOnPartial = null;
      final text = _stripWhisperTokens(combined).trim();
      if (text.isEmpty) {
        throw Exception(
            'No speech detected. Try recording closer to the speaker.');
      }
      return text;
    }
    // Cactus path
    if (_cactus == null || _pendingAudio == null) {
      throw StateError('No active recording to stop');
    }
    final bytes = await _collectStream(_pendingAudio!);
    _pendingAudio = null;
    if (bytes.length < 16000 * 2) {
      throw Exception('Audio too short — microphone may have been muted.');
    }
    final streamed = await _cactus!
        .transcribeStream(audioStream: Stream.value(Uint8List.fromList(bytes)));
    final tokens = StringBuffer();
    streamed.stream.listen((t) => tokens.write(t));
    final result = await streamed.result;
    if (!result.success) {
      throw Exception('Whisper failed: ${result.errorMessage ?? "unknown error"}');
    }
    final raw = result.text.isNotEmpty ? result.text : tokens.toString();
    final text = _stripWhisperTokens(raw).trim();
    if (text.isEmpty) {
      throw Exception('Whisper produced an empty transcript.');
    }
    _cactusFinal = text;
    return text;
  }

  String get lastTranscript {
    if (_backend == SpeechBackend.native) return _native.lastRecognizedWords;
    return _cactusFinal;
  }

  bool get isListening => _backend == SpeechBackend.native ? _native.isListening : false;

  void unload() {
    _wantListening = false;
    _liveOnPartial = null;
    if (_native.isListening) _native.stop();
    _cactus?.unload();
    _cactus = null;
    _status = WhisperStatus.notReady;
  }

  static Future<List<int>> _collectStream(Stream<Uint8List> s) async {
    final out = <int>[];
    await for (final chunk in s) {
      out.addAll(chunk);
    }
    return out;
  }

  /// Strip Whisper's special tokens that occasionally leak through Cactus's
  /// streaming decoder despite the <|notimestamps|> prompt.
  static final RegExp _specialToken = RegExp(r'<\|[^|>]*\|>');
  String _stripWhisperTokens(String s) =>
      s.replaceAll(_specialToken, '').replaceAll(RegExp(r'\s+'), ' ');
}
