import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';
import '../llm/gemma.dart';

class QAScreen extends StatefulWidget {
  final BundleStore store;
  final GemmaService gemma;
  final String dirPath;
  const QAScreen({
    super.key,
    required this.store,
    required this.gemma,
    required this.dirPath,
  });

  @override
  State<QAScreen> createState() => _QAScreenState();
}

class _ChatMessage {
  final bool fromUser;
  String text;
  String thinking = '';
  final List<Citation> citations = <Citation>[];
  _ChatMessage({required this.fromUser, required this.text});
}

class _QAScreenState extends State<QAScreen> with SingleTickerProviderStateMixin {
  Lecture? _lecture;
  final List<_ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final AnimationController _typingDots;
  bool _generating = false;
  bool _cancelGeneration = false;
  String? _modelStatus;
  /// Static starter content (avoids iOS state-leak issue).
  final QAStarters _starters = QAStarters.fallback;

  @override
  void initState() {
    super.initState();
    _typingDots = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _loadLecture();
    _ensureModel();
  }

  @override
  void dispose() {
    _typingDots.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadLecture() async {
    final l = await widget.store.load(Directory(widget.dirPath));
    if (mounted) setState(() => _lecture = l);
    _maybePrewarm();
  }

  Future<void> _ensureModel() async {
    if (widget.gemma.status == GemmaStatus.ready) {
      setState(() => _modelStatus = null);
      _maybePrewarm();
      return;
    }
    setState(() => _modelStatus = 'Loading Gemma 4…');
    try {
      await widget.gemma.ensureReady(
        onProgress: (p, status) {
          if (!mounted) return;
          setState(() => _modelStatus =
              p != null && p < 0.999
                  ? 'Loading Gemma 4 — ${(p * 100).toStringAsFixed(0)}%'
                  : status);
        },
      );
      if (mounted) setState(() => _modelStatus = null);
      _maybePrewarm();
    } catch (e) {
      if (mounted) setState(() => _modelStatus = 'Couldn’t load Gemma: $e');
    }
  }

  void _maybePrewarm() {
    if (_lecture == null) return;
    if (widget.gemma.status != GemmaStatus.ready) return;
    final ctx = _lecture!.transcript.map((l) => l.text).join(' ');
    unawaited(widget.gemma.primeContext(ctx).catchError((_) {}));
    _maybeLoadStarters();
  }

  /// Kept for compatibility with _maybePrewarm.
  void _maybeLoadStarters() {}

  Future<void> _send([String? prefilled]) async {
    final q = (prefilled ?? _input.text).trim();
    if (q.isEmpty || _generating || _lecture == null) return;
    if (widget.gemma.status != GemmaStatus.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model still loading — try again in a moment.')),
      );
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _input.clear();
      _messages.add(_ChatMessage(fromUser: true, text: q));
      _messages.add(_ChatMessage(fromUser: false, text: ''));
      _generating = true;
      _cancelGeneration = false;
    });
    _scrollToBottom();
    try {
      final buf = StringBuffer();
      final stream = widget.gemma.askWithToolsStream(
        transcript: _lecture!.transcript,
        keyTerms: _lecture!.studyPack?.keyTerms ?? const [],
        question: q,
      );
      await for (final ev in stream) {
        if (!mounted) return;
        if (_cancelGeneration) {
          if (buf.isEmpty) buf.write('(stopped)');
          break;
        }
        switch (ev) {
          case AskText(:final token):
            buf.write(token);
            setState(() => _messages.last.text = buf.toString());
          case AskCitation(:final citation):
            setState(() => _messages.last.citations.add(citation));
          case AskThinking(:final content):
            setState(() => _messages.last.thinking += content);
        }
        _scrollToBottom();
      }
      if (!mounted) return;
      setState(() {
        if (_cancelGeneration && _messages.last.text.isEmpty) {
          _messages.last.text = '(stopped)';
        }
        _generating = false;
        _cancelGeneration = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.last.text = 'Error: $e';
        _generating = false;
        _cancelGeneration = false;
      });
    }
  }

  void _stop() {
    if (!_generating) return;
    HapticFeedback.mediumImpact();
    setState(() => _cancelGeneration = true);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _lecture?.manifest.title ?? 'Lecture',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Row(
              children: [
                Container(
                  width: 6, height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.gemma.status == GemmaStatus.ready
                        ? const Color(0xFF7AE0A0)
                        : cs.outline,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _modelStatus ?? _starters.subtitle,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _Welcome(starters: _starters)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      final showTyping = !m.fromUser &&
                          m.text.isEmpty &&
                          i == _messages.length - 1 &&
                          _generating;
                      return _Bubble(
                        msg: m,
                        showTyping: showTyping,
                        typingDots: _typingDots,
                      );
                    },
                  ),
          ),
          if (_starters.questions.isNotEmpty && _messages.isEmpty)
            _SuggestionRow(
              questions: _starters.questions,
              onPick: _send,
            ),
          _Composer(
            controller: _input,
            enabled: !_generating && widget.gemma.status == GemmaStatus.ready,
            generating: _generating,
            hintText: _starters.hint,
            onSubmit: () => _send(),
            onStop: _stop,
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final QAStarters? starters;
  const _Welcome({this.starters});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = starters?.welcomeTitle ?? 'Ask anything about this lecture';
    final body = starters?.welcomeBody
        ?? 'Gemma 4 runs on this phone. Nothing leaves your device — works anywhere.';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [
                cs.primary.withValues(alpha: 0.32),
                cs.primary.withValues(alpha: 0.05),
              ],
            ),
          ),
          child: Icon(Icons.auto_awesome_rounded, color: cs.primary, size: 28),
        ),
        const SizedBox(height: 18),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          body,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.6),
              ),
        ),
      ],
    );
  }
}

class _Bubble extends StatefulWidget {
  final _ChatMessage msg;
  final bool showTyping;
  final AnimationController typingDots;
  const _Bubble({
    required this.msg,
    required this.showTyping,
    required this.typingDots,
  });

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> with SingleTickerProviderStateMixin {
  late final AnimationController _enter;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _enter, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(_fade);
    _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.msg;
    final align = m.fromUser ? Alignment.centerRight : Alignment.centerLeft;
    final cs = Theme.of(context).colorScheme;
    final bg = m.fromUser ? cs.primary : cs.surfaceContainerHighest;
    final fg = m.fromUser ? cs.onPrimary : cs.onSurface;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: m.fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!m.fromUser)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 4),
                  child: Text(
                    'Gemma 4',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.45),
                      fontSize: 11,
                      letterSpacing: 0.3,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              if (!m.fromUser && m.thinking.trim().isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                  child: _ReasoningPanel(thinking: m.thinking),
                ),
              if (!m.fromUser && m.text.trim().isNotEmpty &&
                  (_isOffTopic(m.text) ||
                      m.citations.any((c) => c.result['found'] == true)))
                _GroundingChip(message: m),
              Align(
                alignment: align,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(m.fromUser ? 16 : 4),
                        bottomRight: Radius.circular(m.fromUser ? 4 : 16),
                      ),
                    ),
                    child: widget.showTyping
                        ? _TypingDots(controller: widget.typingDots, color: fg)
                        : SelectableText(
                            _stripMarkers(m.text),
                            style: TextStyle(color: fg, fontSize: 15.5, height: 1.4),
                          ),
                  ),
                ),
              ),
              if (!m.fromUser && m.citations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 6),
                          child: Text(
                            'Grounded in the lecture',
                            style: TextStyle(
                              fontSize: 11, letterSpacing: 0.3,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                        ...m.citations.map((c) => _CitationCard(citation: c)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _isOffTopic(String text) =>
    text.trimLeft().toLowerCase().startsWith('[off-topic]');

String _stripMarkers(String text) {
  final trimmed = text.trimLeft();
  if (trimmed.toLowerCase().startsWith('[off-topic]')) {
    return trimmed.substring('[off-topic]'.length).trimLeft();
  }
  return text;
}

class _GroundingChip extends StatelessWidget {
  final _ChatMessage message;
  const _GroundingChip({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final offTopic = _isOffTopic(message.text);
    final citations = message.citations
        .where((c) => c.result['found'] == true)
        .length;
    final Color bg;
    final Color fg;
    final IconData icon;
    final String label;
    if (offTopic) {
      bg = cs.error.withValues(alpha: 0.16);
      fg = cs.error;
      icon = Icons.report_problem_rounded;
      label = 'Off-topic · not answered from the lecture';
    } else if (citations > 0) {
      bg = const Color(0xFF1E4D34);
      fg = const Color(0xFF7AE0A0);
      icon = Icons.verified_rounded;
      label = 'Grounded · $citations citation${citations == 1 ? '' : 's'}';
    } else {
      bg = Colors.white.withValues(alpha: 0.06);
      fg = Colors.white.withValues(alpha: 0.55);
      icon = Icons.info_outline_rounded;
      label = 'No citations';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(8),
          border: Border.all(color: fg.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                letterSpacing: 0.2, color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasoningPanel extends StatefulWidget {
  final String thinking;
  const _ReasoningPanel({required this.thinking});

  @override
  State<_ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<_ReasoningPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(Icons.psychology_alt_rounded,
                      size: 14, color: cs.secondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _expanded ? 'Reasoning' : 'Reasoning · tap to reveal',
                      style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: cs.secondary,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 16, color: Colors.white.withValues(alpha: 0.55),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                widget.thinking.trim(),
                style: TextStyle(
                  fontSize: 13, height: 1.4,
                  color: Colors.white.withValues(alpha: 0.7),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CitationCard extends StatelessWidget {
  final Citation citation;
  const _CitationCard({required this.citation});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = citation;
    final found = c.result['found'] == true;
    final isQuote = c.toolName == 'quote_from_lecture';
    final isTerm = c.toolName == 'look_up_term';
    final icon = isQuote
        ? Icons.format_quote_rounded
        : (isTerm ? Icons.menu_book_rounded : Icons.bolt_rounded);
    String title;
    String body;
    String? trailing;
    if (!found) {
      title = isQuote ? 'No matching quote' : 'No matching term';
      body = isQuote
          ? '"${c.args['query']}" wasn\'t in the transcript.'
          : '"${c.args['term']}" isn\'t in the study pack.';
    } else if (isQuote) {
      title = 'quote_from_lecture';
      body = '"${c.result['quote']}"';
      trailing = c.result['timestamp'] as String?;
    } else if (isTerm) {
      title = 'look_up_term · ${c.result['term']}';
      body = c.result['definition'] as String? ?? '';
    } else {
      title = c.toolName;
      body = c.result.toString();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: cs.primary,
                  ),
                ),
              ),
              if (trailing != null)
                Text(
                  trailing,
                  style: TextStyle(
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(
              fontSize: 13, height: 1.4,
              color: Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  final AnimationController controller;
  final Color color;
  const _TypingDots({required this.controller, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36, height: 18,
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          double opacity(int i) {
            // Stagger 3 dots so they pulse out of phase.
            final phase = (controller.value - i * 0.25) % 1.0;
            // Triangular pulse: 0 -> 1 -> 0 across the period.
            return phase < 0.5
                ? 0.3 + 0.7 * (phase * 2)
                : 0.3 + 0.7 * (1 - (phase - 0.5) * 2);
          }
          Widget dot(int i) => Container(
                width: 7, height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: opacity(i).clamp(0.3, 1.0)),
                ),
              );
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [dot(0), dot(1), dot(2)],
          );
        },
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  final List<String> questions;
  final void Function(String) onPick;
  const _SuggestionRow({required this.questions, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        itemCount: questions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final q = questions[i];
          return Material(
            color: cs.primary.withValues(alpha: 0.12),
            shape: RoundedRectangleBorder(
              side: BorderSide(color: cs.primary.withValues(alpha: 0.32)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                HapticFeedback.selectionClick();
                onPick(q);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_awesome_rounded,
                        size: 14, color: cs.primary),
                    const SizedBox(width: 6),
                    Text(
                      q,
                      style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.88),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool generating;
  final VoidCallback onSubmit;
  final VoidCallback? onStop;
  final String? hintText;
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSubmit,
    this.generating = false,
    this.onStop,
    this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  decoration: InputDecoration(
                    hintText: hintText ?? 'Ask Gemma about this lecture…',
                    filled: false,
                    fillColor: Colors.transparent,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    isDense: true,
                  ),
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSubmit(),
                ),
              ),
              const SizedBox(width: 4),
              if (generating)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.error.withValues(alpha: 0.9),
                  ),
                  child: IconButton(
                    tooltip: 'Stop',
                    icon: Icon(Icons.stop_rounded, color: cs.onError, size: 22),
                    onPressed: onStop,
                  ),
                )
              else
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (_, v, __) {
                    final canSend = enabled && v.text.trim().isNotEmpty;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: canSend ? cs.primary : cs.surfaceContainerHighest,
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.arrow_upward_rounded,
                          color: canSend ? cs.onPrimary : Colors.white.withValues(alpha: 0.3),
                          size: 22,
                        ),
                        onPressed: canSend ? onSubmit : null,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
