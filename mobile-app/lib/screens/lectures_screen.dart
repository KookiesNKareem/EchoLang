import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';
import '../llm/gemma.dart';
import '../llm/whisper.dart';
import 'model_info_sheet.dart';

class LecturesScreen extends StatefulWidget {
  final BundleStore store;
  final GemmaService gemma;
  final WhisperService whisper;
  const LecturesScreen({
    super.key,
    required this.store,
    required this.gemma,
    required this.whisper,
  });

  @override
  State<LecturesScreen> createState() => _LecturesScreenState();
}

class _LecturesScreenState extends State<LecturesScreen> {
  late Future<List<LectureRef>> _future;

  double? _gemmaProgress;
  String? _gemmaMessage;
  double? _whisperProgress;
  String? _whisperMessage;

  bool _fabOpen = false;

  @override
  void initState() {
    super.initState();
    _future = widget.store.list();
    widget.gemma
        .ensureReady(onProgress: (p, status) {
          if (!mounted) return;
          setState(() {
            _gemmaProgress = p;
            _gemmaMessage = status;
          });
        })
        .then((_) { if (mounted) setState(() {}); })
        .catchError((_) { if (mounted) setState(() {}); });
    widget.whisper
        .ensureReady(onProgress: (p, status) {
          if (!mounted) return;
          setState(() {
            _whisperProgress = p;
            _whisperMessage = status;
          });
        })
        .then((_) { if (mounted) setState(() {}); })
        .catchError((_) { if (mounted) setState(() {}); });
  }

  void _refresh() {
    setState(() {
      _future = widget.store.list();
    });
  }

  bool get _showSetup =>
      widget.gemma.status != GemmaStatus.ready ||
      widget.whisper.status != WhisperStatus.ready;

  Future<void> _showCardMenu(LectureRef ref) async {
    HapticFeedback.mediumImpact();
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _LectureActionSheet(title: ref.manifest.title),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'rename':
        await _renameLecture(ref);
        break;
      case 'translate':
        // Defer to the lecture viewer's existing flow — push and let the
        // user open the language picker there.
        await context.push('/lecture/${Uri.encodeComponent(ref.dir.path)}');
        _refresh();
        break;
      case 'delete':
        await _deleteLecture(ref);
        break;
    }
  }

  Future<void> _renameLecture(LectureRef ref) async {
    final ctrl = TextEditingController(text: ref.manifest.title);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename lecture'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (next == null || next.trim().isEmpty || next.trim() == ref.manifest.title) return;
    try {
      await widget.store.renameLecture(dir: ref.dir, title: next.trim());
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rename failed: $e')),
      );
    }
  }

  Future<void> _deleteLecture(LectureRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this lecture?'),
        content: Text(
          '"${ref.manifest.title}" will be removed from this phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await widget.store.delete(ref.dir);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  Future<void> _openRecord() async {
    setState(() => _fabOpen = false);
    HapticFeedback.mediumImpact();
    await context.push('/record');
    _refresh();
  }

  Future<void> _openConnect() async {
    setState(() => _fabOpen = false);
    HapticFeedback.selectionClick();
    await context.push('/connect');
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: _buildBody(),
          ),
          IgnorePointer(
            ignoring: !_fabOpen,
            child: AnimatedOpacity(
              opacity: _fabOpen ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _fabOpen = false),
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _buildSpeedDial(cs),
    );
  }

  Widget _buildBody() {
    return FutureBuilder<List<LectureRef>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final lectures = snap.data ?? const [];
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                'EchoLang',
                                style: Theme.of(context).textTheme.headlineMedium,
                              ),
                            ),
                            const _PrivacyChip(),
                            const SizedBox(width: 6),
                            IconButton(
                              tooltip: 'Settings',
                              icon: const Icon(Icons.settings_outlined),
                              onPressed: () => context.push('/settings'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          lectures.isEmpty
                              ? 'No lectures yet — record one or join a classroom.'
                              : '${lectures.length} ${lectures.length == 1 ? "lecture" : "lectures"} saved on this device',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                        ),
                        if (_showSetup) ...[
                          const SizedBox(height: 16),
                          _SetupBanner(
                            gemmaStatus: widget.gemma.status,
                            gemmaProgress: _gemmaProgress,
                            gemmaMessage: _gemmaMessage,
                            whisperStatus: widget.whisper.status,
                            whisperProgress: _whisperProgress,
                            whisperMessage: _whisperMessage,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (lectures.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                    sliver: SliverList.separated(
                      itemCount: lectures.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _LectureCard(
                        ref: lectures[i],
                        onTap: () async {
                          await context.push('/lecture/${Uri.encodeComponent(lectures[i].dir.path)}');
                          _refresh();
                        },
                        onLongPress: () => _showCardMenu(lectures[i]),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
  }

  Widget _buildSpeedDial(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _SpeedDialAction(
            visible: _fabOpen,
            icon: Icons.wifi_rounded,
            label: 'Join classroom',
            heroTag: 'connect',
            backgroundColor: cs.surfaceContainerHighest,
            foregroundColor: cs.onSurface,
            onPressed: _openConnect,
          ),
          const SizedBox(height: 12),
          _SpeedDialAction(
            visible: _fabOpen,
            icon: Icons.mic_rounded,
            label: 'Record now',
            heroTag: 'record',
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
            onPressed: _openRecord,
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'speeddial',
            onPressed: () {
              HapticFeedback.lightImpact();
              setState(() => _fabOpen = !_fabOpen);
            },
            backgroundColor: cs.primary,
            foregroundColor: cs.onPrimary,
            tooltip: _fabOpen ? 'Close' : 'New lecture',
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, anim) => RotationTransition(
                turns: Tween<double>(begin: 0.6, end: 1.0).animate(anim),
                child: ScaleTransition(scale: anim, child: child),
              ),
              child: Icon(
                _fabOpen ? Icons.close_rounded : Icons.add_rounded,
                key: ValueKey(_fabOpen),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpeedDialAction extends StatelessWidget {
  final bool visible;
  final IconData icon;
  final String label;
  final String heroTag;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback onPressed;
  const _SpeedDialAction({
    required this.visible,
    required this.icon,
    required this.label,
    required this.heroTag,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 0.35),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: FloatingActionButton.extended(
            heroTag: heroTag,
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
          ),
        ),
      ),
    );
  }
}

class _PrivacyChip extends StatelessWidget {
  const _PrivacyChip();
  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF7AE0A0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: accent,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'Offline · On-device',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: accent.withValues(alpha: 0.92),
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatefulWidget {
  @override
  State<_EmptyState> createState() => _EmptyStateState();
}

class _EmptyStateState extends State<_EmptyState> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) {
                final t = _ctrl.value;
                return SizedBox(
                  width: 160, height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Transform.scale(
                        scale: 0.92 + 0.16 * t,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                cs.primary.withValues(alpha: 0.20 * (1 - t)),
                                cs.primary.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Transform.scale(
                        scale: 0.86 + 0.06 * (1 - t),
                        child: Container(
                          width: 110, height: 110,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                              colors: [
                                cs.primary.withValues(alpha: 0.32 + 0.10 * t),
                                cs.primary.withValues(alpha: 0.04),
                              ],
                            ),
                          ),
                          child: Transform.translate(
                            offset: Offset(0, -2 + 4 * t),
                            child: Icon(
                              Icons.auto_stories_rounded,
                              size: 48, color: cs.primary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 24),
            Text(
              'Your lecture library is empty',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap the + below to record a lecture on this phone '
              'or join a classroom Pi nearby.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _LectureCard extends StatelessWidget {
  final LectureRef ref;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _LectureCard({required this.ref, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final manifest = ref.manifest;
    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: cs.primary.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.school_rounded,
                  color: cs.primary, size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manifest.title,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _Pill(text: manifest.lang.toUpperCase()),
                        const SizedBox(width: 6),
                        Text(
                          '${manifest.captionCount} caption${manifest.captionCount == 1 ? "" : "s"}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SetupBanner extends StatelessWidget {
  final GemmaStatus gemmaStatus;
  final double? gemmaProgress;
  final String? gemmaMessage;
  final WhisperStatus whisperStatus;
  final double? whisperProgress;
  final String? whisperMessage;

  const _SetupBanner({
    required this.gemmaStatus,
    required this.gemmaProgress,
    required this.gemmaMessage,
    required this.whisperStatus,
    required this.whisperProgress,
    required this.whisperMessage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gemmaError = gemmaStatus == GemmaStatus.error;
    final whisperError = whisperStatus == WhisperStatus.error;
    final anyError = gemmaError || whisperError;
    final showGemma = gemmaStatus != GemmaStatus.ready;
    final showWhisper = whisperStatus != WhisperStatus.ready;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: BoxDecoration(
                    color: anyError
                        ? cs.error.withValues(alpha: 0.15)
                        : cs.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    anyError ? Icons.warning_amber_rounded : Icons.cloud_download_rounded,
                    color: anyError ? cs.error : cs.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    anyError ? 'Setup needs attention' : 'Setting up offline AI',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (showGemma) ...[
              const SizedBox(height: 12),
              Builder(
                builder: (ctx) => InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => ModelInfoSheet.show(ctx),
                  child: _ModelRow(
                    label: 'Gemma 4 E2B',
                    subtitle: 'Reasoning & study packs · tap for details',
                    progress: gemmaProgress,
                    stageLabel: gemmaMessage,
                    isError: gemmaError,
                    errorMessage: gemmaError ? gemmaMessage : null,
                  ),
                ),
              ),
            ],
            if (showWhisper) ...[
              const SizedBox(height: 12),
              _ModelRow(
                label: 'Transcription model',
                subtitle: 'On-device speech-to-text',
                progress: whisperProgress,
                stageLabel: whisperMessage,
                isError: whisperError,
                errorMessage: whisperError ? whisperMessage : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final double? progress;
  final String? stageLabel;
  final bool isError;
  final String? errorMessage;
  const _ModelRow({
    required this.label,
    required this.subtitle,
    required this.progress,
    required this.stageLabel,
    required this.isError,
    required this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = progress != null ? '${(progress! * 100).toStringAsFixed(0)}%' : null;
    // After download hits 100% we switch to indeterminate so the user
    // doesn't think it's stuck — a 2.6 GB mmap can take 10-30s.
    final indeterminate = progress == null || (progress != null && progress! >= 0.999);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.bodyMedium),
                  Text(
                    stageLabel ?? subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isError)
              Icon(Icons.error_outline_rounded, color: cs.error, size: 20)
            else if (pct != null && !indeterminate)
              Text(
                pct,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: isError ? 0 : (indeterminate ? null : progress),
            minHeight: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.06),
            valueColor: AlwaysStoppedAnimation(isError ? cs.error : cs.primary),
          ),
        ),
        if (errorMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            errorMessage!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.error),
          ),
        ],
      ],
    );
  }
}

class _LectureActionSheet extends StatelessWidget {
  final String title;
  const _LectureActionSheet({required this.title});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.translate_rounded),
              title: const Text('Translate to…'),
              onTap: () => Navigator.of(context).pop('translate'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Rename'),
              onTap: () => Navigator.of(context).pop('rename'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error),
              title: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  const _Pill({required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11, fontWeight: FontWeight.w600,
          color: cs.primary, letterSpacing: 0.4,
        ),
      ),
    );
  }
}
