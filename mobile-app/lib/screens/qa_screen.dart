import 'dart:io';

import 'package:flutter/material.dart';

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
  _ChatMessage({required this.fromUser, required this.text});
}

class _QAScreenState extends State<QAScreen> {
  Lecture? _lecture;
  final List<_ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _generating = false;
  String? _modelStatus;

  @override
  void initState() {
    super.initState();
    _loadLecture();
    _ensureModel();
  }

  Future<void> _loadLecture() async {
    final l = await widget.store.load(Directory(widget.dirPath));
    if (mounted) setState(() => _lecture = l);
  }

  Future<void> _ensureModel() async {
    if (widget.gemma.status == GemmaStatus.ready) {
      setState(() => _modelStatus = 'Model ready');
      return;
    }
    setState(() => _modelStatus = 'Loading model…');
    try {
      await widget.gemma.ensureReady(
        onProgress: (p, status) {
          if (!mounted) return;
          setState(() => _modelStatus =
              p != null ? '${(p * 100).toStringAsFixed(0)}% — $status' : status);
        },
      );
      if (mounted) setState(() => _modelStatus = 'Model ready');
    } catch (e) {
      if (mounted) setState(() => _modelStatus = 'Model error: $e');
    }
  }

  Future<void> _send() async {
    final q = _input.text.trim();
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
      _messages.add(_ChatMessage(fromUser: false, text: '…'));
      _generating = true;
    });
    _scrollToBottom();
    try {
      final ctx = _lecture!.transcript.map((l) => l.text).join(' ');
      final answer = await widget.gemma.ask(lectureContext: ctx, question: q);
      if (!mounted) return;
      setState(() {
        _messages.last.text = answer;
        _generating = false;
      });
      _scrollToBottom();
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
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ask about this lecture'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _modelStatus ?? '',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _Suggestions(
                    pack: _lecture?.studyPack,
                    onPick: (q) {
                      _input.text = q;
                      _send();
                    },
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _Bubble(msg: _messages[i]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !_generating,
                      decoration: const InputDecoration(
                        hintText: 'Ask a question…',
                        border: OutlineInputBorder(),
                      ),
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _generating ? null : _send,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _ChatMessage msg;
  const _Bubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final align = msg.fromUser ? Alignment.centerRight : Alignment.centerLeft;
    final cs = Theme.of(context).colorScheme;
    final bg = msg.fromUser ? cs.primary : cs.surfaceContainerHighest;
    final fg = msg.fromUser ? cs.onPrimary : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: align,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
            child: Text(msg.text, style: TextStyle(color: fg)),
          ),
        ),
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  final StudyPack? pack;
  final void Function(String) onPick;
  const _Suggestions({required this.pack, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final qs = pack?.practiceQuestions ?? const [];
    if (qs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Ask anything about today’s lecture. Gemma is running on this phone — no internet needed.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Suggested questions', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ...qs.take(4).map(
              (q) => Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onPick(q),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(q),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
