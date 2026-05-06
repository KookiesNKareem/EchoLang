import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';

class LecturesScreen extends StatefulWidget {
  final BundleStore store;
  const LecturesScreen({super.key, required this.store});

  @override
  State<LecturesScreen> createState() => _LecturesScreenState();
}

class _LecturesScreenState extends State<LecturesScreen> {
  late Future<List<LectureRef>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.store.list();
  }

  void _refresh() {
    setState(() {
      _future = widget.store.list();
    });
  }

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
