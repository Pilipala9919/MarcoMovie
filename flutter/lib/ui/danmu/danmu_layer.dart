// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform, kIsWeb, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/danmu/block_filter.dart';
import '../../core/danmu/danmu_prefs.dart';
import '../../core/danmu/provider.dart';
import '../../core/danmu/segment_cache.dart';
import '../../core/ohos_runtime.dart';

class DanmuPainterEntry {
  final TextPainter fill;
  final TextPainter stroke;
  final double width;
  final double height;

  DanmuPainterEntry({
    required this.fill,
    required this.stroke,
    required this.width,
    required this.height,
  });

  void dispose() {
    fill.dispose();
    stroke.dispose();
  }
}

/// Bounded LRU object pool for pre-laid-out [TextPainter] pairs (stroke + fill).
/// Eliminates per-frame text layout during scrolling so 4K 300-item frames paint < 8ms.
class DanmuTextPainterPool {
  static const int defaultMaxEntries = 384;

  final int maxEntries;
  final LinkedHashMap<String, DanmuPainterEntry> _entries =
      LinkedHashMap<String, DanmuPainterEntry>();

  int hitCount = 0;
  int missCount = 0;
  int evictionCount = 0;

  DanmuTextPainterPool({this.maxEntries = defaultMaxEntries})
      : assert(maxEntries > 0);

  int get length => _entries.length;

  DanmuPainterEntry acquire({
    required String text,
    required int rgbColor,
    required double fontSize,
    required double opacity,
  }) {
    final sizeTenths = (fontSize * 10).round();
    final alphaByte = (opacity.clamp(0.0, 1.0) * 255).round();
    final colorHex = rgbColor & 0xFFFFFF;
    final key = '$sizeTenths|$alphaByte|$colorHex|$text';

    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      hitCount++;
      return existing;
    }

    missCount++;
    while (_entries.length >= maxEntries) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey);
      removed?.dispose();
      evictionCount++;
    }

    final strokeWidth = math.max(1.8, fontSize * 0.11);
    final strokeAlpha = (alphaByte * 0.90).round().clamp(0, 255);
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = Color.fromARGB(strokeAlpha, 0, 0, 0);

    final strokePainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          foreground: strokePaint,
          height: 1.15,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final fillColor = Color((alphaByte << 24) | colorHex);
    final fillPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: fillColor,
          height: 1.15,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

    final entry = DanmuPainterEntry(
      fill: fillPainter,
      stroke: strokePainter,
      width: fillPainter.width,
      height: fillPainter.height,
    );
    _entries[key] = entry;
    return entry;
  }

  void clear() {
    for (final e in _entries.values) {
      e.dispose();
    }
    _entries.clear();
  }

  void dispose() => clear();
}

class DanmuActiveEntry {
  final DanmuItem item;
  final int lane;
  final int durationMs;
  final double width;
  final double velocityPxPerMs;
  double x = 0;
  double y = 0;

  DanmuActiveEntry({
    required this.item,
    required this.lane,
    required this.durationMs,
    required this.width,
    required this.velocityPxPerMs,
  });
}

/// Collision-free linear kinematics danmu lane allocator (`>= 24px` right-entry & tail-exit gap).
class DanmuLayoutEngine {
  static const int minRows = 2;
  static const int maxSupportedLanes = 24;
  static const double clearancePx = 24.0;
  static const double lineHeightFactor = 1.42;
  static const int pinnedDurationMs = 4000;
  static const int baseScrollDurationMs = 7600;
  static const double minBottomSafeInset = 44.0;
  static const int desktopMaxOnScreen = 300;
  static const int mobileMaxOnScreen = 120;

  final List<double> _entryClearTimeMs =
      List<double>.filled(maxSupportedLanes, double.negativeInfinity);
  final List<double> _tailExitTimeMs =
      List<double>.filled(maxSupportedLanes, double.negativeInfinity);
  final List<double> _prevVelocity =
      List<double>.filled(maxSupportedLanes, 0.0);
  final List<int> _topPinnedUntilMs = List<int>.filled(maxSupportedLanes, -1);
  final List<int> _bottomPinnedUntilMs =
      List<int>.filled(maxSupportedLanes, -1);

  final Map<String, DanmuActiveEntry> _active = <String, DanmuActiveEntry>{};
  final Queue<String> _droppedOrder = Queue<String>();
  final Set<String> _droppedIds = <String>{};

  int? _lastEffectiveMs;
  double _lastViewW = -1;
  double _lastViewH = -1;
  double _lastFontSize = -1;
  double _lastTopInset = -1;
  double _lastBottomSafeInset = -1;

  List<DanmuActiveEntry> get activeEntries => _active.values.toList(growable: false);
  Iterable<DanmuActiveEntry> get activeIterable => _active.values;
  int get activeCount => _active.length;

  static int computeMaxRows({
    required double viewHeight,
    required double topInset,
    required double bottomSafeInset,
    required double area,
    required double fontSize,
    required int rowCap,
  }) {
    final cap = rowCap.clamp(minRows, maxSupportedLanes);
    if (viewHeight <= 0 || fontSize <= 0) return minRows;
    final clampedArea = area.clamp(0.25, 1.0);
    final bottomReserve =
        clampedArea >= 0.75 ? math.max(minBottomSafeInset, bottomSafeInset) : 0.0;
    final usableHeight =
        math.max(0.0, viewHeight - math.max(0.0, topInset) - bottomReserve);
    final rows = ((usableHeight * clampedArea) / (fontSize * lineHeightFactor))
        .floor();
    return rows.clamp(minRows, cap);
  }

  static int computeScrollDurationMs(double speedMultiplier) {
    final mult = speedMultiplier.clamp(0.5, 2.0);
    return math.max(2500, (baseScrollDurationMs / mult).round());
  }

  void reset() {
    for (var i = 0; i < maxSupportedLanes; i++) {
      _entryClearTimeMs[i] = double.negativeInfinity;
      _tailExitTimeMs[i] = double.negativeInfinity;
      _prevVelocity[i] = 0.0;
      _topPinnedUntilMs[i] = -1;
      _bottomPinnedUntilMs[i] = -1;
    }
    _active.clear();
    _droppedOrder.clear();
    _droppedIds.clear();
    _lastEffectiveMs = null;
  }

  int allocateScrollLane({
    required int startMs,
    required double viewWidth,
    required double textWidth,
    required int durationMs,
    required int maxRows,
  }) {
    final rows = maxRows.clamp(minRows, maxSupportedLanes);
    final vCurr = (viewWidth + textWidth) / durationMs;
    final arriveLeftMs = startMs + (viewWidth / vCurr);
    for (var r = 0; r < rows; r++) {
      if (startMs < _entryClearTimeMs[r]) continue;
      if (vCurr > _prevVelocity[r] && arriveLeftMs < _tailExitTimeMs[r]) {
        continue;
      }
      _entryClearTimeMs[r] = startMs + (textWidth + clearancePx) / vCurr;
      _tailExitTimeMs[r] = startMs + durationMs + (clearancePx / vCurr);
      _prevVelocity[r] = vCurr;
      return r;
    }
    return -1;
  }

  int allocateTopLane(int startMs, int maxRows) {
    final rows = maxRows.clamp(minRows, maxSupportedLanes);
    for (var r = 0; r < rows; r++) {
      if (_topPinnedUntilMs[r] < 0 || startMs >= _topPinnedUntilMs[r]) {
        _topPinnedUntilMs[r] = startMs + pinnedDurationMs;
        return r;
      }
    }
    return -1;
  }

  int allocateBottomLane(int startMs, int maxRows) {
    final rows = maxRows.clamp(minRows, maxSupportedLanes);
    for (var r = 0; r < rows; r++) {
      if (_bottomPinnedUntilMs[r] < 0 || startMs >= _bottomPinnedUntilMs[r]) {
        _bottomPinnedUntilMs[r] = startMs + pinnedDurationMs;
        return r;
      }
    }
    return -1;
  }

  void purgeBlocked(DanmuBlockFilter filter) {
    if (filter.isEmpty || _active.isEmpty) return;
    _active.removeWhere((_, entry) => filter.isBlocked(entry.item.text));
  }

  void step({
    required int effectiveMs,
    required List<DanmuItem> candidates,
    required double viewWidth,
    required double viewHeight,
    required double fontSize,
    required double topInset,
    required double bottomSafeInset,
    required double area,
    required int rowCap,
    required int maxOnScreenItems,
    required int scrollDurationMs,
    required bool showScroll,
    required bool showTop,
    required bool showBottom,
    required double Function(DanmuItem item) measureWidth,
  }) {
    if (viewWidth <= 0 || viewHeight <= 0 || effectiveMs < 0) {
      reset();
      return;
    }

    final maxRows = computeMaxRows(
      viewHeight: viewHeight,
      topInset: topInset,
      bottomSafeInset: bottomSafeInset,
      area: area,
      fontSize: fontSize,
      rowCap: rowCap,
    );

    // Do NOT include maxRows/area here: adaptive or area row changes only constrain
    // NEW lane admissions so already in-flight danmu never reset or teleport.
    final geometryChanged = viewWidth != _lastViewW ||
        viewHeight != _lastViewH ||
        (fontSize - _lastFontSize).abs() > 0.25 ||
        (topInset - _lastTopInset).abs() > 0.5 ||
        (bottomSafeInset - _lastBottomSafeInset).abs() > 0.5;
    final timeJumped = _lastEffectiveMs != null &&
        (effectiveMs < _lastEffectiveMs! - 100 ||
            effectiveMs > _lastEffectiveMs! + 3000);

    if (geometryChanged || timeJumped) {
      reset();
      _lastViewW = viewWidth;
      _lastViewH = viewHeight;
      _lastFontSize = fontSize;
      _lastTopInset = topInset;
      _lastBottomSafeInset = bottomSafeInset;
    }
    _lastEffectiveMs = effectiveMs;

    // 1. Expire finished or mode-disabled entries
    if (_active.isNotEmpty) {
      final expired = <String>[];
      for (final entry in _active.entries) {
        final item = entry.value.item;
        final age = effectiveMs - item.timeMs;
        final modeDisabled = (item.mode == 1 && !showScroll) ||
            (item.mode == 5 && !showTop) ||
            (item.mode == 4 && !showBottom);
        if (modeDisabled || age < 0 || age > entry.value.durationMs) {
          expired.add(entry.key);
        }
      }
      for (final id in expired) {
        _active.remove(id);
      }
    }

    // 2. Admit newly arriving candidates
    for (final item in candidates) {
      final age = effectiveMs - item.timeMs;
      if (age < 0) break;
      if (item.mode == 1 && !showScroll) continue;
      if (item.mode == 5 && !showTop) continue;
      if (item.mode == 4 && !showBottom) continue;
      final duration =
          (item.mode == 4 || item.mode == 5) ? pinnedDurationMs : scrollDurationMs;
      if (age > duration) continue;
      if (_active.containsKey(item.id) || _droppedIds.contains(item.id)) {
        continue;
      }
      if (_active.length >= maxOnScreenItems) {
        _recordDropped(item.id);
        continue;
      }
      final width = measureWidth(item);
      final int lane;
      if (item.mode == 5) {
        lane = allocateTopLane(item.timeMs, maxRows);
      } else if (item.mode == 4) {
        lane = allocateBottomLane(item.timeMs, maxRows);
      } else {
        lane = allocateScrollLane(
          startMs: item.timeMs,
          viewWidth: viewWidth,
          textWidth: width,
          durationMs: duration,
          maxRows: maxRows,
        );
      }
      if (lane < 0) {
        _recordDropped(item.id);
        continue;
      }
      _active[item.id] = DanmuActiveEntry(
        item: item,
        lane: lane,
        durationMs: duration,
        width: width,
        velocityPxPerMs: (viewWidth + width) / duration,
      );
    }

    // 3. Update draw coordinates
    final lineHeight = fontSize * lineHeightFactor;
    final safeBottom = math.max(minBottomSafeInset, bottomSafeInset);
    for (final entry in _active.values) {
      final age = effectiveMs - entry.item.timeMs;
      if (entry.item.mode == 5) {
        entry.x = (viewWidth - entry.width) * 0.5;
        entry.y = topInset + entry.lane * lineHeight;
      } else if (entry.item.mode == 4) {
        entry.x = (viewWidth - entry.width) * 0.5;
        entry.y = viewHeight - safeBottom - (entry.lane + 1) * lineHeight;
      } else {
        entry.x = viewWidth - entry.velocityPxPerMs * age;
        entry.y = topInset + entry.lane * lineHeight;
      }
    }
  }

  void _recordDropped(String id) {
    if (_droppedIds.add(id)) {
      _droppedOrder.addLast(id);
      if (_droppedOrder.length > 512) {
        _droppedIds.remove(_droppedOrder.removeFirst());
      }
    }
  }
}

class DanmuLayerPainter extends CustomPainter {
  final DanmuLayoutEngine layoutEngine;
  final DanmuTextPainterPool painterPool;
  final DanmuSettings settings;
  final double effectiveFontSize;
  final double bottomSafeInset;
  final double topInset;
  final int maxOnScreenItems;
  final int Function() resolveRawPositionMs;
  final List<DanmuItem> Function(int rawPosMs) resolveCandidates;

  DanmuLayerPainter({
    required this.layoutEngine,
    required this.painterPool,
    required this.settings,
    required this.effectiveFontSize,
    required this.bottomSafeInset,
    required this.topInset,
    required this.maxOnScreenItems,
    required this.resolveRawPositionMs,
    required this.resolveCandidates,
    super.repaint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (OhosRuntime.isOhos || !settings.effectiveEnabled) return;
    if (size.width <= 0 || size.height <= 0) return;

    final rawPosMs = resolveRawPositionMs();
    final effectiveMs =
        DanmuSegmentCache.computeEffectiveMs(rawPosMs, settings.timeOffsetMs);
    if (effectiveMs < 0) return;

    final candidates = resolveCandidates(rawPosMs);
    final scrollDurationMs =
        DanmuLayoutEngine.computeScrollDurationMs(settings.speedMultiplier);

    layoutEngine.step(
      effectiveMs: effectiveMs,
      candidates: candidates,
      viewWidth: size.width,
      viewHeight: size.height,
      fontSize: effectiveFontSize,
      topInset: topInset,
      bottomSafeInset: bottomSafeInset,
      area: settings.displayArea,
      rowCap: settings.maxRows,
      maxOnScreenItems: maxOnScreenItems,
      scrollDurationMs: scrollDurationMs,
      showScroll: settings.showScroll,
      showTop: settings.showTop,
      showBottom: settings.showBottom,
      measureWidth: (item) => painterPool
          .acquire(
            text: item.text,
            rgbColor: item.rgbColor,
            fontSize: effectiveFontSize,
            opacity: settings.opacity,
          )
          .width,
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final entry in layoutEngine.activeIterable) {
      final tp = painterPool.acquire(
        text: entry.item.text,
        rgbColor: entry.item.rgbColor,
        fontSize: effectiveFontSize,
        opacity: settings.opacity,
      );
      final offset = Offset(entry.x, entry.y);
      tp.stroke.paint(canvas, offset);
      tp.fill.paint(canvas, offset);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DanmuLayerPainter oldDelegate) {
    return oldDelegate.settings != settings ||
        oldDelegate.effectiveFontSize != effectiveFontSize ||
        oldDelegate.bottomSafeInset != bottomSafeInset ||
        oldDelegate.maxOnScreenItems != maxOnScreenItems;
  }
}

/// Standalone, collision-free danmu overlay widget backed by [CustomPainter],
/// a [Ticker] synchronized with `playSpeed.clamp(0.5, 2.0)`, and a bounded [DanmuTextPainterPool].
///
/// Automatically renders [SizedBox.shrink] when [OhosRuntime.isOhos] is true.
class DanmuLayer extends StatefulWidget {
  final DanmuSettings settings;
  final int positionMs;
  /// Optional high-frequency position notifier driven directly by the player's
  /// position stream so danmu keeps scrolling smoothly even when the parent
  /// skips `setState` (e.g. fullscreen with hidden progress bar / auto-hidden HUD).
  final ValueListenable<int>? positionListenable;
  final bool playing;
  final double playSpeed;
  final DanmuSegmentCache? segmentCache;
  final List<DanmuItem> items;
  final double bottomSafeInset;
  final double topInset;
  final bool? isDesktopOverride;

  const DanmuLayer({
    super.key,
    required this.settings,
    required this.positionMs,
    this.positionListenable,
    required this.playing,
    this.playSpeed = 1.0,
    this.segmentCache,
    this.items = const <DanmuItem>[],
    this.bottomSafeInset = DanmuLayoutEngine.minBottomSafeInset,
    this.topInset = 8.0,
    this.isDesktopOverride,
  });

  @override
  State<DanmuLayer> createState() => _DanmuLayerState();
}

/// Monotonic sub-tick media clock interpolator that re-anchors smoothly whenever
/// `playSpeed` changes (e.g. M2 long-press 2.0x boost release -> 1.0x), preventing
/// backward jumps that would trigger [DanmuLayoutEngine.reset].
class DanmuClockInterpolator {
  int _lastReportedPosMs = 0;
  int _anchorPosMs = 0;
  Duration _anchorTickElapsed = Duration.zero;
  Duration _lastTickElapsed = Duration.zero;
  double _clampedPlaySpeed = 1.0;

  DanmuClockInterpolator({int initialPosMs = 0, double playSpeed = 1.0})
      : _lastReportedPosMs = initialPosMs,
        _anchorPosMs = initialPosMs,
        _clampedPlaySpeed = playSpeed.clamp(0.5, 2.0);

  double get playSpeed => _clampedPlaySpeed;

  void onTickerStarted(int rawPositionMs) {
    _lastReportedPosMs = rawPositionMs;
    _anchorPosMs = rawPositionMs;
    _anchorTickElapsed = Duration.zero;
    _lastTickElapsed = Duration.zero;
  }

  void onTick(Duration elapsed) {
    _lastTickElapsed = elapsed;
  }

  void setPlaySpeed(double newSpeed, {required bool playing}) {
    final next = newSpeed.clamp(0.5, 2.0);
    if (playing) {
      _anchorPosMs = currentPositionMs(playing: true);
      _anchorTickElapsed = _lastTickElapsed;
    }
    _clampedPlaySpeed = next;
  }

  void onExternalPosition(int newPosMs, {required bool playing}) {
    if (!playing) {
      _lastReportedPosMs = newPosMs;
      _anchorPosMs = newPosMs;
      _anchorTickElapsed = _lastTickElapsed;
      return;
    }
    final current = currentPositionMs(playing: true);
    final isLargeJump = (newPosMs - _lastReportedPosMs).abs() > 1200;
    if (!isLargeJump && newPosMs >= _lastReportedPosMs && newPosMs < current) {
      // Forward player tick slightly behind extrapolated speed-boost estimate: stay monotonic.
      _anchorPosMs = current;
    } else {
      _anchorPosMs = newPosMs;
    }
    _lastReportedPosMs = newPosMs;
    _anchorTickElapsed = _lastTickElapsed;
  }

  int currentPositionMs({required bool playing}) {
    if (!playing) return _lastReportedPosMs;
    final dtMs = (_lastTickElapsed - _anchorTickElapsed).inMilliseconds;
    if (dtMs <= 0) return _anchorPosMs;
    final advance = math.min(1000, (dtMs * _clampedPlaySpeed).round());
    return _anchorPosMs + advance;
  }
}

class _DanmuLayerState extends State<DanmuLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final DanmuLayoutEngine _layoutEngine = DanmuLayoutEngine();
  final DanmuTextPainterPool _painterPool = DanmuTextPainterPool();
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);
  late final DanmuClockInterpolator _clock;
  Ticker? _ticker;
  bool _lifecycleObserverRegistered = false;
  bool _appBackgrounded = false;
  DanmuBlockFilter _blockFilter = DanmuBlockFilter.empty;

  bool get _isDesktop {
    if (widget.isDesktopOverride != null) return widget.isDesktopOverride!;
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  int get _externalPositionMs =>
      widget.positionListenable?.value ?? widget.positionMs;

  void _onExternalPositionListenableChanged() {
    final posMs = widget.positionListenable?.value;
    if (posMs == null || !mounted) return;
    _clock.onExternalPosition(posMs, playing: widget.playing);
    if (!widget.playing &&
        !OhosRuntime.isOhos &&
        widget.settings.effectiveEnabled) {
      widget.segmentCache?.onPlaybackTick(posMs, playing: false);
      _frameTick.value++;
    }
  }

  @override
  void initState() {
    super.initState();
    _clock = DanmuClockInterpolator(
      initialPosMs: _externalPositionMs,
      playSpeed: widget.playSpeed,
    );
    _blockFilter = widget.settings.buildBlockFilter();
    widget.positionListenable?.addListener(_onExternalPositionListenableChanged);
    _attachCache(widget.segmentCache);
    if (!OhosRuntime.isOhos) {
      _ticker = createTicker(_onTick);
      WidgetsBinding.instance.addObserver(this);
      _lifecycleObserverRegistered = true;
      _syncTickerState();
    }
  }

  void _attachCache(DanmuSegmentCache? cache) {
    if (cache == null || cache.isDisposed) return;
    cache.addListener(_onCacheUpdated);
    cache.setTimeOffsetMs(widget.settings.timeOffsetMs);
    cache.setBlockFilter(_blockFilter);
    if (!OhosRuntime.isOhos && widget.settings.effectiveEnabled) {
      cache.onPlaybackTick(
        _clock.currentPositionMs(playing: widget.playing),
        playing: widget.playing,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final backgrounded = state != AppLifecycleState.resumed;
    if (_appBackgrounded == backgrounded) return;
    _appBackgrounded = backgrounded;
    _syncTickerState();
  }

  @override
  void didUpdateWidget(covariant DanmuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    var shouldRepaint = false;

    if (oldWidget.segmentCache != widget.segmentCache) {
      final oldCache = oldWidget.segmentCache;
      if (oldCache != null && !oldCache.isDisposed) {
        oldCache.removeListener(_onCacheUpdated);
      }
      _layoutEngine.reset();
      _attachCache(widget.segmentCache);
      shouldRepaint = true;
    }

    if (!listEquals(oldWidget.settings.blockRules, widget.settings.blockRules)) {
      _blockFilter = widget.settings.buildBlockFilter();
      widget.segmentCache?.setBlockFilter(_blockFilter);
      _layoutEngine.purgeBlocked(_blockFilter);
      shouldRepaint = true;
    }

    if (oldWidget.settings.timeOffsetMs != widget.settings.timeOffsetMs) {
      widget.segmentCache?.setTimeOffsetMs(widget.settings.timeOffsetMs);
      _layoutEngine.reset();
      if (!OhosRuntime.isOhos && widget.settings.effectiveEnabled) {
        widget.segmentCache?.onPlaybackTick(
          _clock.currentPositionMs(playing: widget.playing),
          playing: widget.playing,
        );
      }
      shouldRepaint = true;
    }

    if (oldWidget.settings.showScroll != widget.settings.showScroll ||
        oldWidget.settings.showTop != widget.settings.showTop ||
        oldWidget.settings.showBottom != widget.settings.showBottom) {
      shouldRepaint = true;
    }

    if (oldWidget.playSpeed != widget.playSpeed) {
      _clock.setPlaySpeed(widget.playSpeed, playing: widget.playing);
      shouldRepaint = true;
    }

    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable
          ?.removeListener(_onExternalPositionListenableChanged);
      widget.positionListenable
          ?.addListener(_onExternalPositionListenableChanged);
      _clock.onExternalPosition(_externalPositionMs, playing: widget.playing);
      shouldRepaint = true;
    }

    if (widget.positionListenable == null &&
        oldWidget.positionMs != widget.positionMs) {
      _clock.onExternalPosition(widget.positionMs, playing: widget.playing);
      if (!widget.playing &&
          !OhosRuntime.isOhos &&
          widget.settings.effectiveEnabled) {
        widget.segmentCache?.onPlaybackTick(widget.positionMs, playing: false);
      }
      shouldRepaint = true;
    }

    if (oldWidget.playing != widget.playing ||
        oldWidget.settings.enabled != widget.settings.enabled) {
      _syncTickerState();
      if (!oldWidget.settings.enabled &&
          widget.settings.effectiveEnabled &&
          !OhosRuntime.isOhos) {
        widget.segmentCache?.onPlaybackTick(
          _clock.currentPositionMs(playing: widget.playing),
          playing: widget.playing,
        );
      }
      shouldRepaint = true;
    }

    if (shouldRepaint) {
      _frameTick.value++;
    }
  }

  void _onCacheUpdated() {
    if (mounted) _frameTick.value++;
  }

  void _syncTickerState() {
    final ticker = _ticker;
    if (ticker == null) return;
    final shouldRun = !OhosRuntime.isOhos &&
        !_appBackgrounded &&
        widget.settings.effectiveEnabled &&
        widget.playing;
    if (shouldRun && !ticker.isActive) {
      _clock.onTickerStarted(_externalPositionMs);
      ticker.start();
    } else if (!shouldRun && ticker.isActive) {
      ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    _clock.onTick(elapsed);
    final rawPos = _interpolatedRawPositionMs();
    widget.segmentCache?.onPlaybackTick(rawPos, playing: widget.playing);
    _frameTick.value++;
  }

  int _interpolatedRawPositionMs() {
    return _clock.currentPositionMs(playing: widget.playing);
  }

  List<DanmuItem> _resolveCandidates(int rawPosMs) {
    final cache = widget.segmentCache;
    if (cache != null) {
      return cache.snapshotForPosition(rawPosMs);
    }
    if (widget.items.isEmpty) return const <DanmuItem>[];
    final effectiveMs =
        DanmuSegmentCache.computeEffectiveMs(rawPosMs, widget.settings.timeOffsetMs);
    if (effectiveMs < 0) return const <DanmuItem>[];
    final minTimeMs = effectiveMs - DanmuSegmentCache.maxCommentLifetimeMs;
    var lo = 0;
    var hi = widget.items.length;
    while (lo < hi) {
      final mid = (lo + hi) >>> 1;
      if (widget.items[mid].timeMs < minTimeMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final out = <DanmuItem>[];
    final hasFilter = !_blockFilter.isEmpty;
    for (var i = lo; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (item.timeMs > effectiveMs) break;
      if (item.timeMs < minTimeMs) continue;
      if (hasFilter && _blockFilter.isBlocked(item.text)) continue;
      out.add(item);
    }
    return out;
  }

  @override
  void dispose() {
    widget.positionListenable
        ?.removeListener(_onExternalPositionListenableChanged);
    final cache = widget.segmentCache;
    if (cache != null && !cache.isDisposed) {
      cache.removeListener(_onCacheUpdated);
    }
    if (_lifecycleObserverRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _lifecycleObserverRegistered = false;
    }
    _ticker?.dispose();
    _painterPool.dispose();
    _frameTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OhosRuntime.isOhos || !widget.settings.effectiveEnabled) {
      return const SizedBox.shrink();
    }
    final scaler = MediaQuery.textScalerOf(context).clamp(
      minScaleFactor: 0.85,
      maxScaleFactor: 1.35,
    );
    final effectiveFontSize = scaler.scale(widget.settings.fontSize);
    final itemCap = _isDesktop
        ? DanmuLayoutEngine.desktopMaxOnScreen
        : DanmuLayoutEngine.mobileMaxOnScreen;

    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: DanmuLayerPainter(
            layoutEngine: _layoutEngine,
            painterPool: _painterPool,
            settings: widget.settings,
            effectiveFontSize: effectiveFontSize,
            bottomSafeInset: widget.bottomSafeInset,
            topInset: widget.topInset,
            maxOnScreenItems: itemCap,
            resolveRawPositionMs: _interpolatedRawPositionMs,
            resolveCandidates: _resolveCandidates,
            repaint: _frameTick,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}
