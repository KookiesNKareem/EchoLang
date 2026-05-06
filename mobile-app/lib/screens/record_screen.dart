// Personal record mode: phone-only lecture pipeline.
//
// Tap record → capture audio via the system mic → stop → on-device Whisper
// transcribes → on-device Gemma generates a study pack → the result lands
// in the lectures list as if it had been downloaded from a Pi.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
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

class _RecordScreenState extends State<RecordScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final _titleCtrl = TextEditingController(text: 'Recorded lecture');
  _Phase _phase = _Phase.idle;
  String? _statusMsg;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  String? _audioPath;
  DateTime? _startedAt;

  @override
  void dispose() {
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
    final tmp = await getTemporaryDirectory();
    final path = '${tmp.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    setState(() {
      _phase = _Phase.recording;
      _statusMsg = 'Recording…';
      _elapsed = Duration.zero;
      _audioPath = path;
      _startedAt = DateTime.now();
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stop();
    _timer?.cancel();
    if (path == null) {
      setState(() {
        _phase = _Phase.error;
        _statusMsg = 'Recording produced no audio file.';
      });
      return;
    }
    _audioPath = path;
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

      setState(() => _statusMsg = 'Transcribing…');
      final transcript = await widget.whisper.transcribeFile(_audioPath!);

      setState(() {
        _phase = _Phase.summarizing;
        _statusMsg = 'Loading Gemma…';
      });
      await widget.gemma.ensureReady(onProgress: (p, status) {
        if (!mounted) return;
        setState(() => _statusMsg =
            p != null ? 'Gemma download ${(p * 100).toStringAsFixed(0)}%' : status);
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
      // Pop back to the lectures list, which refreshes on return, then
      // immediately drop into the new lecture.
      context.pop();
      context.push('/lecture/${Uri.encodeComponent(ref.dir.path)}');
      // Drop the temp audio now that the user has navigated away from
      // this screen — we don't need context anymore.
      try { await File(_audioPath!).delete(); } catch (_) {}
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
    return Scaffold(
      appBar: AppBar(title: const Text('Record a lecture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_phase == _Phase.idle || _phase == _Phase.recording) ...[
                Text(
                  'No Pi? No internet? Record the lecture here. Whisper '
                  'transcribes on this phone, then Gemma writes you a study '
                  'pack — all offline.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _titleCtrl,
                  enabled: _phase == _Phase.idle,
                  decoration: const InputDecoration(
                    labelText: 'Lecture title',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: _phase == _Phase.recording
                      ? _RecordingIndicator(elapsed: _elapsed, fmt: _fmt)
                      : _phase == _Phase.transcribing || _phase == _Phase.summarizing
                          ? const _Working()
                          : const Icon(Icons.mic, size: 96, color: Colors.white24),
                ),
              ),
              if (_statusMsg != null) ...[
                Text(
                  _statusMsg!,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
              ],
              if (_phase == _Phase.idle) ...[
                FilledButton.icon(
                  onPressed: _startRecording,
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Start recording'),
                ),
              ] else if (_phase == _Phase.recording) ...[
                FilledButton.icon(
                  onPressed: _stopRecording,
                  icon: const Icon(Icons.stop),
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

class _RecordingIndicator extends StatelessWidget {
  final Duration elapsed;
  final String Function(Duration) fmt;
  const _RecordingIndicator({required this.elapsed, required this.fmt});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 96, height: 96,
          decoration: const BoxDecoration(
            color: Color(0xFFE53935), shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mic, size: 48, color: Colors.white),
        ),
        const SizedBox(height: 16),
        Text(fmt(elapsed),
          style: const TextStyle(
            fontSize: 32, fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();
  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}
