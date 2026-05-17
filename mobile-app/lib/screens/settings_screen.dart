// Settings + about screen. Shows storage usage, on-device model status,
// default language preference, and a "reset everything" escape hatch.
// Keeps the hackathon credit visible so judges who poke around can find it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../data/bundle_store.dart';
import '../data/preferences.dart';
import '../llm/gemma.dart';
import '../llm/whisper.dart';
import 'model_info_sheet.dart';

class SettingsScreen extends StatefulWidget {
  final BundleStore store;
  final GemmaService gemma;
  final WhisperService whisper;
  const SettingsScreen({
    super.key,
    required this.store,
    required this.gemma,
    required this.whisper,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _lectureCount = 0;
  int _lectureBytes = 0;
  int _modelBytes = 0;
  String? _defaultLang;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    final lectures = await widget.store.list();
    int lectureBytes = 0;
    for (final l in lectures) {
      lectureBytes += await _dirSize(l.dir);
    }
    int modelBytes = 0;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final modelDir = Directory(docs.path);
      if (await modelDir.exists()) {
        await for (final ent in modelDir.list(recursive: true)) {
          if (ent is File) {
            final n = ent.path.toLowerCase();
            if (n.endsWith('.litertlm') ||
                n.endsWith('.task') ||
                n.endsWith('.bin') ||
                n.endsWith('.gguf')) {
              modelBytes += await ent.length();
            }
          }
        }
      }
    } catch (_) {}
    final lang = await Preferences.getLastLang();
    if (!mounted) return;
    setState(() {
      _lectureCount = lectures.length;
      _lectureBytes = lectureBytes;
      _modelBytes = modelBytes;
      _defaultLang = (lang != null && langNames.containsKey(lang)) ? lang : 'en';
      _loading = false;
    });
  }

  Future<int> _dirSize(Directory dir) async {
    int total = 0;
    try {
      await for (final ent in dir.list(recursive: true, followLinks: false)) {
        if (ent is File) total += await ent.length();
      }
    } catch (_) {}
    return total;
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _pickDefaultLang() async {
    HapticFeedback.selectionClick();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text('Default study-pack language',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              ...langNames.entries.map((e) => ListTile(
                    title: Text(e.value),
                    trailing: e.key == _defaultLang
                        ? Icon(Icons.check_rounded,
                            color: Theme.of(sheetCtx).colorScheme.primary)
                        : Text(e.key.toUpperCase(),
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.4))),
                    onTap: () => Navigator.of(sheetCtx).pop(e.key),
                  )),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await Preferences.setLastLang(picked);
    if (!mounted) return;
    setState(() => _defaultLang = picked);
  }

  Future<void> _resetAll() async {
    HapticFeedback.mediumImpact();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all lectures?'),
        content: const Text(
          'This removes every recorded and downloaded lecture from this phone. '
          'The Gemma 4 and speech models stay installed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final lectures = await widget.store.list();
    for (final l in lectures) {
      await widget.store.delete(l.dir);
    }
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
        title: const Text('Settings'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                _section('On-device AI'),
                _card(
                  child: Column(
                    children: [
                      _statusRow(
                        icon: Icons.auto_awesome_rounded,
                        label: 'Gemma 4 E2B',
                        sub: _gemmaStatus(),
                        active: widget.gemma.status == GemmaStatus.ready,
                      ),
                      const Divider(height: 1),
                      _statusRow(
                        icon: Icons.mic_rounded,
                        label: 'Speech recognition',
                        sub: _whisperStatus(),
                        active: widget.whisper.status == WhisperStatus.ready,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _section('Privacy'),
                _card(
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.lock_outline_rounded, color: cs.primary, size: 20),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Everything stays on this device',
                                style: TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Audio, transcripts, translations, and Q&A never leave your phone. '
                          'No cloud, no accounts, no analytics — Gemma 4 runs locally for every answer.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: Colors.white.withValues(alpha: 0.72),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _section('Storage on this phone'),
                _card(
                  child: Column(
                    children: [
                      _kvRow('Saved lectures',
                          '$_lectureCount · ${_fmtBytes(_lectureBytes)}'),
                      const Divider(height: 1),
                      _kvRow('AI models', _fmtBytes(_modelBytes)),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _section('Preferences'),
                _card(
                  child: ListTile(
                    leading: Icon(Icons.translate_rounded, color: cs.primary),
                    title: const Text('Default language'),
                    subtitle: Text(
                      langNames[_defaultLang ?? 'en'] ?? 'English',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6)),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _pickDefaultLang,
                  ),
                ),
                const SizedBox(height: 24),
                _section('Danger zone'),
                _card(
                  child: ListTile(
                    leading: Icon(Icons.delete_sweep_outlined, color: cs.error),
                    title: Text('Delete all lectures',
                        style: TextStyle(color: cs.error)),
                    subtitle: const Text('Keeps installed models.'),
                    onTap: _resetAll,
                  ),
                ),
                const SizedBox(height: 32),
                _AboutCard(),
              ],
            ),
    );
  }

  String _gemmaStatus() {
    switch (widget.gemma.status) {
      case GemmaStatus.ready:
        return 'Ready · running on this phone';
      case GemmaStatus.downloading:
        return widget.gemma.statusMessage ?? 'Downloading…';
      case GemmaStatus.error:
        return widget.gemma.statusMessage ?? 'Error';
      case GemmaStatus.notReady:
        return 'Not loaded';
    }
  }

  String _whisperStatus() {
    switch (widget.whisper.status) {
      case WhisperStatus.ready:
        return widget.whisper.backend == SpeechBackend.native
            ? 'Ready · native iOS Speech'
            : 'Ready · Whisper fallback';
      case WhisperStatus.downloading:
        return widget.whisper.statusMessage ?? 'Loading…';
      case WhisperStatus.error:
        return widget.whisper.statusMessage ?? 'Error';
      case WhisperStatus.notReady:
        return 'Not loaded';
    }
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      );

  Widget _card({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1F),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: child,
      );

  Widget _statusRow({
    required IconData icon,
    required String label,
    required String sub,
    required bool active,
  }) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: cs.primary),
      title: Text(label),
      subtitle: Text(sub, style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
      onTap: () => ModelInfoSheet.show(context),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? const Color(0xFF7AE0A0) : cs.outline,
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.info_outline_rounded,
              size: 14, color: Colors.white.withValues(alpha: 0.4)),
        ],
      ),
    );
  }

  Widget _kvRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(child: Text(k)),
            Text(v,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ],
        ),
      );
}

class _AboutCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [
            cs.primary.withValues(alpha: 0.16),
            cs.primary.withValues(alpha: 0.04),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, color: cs.primary, size: 22),
              const SizedBox(width: 8),
              const Text('EchoLang',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Built for the Gemma 4 Good Hackathon. Lecture transcription, '
            'study packs, translation, and Q&A — all running on this phone '
            'with Gemma 4 and on-device speech recognition.',
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: Colors.white.withValues(alpha: 0.78),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _credit('Gemma 4 E2B'),
              const SizedBox(width: 6),
              _credit('LiteRT'),
              const SizedBox(width: 6),
              _credit('Flutter'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _credit(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3,
          ),
        ),
      );
}
