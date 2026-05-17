import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'sample_lecture.dart';

class BundleStore {
  Future<Directory> get _root async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/lectures');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<List<LectureRef>> list() async {
    await _ensureSampleLecture();
    final root = await _root;
    final entries = await root.list().toList();
    final out = <LectureRef>[];
    for (final e in entries) {
      if (e is! Directory) continue;
      final manifestFile = File('${e.path}/manifest.json');
      if (!await manifestFile.exists()) continue;
      try {
        final m = BundleManifest.fromJson(
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>,
        );
        out.add(LectureRef(dir: e, manifest: m));
      } catch (_) {
        // Corrupt directory; skip silently.
      }
    }
    out.sort((a, b) => b.manifest.startedAt.compareTo(a.manifest.startedAt));
    return out;
  }

  Future<Lecture> load(Directory dir) async {
    final manifest = BundleManifest.fromJson(
      jsonDecode(await File('${dir.path}/manifest.json').readAsString()) as Map<String, dynamic>,
    );
    final transcript = TranscriptLine.parseFile(File('${dir.path}/transcript.txt'));
    final translationFile = File('${dir.path}/translation.txt');
    final translation = await translationFile.exists()
        ? TranscriptLine.parseFile(translationFile)
        : <TranscriptLine>[];
    final packFile = File('${dir.path}/study_pack.json');
    final studyPack = await packFile.exists()
        ? StudyPack.fromJson(jsonDecode(await packFile.readAsString()) as Map<String, dynamic>)
        : null;
    final confusionsFile = File('${dir.path}/confusions.json');
    final confusions = await confusionsFile.exists()
        ? (jsonDecode(await confusionsFile.readAsString()) as List)
            .map((e) => ConfusionMark.fromJson(e as Map<String, dynamic>))
            .toList()
        : <ConfusionMark>[];
    return Lecture(
      dir: dir,
      manifest: manifest,
      transcript: transcript,
      translation: translation,
      studyPack: studyPack,
      confusions: confusions,
    );
  }

  Future<LectureRef> download({
    required String piBaseUrl,
    required String classId,
    required String lang,
  }) async {
    final base = piBaseUrl.replaceAll(RegExp(r'/$'), '');
    final url = Uri.parse('$base/api/lecture/$classId/bundle?lang=$lang');
    final resp = await http.get(url);
    if (resp.statusCode != 200) {
      throw Exception('Pi returned ${resp.statusCode}: ${resp.body}');
    }
    final root = await _root;
    final outDir = Directory('${root.path}/${classId}_$lang');
    if (await outDir.exists()) await outDir.delete(recursive: true);
    await outDir.create(recursive: true);
    final archive = ZipDecoder().decodeBytes(resp.bodyBytes);
    for (final entry in archive) {
      final outPath = '${outDir.path}/${entry.name}';
      if (entry.isFile) {
        final f = File(outPath);
        await f.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    final manifest = BundleManifest.fromJson(
      jsonDecode(await File('${outDir.path}/manifest.json').readAsString()) as Map<String, dynamic>,
    );
    return LectureRef(dir: outDir, manifest: manifest);
  }

  Future<void> delete(Directory dir) async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> _ensureSampleLecture() async {
    final root = await _root;
    final dir = Directory('${root.path}/${kSampleLectureClassId}_en');
    final sentinel = File('${dir.path}/.seeded');
    if (await sentinel.exists()) return;
    if (await dir.exists()) {
      // Already created by a previous run (older version without sentinel).
      // Just write the sentinel and bail.
      await sentinel.writeAsString('1');
      return;
    }
    final startedAt = DateTime.now().toUtc().subtract(const Duration(days: 1));
    final endedAt = startedAt.add(const Duration(minutes: 38));
    await saveLocal(
      classId: kSampleLectureClassId,
      title: kSampleLectureTitle,
      lang: 'en',
      startedAt: startedAt,
      endedAt: endedAt,
      transcript: kSampleLectureTranscript,
      studyPack: null,
    );
    await sentinel.writeAsString('1');
  }

  Future<void> saveTranslation({
    required Directory dir,
    required String text,
  }) async {
    final startedAt = DateTime.now().toUtc();
    final lines = _segmentTranscript(text, startedAt);
    final formatted = lines.asMap().entries.map((e) {
      final ts = _hms(startedAt.add(Duration(seconds: e.key * 4)));
      return '[$ts] (#${e.key}) ${e.value}';
    }).join('\n');
    await File('${dir.path}/translation.txt').writeAsString('$formatted\n');
  }

  Future<void> renameLecture({required Directory dir, required String title}) async {
    final manifestFile = File('${dir.path}/manifest.json');
    final raw = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    raw['title'] = title;
    await manifestFile.writeAsString(const JsonEncoder.withIndent('  ').convert(raw));
  }

  Future<void> renameLectureLang({required Directory dir, required String lang}) async {
    final manifestFile = File('${dir.path}/manifest.json');
    final raw = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    raw['lang'] = lang;
    await manifestFile.writeAsString(const JsonEncoder.withIndent('  ').convert(raw));
  }

  Future<void> saveStudyPack({
    required Directory dir,
    required StudyPack pack,
  }) async {
    await File('${dir.path}/study_pack.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'lang': pack.lang,
        'summary': pack.summary,
        'key_terms': pack.keyTerms
            .map((kt) => {'term': kt.term, 'definition': kt.definition})
            .toList(),
        'practice_questions': pack.practiceQuestions,
      }),
    );
  }

  Future<LectureRef> saveLocal({
    required String classId,
    required String title,
    required String lang,
    required DateTime startedAt,
    required DateTime endedAt,
    required String transcript,
    StudyPack? studyPack,
  }) async {
    final root = await _root;
    final dir = Directory('${root.path}/${classId}_$lang');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final captionLines = _segmentTranscript(transcript, startedAt);

    final manifest = {
      'bundle_version': '1',
      'class_id': classId,
      'title': title,
      'teacher': null,
      'lang': lang,
      'started_at': startedAt.toUtc().toIso8601String(),
      'ended_at': endedAt.toUtc().toIso8601String(),
      'caption_count': captionLines.length,
      'built_at': DateTime.now().toUtc().toIso8601String(),
      'source': 'local-recording',
    };
    await File('${dir.path}/manifest.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    final transcriptText = captionLines.asMap().entries.map((e) {
      final ts = _hms(startedAt.add(Duration(seconds: e.key * 4)));
      return '[$ts] (#${e.key}) ${e.value}';
    }).join('\n');
    await File('${dir.path}/transcript.txt').writeAsString('$transcriptText\n');
    // No translation in personal mode (yet) — write empty so the viewer
    // shows the "no content for this language" state on the Translation tab
    // rather than crashing.
    await File('${dir.path}/translation.txt').writeAsString('');

    if (studyPack != null) {
      await File('${dir.path}/study_pack.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'lang': studyPack.lang,
          'summary': studyPack.summary,
          'key_terms': studyPack.keyTerms
              .map((kt) => {'term': kt.term, 'definition': kt.definition})
              .toList(),
          'practice_questions': studyPack.practiceQuestions,
        }),
      );
    }
    await File('${dir.path}/confusions.json').writeAsString('[]');

    final m = BundleManifest.fromJson(manifest);
    return LectureRef(dir: dir, manifest: m);
  }

  List<String> _segmentTranscript(String text, DateTime startedAt) {
    final clean = text.trim();
    if (clean.isEmpty) return ['(no speech detected)'];
    final parts = clean
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? [clean] : parts;
  }

  String _hms(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
