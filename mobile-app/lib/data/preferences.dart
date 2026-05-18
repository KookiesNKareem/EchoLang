// Tiny JSON-on-disk preferences store. Keeps a couple of UX-sticky values
// (last picked study-pack language, etc.) so the user doesn't have to
// repeat themselves across record/re-translate flows. Backed by a single
// file in the app docs dir — no shared_preferences dep, no migrations.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

const Map<String, String> langNames = {
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
  'nl': 'Dutch',
  'pl': 'Polish',
  'ru': 'Russian',
  'uk': 'Ukrainian',
  'tr': 'Turkish',
  'el': 'Greek',
  'ar': 'Arabic',
  'fa': 'Persian',
  'ur': 'Urdu',
  'ps': 'Pashto',
  'he': 'Hebrew',
  'hi': 'Hindi',
  'bn': 'Bengali',
  'ta': 'Tamil',
  'th': 'Thai',
  'vi': 'Vietnamese',
  'id': 'Indonesian',
  'tl': 'Tagalog',
  'sw': 'Swahili',
  'ko': 'Korean',
  'ja': 'Japanese',
  'zh': 'Chinese (Mandarin)',
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

  /// "Watched" Pi: the lectures screen polls this Pi for new classes so the
  /// user can pre-join before recording starts and lectures show up
  /// automatically. Stores the base URL plus the language to fetch in.
  static Future<({String url, String lang})?> getWatchedPi() async {
    final m = await _read();
    final url = m['watched_pi_url'];
    final lang = m['watched_pi_lang'];
    if (url is String && url.isNotEmpty && lang is String && lang.isNotEmpty) {
      return (url: url, lang: lang);
    }
    return null;
  }

  static Future<void> setWatchedPi(String url, String lang) async {
    final m = await _read();
    m['watched_pi_url'] = url;
    m['watched_pi_lang'] = lang;
    await _write(m);
  }

  static Future<void> clearWatchedPi() async {
    final m = await _read();
    m.remove('watched_pi_url');
    m.remove('watched_pi_lang');
    await _write(m);
  }
}
