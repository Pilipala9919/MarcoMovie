// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
// Clean-room segmented danmu provider contract shared across Flutter platforms.

typedef DanmuVoidCallback = void Function();

class DanmuCancelToken {
  bool _cancelled = false;
  final List<DanmuVoidCallback> _hooks = <DanmuVoidCallback>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final snapshot = List<DanmuVoidCallback>.from(_hooks);
    _hooks.clear();
    for (final hook in snapshot) {
      try {
        hook();
      } catch (_) {}
    }
  }

  void onCancel(DanmuVoidCallback hook) {
    if (_cancelled) {
      try {
        hook();
      } catch (_) {}
      return;
    }
    _hooks.add(hook);
  }

  void removeCancelHook(DanmuVoidCallback hook) {
    _hooks.remove(hook);
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const DanmuCancelledException();
    }
  }
}

class DanmuCancelledException implements Exception {
  final String message;
  const DanmuCancelledException([this.message = 'Danmu request cancelled']);

  @override
  String toString() => 'DanmuCancelledException: $message';
}

class DanmuHttpException implements Exception {
  final int statusCode;
  final String message;
  final int retryAfterMs;

  const DanmuHttpException(
    this.statusCode,
    this.message, {
    this.retryAfterMs = 0,
  });

  @override
  String toString() => 'DanmuHttpException($statusCode): $message';
}

class DanmuMatchQuery {
  final String title;
  final String episodeTitle;
  final int episodeIndex;
  final int durationSec;
  final int? seasonNumber;
  final bool isMotionComic;
  final String year;
  final String animeIdOverride;
  final String originOverride;

  const DanmuMatchQuery({
    required this.title,
    this.episodeTitle = '',
    this.episodeIndex = 0,
    this.durationSec = 0,
    this.seasonNumber,
    this.isMotionComic = false,
    this.year = '',
    this.animeIdOverride = '',
    this.originOverride = '',
  });
}

class DanmuCandidate {
  final String sourceOrigin;
  final String animeId;
  final String animeTitle;
  final String boundEpisodeId; // mmdanmu://v1?src=...&ep=...
  final String episodeTitle;
  final double confidence;

  const DanmuCandidate({
    required this.sourceOrigin,
    required this.animeId,
    required this.animeTitle,
    required this.boundEpisodeId,
    required this.episodeTitle,
    required this.confidence,
  });
}

class DanmuSegmentDescriptor {
  final int startMs;
  final int endMs;
  final String segmentUrl;

  const DanmuSegmentDescriptor({
    required this.startMs,
    required this.endMs,
    required this.segmentUrl,
  });
}

class DanmuEpisodeSession {
  final String boundEpisodeId;
  final bool segmented;
  final List<DanmuSegmentDescriptor> segments;
  final List<DanmuItem> preloadComments;

  const DanmuEpisodeSession({
    required this.boundEpisodeId,
    required this.segmented,
    this.segments = const <DanmuSegmentDescriptor>[],
    this.preloadComments = const <DanmuItem>[],
  });
}

class DanmuItem {
  final String id;
  final int timeMs;
  final int mode; // 1=scroll, 4=bottom, 5=top
  final int rgbColor;
  final String text;

  const DanmuItem({
    required this.id,
    required this.timeMs,
    required this.mode,
    required this.rgbColor,
    required this.text,
  });

  static int compareOrder(DanmuItem a, DanmuItem b) {
    final cmp = a.timeMs.compareTo(b.timeMs);
    if (cmp != 0) return cmp;
    return a.id.compareTo(b.id);
  }
}

abstract class DanmuProvider {
  Future<List<DanmuCandidate>> matchOrSearch(
    DanmuMatchQuery query, {
    DanmuCancelToken? cancelToken,
  });

  Future<List<DanmuCandidate>> listEpisodes(
    String sourceOrigin,
    String animeId, {
    DanmuCancelToken? cancelToken,
  });

  Future<DanmuEpisodeSession> openSession(
    String boundEpisodeId, {
    DanmuCancelToken? cancelToken,
  });

  Future<List<DanmuItem>> fetchWindow(
    DanmuEpisodeSession session,
    int windowIndex, {
    DanmuCancelToken? cancelToken,
  });
}
