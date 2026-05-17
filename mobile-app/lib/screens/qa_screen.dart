import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/bundle_store.dart';
import '../data/models.dart';
import '../data/preferences.dart';
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
  _ChatMessage({required this.fromUser, required this.text});
}

class _QAScreenState extends State<QAScreen> with SingleTickerProviderStateMixin {
  Lecture? _lecture;
  final List<_ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  late final AnimationController _typingDots;
  bool _generating = false;
  String? _modelStatus;
  QAStarters? _starters;
  bool _startersLoading = false;
  String? _startersForLang;

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

  void _maybeLoadStarters() {
    if (_lecture == null) return;
    if (widget.gemma.status != GemmaStatus.ready) return;
    final lang = _lecture!.manifest.lang;
    if (_startersLoading || _startersForLang == lang) return;
    _startersLoading = true;
    _startersForLang = lang;
    final ctx = _lecture!.transcript.map((l) => l.text).join(' ');
    final langName = langNames[lang] ?? 'English';
    () async {
      try {
        final s = await widget.gemma.generateStarters(
          lectureContext: ctx,
          languageName: langName,
        );
        if (!mounted) return;
        setState(() {
          _starters = s;
          _startersLoading = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _startersLoading = false);
      }
    }();
  }

  Future<void> _send([String? prefilled]) async {
    final q = (prefilled ?? _input.text).trim();
    if (q.isEmpty || _generating || _lecture == null) return;
    if (widget.gemma.status != GemmaStatus.ready) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model still loading — try again in a moment.')),
      );
      return;
    }
    setState(() {
      _input.clear();
      _messages.add(_ChatMessage(fromUser: true, text: q));
      _messages.add(_ChatMessage(fromUser: false, text: ''));
      _generating = true;
    });
    _scrollToBottom();
    try {
      final ctx = _lecture!.transcript.map((l) => l.text).join(' ');
      final buf = StringBuffer();
      await for (final token in widget.gemma.askStream(lectureContext: ctx, question: q)) {
        if (!mounted) return;
        buf.write(token);
        setState(() => _messages.last.text = buf.toString());
        _scrollToBottom();
      }
      if (!mounted) return;
      setState(() => _generating = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.last.text = 'Error: $e';
        _generating = false;
      });
    }
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
                  _modelStatus ?? _starters?.subtitle ?? 'Gemma 4 · on this phone',
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
                ? _Welcome(
                    pack: _lecture?.studyPack,
                    onPick: (q) => _send(q),
                  )
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
          if (_starters != null &&
              _starters!.questions.isNotEmpty &&
              _messages.isEmpty)
            _SuggestionRow(
              questions: _starters!.questions,
              onPick: _send,
            ),
          _Composer(
            controller: _input,
            enabled: !_generating && widget.gemma.status == GemmaStatus.ready,
            hintText: _starters?.hint,
            onSubmit: () => _send(),
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final StudyPack? pack;
  final void Function(String) onPick;
  const _Welcome({required this.pack, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final qs = pack?.practiceQuestions ?? const [];
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
        Text('Ask anything about this lecture',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Gemma 4 runs on this phone. Nothing leaves your device — '
          'works on the bus, on a plane, with no signal.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.6),
              ),
        ),
        if (qs.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('Try one of these',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.7),
                  )),
          const SizedBox(height: 10),
          ...qs.take(4).map((q) => _SuggestionTile(text: q, onTap: () => onPick(q))),
        ],
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _SuggestionTile({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
                Icon(Icons.chevron_right_rounded,
                    color: Colors.white.withValues(alpha: 0.3), size: 18),
              ],
            ),
          ),
        ),
      ),
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
                            m.text,
                            style: TextStyle(color: fg, fontSize: 15.5, height: 1.4),
                          ),
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
              onTap: () => onPick(q),
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
  final VoidCallback onSubmit;
  final String? hintText;
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSubmit,
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
