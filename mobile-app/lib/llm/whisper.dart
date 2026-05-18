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

  /// Re-checks native speech-recognition when user re-enables in Settings.
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
      _sessionStarted = '';
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
  /// Running cumulative text we've already credited to [_accumulated] for the
  /// active session. iOS Speech delivers cumulative results, so we diff each
  /// new commit against this to avoid re-appending what we already added.
  String _sessionStarted = '';
  String _liveLocale = 'en_US';
  void Function(String)? _liveOnPartial;
  Timer? _cycleTimer;
  String? _lastErrorMessage;
  int _restartAttempts = 0;
  bool _cycling = false;
  /// Drops onResult callbacks during a cycle transition, so a late final from
  /// the prior session can't write its full text into the new session's state.
  bool _acceptingResults = true;
  static const _maxConsecutiveRestartFailures = 5;

  /// Latest non-permanent STT error message, surfaced in the recording UI so
  /// users can see when the recognizer hits a transient issue (and our
  /// retry logic is responding).
  String? get lastErrorMessage => _lastErrorMessage;

  Future<void> _startNativeSession() async {
    _currentPartial = '';
    await _native.listen(
      onResult: (r) {
        if (!_acceptingResults) return;
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
    _acceptingResults = true;
    _restartAttempts = 0;
    _cycleTimer?.cancel();
    _cycleTimer = Timer(const Duration(seconds: 20), () => _cycleNativeSession());
  }

  void _commitPartial() {
    final t = _currentPartial.trim();
    _currentPartial = '';
    if (t.isEmpty) return;
    String toAppend;
    if (_sessionStarted.isNotEmpty && t.startsWith(_sessionStarted)) {
      toAppend = t.substring(_sessionStarted.length).trim();
      if (toAppend.isEmpty) return;
      _sessionStarted = t;
    } else if (_sessionStarted.isNotEmpty && _sessionStarted.startsWith(t)) {
      return;
    } else if (_accumulated.endsWith(t)) {
      return;
    } else {
      toAppend = t;
      _sessionStarted = t;
    }
    _accumulated = _accumulated.isEmpty ? toAppend : '$_accumulated $toAppend';
    _liveOnPartial?.call(_accumulated);
  }

  String _previewText() {
    final p = _currentPartial.trim();
    if (_accumulated.isEmpty) return p;
    if (p.isEmpty) return _accumulated;
    if (_sessionStarted.isNotEmpty && p.startsWith(_sessionStarted)) {
      final tail = p.substring(_sessionStarted.length).trim();
      if (tail.isEmpty) return _accumulated;
      return '$_accumulated $tail';
    }
    return '$_accumulated $p';
  }

  /// Cycle the recognizer with retry logic; re-entrant calls blocked by [_cycling].
  Future<void> _cycleNativeSession() async {
    if (_cycling || !_wantListening) return;
    _cycling = true;
    _acceptingResults = false;
    try {
      _commitPartial();
      try {
        if (_native.isListening) await _native.stop();
      } catch (_) {}
      // Drain pending callbacks — iOS often delivers a cumulative final
      // result after stop(), which the gate above will now ignore.
      await Future.delayed(const Duration(milliseconds: 450));
      if (!_wantListening) return;
      _sessionStarted = '';
      try {
        await _startNativeSession();
      } catch (e) {
        _restartAttempts += 1;
        _lastErrorMessage = 'Restart attempt $_restartAttempts: $e';
        _liveOnPartial?.call(_previewText());
        if (_restartAttempts < _maxConsecutiveRestartFailures) {
          await Future.delayed(Duration(milliseconds: 400 * _restartAttempts));
          if (_wantListening) {
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

  /// Errors that are part of normal continuous-dictation operation and
  /// should not be surfaced to the user. iOS fires these whenever there's
  /// silence or audio that doesn't match a phrase — we just cycle and move on.
  static const _quietErrors = {
    'error_no_match',
    'error_speech_timeout',
    'error_no_speech_input',
  };

  /// Speech.framework error callback; transient errors trigger session recycle.
  void _onNativeError(dynamic err) {
    final code = err.errorMsg?.toString() ?? '';
    if (!_quietErrors.contains(code)) {
      _lastErrorMessage = code;
    }
    if (!_wantListening) return;
    if (err.permanent) {
      _wantListening = false;
      _cycleTimer?.cancel();
      return;
    }
    unawaited(_cycleNativeSession());
  }

  void _onNativeStatusChanged(String status) {
    if (!_wantListening) return;
    if (status == 'notListening' || status == 'done') {
      // iOS stopped us; recycle the session (handles commit + restart).
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
      // iOS doesn't reliably fire finalResult on stop; commit what's buffered.
      _commitPartial();
      _liveOnPartial = null;
      final combined = _accumulated.trim();
      final text = _stripWhisperTokens(combined).trim();
      _accumulated = '';
      _sessionStarted = '';
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
    _sessionStarted = '';
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
