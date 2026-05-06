import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import 'scan_screen.dart';

const _langs = ['en', 'ar', 'uk', 'es', 'zh', 'fr', 'ps', 'fa'];

class ConnectScreen extends StatefulWidget {
  final BundleStore store;
  final String? prefillHost;
  final String? prefillClassId;
  final String? prefillLang;

  const ConnectScreen({
    super.key,
    required this.store,
    this.prefillHost,
    this.prefillClassId,
    this.prefillLang,
  });

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _host;
  late final TextEditingController _classId;
  String _lang = 'en';
  String? _status;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.prefillHost ?? '');
    _classId = TextEditingController(text: widget.prefillClassId ?? '');
    if (widget.prefillLang != null) _lang = widget.prefillLang!;
  }

  @override
  void dispose() {
    _host.dispose();
    _classId.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() {
      _loading = true;
      _status = 'Downloading…';
    });
    try {
      final ref = await widget.store.download(
        piBaseUrl: _host.text.trim(),
        classId: _classId.text.trim(),
        lang: _lang,
      );
      setState(() => _status = 'Saved: ${ref.manifest.title}');
      if (mounted) context.pop();
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scan() async {
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (result == null || !mounted) return;
    setState(() {
      _host.text = result.host;
      _classId.text = result.classId;
      if (result.lang != null) _lang = result.lang!;
    });
    // Scanner gave us everything — kick off the download immediately.
    _download();
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_loading && _host.text.trim().isNotEmpty && _classId.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to classroom')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _loading ? null : _scan,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const Icon(Icons.qr_code_scanner, size: 36),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Scan the classroom QR', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            'Point your camera at the QR code on the teacher’s screen.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or enter manually', style: Theme.of(context).textTheme.bodySmall),
            ),
            const Expanded(child: Divider()),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Pi address',
              hintText: 'http://192.168.0.185:8080',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _classId,
            decoration: const InputDecoration(
              labelText: 'Class id',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
            autocorrect: false,
          ),
          const SizedBox(height: 16),
          Text('Language', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _langs
                .map((c) => FilterChip(
                      label: Text(c.toUpperCase()),
                      selected: c == _lang,
                      onSelected: (_) => setState(() => _lang = c),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: canSubmit ? _download : null,
            icon: _loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download),
            label: const Text('Download lecture'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
