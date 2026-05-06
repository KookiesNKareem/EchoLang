// Data models for downloaded lecture bundles.
//
// The Pi server emits ZIPs of this shape:
//   manifest.json    - lecture metadata, language, version, build time
//   transcript.txt   - English captions, "[HH:MM:SS] (#N) text" per line
//   translation.txt  - target-language captions in the same format
//   study_pack.json  - {summary, key_terms, practice_questions} in target lang
//   confusions.json  - caption indices the student marked confusing

import 'dart:io';
import 'dart:convert';

class BundleManifest {
  final String bundleVersion;
  final String classId;
  final String title;
  final String? teacher;
  final String lang;
  final DateTime startedAt;
  final DateTime endedAt;
  final int captionCount;
  final DateTime builtAt;

  BundleManifest({
    required this.bundleVersion,
    required this.classId,
    required this.title,
    required this.teacher,
    required this.lang,
    required this.startedAt,
    required this.endedAt,
    required this.captionCount,
    required this.builtAt,
  });

  factory BundleManifest.fromJson(Map<String, dynamic> j) => BundleManifest(
        bundleVersion: j['bundle_version'] as String,
        classId: j['class_id'] as String,
        title: j['title'] as String,
        teacher: j['teacher'] as String?,
        lang: j['lang'] as String,
        startedAt: DateTime.parse(j['started_at'] as String),
        endedAt: DateTime.parse(j['ended_at'] as String),
        captionCount: j['caption_count'] as int,
        builtAt: DateTime.parse(j['built_at'] as String),
      );
}

class KeyTerm {
  final String term;
  final String definition;
  KeyTerm({required this.term, required this.definition});
  factory KeyTerm.fromJson(Map<String, dynamic> j) =>
      KeyTerm(term: j['term'] as String, definition: j['definition'] as String);
}

class StudyPack {
  final String lang;
  final String summary;
  final List<KeyTerm> keyTerms;
  final List<String> practiceQuestions;

  StudyPack({
    required this.lang,
    required this.summary,
    required this.keyTerms,
    required this.practiceQuestions,
  });

  factory StudyPack.fromJson(Map<String, dynamic> j) => StudyPack(
        lang: j['lang'] as String,
        summary: j['summary'] as String,
        keyTerms: ((j['key_terms'] as List?) ?? const [])
            .map((e) => KeyTerm.fromJson(e as Map<String, dynamic>))
            .toList(),
        practiceQuestions: ((j['practice_questions'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
      );
}

class ConfusionMark {
  final String studentId;
  final int captionIndex;
  final DateTime markedAt;
  ConfusionMark({
    required this.studentId,
    required this.captionIndex,
    required this.markedAt,
  });
  factory ConfusionMark.fromJson(Map<String, dynamic> j) => ConfusionMark(
        studentId: j['student_id'] as String,
        captionIndex: j['caption_index'] as int,
        markedAt: DateTime.parse(j['marked_at'] as String),
      );
}

class TranscriptLine {
  final String timestamp;
  final int index;
  final String text;
  TranscriptLine({required this.timestamp, required this.index, required this.text});

  static final RegExp _re = RegExp(r'^\[(\d{2}:\d{2}:\d{2})\] \(#(\d+)\)\s*(.*)$');

  static List<TranscriptLine> parseFile(File f) {
    final out = <TranscriptLine>[];
    for (final raw in const LineSplitter().convert(f.readAsStringSync())) {
      final m = _re.firstMatch(raw);
      if (m == null) continue;
      out.add(TranscriptLine(
        timestamp: m.group(1)!,
        index: int.parse(m.group(2)!),
        text: m.group(3)!,
      ));
    }
    return out;
  }
}

/// A lecture bundle as it lives on disk after download + unzip.
class Lecture {
  final Directory dir;
  final BundleManifest manifest;
  final List<TranscriptLine> transcript;
  final List<TranscriptLine> translation;
  final StudyPack? studyPack;
  final List<ConfusionMark> confusions;

  Lecture({
    required this.dir,
    required this.manifest,
    required this.transcript,
    required this.translation,
    required this.studyPack,
    required this.confusions,
  });
}

/// A lightweight reference for the lectures-list screen — just the
/// metadata, no transcript/study-pack contents loaded.
class LectureRef {
  final Directory dir;
  final BundleManifest manifest;
  LectureRef({required this.dir, required this.manifest});
}

const Set<String> rtlLangs = {'ar', 'ps', 'fa', 'ur', 'he'};
