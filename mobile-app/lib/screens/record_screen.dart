// Personal record mode: phone-only lecture pipeline.
//
// Tap record → capture audio via the system mic → stop → on-device Whisper
// transcribes → on-device Gemma generates a study pack → the result lands
// in the lectures list as if it had been downloaded from a Pi.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
  // Live transcript built up from partial-result callbacks while recording.
  String _livePartial = '';
  DateTime? _startedAt;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _timer?.cancel();
    widget.whisper.unload();
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
      _startedAt = DateTime.now();
    });
    try {
      await widget.whisper.startListening(onPartial: (partial) {
        if (!mounted) return;
        setState(() => _livePartial = partial);
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
  }

  Future<void> _stopRecording() async {
    _timer?.cancel();
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
              const SizedBox(height: 24),
              Expanded(
                child: Center(
                  child: switch (_phase) {
                    _Phase.recording => _RecordingIndicator(
                        elapsed: _elapsed,
                        fmt: _fmt,
                        pulse: _pulse,
                        livePartial: widget.whisper.supportsLiveCaptions ? _livePartial : null,
                      ),
                    _Phase.transcribing || _Phase.summarizing =>
                      _ProcessingIndicator(message: _statusMsg ?? 'Working…'),
                    _Phase.error => _ErrorIndicator(message: _statusMsg ?? 'Something went wrong'),
                    _ => _IdleHint(color: cs.primary),
                  },
                ),
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

class _RecordingIndicator extends StatelessWidget {
  final Duration elapsed;
  final String Function(Duration) fmt;
  final AnimationController pulse;
  final String? livePartial; // null when backend doesn't stream partials
  const _RecordingIndicator({
    required this.elapsed,
    required this.fmt,
    required this.pulse,
    this.livePartial,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: pulse,
          builder: (_, __) {
            final t = pulse.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 160 + 40 * t, height: 160 + 40 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE53935).withValues(alpha: 0.10 * (1 - t)),
                  ),
                ),
                Container(
                  width: 140, height: 140,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE53935), shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic_rounded, size: 64, color: Colors.white),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        Text(
          fmt(elapsed),
          style: const TextStyle(
            fontSize: 36, fontWeight: FontWeight.w300,
            fontFeatures: [FontFeature.tabularFigures()],
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          livePartial != null && livePartial!.isNotEmpty ? 'Listening…' : 'Recording…',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
        if (livePartial != null && livePartial!.isNotEmpty) ...[
          const SizedBox(height: 24),
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            margin: const EdgeInsets.symmetric(horizontal: 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                livePartial!,
                style: const TextStyle(fontSize: 16, height: 1.4),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
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
