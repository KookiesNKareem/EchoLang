// Personal record mode: phone-only lecture pipeline.
//
// Tap record → capture audio via the system mic → stop → on-device Whisper
// transcribes → on-device Gemma generates a study pack → the result lands
// in the lectures list as if it had been downloaded from a Pi.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/bundle_store.dart';
import '../llm/gemma.dart';
import '../llm/whisper.dart';

enum _Phase { idle, recording, transcribing, summarizing, error, done }

class RecordScreen extends StatefulWidget {
  final BundleStore store;
  final WhisperService whisper;
  final GemmaService gemma;
  const RecordScreen({
    super.key,
    required this.store,
    required this.whisper,
    required this.gemma,
  });

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> with SingleTickerProviderStateMixin {
  final _titleCtrl = TextEditingController(text: 'Recorded lecture');
  late final AnimationController _pulse;
  _Phase _phase = _Phase.idle;
  String? _statusMsg;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Timer? _flushTimer;
  String _livePartial = '';
  String _latestPartial = '';
  DateTime _lastUiFlush = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    // Unload Gemma to free RAM during recording; reload when study pack starts.
    widget.gemma.unload();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _timer?.cancel();
    _flushTimer?.cancel();
    if (widget.whisper.isListening) {
      widget.whisper.stopListening().catchError((_) => '');
    }
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      await widget.whisper.ensureReady();
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _statusMsg = 'Speech recognition not ready: $e';
      });
      return;
    }
    setState(() {
      _phase = _Phase.recording;
      _statusMsg = null;
      _elapsed = Duration.zero;
      _livePartial = '';
      _latestPartial = '';
      _startedAt = DateTime.now();
    });
    try {
      await widget.whisper.startListening(onPartial: (partial) {
        if (!mounted) return;
        _latestPartial = partial;
        // Throttle UI rebuilds — without this, a 30-minute session fires
        // setState on every token and the whole transcript widget re-lays
        // out hundreds of times a second. We cap to ~10 fps; the file flush
        // timer below catches whatever lands between rebuilds.
        final now = DateTime.now();
        if (now.difference(_lastUiFlush).inMilliseconds >= 100) {
          _lastUiFlush = now;
          setState(() => _livePartial = partial);
        }
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.error;
        _statusMsg = 'Couldn’t start recording: $e';
      });
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
    // Flush the live transcript to disk every 10s so a crash mid-recording
    // doesn't lose everything. On next launch we can recover from
    // Documents/in_progress_recording.txt.
    _flushTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (_latestPartial.isEmpty) return;
      try {
        final docs = await getApplicationDocumentsDirectory();
        final f = File('${docs.path}/in_progress_recording.json');
        final payload = {
          'started_at_ms': _startedAt?.millisecondsSinceEpoch,
          'elapsed_ms': _elapsed.inMilliseconds,
          'title': _titleCtrl.text.trim().isEmpty
              ? 'Recovered lecture'
              : _titleCtrl.text.trim(),
          'transcript': _latestPartial,
        };
        await f.writeAsString(jsonEncode(payload));
      } catch (_) {}
    });
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
    _flushTimer?.cancel();
    await _processRecording();
  }

  Future<void> _processRecording() async {
    setState(() {
      _phase = _Phase.transcribing;
      _statusMsg = 'Finalizing transcript…';
    });
    try {
      final transcript = await widget.whisper.stopListening();

      setState(() {
        _phase = _Phase.summarizing;
        _statusMsg = 'Loading Gemma 4…';
      });
      await widget.gemma.ensureReady(onProgress: (p, status) {
        if (!mounted) return;
        setState(() => _statusMsg =
            p != null ? 'Gemma 4 download ${(p * 100).toStringAsFixed(0)}%' : status);
      });

      setState(() => _statusMsg = 'Writing your study pack…');
      final pack = await widget.gemma.generateStudyPack(transcript: transcript);

      final classId = const Uuid().v4().substring(0, 12);
      final endedAt = DateTime.now();
      final ref = await widget.store.saveLocal(
        classId: classId,
        title: _titleCtrl.text.trim().isEmpty ? 'Recorded lecture' : _titleCtrl.text.trim(),
        lang: 'en',
        startedAt: _startedAt ?? endedAt.subtract(_elapsed),
        endedAt: endedAt,
        transcript: transcript,
        studyPack: pack,
      );

      // Recording made it safely to disk — clear the recovery file.
      try {
        final docs = await getApplicationDocumentsDirectory();
        final f = File('${docs.path}/in_progress_recording.json');
        if (await f.exists()) await f.delete();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _phase = _Phase.done;
        _statusMsg = 'Saved.';
      });
      context.pop();
      context.push('/lecture/${Uri.encodeComponent(ref.dir.path)}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _statusMsg = 'Failed: $e';
      });
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _phase == _Phase.recording ? null : () => context.pop(),
        ),
        title: const Text('Record a lecture'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_phase == _Phase.idle) ...[
                Text(
                  'No Pi? No internet?',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Record the lecture here. Whisper transcribes on this phone, '
                  'then Gemma 4 writes you a study pack — all offline.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Lecture title',
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: switch (_phase) {
                  _Phase.recording => _RecordingView(
                      elapsed: _elapsed,
                      fmt: _fmt,
                      livePartial: widget.whisper.supportsLiveCaptions ? _livePartial : null,
                      backendLabel: widget.whisper.hasNativeBackend
                          ? 'iOS Speech · on-device'
                          : 'Whisper · fallback',
                      errorMessage: widget.whisper.lastErrorMessage,
                    ),
                  _Phase.transcribing || _Phase.summarizing =>
                    Center(child: _ProcessingIndicator(message: _statusMsg ?? 'Working…')),
                  _Phase.error => Center(child: _ErrorIndicator(message: _statusMsg ?? 'Something went wrong')),
                  _ => Center(child: _IdleHint(color: cs.primary)),
                },
              ),
              const SizedBox(height: 16),
              if (_phase == _Phase.idle) ...[
                FilledButton.icon(
                  onPressed: _startRecording,
                  icon: const Icon(Icons.fiber_manual_record_rounded, color: Color(0xFFE53935)),
                  label: const Text('Start recording'),
                ),
              ] else if (_phase == _Phase.recording) ...[
                FilledButton.icon(
                  onPressed: _stopRecording,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Stop & transcribe'),
                ),
              ] else if (_phase == _Phase.error) ...[
                FilledButton(
                  onPressed: () => setState(() {
                    _phase = _Phase.idle;
                    _statusMsg = null;
                  }),
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IdleHint extends StatelessWidget {
  final Color color;
  const _IdleHint({required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160, height: 160,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.02)],
        ),
      ),
      child: Icon(Icons.mic_rounded, size: 72, color: color.withValues(alpha: 0.6)),
    );
  }
}

class _RecordingView extends StatelessWidget {
  final Duration elapsed;
  final String Function(Duration) fmt;
  final String? livePartial;
  final String backendLabel;
  final String? errorMessage;
  const _RecordingView({
    required this.elapsed,
    required this.fmt,
    required this.backendLabel,
    this.livePartial,
    this.errorMessage,
  });

  int get _wordCount {
    final t = livePartial?.trim();
    if (t == null || t.isEmpty) return 0;
    return t.split(RegExp(r'\s+')).length;
  }

  @override
  Widget build(BuildContext context) {
    final hasText = livePartial != null && livePartial!.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Compact pulse header — keeps the mic visible without dominating.
        Row(
          children: [
            Container(
              width: 56, height: 56,
              decoration: const BoxDecoration(
                color: Color(0xFFE53935), shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mic_rounded, size: 26, color: Colors.white),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fmt(elapsed),
                    style: const TextStyle(
                      fontSize: 32, fontWeight: FontWeight.w300,
                      fontFeatures: [FontFeature.tabularFigures()],
                      letterSpacing: 1,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        width: 6, height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF7AE0A0),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          backendLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                      if (hasText) ...[
                        const SizedBox(width: 8),
                        Text(
                          '· $_wordCount words',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (errorMessage != null && errorMessage!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE57373).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE57373).withValues(alpha: 0.32)),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 14, color: Color(0xFFE57373)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'STT: $errorMessage',
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5, color: Color(0xFFE57373),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Live transcript fills the rest of the screen so the user can SEE
        // every word land. Empty state explains why nothing is showing yet.
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: hasText
                ? SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      livePartial!,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                  )
                : Center(
                    child: Text(
                      livePartial == null
                          ? 'Live transcription not available on this backend.\nSpeech will be transcribed when you stop.'
                          : 'Listening…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14, height: 1.5,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ProcessingIndicator extends StatelessWidget {
  final String message;
  const _ProcessingIndicator({required this.message});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 64, height: 64,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            message,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _ErrorIndicator extends StatelessWidget {
  final String message;
  const _ErrorIndicator({required this.message});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline_rounded, size: 64, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
