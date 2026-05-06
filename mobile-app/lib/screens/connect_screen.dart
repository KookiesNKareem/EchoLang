import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../data/bundle_store.dart';
import '../data/pi_discovery.dart';

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

  final PiDiscovery _discovery = PiDiscovery();
  List<PiNode> _discoveredPis = const [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.prefillHost ?? '');
    _classId = TextEditingController(text: widget.prefillClassId ?? '');
    if (widget.prefillLang != null) _lang = widget.prefillLang!;
    _scanLan();
  }

  Future<void> _scanLan() async {
    setState(() => _scanning = true);
    try {
      final pis = await _discovery.browse();
      if (!mounted) return;
      setState(() => _discoveredPis = pis);
    } catch (_) {
      // mDNS can fail (permissions, network type) — silently fall through
      // to manual entry.
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _useDiscovered(PiNode pi) {
    setState(() {
      _host.text = pi.baseUrl;
      if (pi.activeClassId != null) _classId.text = pi.activeClassId!;
    });
    if (pi.activeClassId != null) _download();
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

  @override
  Widget build(BuildContext context) {
    final canSubmit = !_loading && _host.text.trim().isNotEmpty && _classId.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Join classroom')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Text('Found nearby', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              if (_scanning)
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _scanning ? null : _scanLan,
                tooltip: 'Rescan',
              ),
            ],
          ),
          if (_discoveredPis.isEmpty && !_scanning)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'No classroom Pis on this network. Enter the address manually below.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ..._discoveredPis.map((pi) => Card(
                child: ListTile(
                  leading: Icon(
                    pi.hasActiveClass ? Icons.podcasts : Icons.dns,
                    color: pi.hasActiveClass ? Colors.greenAccent : null,
                  ),
                  title: Text(pi.activeTitle?.isNotEmpty == true
                      ? pi.activeTitle!
                      : 'No class in session'),
                  subtitle: Text([
                    pi.host,
                    if (pi.activeTeacher?.isNotEmpty == true) pi.activeTeacher!,
                  ].join(' · ')),
                  enabled: pi.hasActiveClass && !_loading,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _useDiscovered(pi),
                ),
              )),
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
