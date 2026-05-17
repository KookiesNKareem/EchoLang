import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';
import '../data/preferences.dart';
import '../llm/gemma.dart';

class LectureScreen extends StatefulWidget {
  final BundleStore store;
  final GemmaService gemma;
  final String dirPath;
  const LectureScreen({
    super.key,
    required this.store,
    required this.gemma,
    required this.dirPath,
  });

  @override
  State<LectureScreen> createState() => _LectureScreenState();
}

class _LectureScreenState extends State<LectureScreen> {
  late Future<Lecture> _future;
  // Live-translation state: when [_translating] is true the Translation tab
  // renders [_streamingText] as it grows, instead of (or alongside) the
  // already-saved translation from disk.
  bool _translating = false;
  String _streamingText = '';
  String? _translatingTo;
  bool _cancelTranslation = false;

  @override
  void initState() {
    super.initState();
    _future = widget.store.load(Directory(widget.dirPath))..then(_prewarm);
  }

  void _reload() {
    setState(() {
      _future = widget.store.load(Directory(widget.dirPath))..then(_prewarm);
    });
  }

  /// Kick off transcript prime + starter generation as soon as the lecture
  /// is loaded, so by the time the user taps Ask Gemma the primed chat and
  /// the localized hint/questions are already cached.
  void _prewarm(Lecture lecture) {
    if (widget.gemma.status != GemmaStatus.ready) return;
    final ctx = lecture.transcript.map((l) => l.text).join(' ');
    unawaited(widget.gemma.primeContext(ctx).catchError((_) {}));
    final langName = langNames[lecture.manifest.lang] ?? 'English';
    () async {
      try {
        await widget.gemma.generateStarters(
          lectureContext: ctx,
          languageName: langName,
        );
      } catch (_) {}
    }();
  }

  Future<void> _translate(Lecture lecture, {VoidCallback? onStart}) async {
    final targetCode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => _LanguagePickerSheet(),
    );
    if (targetCode == null || !mounted) return;
    final targetName = langNames[targetCode] ?? targetCode;

    if (widget.gemma.status != GemmaStatus.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gemma is still loading — try again in a moment.')),
      );
      return;
    }

    setState(() {
      _translating = true;
      _streamingText = '';
      _translatingTo = targetCode;
      _cancelTranslation = false;
    });
    // Let the caller animate to the Translation tab now that the live state
    // is set up, so the user watches the tokens stream in directly.
    onStart?.call();

    final sourceText = lecture.transcript.map((l) => l.text).join(' ');
    try {
      await for (final token in widget.gemma.translateStream(
        text: sourceText,
        targetLanguageName: targetName,
      )) {
        if (_cancelTranslation || !mounted) break;
        setState(() => _streamingText += token);
      }
      if (_cancelTranslation || !mounted) {
        if (mounted) {
          setState(() {
            _translating = false;
            _streamingText = '';
            _translatingTo = null;
          });
        }
        return;
      }
      await widget.store.saveTranslation(
        dir: Directory(widget.dirPath),
        text: _streamingText.trim(),
      );
      await widget.store.renameLectureLang(
        dir: Directory(widget.dirPath),
        lang: targetCode,
      );
      if (!mounted) return;
      setState(() {
        _translating = false;
        _streamingText = '';
        _translatingTo = null;
      });
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Translated to $targetName')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _translating = false;
        _streamingText = '';
        _translatingTo = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Translation failed: $e')),
      );
    }
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
        final tabs = <_TabSpec>[
          if (hasPack) const _TabSpec('Study pack', Icons.auto_stories_rounded),
          const _TabSpec('Translation', Icons.translate_rounded),
          const _TabSpec('Original', Icons.subject_rounded),
        ];
        final translationIdx = tabs.indexWhere((t) => t.label == 'Translation');
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            body: NestedScrollView(
              headerSliverBuilder: (_, __) => [
                _buildHeader(context, lecture, translationIdx),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabBarDelegate(
                    tabs: tabs.map((t) => Tab(
                          icon: Icon(t.icon, size: 18),
                          iconMargin: const EdgeInsets.only(bottom: 4),
                          child: Text(t.label),
                        )).toList(),
                  ),
                ),
              ],
              body: TabBarView(
                children: tabs.map((t) {
                  switch (t.label) {
                    case 'Study pack':
                      return _StudyPackTab(lecture: lecture);
                    case 'Translation':
                      return _TranslationTab(
                        lecture: lecture,
                        translating: _translating,
                        streamingText: _streamingText,
                        targetLangCode: _translatingTo,
                      );
                    case 'Original':
                    default:
                      return _TranscriptTab(lines: lecture.transcript, isRtl: false);
                  }
                }).toList(),
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => context.push('/qa/${Uri.encodeComponent(widget.dirPath)}'),
              icon: const Icon(Icons.auto_awesome_rounded),
              label: const Text('Ask Gemma'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, Lecture lecture, int translationIdx) {
    final cs = Theme.of(context).colorScheme;
    final m = lecture.manifest;
    final duration = m.endedAt.difference(m.startedAt);
    return SliverAppBar(
      pinned: true,
      expandedHeight: 196,
      backgroundColor: const Color(0xFF101013),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => context.pop(),
      ),
      actions: [
        // Builder so onPressed gets a context inside DefaultTabController and
        // can animate to the Translation tab the instant translation starts.
        Builder(
          builder: (innerCtx) => IconButton(
            tooltip: 'Translate',
            icon: _translating
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.translate_rounded),
            onPressed: _translating
                ? null
                : () => _translate(
                      lecture,
                      onStart: () {
                        if (translationIdx >= 0) {
                          DefaultTabController.of(innerCtx).animateTo(translationIdx);
                        }
                      },
                    ),
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsets.fromLTRB(56, 0, 56, 16),
        title: Text(
          m.title,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
        background: _HeaderBackground(lecture: lecture, cs: cs, duration: duration),
      ),
    );
  }
}

class _TabSpec {
  final String label;
  final IconData icon;
  const _TabSpec(this.label, this.icon);
}

class _HeaderBackground extends StatelessWidget {
  final Lecture lecture;
  final ColorScheme cs;
  final Duration duration;
  const _HeaderBackground({required this.lecture, required this.cs, required this.duration});

  @override
  Widget build(BuildContext context) {
    final m = lecture.manifest;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [
                cs.primary.withValues(alpha: 0.20),
                cs.primary.withValues(alpha: 0.04),
                const Color(0xFF101013),
              ],
              stops: const [0, 0.55, 1.0],
            ),
          ),
        ),
        Positioned(
          left: 20, right: 20, bottom: 60,
          child: Wrap(
            spacing: 8, runSpacing: 6,
            children: [
              _Chip(icon: Icons.language_rounded, label: m.lang.toUpperCase()),
              _Chip(icon: Icons.access_time_rounded, label: _fmtDuration(duration)),
              _Chip(icon: Icons.format_quote_rounded, label: '${m.captionCount} captions'),
              if (m.teacher != null && m.teacher!.isNotEmpty)
                _Chip(icon: Icons.person_outline_rounded, label: m.teacher!),
            ],
          ),
        ),
      ],
    );
  }

  String _fmtDuration(Duration d) {
    if (d.inMinutes < 1) return '${d.inSeconds}s';
    if (d.inHours < 1) return '${d.inMinutes}m';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w500, letterSpacing: 0.1,
              )),
        ],
      ),
    );
  }
}

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final List<Tab> tabs;
  _TabBarDelegate({required this.tabs});

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: const Color(0xFF101013),
      child: TabBar(
        tabs: tabs,
        indicatorColor: cs.primary,
        indicatorWeight: 2.5,
        labelColor: cs.onSurface,
        unselectedLabelColor: Colors.white.withValues(alpha: 0.5),
        labelStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.1),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
        dividerColor: Colors.white.withValues(alpha: 0.06),
      ),
    );
  }

  @override
  double get maxExtent => 64;
  @override
  double get minExtent => 64;
  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => false;
}

// =================================================================
// Study pack tab
// =================================================================

class _StudyPackTab extends StatelessWidget {
  final Lecture lecture;
  const _StudyPackTab({required this.lecture});

  @override
  Widget build(BuildContext context) {
    final pack = lecture.studyPack;
    if (pack == null) {
      return const Center(child: Text('No study pack in this bundle.'));
    }
    final isRtl = rtlLangs.contains(lecture.manifest.lang);
    final dir = isRtl ? TextDirection.rtl : TextDirection.ltr;
    final align = isRtl ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final tAlign = isRtl ? TextAlign.end : TextAlign.start;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _SectionHeader(icon: Icons.auto_stories_rounded, label: 'Summary'),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _softCard(context),
          child: Column(
            crossAxisAlignment: align,
            children: [
              Text(
                pack.summary,
                textAlign: tAlign,
                textDirection: dir,
                style: const TextStyle(fontSize: 15.5, height: 1.55),
              ),
            ],
          ),
        ),
        if (pack.keyTerms.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(icon: Icons.key_rounded, label: 'Key terms', count: pack.keyTerms.length),
          const SizedBox(height: 10),
          ...pack.keyTerms.map((kt) => _KeyTermCard(kt: kt, dir: dir, align: align, tAlign: tAlign)),
        ],
        if (pack.practiceQuestions.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(
              icon: Icons.quiz_rounded,
              label: 'Practice questions',
              count: pack.practiceQuestions.length),
          const SizedBox(height: 10),
          ...pack.practiceQuestions.asMap().entries.map(
                (e) => _PracticeRow(index: e.key + 1, text: e.value, dir: dir, tAlign: tAlign),
              ),
        ],
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final int? count;
  const _SectionHeader({required this.icon, required this.label, this.count});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 8),
        Text(label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
        if (count != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _KeyTermCard extends StatelessWidget {
  final KeyTerm kt;
  final TextDirection dir;
  final CrossAxisAlignment align;
  final TextAlign tAlign;
  const _KeyTermCard({required this.kt, required this.dir, required this.align, required this.tAlign});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: _softCard(context),
        child: Column(
          crossAxisAlignment: align,
          children: [
            Text(
              kt.term,
              style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w600,
                color: cs.primary, letterSpacing: -0.2,
              ),
              textDirection: dir, textAlign: tAlign,
            ),
            const SizedBox(height: 4),
            Text(
              kt.definition,
              style: TextStyle(
                fontSize: 14, height: 1.45,
                color: Colors.white.withValues(alpha: 0.78),
              ),
              textDirection: dir, textAlign: tAlign,
            ),
          ],
        ),
      ),
    );
  }
}

class _PracticeRow extends StatelessWidget {
  final int index;
  final String text;
  final TextDirection dir;
  final TextAlign tAlign;
  const _PracticeRow({
    required this.index,
    required this.text,
    required this.dir,
    required this.tAlign,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26, height: 26,
            margin: const EdgeInsets.only(top: 1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.primary.withValues(alpha: 0.14),
            ),
            child: Center(
              child: Text(
                '$index',
                style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                text,
                textDirection: dir, textAlign: tAlign,
                style: const TextStyle(fontSize: 14.5, height: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =================================================================
// Transcript tab (Translation + Original both render here)
// =================================================================

class _TranscriptTab extends StatelessWidget {
  final List<TranscriptLine> lines;
  final bool isRtl;
  const _TranscriptTab({required this.lines, required this.isRtl});

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No content for this language yet.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final dir = isRtl ? TextDirection.rtl : TextDirection.ltr;
    final tAlign = isRtl ? TextAlign.end : TextAlign.start;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      itemCount: lines.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (_, i) {
        final l = lines[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                l.timestamp,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.55),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l.text,
                textDirection: dir, textAlign: tAlign,
                style: const TextStyle(fontSize: 15, height: 1.55),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Translation tab. Three states:
///   1. Live streaming from on-device Gemma — renders [streamingText] +
///      a typing indicator. The user watches the tokens land in real time.
///   2. Saved translation on disk — defers to [_TranscriptTab].
///   3. Empty — shows a hint to tap the translate icon.
class _TranslationTab extends StatelessWidget {
  final Lecture lecture;
  final bool translating;
  final String streamingText;
  final String? targetLangCode;
  const _TranslationTab({
    required this.lecture,
    required this.translating,
    required this.streamingText,
    required this.targetLangCode,
  });

  @override
  Widget build(BuildContext context) {
    if (translating) {
      final langName = langNames[targetLangCode] ?? targetLangCode ?? '';
      final isRtl = rtlLangs.contains(targetLangCode);
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                'Translating to $langName…',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            streamingText.isEmpty ? 'Priming Gemma…' : streamingText,
            textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
            textAlign: isRtl ? TextAlign.end : TextAlign.start,
            style: const TextStyle(fontSize: 15, height: 1.55),
          ),
        ],
      );
    }
    if (lecture.translation.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.translate_rounded,
                  size: 36, color: Colors.white.withValues(alpha: 0.3)),
              const SizedBox(height: 14),
              Text(
                'No translation yet.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tap the translate icon in the top bar to translate this '
                'lecture into another language — Gemma runs the translation '
                'right here on your phone.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13, height: 1.45,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _TranscriptTab(
      lines: lecture.translation,
      isRtl: rtlLangs.contains(lecture.manifest.lang),
    );
  }
}

/// Bottom sheet for picking a translation target. Draggable, scrollable, and
/// designed to feel iOS-native without growing past 85% of the screen.
class _LanguagePickerSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final entries =
        langNames.entries.where((e) => e.key != 'en').toList(growable: false);
    final screenH = MediaQuery.of(context).size.height;
    return Container(
      constraints: BoxConstraints(maxHeight: screenH * 0.85),
      decoration: const BoxDecoration(
        color: Color(0xFF15151A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 38, height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.translate_rounded,
                      color: cs.primary, size: 20),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Translate this lecture',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600,
                              letterSpacing: -0.2)),
                      SizedBox(height: 2),
                      Text('Runs on this phone with Gemma 4',
                          style: TextStyle(
                            fontSize: 12, color: Colors.white54,
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 2),
              itemBuilder: (ctx, i) {
                final e = entries[i];
                final isRtl = rtlLangs.contains(e.key);
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.of(ctx).pop(e.key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    child: Row(
                      children: [
                        Container(
                          width: 36, height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            e.key.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            e.value,
                            style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (isRtl)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'RTL',
                              style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        const SizedBox(width: 4),
                        Icon(Icons.chevron_right_rounded,
                            size: 18,
                            color: Colors.white.withValues(alpha: 0.3)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

// =================================================================
// Shared helpers
// =================================================================

BoxDecoration _softCard(BuildContext context) => BoxDecoration(
      color: const Color(0xFF1A1A1F),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
    );
