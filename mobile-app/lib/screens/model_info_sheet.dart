// Shared bottom sheet describing the on-device model stack — surfaced from
// the lectures setup banner, the Q&A app bar, and the settings screen.
// Lives in one place so the wording stays consistent (this is essentially
// the demo's "trust me" moment).

import 'package:flutter/material.dart';

class ModelInfoSheet extends StatelessWidget {
  const ModelInfoSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1F),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const ModelInfoSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 12,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, color: cs.primary),
                const SizedBox(width: 8),
                const Text('Running on this phone',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Nothing in this app calls the cloud. The whole stack — speech, '
              'reasoning, translation — runs locally on your device.',
              style: TextStyle(
                fontSize: 13, height: 1.45,
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 18),
            _ModelTile(
              icon: Icons.psychology_alt_rounded,
              name: 'Gemma 4 E2B',
              role: 'Reasoning, summarization, translation, Q&A',
              specs: const [
                ('Size on disk', '~2.6 GB'),
                ('Runtime', 'MediaPipe LiteRT'),
                ('Optimization', 'MTP (Multi-Token Prediction) — ~2× faster'),
              ],
              accent: cs.primary,
            ),
            const SizedBox(height: 12),
            _ModelTile(
              icon: Icons.graphic_eq_rounded,
              name: 'Speech recognition',
              role: 'Transcribes your lecture audio',
              specs: const [
                ('Primary', 'Apple Speech (iOS) — streams live captions'),
                ('Fallback', 'Whisper base via Cactus — for devices w/o native STT'),
                ('Audio leaves device?', 'No'),
              ],
              accent: cs.primary,
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF7AE0A0).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF7AE0A0).withValues(alpha: 0.22),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      color: const Color(0xFF7AE0A0).withValues(alpha: 0.9), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Built for the Gemma 4 Good Hackathon. Works on a plane, '
                      'a bus, in a classroom with no WiFi.',
                      style: TextStyle(
                        fontSize: 12.5, height: 1.45,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final IconData icon;
  final String name;
  final String role;
  final List<(String, String)> specs;
  final Color accent;
  const _ModelTile({
    required this.icon,
    required this.name,
    required this.role,
    required this.specs,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF101013),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: accent.withValues(alpha: 0.14),
                ),
                child: Icon(icon, color: accent, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600,
                        )),
                    Text(
                      role,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...specs.map((s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Text(
                      s.$1,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.$2,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }
}
