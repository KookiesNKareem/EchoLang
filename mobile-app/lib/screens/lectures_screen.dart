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
    return Scaffold(
      appBar: AppBar(title: const Text('My lectures')),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'record',
            onPressed: () async {
              await context.push('/record');
              _refresh();
            },
            icon: const Icon(Icons.mic),
            label: const Text('Record now'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'connect',
            onPressed: () async {
              await context.push('/connect');
              _refresh();
            },
            icon: const Icon(Icons.wifi),
            label: const Text('Join classroom'),
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            foregroundColor: Theme.of(context).colorScheme.onSurface,
          ),
        ],
      ),
      body: FutureBuilder<List<LectureRef>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final lectures = snap.data ?? const [];
          if (lectures.isEmpty) return const _EmptyState();
          return RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: lectures.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _LectureCard(
                ref: lectures[i],
                onTap: () => context.push('/lecture/${Uri.encodeComponent(lectures[i].dir.path)}'),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.school_outlined, size: 48, color: Colors.white24),
              const SizedBox(height: 12),
              Text('No lectures yet', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Tap Add lecture and connect to your classroom Pi to download today’s lesson.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}

class _LectureCard extends StatelessWidget {
  final LectureRef ref;
  final VoidCallback onTap;
  const _LectureCard({required this.ref, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref.manifest.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                [
                  ref.manifest.lang.toUpperCase(),
                  '${ref.manifest.captionCount} captions',
                  if (ref.manifest.teacher != null) ref.manifest.teacher!,
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
