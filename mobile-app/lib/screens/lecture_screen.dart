import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';

class LectureScreen extends StatefulWidget {
  final BundleStore store;
  final String dirPath;
  const LectureScreen({super.key, required this.store, required this.dirPath});

  @override
  State<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends State<LectureScreen> {
  late Future<Lecture> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.store.load(Directory(widget.dirPath));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lecture>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text('Failed to load: ${snap.error}')),
          );
        }
        final lecture = snap.data!;
        final hasPack = lecture.studyPack != null;
        final tabs = <String>[
          if (hasPack) 'Study pack',
          'Translation',
          'Original',
        ];
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            appBar: AppBar(
              title: Text(lecture.manifest.title),
              bottom: TabBar(tabs: tabs.map((t) => Tab(text: t)).toList()),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () =>
                  context.push('/qa/${Uri.encodeComponent(widget.dirPath)}'),
              icon: const Icon(Icons.question_answer),
              label: const Text('Ask Gemma'),
            ),
            body: TabBarView(
              children: tabs.map((t) {
                switch (t) {
                  case 'Study pack':
                    return _StudyPackTab(lecture: lecture);
                  case 'Translation':
                    return _TranscriptTab(
                      lines: lecture.translation,
                      isRtl: rtlLangs.contains(lecture.manifest.lang),
                    );
                  case 'Original':
                  default:
                    return _TranscriptTab(lines: lecture.transcript, isRtl: false);
                }
              }).toList(),
            ),
          ),
        );
      },
    );
  }
}

class _StudyPackTab extends StatelessWidget {
  final Lecture lecture;
  const _StudyPackTab({required this.lecture});

  @override
  Widget build(BuildContext context) {
    final pack = lecture.studyPack;
    if (pack == null) return const Center(child: Text('No study pack in this bundle.'));
    final isRtl = rtlLangs.contains(lecture.manifest.lang);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text('Summary', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  pack.summary,
                  textAlign: isRtl ? TextAlign.end : TextAlign.start,
                  textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                ),
              ],
            ),
          ),
        ),
        if (pack.keyTerms.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Key terms', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...pack.keyTerms.map(
            (kt) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(
                      kt.term,
                      style: Theme.of(context).textTheme.titleSmall,
                      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                    ),
                    Text(
                      kt.definition,
                      textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        if (pack.practiceQuestions.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('Practice questions', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...pack.practiceQuestions.asMap().entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${e.key + 1}. ${e.value}',
                    textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                  ),
                ),
              ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }
}

class _TranscriptTab extends StatelessWidget {
  final List<TranscriptLine> lines;
  final bool isRtl;
  const _TranscriptTab({required this.lines, required this.isRtl});

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const Center(child: Text('No content for this language yet.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: lines.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final l = lines[i];
        return Column(
          crossAxisAlignment: isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(l.timestamp, style: Theme.of(context).textTheme.labelSmall),
            Text(
              l.text,
              textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            ),
          ],
        );
      },
    );
  }
}
