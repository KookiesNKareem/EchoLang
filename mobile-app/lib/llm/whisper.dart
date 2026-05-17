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
      _lastErrorMessage = null;
      _native.statusListener = _onNativeStatusChanged;
      _native.errorListener = _onNativeError;
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
  String? _lastErrorMessage;
  int _restartAttempts = 0;
  // Guard against concurrent _cycleNativeSession invocations. iOS can fire
  // a status='notListening' callback AT THE SAME TIME the proactive cycle
  // timer fires — without this gate, both fire stop()+listen() and we end
  // up with two parallel recognizers, each delivering the same partial as
  // a new final. The visible symptom was the word counter doubling in one
  // tick (e.g. 80 → 158).
  bool _cycling = false;
  static const _maxConsecutiveRestartFailures = 5;

  /// Latest non-permanent STT error message, surfaced in the recording UI so
  /// users can see when the recognizer hits a transient issue (and our
  /// retry logic is responding).
  String? get lastErrorMessage => _lastErrorMessage;

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
    // Successful start resets the retry counter.
    _restartAttempts = 0;
    _cycleTimer?.cancel();
    _cycleTimer = Timer(const Duration(seconds: 25), () => _cycleNativeSession());
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

  /// Stop + restart cycle. Errors are caught and retried up to a small
  /// cap so a single bad transition can't permanently kill the recognizer.
  /// Re-entrant calls are dropped — see [_cycling].
  Future<void> _cycleNativeSession() async {
    if (_cycling || !_wantListening) return;
    _cycling = true;
    try {
      _commitPartial();
      try {
        if (_native.isListening) await _native.stop();
      } catch (_) {}
      // Brief beat for iOS to fully release the audio session before we
      // ask for it back. Without this, listen() sometimes throws on rapid
      // cycle.
      await Future.delayed(const Duration(milliseconds: 250));
      if (!_wantListening) return;
      try {
        await _startNativeSession();
      } catch (e) {
        _restartAttempts += 1;
        _lastErrorMessage = 'Restart attempt $_restartAttempts: $e';
        _liveOnPartial?.call(_previewText());
        if (_restartAttempts < _maxConsecutiveRestartFailures) {
          await Future.delayed(Duration(milliseconds: 400 * _restartAttempts));
          if (_wantListening) {
            // Re-enter via a fresh call so the gate lets us through.
            _cycling = false;
            unawaited(_cycleNativeSession());
            return;
          }
        }
      }
    } finally {
      _cycling = false;
    }
  }

  /// Speech.framework reports errors via this callback. Most of them are
  /// transient (audio session interruption, brief network blip, etc.) and
  /// the right response is to recycle the session.
  void _onNativeError(dynamic err) {
    _lastErrorMessage = err.errorMsg;
    if (!_wantListening) return;
    // Don't double-cycle if the status listener is already going to fire.
    if (err.permanent) {
      // Permanent errors usually mean no recognition will work in this
      // session — let it die rather than spinning forever.
      _wantListening = false;
      _cycleTimer?.cancel();
      return;
    }
    // Best-effort: kick off a recycle. cycle is idempotent against
    // statusListener-driven recycles via _restartAttempts cap.
    unawaited(_cycleNativeSession());
  }

  void _onNativeStatusChanged(String status) {
    if (!_wantListening) return;
    if (status == 'notListening' || status == 'done') {
      // Safety net for when iOS stops us before our proactive cycle fires
      // (silence cut, audio session interruption, etc.). _cycleNativeSession
      // handles commit, stop, restart, and retry-with-backoff in one place.
      _cycleTimer?.cancel();
      unawaited(_cycleNativeSession());
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
