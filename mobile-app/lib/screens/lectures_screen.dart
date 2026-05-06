import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';
import '../llm/gemma.dart';
import '../llm/whisper.dart';

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

  // Latest progress from each model's pre-load. Null = not started.
  double? _gemmaProgress;
  String? _gemmaStatus;
  double? _whisperProgress;
  String? _whisperStatus;

  @override
  void initState() {
    super.initState();
    _future = widget.store.list();
    // Subscribe to in-flight downloads. ensureReady is memoized, so this
    // attaches a listener to the existing pre-load started in main.dart
    // rather than kicking off a second one.
    widget.gemma.ensureReady(onProgress: (p, status) {
      if (!mounted) return;
      setState(() {
        _gemmaProgress = p;
        _gemmaStatus = status;
      });
    }).catchError((_) {});
    widget.whisper.ensureReady(onProgress: (p, status) {
      if (!mounted) return;
      setState(() {
        _whisperProgress = p;
        _whisperStatus = status;
      });
    }).catchError((_) {});
  }

  void _refresh() {
    setState(() {
      _future = widget.store.list();
    });
  }

  bool get _showSetup =>
      widget.gemma.status != GemmaStatus.ready ||
      widget.whisper.status != WhisperStatus.ready;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: FutureBuilder<List<LectureRef>>(
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
                        Text(
                          'LocalLearning',
                          style: Theme.of(context).textTheme.headlineMedium,
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
                            gemmaMessage: _gemmaStatus,
                            whisperStatus: widget.whisper.status,
                            whisperProgress: _whisperProgress,
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
                        onTap: () => context.push('/lecture/${Uri.encodeComponent(lectures[i].dir.path)}'),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            FloatingActionButton.extended(
              heroTag: 'connect',
              onPressed: () async {
                await context.push('/connect');
                _refresh();
              },
              icon: const Icon(Icons.wifi_rounded),
              label: const Text('Join classroom'),
              backgroundColor: cs.surfaceContainerHighest,
              foregroundColor: cs.onSurface,
            ),
            const SizedBox(height: 12),
            FloatingActionButton.extended(
              heroTag: 'record',
              onPressed: () async {
                await context.push('/record');
                _refresh();
              },
              icon: const Icon(Icons.mic_rounded),
              label: const Text('Record now'),
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft, end: Alignment.bottomRight,
                  colors: [
                    cs.primary.withValues(alpha: 0.3),
                    cs.primary.withValues(alpha: 0.05),
                  ],
                ),
              ),
              child: Icon(Icons.auto_stories_rounded, size: 44, color: cs.primary),
            ),
            const SizedBox(height: 24),
            Text(
              'Your lecture library is empty',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Tap Record now to capture a lecture on this phone, '
              'or Join classroom to download one from a Pi nearby.',
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
  const _LectureCard({required this.ref, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final manifest = ref.manifest;
    return Card(
      child: InkWell(
        onTap: onTap,
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

  const _SetupBanner({
    required this.gemmaStatus,
    required this.gemmaProgress,
    required this.gemmaMessage,
    required this.whisperStatus,
    required this.whisperProgress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gemmaError = gemmaStatus == GemmaStatus.error;
    final whisperError = whisperStatus == WhisperStatus.error;
    final anyError = gemmaError || whisperError;
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
            const SizedBox(height: 12),
            _ModelRow(
              label: 'Gemma 4 E2B',
              subtitle: 'Reasoning & study packs · ~2.6 GB',
              status: gemmaStatus.name,
              progress: gemmaProgress,
              isReady: gemmaStatus == GemmaStatus.ready,
              isError: gemmaError,
              errorMessage: gemmaError ? gemmaMessage : null,
            ),
            const SizedBox(height: 12),
            _ModelRow(
              label: 'Whisper Tiny',
              subtitle: 'On-device transcription · ~30 MB',
              status: whisperStatus.name,
              progress: whisperProgress,
              isReady: whisperStatus == WhisperStatus.ready,
              isError: whisperError,
              errorMessage: null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final String status;
  final double? progress;
  final bool isReady;
  final bool isError;
  final String? errorMessage;
  const _ModelRow({
    required this.label,
    required this.subtitle,
    required this.status,
    required this.progress,
    required this.isReady,
    required this.isError,
    required this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (isReady)
              Icon(Icons.check_circle_rounded, color: cs.primary, size: 20)
            else if (isError)
              Icon(Icons.error_outline_rounded, color: cs.error, size: 20)
            else
              Text(
                progress != null ? '${(progress! * 100).toStringAsFixed(0)}%' : '…',
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
            value: isReady ? 1 : (isError ? 0 : progress),
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
