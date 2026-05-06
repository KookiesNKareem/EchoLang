// Personal record mode: phone-only lecture pipeline.
//
// Tap record → capture audio via the system mic → stop → on-device Whisper
// transcribes → on-device Gemma generates a study pack → the result lands
// in the lectures list as if it had been downloaded from a Pi.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:record/record.dart';
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
  final AudioRecorder _recorder = AudioRecorder();
  final _titleCtrl = TextEditingController(text: 'Recorded lecture');
  late final AnimationController _pulse;
  _Phase _phase = _Phase.idle;
  String? _statusMsg;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  // Raw PCM16 audio captured during recording. Cactus's STT pipeline
  // expects a stream of these bytes; we collect them here, then hand
  // off as a single Stream.value(...) at stop time.
  final List<int> _audioBuffer = [];
  StreamSubscription<List<int>>? _audioSub;
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
    _recorder.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      setState(() {
        _phase = _Phase.error;
        _statusMsg = 'Microphone permission denied. Enable it in Settings.';
      });
      return;
    }
    _audioBuffer.clear();
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _audioSub = stream.listen(_audioBuffer.addAll);
    setState(() {
      _phase = _Phase.recording;
      _statusMsg = null;
      _elapsed = Duration.zero;
      _startedAt = DateTime.now();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _stopRecording() async {
    await _recorder.stop();
    await _audioSub?.cancel();
    _audioSub = null;
    _timer?.cancel();
    if (_audioBuffer.isEmpty) {
      setState(() {
        _phase = _Phase.error;
        _statusMsg = 'Recording captured no audio.';
      });
      return;
    }
    await _processRecording();
  }

  Future<void> _processRecording() async {
    setState(() {
      _phase = _Phase.transcribing;
      _statusMsg = 'Loading Whisper…';
    });
    try {
      await widget.whisper.ensureReady(onProgress: (p, status) {
        if (!mounted) return;
        setState(() => _statusMsg =
            p != null ? 'Whisper download ${(p * 100).toStringAsFixed(0)}%' : status);
      });

      setState(() => _statusMsg = 'Transcribing your lecture…');
      final audio = Uint8List.fromList(_audioBuffer);
      _audioBuffer.clear();
      final transcript = await widget.whisper.transcribeBytes(audio);

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
                        elapsed: _elapsed, fmt: _fmt, pulse: _pulse),
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
  const _RecordingIndicator({required this.elapsed, required this.fmt, required this.pulse});

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
          'Recording…',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
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
