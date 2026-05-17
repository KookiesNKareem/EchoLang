// Robust download of the Gemma 4 E2B .litertlm bundle.
//
// Three problems this solves vs. flutter_gemma's built-in fromNetwork():
//
//   1. Bad classroom internet. We probe the classroom Pi first (via mDNS
//      and any persisted "last Pi" baseUrl) and pull the bundle from it
//      over LAN. The Pi caches the file once; phones get WiFi speeds and
//      no public internet is required for the demo.
//
//   2. Flaky connections. Each candidate URL is downloaded via
//      background_downloader, which transparently uses HTTP Range to resume
//      from a .part file on failure, with retries.
//
//   3. App backgrounding. background_downloader hands off to NSURLSession
//      background tasks on iOS and WorkManager on Android, so a 2.6 GB
//      download keeps going when the student locks the screen.
//
// We hand the resulting on-disk path to FlutterGemma.installModel().fromFile()
// instead of fromNetwork() — flutter_gemma's network path doesn't support
// any of the three above.
import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// What the [ModelDownloader] is doing right now, for the UI banner.
enum DownloadPhase { probing, downloading, ready, failed }

class DownloadProgress {
  final DownloadPhase phase;
  final double? fraction;
  final String message;
  const DownloadProgress(this.phase, this.fraction, this.message);
}

class ModelDownloader {
  /// Where we save the bundle. Application support is *not* iCloud-backed
  /// on iOS, which matters for a 2.6 GB blob.
  static const _baseDir = BaseDirectory.applicationSupport;
  static const _subDir = 'models';
  static const _filename = 'gemma-4-E2B-it.litertlm';

  /// Returns the absolute path the bundle lives at on this device, whether
  /// or not it has been downloaded yet.
  Future<String> localPath() async {
    final root = await getApplicationSupportDirectory();
    return '${root.path}/$_subDir/$_filename';
  }

  /// Returns the local path if the bundle is already on disk with the
  /// expected size, else null. Lets the caller skip the downloader entirely
  /// on subsequent app launches.
  Future<String?> existingLocalPath({int? expectedBytes}) async {
    final path = await localPath();
    final f = File(path);
    if (!await f.exists()) return null;
    if (expectedBytes != null) {
      final size = await f.length();
      if (size != expectedBytes) return null;
    }
    return path;
  }

  /// Download the bundle, trying each URL in [candidates] in order until one
  /// succeeds. Reports progress via [onProgress]. Returns the on-disk path
  /// of the completed download.
  ///
  /// Candidates are typically a list of Pi LAN URLs followed by the public
  /// Hugging Face URL; the first one that responds to a HEAD probe within
  /// [probeTimeout] wins.
  Future<String> download({
    required List<Uri> candidates,
    void Function(DownloadProgress)? onProgress,
    Duration probeTimeout = const Duration(seconds: 3),
  }) async {
    if (candidates.isEmpty) {
      throw ArgumentError('ModelDownloader.download needs at least one URL');
    }

    // 1. Find the first reachable candidate. We don't probe in parallel — Pi
    //    candidates are intentionally listed before the HF fallback so we
    //    prefer LAN even when both are reachable.
    Uri? picked;
    for (final url in candidates) {
      onProgress?.call(DownloadProgress(
        DownloadPhase.probing,
        null,
        'Looking for Gemma 4 on ${url.host}…',
      ));
      if (await _isReachable(url, probeTimeout)) {
        picked = url;
        break;
      }
    }
    if (picked == null) {
      onProgress?.call(const DownloadProgress(
        DownloadPhase.failed,
        null,
        'No download source reachable',
      ));
      throw const ModelDownloadException('No reachable URL for the Gemma bundle');
    }

    final sourceLabel = _isLanHost(picked.host) ? 'classroom Pi' : 'Hugging Face';
    onProgress?.call(DownloadProgress(
      DownloadPhase.downloading,
      0.0,
      'Downloading Gemma 4 from $sourceLabel…',
    ));

    // 2. background_downloader handles Range/resume + iOS NSURLSession
    //    background tasks + Android WorkManager. allowPause:true makes it
    //    use byte-range resume across temporary failures.
    final task = DownloadTask(
      url: picked.toString(),
      filename: _filename,
      directory: _subDir,
      baseDirectory: _baseDir,
      updates: Updates.statusAndProgress,
      requiresWiFi: false,
      retries: 5,
      allowPause: true,
      displayName: 'Gemma 4 E2B',
    );

    final result = await FileDownloader().download(
      task,
      onStatus: (status) {
        if (status == TaskStatus.waitingToRetry) {
          onProgress?.call(DownloadProgress(
            DownloadPhase.downloading,
            null,
            'Reconnecting to $sourceLabel…',
          ));
        }
      },
      onProgress: (p) {
        // background_downloader emits negative sentinels (-1 = unknown,
        // -2 = paused, etc.) — only forward real [0..1] values.
        if (p < 0 || p > 1) return;
        onProgress?.call(DownloadProgress(
          DownloadPhase.downloading,
          p,
          'Downloading Gemma 4 from $sourceLabel (${(p * 100).toStringAsFixed(0)}%)…',
        ));
      },
    );

    if (result.status != TaskStatus.complete) {
      onProgress?.call(DownloadProgress(
        DownloadPhase.failed,
        null,
        'Download failed: ${result.status.name}',
      ));
      throw ModelDownloadException(
        'Download from $sourceLabel did not complete: ${result.status.name}',
      );
    }

    final path = await task.filePath();
    onProgress?.call(const DownloadProgress(
      DownloadPhase.ready,
      1.0,
      'Gemma 4 ready',
    ));
    return path;
  }

  /// HEAD-probe a URL with a short timeout. We don't care about the
  /// response body — only that the server is up and the URL exists. 200 or
  /// 206 are both acceptable; anything else (incl. 404 for a Pi without
  /// the bundle cached) means try the next candidate.
  Future<bool> _isReachable(Uri url, Duration timeout) async {
    final client = http.Client();
    try {
      final resp = await client.head(url).timeout(timeout);
      return resp.statusCode == 200 || resp.statusCode == 206;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Heuristic for "is this a LAN host" — drives the UX label so the user
  /// sees "Downloading from classroom Pi" instead of an IP. Matches RFC1918
  /// ranges, .local mDNS hostnames, and common Pi defaults.
  bool _isLanHost(String host) {
    if (host.endsWith('.local')) return true;
    if (host == 'localhost') return true;
    if (host.startsWith('10.')) return true;
    if (host.startsWith('192.168.')) return true;
    if (host.startsWith('172.')) {
      final parts = host.split('.');
      if (parts.length >= 2) {
        final second = int.tryParse(parts[1]);
        if (second != null && second >= 16 && second <= 31) return true;
      }
    }
    return false;
  }
}

class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => 'ModelDownloadException: $message';
}
