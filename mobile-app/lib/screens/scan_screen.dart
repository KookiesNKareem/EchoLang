// QR scanner: read the Pi's PWA join URL and extract host + class id
// so the student can connect with one tap instead of typing IPs.
//
// The Pi serves QR codes at /api/qr/{class_id} that encode URLs like
//   http://192.168.0.185:8080/join?class=abc123
// We parse those into (host="http://192.168.0.185:8080", class="abc123")
// and either return them to the caller or kick off a download immediately.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class ScanResult {
  final String host;
  final String classId;
  final String? lang;
  ScanResult({required this.host, required this.classId, this.lang});

  /// Parse a Pi-style join URL (or any URL with ?class=) into a ScanResult.
  /// Returns null if the URL doesn't carry a class id.
  static ScanResult? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return null;
    final classId = uri.queryParameters['class'];
    if (classId == null || classId.isEmpty) return null;
    final host = '${uri.scheme}://${uri.authority}';
    return ScanResult(
      host: host,
      classId: classId,
      lang: uri.queryParameters['lang'],
    );
  }
}

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  String? _badRead;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final b in capture.barcodes) {
      final value = b.rawValue;
      if (value == null) continue;
      final result = ScanResult.tryParse(value);
      if (result != null) {
        _handled = true;
        Navigator.of(context).pop(result);
        return;
      }
      setState(() => _badRead = "Scanned QR doesn't look like a class join URL");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan classroom QR')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Aim guide
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _badRead ??
                          "Point at the QR code on the teacher's screen.",
                      style: const TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
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
