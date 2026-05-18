// Pi discovery on the LAN. Two strategies, run together:
//   1. mDNS/Bonjour browse for `_locallearning._tcp.local.` — fast when it
//      works, but iOS local-network permission timing and the multicast_dns
//      package can silently drop replies.
//   2. HTTP sweep of the device's local /24 on port 8080, probing `/` for
//      the EchoLang Pi fingerprint. Slower setup but works whenever the
//      phone and Pi share a subnet, no permission prompts required.
// Results are merged by IP so the same Pi found by both shows up once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

class PiNode {
  /// Bonjour instance name, e.g. "LocalLearning on raspberrypi"
  final String name;
  final String host; // e.g. "raspberrypi.local"
  final String? ip;  // resolved A record — preferred over `.local` on iOS
  final int port;
  final String? activeClassId;
  final String? activeTitle;
  final String? activeTeacher;
  final List<String> langs;

  PiNode({
    required this.name,
    required this.host,
    required this.port,
    this.ip,
    this.activeClassId,
    this.activeTitle,
    this.activeTeacher,
    this.langs = const [],
  });

  String get baseUrl => 'http://${ip ?? host}:$port';
  bool get hasActiveClass => activeClassId != null && activeClassId!.isNotEmpty;
}

class PiDiscovery {
  static const String serviceType = '_locallearning._tcp.local';
  static const int piPort = 8080;

  /// Browse via mDNS AND sweep the local /24 in parallel; merge results by IP.
  Future<List<PiNode>> browse({
    Duration duration = const Duration(seconds: 6),
  }) async {
    final results = await Future.wait([
      _mdnsBrowse(duration),
      _lanSweep(),
    ]);
    final byIp = <String, PiNode>{};
    for (final list in results) {
      for (final pi in list) {
        final key = pi.ip ?? pi.host;
        // Prefer the entry with the richest metadata (mDNS provides class/title).
        final existing = byIp[key];
        if (existing == null || (pi.activeClassId != null && existing.activeClassId == null)) {
          byIp[key] = pi;
        }
      }
    }
    return byIp.values.toList();
  }

  Future<List<PiNode>> _mdnsBrowse(Duration duration) async {
    final client = MDnsClient();
    try {
      await client.start();
    } catch (_) {
      return const [];
    }
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
          final ip = await _firstIp(client, srv.target);
          final node = PiNode(
            name: ptr.domainName,
            host: srv.target,
            ip: ip,
            port: srv.port,
            activeClassId: txt['class_id']?.isNotEmpty == true ? txt['class_id'] : null,
            activeTitle: txt['title']?.isNotEmpty == true ? txt['title'] : null,
            activeTeacher: txt['teacher']?.isNotEmpty == true ? txt['teacher'] : null,
            langs: (txt['langs'] ?? '').split(',').where((s) => s.isNotEmpty).toList(),
          );
          found[ptr.domainName] = node;
        }
      }
    } catch (_) {
      // Best effort — fall back to whatever the LAN sweep finds.
    } finally {
      client.stop();
    }
    return found.values.toList();
  }

  /// Sweep every host on each local /24 we're a member of, probing port 8080
  /// for the EchoLang Pi fingerprint. Runs all 254 probes concurrently with a
  /// tight per-host timeout; total wall time is ~1s on a healthy LAN.
  Future<List<PiNode>> _lanSweep() async {
    final subnets = await _localSubnets();
    if (subnets.isEmpty) return const [];
    final futures = <Future<PiNode?>>[];
    for (final prefix in subnets) {
      for (var i = 1; i <= 254; i++) {
        futures.add(_probe('$prefix.$i'));
      }
    }
    final results = await Future.wait(futures);
    return results.whereType<PiNode>().toList();
  }

  Future<List<String>> _localSubnets() async {
    final out = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              _is172Private(ip)) {
            final lastDot = ip.lastIndexOf('.');
            out.add(ip.substring(0, lastDot));
          }
        }
      }
    } catch (_) {}
    return out.toList();
  }

  static bool _is172Private(String ip) {
    if (!ip.startsWith('172.')) return false;
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  Future<PiNode?> _probe(String ip) async {
    try {
      final resp = await http
          .get(Uri.parse('http://$ip:$piPort/'))
          .timeout(const Duration(milliseconds: 600));
      if (resp.statusCode != 200) return null;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      if (body['service'] != 'EchoLang Pi') return null;
      String? classId, title, teacher;
      try {
        final c = await http
            .get(Uri.parse('http://$ip:$piPort/api/class/active'))
            .timeout(const Duration(seconds: 1));
        if (c.statusCode == 200 && c.body.isNotEmpty) {
          final j = jsonDecode(c.body) as Map<String, dynamic>;
          classId = j['id'] as String?;
          title = j['title'] as String?;
          teacher = j['teacher'] as String?;
        }
      } catch (_) {}
      return PiNode(
        name: ip,
        host: ip,
        ip: ip,
        port: piPort,
        activeClassId: classId,
        activeTitle: title,
        activeTeacher: teacher,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> _firstIp(MDnsClient client, String host) async {
    try {
      await for (final ip in client
          .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(host))
          .timeout(const Duration(seconds: 2), onTimeout: (_) {})) {
        return ip.address.address;
      }
    } catch (_) {}
    return null;
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
