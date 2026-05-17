// Tiny JSON-on-disk preferences store. Keeps a couple of UX-sticky values
// (last picked study-pack language, etc.) so the user doesn't have to
// repeat themselves across record/re-translate flows. Backed by a single
// file in the app docs dir — no shared_preferences dep, no migrations.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const Map<String, String> langNames = {
  'en': 'English',
  'ar': 'Arabic',
  'uk': 'Ukrainian',
  'es': 'Spanish',
  'zh': 'Chinese',
  'fr': 'French',
  'ps': 'Pashto',
  'fa': 'Persian',
};

class Preferences {
  static Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/preferences.json');
  }

  static Future<Map<String, dynamic>> _read() async {
    final f = await _file();
    if (!await f.exists()) return {};
    try {
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, dynamic> data) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(data));
  }

  /// Last study-pack language the user picked, or null if never set.
  /// Callers should validate against [langNames] before applying.
  static Future<String?> getLastLang() async {
    final m = await _read();
    final v = m['last_lang'];
    return v is String ? v : null;
  }

  static Future<void> setLastLang(String lang) async {
    final m = await _read();
    m['last_lang'] = lang;
    await _write(m);
  }

  /// Last Pi baseUrl (e.g. "http://192.168.0.185:8080") the user successfully
  /// connected to. Lets the model downloader try the classroom Pi at app
  /// startup, before the user has joined a class this session.
  static Future<String?> getLastPiBaseUrl() async {
    final m = await _read();
    final v = m['last_pi_base_url'];
    return v is String && v.isNotEmpty ? v : null;
  }

  static Future<void> setLastPiBaseUrl(String url) async {
    final m = await _read();
    m['last_pi_base_url'] = url;
    await _write(m);
  }
}
