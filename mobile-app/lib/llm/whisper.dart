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

  /// Force a fresh attempt at native speech-recognition initialization. Used
  /// by the Settings "Retry permission" button: if the user originally
  /// denied the iOS Speech Recognition prompt and has since flipped it on
  /// in Settings, this re-checks without restarting the app.
  Future<void> retryNativeInit() async {
    _readyFuture = null;
    _status = WhisperStatus.notReady;
    _backend = null;
    _statusMessage = null;
    return ensureReady();
  }

  /// True when the active backend is the on-device iOS Speech framework.
  bool get hasNativeBackend => _backend == SpeechBackend.native;

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
  String _currentPartial = '';
  String _liveLocale = 'en_US';
  void Function(String)? _liveOnPartial;
  Timer? _cycleTimer;

  Future<void> _startNativeSession() async {
    _currentPartial = '';
    await _native.listen(
      onResult: (r) {
        // Always update the live partial — iOS may or may not fire a
        // finalResult before auto-stopping, so we can't trust that flag to
        // commit. Track the most recent guess on every callback and commit
        // it whenever the session ends.
        _currentPartial = r.recognizedWords;
        if (r.finalResult) {
          _commitPartial();
        } else {
          _liveOnPartial?.call(_previewText());
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
    // Pre-emptive cycle: iOS Speech.framework will auto-stop at ~30 s wall
    // clock regardless of what we set, so we manually rotate sessions at
    // 25 s to ensure we own the transition. _commitPartial preserves words
    // across the boundary; the new session resumes recognition immediately.
    _cycleTimer?.cancel();
    _cycleTimer = Timer(const Duration(seconds: 25), () async {
      if (!_wantListening) return;
      _commitPartial();
      try {
        if (_native.isListening) await _native.stop();
      } catch (_) {}
      if (_wantListening) {
        try {
          await _startNativeSession();
        } catch (_) {}
      }
    });
  }

  void _commitPartial() {
    final t = _currentPartial.trim();
    _currentPartial = '';
    if (t.isEmpty) return;
    // Avoid double-counting if the same final fires twice (iOS sometimes
    // emits both a final and a 'done' status with identical text).
    if (_accumulated.endsWith(t)) return;
    _accumulated = _accumulated.isEmpty ? t : '$_accumulated $t';
    _liveOnPartial?.call(_accumulated);
  }

  String _previewText() {
    final p = _currentPartial.trim();
    if (_accumulated.isEmpty) return p;
    if (p.isEmpty) return _accumulated;
    return '$_accumulated $p';
  }

  void _onNativeStatusChanged(String status) {
    if (!_wantListening) return;
    if (status == 'notListening' || status == 'done') {
      // Commit whatever the recognizer had before iOS yanked the session,
      // then restart. The proactive cycle timer is the primary mechanism;
      // this is the safety net for when iOS stops us early (silence, audio
      // session interruption, etc.).
      _commitPartial();
      _cycleTimer?.cancel();
      Future.delayed(const Duration(milliseconds: 120), () {
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
      _cycleTimer?.cancel();
      if (_native.isListening) await _native.stop();
      // Commit whatever the recognizer still had buffered, then return the
      // running accumulator. We can't trust the recognizer to fire one last
      // finalResult on stop.
      _commitPartial();
      _liveOnPartial = null;
      final combined = _accumulated.trim();
      final text = _stripWhisperTokens(combined).trim();
      _accumulated = '';
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
    _cycleTimer?.cancel();
    if (_native.isListening) _native.stop();
    _cactus?.unload();
    _cactus = null;
    _status = WhisperStatus.notReady;
    _accumulated = '';
    _currentPartial = '';
    _readyFuture = null;
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
