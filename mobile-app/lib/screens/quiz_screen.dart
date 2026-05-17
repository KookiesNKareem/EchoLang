import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';
import '../data/preferences.dart';
import '../llm/gemma.dart';

/// Multiple-choice quiz generated on-device from the lecture transcript.
/// One question at a time, immediate feedback with the model's explanation,
/// final score and review at the end.
class QuizScreen extends StatefulWidget {
  final BundleStore store;
  final GemmaService gemma;
  final String dirPath;
  const QuizScreen({
    super.key,
    required this.store,
    required this.gemma,
    required this.dirPath,
  });

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  Lecture? _lecture;
  final List<QuizItem> _items = [];
  final List<int?> _answers = [];
  int _current = 0;
  int? _selected;
  bool _generating = true;
  Object? _error;
  StreamSubscription<QuizItem>? _sub;

  static const int _kTargetCount = 5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await widget.store.load(Directory(widget.dirPath));
      if (!mounted) return;
      setState(() => _lecture = l);
      _startGeneration(l);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  void _startGeneration(Lecture lecture) {
    final ctx = lecture.transcript.map((l) => l.text).join(' ');
    final langName = langNames[lecture.manifest.lang] ?? 'English';
    _sub = widget.gemma
        .generateQuizStream(
          transcript: ctx,
          languageName: langName,
          count: _kTargetCount,
        )
        .listen(
          (item) {
            if (!mounted) return;
            setState(() {
              _items.add(item);
              _answers.add(null);
            });
          },
          onError: (e) {
            if (!mounted) return;
            setState(() {
              _error = e;
              _generating = false;
            });
          },
          onDone: () {
            if (!mounted) return;
            setState(() => _generating = false);
          },
        );
  }

  void _select(int index) {
    if (_selected != null) return;
    HapticFeedback.selectionClick();
    setState(() {
      _selected = index;
      _answers[_current] = index;
    });
  }

  void _next() {
    HapticFeedback.lightImpact();
    if (_current + 1 < _items.length) {
      setState(() {
        _current += 1;
        _selected = null;
      });
    } else if (!_generating) {
      // All done — show summary screen via state.
      setState(() => _current = _items.length);
    }
  }

  int get _score => _items
      .asMap()
      .entries
      .where((e) => _answers[e.key] == e.value.correctIndex)
      .length;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Quiz',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              _lecture?.manifest.title ?? '',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
            ),
          ],
        ),
      ),
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: cs.error, size: 40),
              const SizedBox(height: 12),
              Text(
                'Could not generate quiz.\n$_error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36, height: 36,
              child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
            ),
            const SizedBox(height: 18),
            Text(
              'Gemma is writing your quiz…',
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      );
    }
    if (_current >= _items.length) {
      return _ResultsView(items: _items, answers: _answers, score: _score);
    }
    return _QuestionView(
      index: _current,
      total: _generating ? _kTargetCount : _items.length,
      item: _items[_current],
      selected: _selected,
      generatingMore: _generating && _items.length <= _current + 1,
      onSelect: _select,
      onNext: _next,
    );
  }
}

class _QuestionView extends StatelessWidget {
  final int index;
  final int total;
  final QuizItem item;
  final int? selected;
  final bool generatingMore;
  final void Function(int) onSelect;
  final VoidCallback onNext;
  const _QuestionView({
    required this.index,
    required this.total,
    required this.item,
    required this.selected,
    required this.generatingMore,
    required this.onSelect,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final revealed = selected != null;
    final progress = (index + 1) / total;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Question ${index + 1} of $total',
                    style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: cs.primary,
                    ),
                  ),
                  if (generatingMore) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 10, height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: cs.primary,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  valueColor: AlwaysStoppedAnimation(cs.primary),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
            children: [
              Text(
                item.question,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      height: 1.35,
                    ),
              ),
              const SizedBox(height: 20),
              ...item.options.asMap().entries.map((e) {
                final i = e.key;
                final option = e.value;
                final isSelected = selected == i;
                final isCorrect = revealed && i == item.correctIndex;
                final isWrong = revealed && isSelected && !isCorrect;
                Color bg = cs.surfaceContainerHighest.withValues(alpha: 0.5);
                Color border = Colors.white.withValues(alpha: 0.08);
                Color label = Colors.white.withValues(alpha: 0.92);
                IconData? icon;
                if (isCorrect) {
                  bg = const Color(0xFF1E4D34);
                  border = const Color(0xFF7AE0A0);
                  label = Colors.white;
                  icon = Icons.check_circle_rounded;
                } else if (isWrong) {
                  bg = cs.error.withValues(alpha: 0.18);
                  border = cs.error;
                  label = Colors.white;
                  icon = Icons.cancel_rounded;
                } else if (isSelected) {
                  border = cs.primary;
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: revealed ? null : () => onSelect(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: border, width: 1.4),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 28, height: 28,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                              child: Text(
                                String.fromCharCode(65 + i),
                                style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                option,
                                style: TextStyle(
                                  fontSize: 15, height: 1.4,
                                  color: label,
                                ),
                              ),
                            ),
                            if (icon != null) ...[
                              const SizedBox(width: 8),
                              Icon(icon,
                                  color: isCorrect
                                      ? const Color(0xFF7AE0A0)
                                      : cs.error,
                                  size: 20),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
              if (revealed) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lightbulb_outline_rounded,
                          color: cs.primary, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.explanation,
                          style: const TextStyle(fontSize: 13.5, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: revealed ? onNext : null,
                child: Text(index + 1 == total ? 'See results' : 'Next question'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ResultsView extends StatelessWidget {
  final List<QuizItem> items;
  final List<int?> answers;
  final int score;
  const _ResultsView({
    required this.items,
    required this.answers,
    required this.score,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = items.isEmpty ? 0 : ((score / items.length) * 100).round();
    final flavor = pct == 100
        ? 'Perfect.'
        : pct >= 80
            ? 'Excellent.'
            : pct >= 60
                ? 'Solid work.'
                : 'Worth another pass.';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 80),
      children: [
        Center(
          child: Column(
            children: [
              Container(
                width: 88, height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.primary.withValues(alpha: 0.14),
                  border: Border.all(
                      color: cs.primary.withValues(alpha: 0.4), width: 2),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$score / ${items.length}',
                      style: TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    ),
                    Text(
                      '$pct%',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Text(
                flavor,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          'Review',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Colors.white.withValues(alpha: 0.7),
              ),
        ),
        const SizedBox(height: 10),
        ...items.asMap().entries.map((e) {
          final i = e.key;
          final item = e.value;
          final picked = answers[i];
          final correct = picked == item.correctIndex;
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1F),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: correct
                    ? const Color(0xFF7AE0A0).withValues(alpha: 0.35)
                    : cs.error.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      correct ? Icons.check_circle_rounded : Icons.cancel_rounded,
                      size: 16,
                      color: correct
                          ? const Color(0xFF7AE0A0)
                          : cs.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Q${i + 1}',
                      style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        color: correct
                            ? const Color(0xFF7AE0A0)
                            : cs.error,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(item.question, style: const TextStyle(height: 1.35)),
                const SizedBox(height: 8),
                if (picked != null && !correct)
                  Text(
                    'You picked: ${item.options[picked]}',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                Text(
                  'Correct: ${item.options[item.correctIndex]}',
                  style: TextStyle(
                    fontSize: 13,
                    color: const Color(0xFF7AE0A0).withValues(alpha: 0.95),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  item.explanation,
                  style: TextStyle(
                    fontSize: 12.5, height: 1.4,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.check_rounded),
          label: const Text('Done'),
        ),
      ],
    );
  }
}
