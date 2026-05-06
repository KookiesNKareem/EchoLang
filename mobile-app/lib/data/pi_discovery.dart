// mDNS/Bonjour discovery of LocalLearning Pis on the LAN.
//
// The Pi advertises `_locallearning._tcp.local.` with TXT records:
//   title, teacher, class_id, langs, version
// We browse, resolve SRV (host+port) and TXT, and emit a list of [PiNode]
// the connect screen renders so students never have to type IPs.

import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

class PiNode {
  /// Bonjour instance name, e.g. "LocalLearning on raspberrypi"
  final String name;
  final String host; // e.g. "raspberrypi.local"
  final int port;
  final String? activeClassId;
  final String? activeTitle;
  final String? activeTeacher;
  final List<String> langs;

  PiNode({
    required this.name,
    required this.host,
    required this.port,
    this.activeClassId,
    this.activeTitle,
    this.activeTeacher,
    this.langs = const [],
  });

  String get baseUrl => 'http://$host:$port';
  bool get hasActiveClass => activeClassId != null && activeClassId!.isNotEmpty;
}

class PiDiscovery {
  static const String serviceType = '_locallearning._tcp.local';

  /// Browse for [duration]; returns the set of discovered Pis.
  Future<List<PiNode>> browse({
    Duration duration = const Duration(seconds: 4),
  }) async {
    final client = MDnsClient();
    await client.start();
    final found = <String, PiNode>{};
    try {
      final ptrStream = client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(serviceType),
      );
      await for (final ptr in ptrStream.timeout(duration, onTimeout: (_) {})) {
        final srvStream = client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        );
        await for (final srv in srvStream.timeout(const Duration(seconds: 2),
            onTimeout: (_) {})) {
          final txt = await _firstTxt(client, ptr.domainName);
          final node = PiNode(
            name: ptr.domainName,
            host: srv.target,
            port: srv.port,
            activeClassId: txt['class_id']?.isNotEmpty == true ? txt['class_id'] : null,
            activeTitle: txt['title']?.isNotEmpty == true ? txt['title'] : null,
            activeTeacher: txt['teacher']?.isNotEmpty == true ? txt['teacher'] : null,
            langs: (txt['langs'] ?? '').split(',').where((s) => s.isNotEmpty).toList(),
          );
          found[ptr.domainName] = node;
        }
      }
    } finally {
      client.stop();
    }
    return found.values.toList();
  }

  Future<Map<String, String>> _firstTxt(MDnsClient client, String fullName) async {
    final out = <String, String>{};
    try {
      await for (final txt in client
          .lookup<TxtResourceRecord>(ResourceRecordQuery.text(fullName))
          .timeout(const Duration(seconds: 2), onTimeout: (_) {})) {
        // TxtResourceRecord exposes `text` as one big string with
        // newline-separated key=value pairs (it's actually one entry per
        // sub-record, but the multicast_dns package collapses them).
        for (final line in txt.text.split('\n')) {
          final eq = line.indexOf('=');
          if (eq > 0) {
            out[line.substring(0, eq)] = line.substring(eq + 1);
          }
        }
        break;
      }
    } catch (_) {}
    return out;
  }
}
