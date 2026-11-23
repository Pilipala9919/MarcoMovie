// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../apple_theme.dart';
import '../ios_glass_popover.dart';
import '../ios_liquid_glass.dart';
import 'start_spec_overlay.dart';

/// Metrics aligned with iOS 27 Spatial Cinema Concentric Liquid Glass HUD.
class Ios26PlayerGlassMetrics {
  static const double topCapsuleHeightPt = 40.0;
  static const double topCapsuleRadiusPt = 20.0;
  static const double topActionCirclePt = 36.0;
  static const double leftLockCirclePt = 42.0;
  static const double centerPrimaryButtonSizePt = 76.0;
  static const double centerSecondaryButtonSizePt = 56.0;
  static const double scrubberTrackIdleHeightPt = 5.0;
  static const double scrubberTrackExpandedHeightPt = 12.0;
  static const double dockCapsuleRadiusPt = 24.0;
  static const int maxPrimaryDockActions = 10;

  /// Computes a concentric inner radius inside an outer surface padded by [inset].
  static double concentricRadius(double outerRadius, double inset) {
    return math.max(outerRadius - inset, 8.0);
  }
}

/// Unified iOS / iPadOS 26 Concentric Spatial Cinema Player HUD.
///
/// Architectural guarantees:
/// - **Zero `UiKitView` controls** are mounted over the active 60fps video
///   texture, preventing Impeller platform-view layer slicing and capture holes.
/// - **`glasswork.frag` runs ONLY while this widget is mounted** (HUD visible);
///   unmounting on HUD hide gives zero GPU shader cost.
/// - Top header keeps media spec badges as compact micro-pills beside/under the
///   title, with **Cast / Favorite / Download / More** pinned top-right.
/// - Bottom **progress bar + toolbar are fused into one compact Liquid Glass
///   deck** for low vertical footprint.
/// - **Screen lock button** sits independently centered on the left edge.
/// - Every popover-triggering control reports its screen anchor [Rect] so menus
///   emerge as native Liquid Glass bubbles from the tapped button.
class IosPlayerChrome extends StatefulWidget {
  final String title;
  final String episodeName;
  final String lineName;
  final bool isLive;
  final bool playing;
  final bool loading;
  final bool buffering;
  final bool hasError;
  final Duration position;
  final Duration duration;
  final bool isScrubbing;
  final int scrubPositionMs;
  final double playbackSpeed;
  final int skipIntroSec;
  final int skipOutroSec;
  final List<PlayerSpecBadge> specBadges;
  final String fallbackSpecsLabel;
  final bool specBadgesExpanded;
  final bool isLandscape;
  final bool portraitCompanionBox;
  final bool danmuEnabled;
  final bool sleepTimerActive;
  final bool hasMultipleLines;
  final bool isFavorite;
  final bool isCasting;
  final bool isDownloading;
  final bool storageReduceTransparency;

  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onRewind15;
  final VoidCallback onForward15;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final ValueChanged<double> onScrubEnd;
  final VoidCallback onScrubCancel;
  final VoidCallback onEpisodesTap;
  final VoidCallback onLinesTap;
  final VoidCallback onSpeedTap;
  final VoidCallback onDanmuToggle;
  final VoidCallback onDanmuSettingsTap;
  final VoidCallback onAspectAndStrategyTap;
  final VoidCallback onAudioSubtitleTap;
  final VoidCallback onMoreTap;
  final VoidCallback onLockTap;
  final VoidCallback onFullscreenToggle;
  final VoidCallback onInteraction;

  // Anchored popover callbacks (pass screen Rect of tapped button).
  final ValueChanged<Rect?>? onCastTap;
  final ValueChanged<Rect?>? onFavoriteTap;
  final ValueChanged<Rect?>? onDownloadTap;
  final ValueChanged<Rect?>? onMoreAnchoredTap;
  final ValueChanged<Rect?>? onSpeedAnchoredTap;
  final ValueChanged<Rect?>? onEpisodesAnchoredTap;
  final ValueChanged<Rect?>? onLinesAnchoredTap;
  final ValueChanged<Rect?>? onDanmuSettingsAnchoredTap;
  final ValueChanged<Rect?>? onAspectAnchoredTap;
  final ValueChanged<Rect?>? onAudioSubtitleAnchoredTap;

  // Optional iOS 27 Wave 2 dual-engine, PiP & vocal loudness hooks.
  final bool isPipSupported;
  final bool isPipActive;
  final VoidCallback? onPipTap;
  final ValueChanged<Rect?>? onPipAnchoredTap;
  final String engineLabel;
  final bool isAvPlayerActive;
  final VoidCallback? onEngineSwitchTap;
  final ValueChanged<Rect?>? onEngineSwitchAnchoredTap;
  final String vocalLoudnessLabel;
  final bool vocalLoudnessActive;
  final VoidCallback? onVocalLoudnessTap;
  final ValueChanged<Rect?>? onVocalLoudnessAnchoredTap;

  const IosPlayerChrome({
    super.key,
    required this.title,
    required this.episodeName,
    required this.lineName,
    required this.isLive,
    required this.playing,
    required this.loading,
    required this.buffering,
    required this.hasError,
    required this.position,
    required this.duration,
    required this.isScrubbing,
    required this.scrubPositionMs,
    required this.playbackSpeed,
    required this.skipIntroSec,
    required this.skipOutroSec,
    required this.specBadges,
    required this.fallbackSpecsLabel,
    required this.specBadgesExpanded,
    required this.isLandscape,
    this.portraitCompanionBox = false,
    required this.danmuEnabled,
    required this.sleepTimerActive,
    required this.hasMultipleLines,
    this.isFavorite = false,
    this.isCasting = false,
    this.isDownloading = false,
    required this.storageReduceTransparency,
    required this.onBack,
    required this.onPlayPause,
    required this.onRewind15,
    required this.onForward15,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onScrubCancel,
    required this.onEpisodesTap,
    required this.onLinesTap,
    required this.onSpeedTap,
    required this.onDanmuToggle,
    required this.onDanmuSettingsTap,
    required this.onAspectAndStrategyTap,
    required this.onAudioSubtitleTap,
    required this.onMoreTap,
    required this.onLockTap,
    required this.onFullscreenToggle,
    required this.onInteraction,
    this.onCastTap,
    this.onFavoriteTap,
    this.onDownloadTap,
    this.onMoreAnchoredTap,
    this.onSpeedAnchoredTap,
    this.onEpisodesAnchoredTap,
    this.onLinesAnchoredTap,
    this.onDanmuSettingsAnchoredTap,
    this.onAspectAnchoredTap,
    this.onAudioSubtitleAnchoredTap,
    this.isPipSupported = false,
    this.isPipActive = false,
    this.onPipTap,
    this.onPipAnchoredTap,
    this.engineLabel = 'MPV',
    this.isAvPlayerActive = false,
    this.onEngineSwitchTap,
    this.onEngineSwitchAnchoredTap,
    this.vocalLoudnessLabel = '关闭',
    this.vocalLoudnessActive = false,
    this.onVocalLoudnessTap,
    this.onVocalLoudnessAnchoredTap,
  });

  static String formatTimestamp(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String formatSpeedBadge(double speed) {
    final s = speed.toStringAsFixed(2);
    if (s.endsWith('00')) return '${speed.toStringAsFixed(1)}×';
    if (s.endsWith('0')) return '${speed.toStringAsFixed(1)}×';
    return '$s×';
  }

  @override
  State<IosPlayerChrome> createState() => _IosPlayerChromeState();
}

class _IosPlayerChromeState extends State<IosPlayerChrome> {
  final GlobalKey _castAnchorKey = GlobalKey();
  final GlobalKey _pipAnchorKey = GlobalKey();
  final GlobalKey _favoriteAnchorKey = GlobalKey();
  final GlobalKey _downloadAnchorKey = GlobalKey();
  final GlobalKey _moreAnchorKey = GlobalKey();
  final GlobalKey _episodesAnchorKey = GlobalKey();
  final GlobalKey _linesAnchorKey = GlobalKey();
  final GlobalKey _speedAnchorKey = GlobalKey();
  final GlobalKey _danmuAnchorKey = GlobalKey();
  final GlobalKey _aspectAnchorKey = GlobalKey();
  final GlobalKey _tracksAnchorKey = GlobalKey();
  final GlobalKey _engineAnchorKey = GlobalKey();
  final GlobalKey _loudnessAnchorKey = GlobalKey();

  void _triggerAnchored(
    GlobalKey anchorKey,
    ValueChanged<Rect?>? anchored,
    VoidCallback? fallback,
  ) {
    widget.onInteraction();
    if (anchored != null) {
      anchored(rectForGlobalKey(anchorKey));
    } else {
      fallback?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceTransparency = widget.storageReduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final ios26Visual = IosLiquidGlassBridge.isAvailable && !reduceTransparency;

    if (widget.portraitCompanionBox) {
      return _buildPortraitCompanionBoxChrome(
        context,
        ios26Visual: ios26Visual,
        reduceTransparency: reduceTransparency,
        reduceMotion: reduceMotion,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isCompactWidth = width < 440;
        final isUltraCompact = width < 340;
        final horizInset =
            widget.isLandscape ? 18.0 : (isUltraCompact ? 10.0 : 14.0);
        final topInset = widget.isLandscape ? 10.0 : 10.0;
        final safeBottom = MediaQuery.paddingOf(context).bottom;
        final bottomInset = widget.isLandscape
            ? math.max(5.0, safeBottom * 0.28)
            : math.max(10.0, safeBottom * 0.55);

        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Subtle cinema gradient scrims for guaranteed typography legibility.
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 98,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x94000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 126,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xA8000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),

              SafeArea(
                bottom: false,
                child: Stack(
                  key: const Key('ios-player-chrome-root'),
                  fit: StackFit.expand,
                  children: [
                    // 1. Top Spatial Floating Header
                    //    Left: 40pt back capsule
                    //    Center: title + compact micro spec badges (never stretched!)
                    //    Right: Cast / Favorite / Download / More
                    Positioned(
                      left: horizInset,
                      right: horizInset,
                      top: topInset,
                      child: _buildTopSpatialHeader(
                        context,
                        width: width,
                        isCompactWidth: isCompactWidth,
                        isUltraCompact: isUltraCompact,
                        ios26Visual: ios26Visual,
                        reduceTransparency: reduceTransparency,
                        reduceMotion: reduceMotion,
                      ),
                    ),

                    // 2. Standalone Left-Edge Screen Lock Button (Req 3)
                    Positioned(
                      left: horizInset,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _buildLeftLockButton(
                          ios26Visual: ios26Visual,
                          reduceTransparency: reduceTransparency,
                          reduceMotion: reduceMotion,
                        ),
                      ),
                    ),

                    // 3. Center Refractive Transport (56pt / 76pt / 56pt)
                    if (!widget.loading && !widget.buffering && !widget.hasError)
                      Center(
                        child: _buildCenterTransport(
                          ios26Visual: ios26Visual,
                          reduceTransparency: reduceTransparency,
                          reduceMotion: reduceMotion,
                          isUltraCompact: isUltraCompact,
                        ),
                      ),

                    // 4. Unified Compact Bottom Liquid Glass Deck (Req 2)
                    //    Progress bar + primary toolbar fused into ONE low-height capsule.
                    Positioned(
                      left: horizInset,
                      right: horizInset,
                      bottom: bottomInset,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: widget.isLandscape ? 736.0 : 560.0,
                          ),
                          child: _buildUnifiedBottomDeck(
                            width: width,
                            ios26Visual: ios26Visual,
                            reduceTransparency: reduceTransparency,
                            reduceMotion: reduceMotion,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Slim Tencent-Video-style HUD inside the top 16:9 video frame when the iOS
  /// player is in Portrait Companion Mode (Req 8).
  Widget _buildPortraitCompanionBoxChrome(
    BuildContext context, {
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    return Stack(
      key: const Key('ios-player-chrome-root'),
      fit: StackFit.expand,
      children: [
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 62,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x9E000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 68,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xB3000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        // Top row: compact back + title + Cast / Favorite / Download / More
        Positioned(
          left: 10,
          right: 10,
          top: 8,
          child: Listener(
            key: const Key('ios-player-top-header-hit-area'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => widget.onInteraction(),
            child: Row(
              children: [
                _IosRefractivePressButton(
                  key: const Key('ios-player-back-button'),
                  reduceMotion: reduceMotion,
                  onTap: () {
                    widget.onInteraction();
                    widget.onBack();
                  },
                  child: _IosSpatialGlassSurface(
                    width: 34,
                    height: 34,
                    borderRadius: 17,
                    ios26Visual: ios26Visual,
                    reduceTransparency: reduceTransparency,
                    child: const Center(
                      child: Icon(
                        CupertinoIcons.chevron_back,
                        color: Colors.white,
                        size: 17,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _buildTopRightActionGroup(
                  buttonSize: 32,
                  iconSize: 15.5,
                  gap: 6,
                  isUltraCompact: false,
                  includeMore: true,
                  ios26Visual: ios26Visual,
                  reduceTransparency: reduceTransparency,
                  reduceMotion: reduceMotion,
                ),
              ],
            ),
          ),
        ),
        // Left-edge compact lock button (consistent with landscape standalone lock)
        Positioned(
          left: 10,
          top: 0,
          bottom: 0,
          child: Center(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => widget.onInteraction(),
              child: Semantics(
                button: true,
                label: '锁定屏幕',
                child: _IosRefractivePressButton(
                  key: const Key('player-lock-button'),
                  reduceMotion: reduceMotion,
                  onTap: () {
                    widget.onInteraction();
                    widget.onLockTap();
                  },
                  child: _IosSpatialGlassSurface(
                    width: 34,
                    height: 34,
                    borderRadius: 17,
                    ios26Visual: ios26Visual,
                    reduceTransparency: reduceTransparency,
                    child: const Center(
                      child: Icon(
                        CupertinoIcons.lock_open_fill,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Center play/pause button
        if (!widget.loading && !widget.buffering && !widget.hasError)
          Center(
            child: _IosRefractivePressButton(
              key: const Key('player-center-play-pause'),
              reduceMotion: reduceMotion,
              onTap: () {
                widget.onInteraction();
                widget.onPlayPause();
              },
              child: _IosSpatialGlassSurface(
                width: 54,
                height: 54,
                borderRadius: 27,
                ios26Visual: ios26Visual,
                reduceTransparency: reduceTransparency,
                heroHighlight: true,
                child: Center(
                  child: Icon(
                    widget.playing
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    color: Colors.white,
                    size: 25,
                  ),
                ),
              ),
            ),
          ),
        // Bottom compact bar: scrubber + fullscreen toggle
        Positioned(
          left: 10,
          right: 10,
          bottom: 8,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => widget.onInteraction(),
            child: _IosSpatialGlassSurface(
              key: const Key('player-tool-dock-portrait'),
              borderRadius: 16,
              ios26Visual: ios26Visual,
              reduceTransparency: reduceTransparency,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                children: [
                  if (!widget.isLive)
                    Expanded(
                      child: IosFluidScrubberCapsule(
                        key: const Key('player-progress-bar'),
                        position: widget.position,
                        duration: widget.duration,
                        isScrubbing: widget.isScrubbing,
                        scrubPositionMs: widget.scrubPositionMs,
                        skipIntroSec: widget.skipIntroSec,
                        skipOutroSec: widget.skipOutroSec,
                        ios26Visual: ios26Visual,
                        reduceTransparency: reduceTransparency,
                        reduceMotion: reduceMotion,
                        embedded: true,
                        onInteraction: widget.onInteraction,
                        onScrubStart: widget.onScrubStart,
                        onScrubUpdate: widget.onScrubUpdate,
                        onScrubEnd: widget.onScrubEnd,
                        onScrubCancel: widget.onScrubCancel,
                      ),
                    )
                  else
                    const Expanded(
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.dot_radiowaves_left_right,
                            color: AppleColors.systemRed,
                            size: 14,
                          ),
                          SizedBox(width: 5),
                          Text(
                            '正在直播',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(width: 6),
                  _IosRefractivePressButton(
                    key: const Key('player-fullscreen-toggle'),
                    reduceMotion: reduceMotion,
                    onTap: () {
                      widget.onInteraction();
                      widget.onFullscreenToggle();
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        CupertinoIcons.fullscreen,
                        color: Colors.white,
                        size: 17,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLeftLockButton({
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => widget.onInteraction(),
      child: Semantics(
        button: true,
        label: '锁定屏幕',
        child: _IosRefractivePressButton(
          key: const Key('player-lock-button'),
          reduceMotion: reduceMotion,
          onTap: () {
            widget.onInteraction();
            widget.onLockTap();
          },
          child: _IosSpatialGlassSurface(
            width: Ios26PlayerGlassMetrics.leftLockCirclePt,
            height: Ios26PlayerGlassMetrics.leftLockCirclePt,
            borderRadius: Ios26PlayerGlassMetrics.leftLockCirclePt * 0.5,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            child: const Center(
              child: Icon(
                CupertinoIcons.lock_open_fill,
                color: AppleColors.labelPrimary,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopSpatialHeader(
    BuildContext context, {
    required double width,
    required bool isCompactWidth,
    required bool isUltraCompact,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    final compactBadges = _buildMicroSpecBadges(
      reduceTransparency: reduceTransparency,
    );
    final placeBadgesNextToTitle = !isCompactWidth && compactBadges != null;
    final buttonSize = isCompactWidth ? 34.0 : Ios26PlayerGlassMetrics.topActionCirclePt;

    return Listener(
      key: const Key('ios-player-top-header-hit-area'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => widget.onInteraction(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: 40pt concentric rounded glass back capsule (radius = 20pt).
          _IosRefractivePressButton(
            key: const Key('ios-player-back-button'),
            reduceMotion: reduceMotion,
            onTap: () {
              widget.onInteraction();
              widget.onBack();
            },
            child: _IosSpatialGlassSurface(
              height: Ios26PlayerGlassMetrics.topCapsuleHeightPt,
              width: isCompactWidth
                  ? Ios26PlayerGlassMetrics.topCapsuleHeightPt
                  : null,
              borderRadius: Ios26PlayerGlassMetrics.topCapsuleRadiusPt,
              ios26Visual: ios26Visual,
              reduceTransparency: reduceTransparency,
              padding: isCompactWidth
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    CupertinoIcons.chevron_back,
                    color: AppleColors.labelPrimary,
                    size: 18,
                  ),
                  if (!isCompactWidth) ...[
                    const SizedBox(width: 4),
                    const Text(
                      '返回',
                      maxLines: 1,
                      style: TextStyle(
                        color: AppleColors.labelPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Center: crisp title + compact micro spec badges right beside/below title
          // (strictly shrink-wrapped, NEVER stretches horizontally or overlaps back button).
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppleColors.labelPrimary,
                          fontSize: isCompactWidth ? 14.5 : 15.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.25,
                          height: 1.15,
                        ),
                      ),
                    ),
                    if (widget.isLive) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppleColors.systemRed.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          '直播',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                    if (placeBadgesNextToTitle) ...[
                      const SizedBox(width: 7),
                      compactBadges,
                    ],
                  ],
                ),
                const SizedBox(height: 2.5),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${widget.episodeName} · ${widget.lineName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppleColors.labelSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!placeBadgesNextToTitle && compactBadges != null) ...[
                      const SizedBox(width: 6),
                      compactBadges,
                    ],
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),

          // Right: Cast / Favorite / Download / More circular glass buttons (Req 5).
          _buildTopRightActionGroup(
            buttonSize: buttonSize,
            iconSize: isCompactWidth ? 16.0 : 17.0,
            gap: isUltraCompact ? 4.0 : 6.0,
            isUltraCompact: isUltraCompact,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion,
          ),
        ],
      ),
    );
  }

  Widget? _buildMicroSpecBadges({required bool reduceTransparency}) {
    if (widget.specBadges.isNotEmpty) {
      return InlineSpecBadgeRow(
        badges: widget.specBadges,
        expanded: widget.specBadgesExpanded,
        concentric: true,
        reduceTransparency: reduceTransparency,
      );
    }
    if (widget.fallbackSpecsLabel.isNotEmpty) {
      return Container(
        key: const Key('player-video-specs'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: reduceTransparency
              ? const Color(0xEB25252B)
              : const Color(0x3DFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: Colors.white.withValues(
              alpha: reduceTransparency ? 0.45 : 0.22,
            ),
            width: 0.7,
          ),
        ),
        child: Text(
          widget.fallbackSpecsLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppleColors.labelPrimary,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    return null;
  }

  Widget _buildTopRightActionGroup({
    required double buttonSize,
    required double iconSize,
    required double gap,
    required bool isUltraCompact,
    bool includeMore = false,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    final children = <Widget>[
      // 1. 画中画 (Picture-in-Picture) when supported/wired
      if (widget.onPipTap != null || widget.onPipAnchoredTap != null)
        _buildTopCircleButton(
          key: const Key('ios-player-pip-button'),
          anchorKey: _pipAnchorKey,
          size: buttonSize,
          iconSize: iconSize,
          icon: widget.isPipActive
              ? CupertinoIcons.rectangle_fill_on_rectangle_fill
              : CupertinoIcons.rectangle_on_rectangle,
          active: widget.isPipActive,
          activeTint: AppleColors.systemBlue,
          semanticLabel: '画中画',
          ios26Visual: ios26Visual,
          reduceTransparency: reduceTransparency,
          reduceMotion: reduceMotion,
          onTap: () => _triggerAnchored(
            _pipAnchorKey,
            widget.onPipAnchoredTap,
            widget.onPipTap,
          ),
        ),
      // 2. 投屏 (Cast)
      _buildTopCircleButton(
        key: const Key('ios-player-cast-button'),
        anchorKey: _castAnchorKey,
        size: buttonSize,
        iconSize: iconSize,
        icon: widget.isCasting ? CupertinoIcons.tv_fill : CupertinoIcons.tv,
        active: widget.isCasting,
        activeTint: AppleColors.systemBlue,
        semanticLabel: '投屏',
        ios26Visual: ios26Visual,
        reduceTransparency: reduceTransparency,
        reduceMotion: reduceMotion,
        onTap: () => _triggerAnchored(_castAnchorKey, widget.onCastTap, null),
      ),
      if (!isUltraCompact)
        _buildTopCircleButton(
          key: const Key('ios-player-favorite-button'),
          anchorKey: _favoriteAnchorKey,
          size: buttonSize,
          iconSize: iconSize,
          icon: widget.isFavorite
              ? CupertinoIcons.heart_fill
              : CupertinoIcons.heart,
          active: widget.isFavorite,
          activeTint: AppleColors.systemPink,
          semanticLabel: widget.isFavorite ? '取消收藏' : '收藏',
          ios26Visual: ios26Visual,
          reduceTransparency: reduceTransparency,
          reduceMotion: reduceMotion,
          onTap: () => _triggerAnchored(
            _favoriteAnchorKey,
            widget.onFavoriteTap,
            null,
          ),
        ),
      if (!widget.isLive && !isUltraCompact)
        _buildTopCircleButton(
          key: const Key('ios-player-download-button'),
          anchorKey: _downloadAnchorKey,
          size: buttonSize,
          iconSize: iconSize,
          icon: widget.isDownloading
              ? CupertinoIcons.arrow_down_circle_fill
              : CupertinoIcons.arrow_down_circle,
          active: widget.isDownloading,
          activeTint: AppleColors.systemGreen,
          semanticLabel: '下载',
          ios26Visual: ios26Visual,
          reduceTransparency: reduceTransparency,
          reduceMotion: reduceMotion,
          onTap: () => _triggerAnchored(
            _downloadAnchorKey,
            widget.onDownloadTap,
            null,
          ),
        ),
      if (includeMore)
        _buildTopCircleButton(
          key: const Key('ios-player-more-button'),
          anchorKey: _moreAnchorKey,
          size: buttonSize,
          iconSize: iconSize,
          icon: CupertinoIcons.ellipsis,
          active: widget.sleepTimerActive,
          activeTint: AppleColors.systemBlue,
          showDot: widget.sleepTimerActive,
          semanticLabel: '更多与定时关闭',
          ios26Visual: ios26Visual,
          reduceTransparency: reduceTransparency,
          reduceMotion: reduceMotion,
          onTap: () => _triggerAnchored(
            _moreAnchorKey,
            widget.onMoreAnchoredTap,
            widget.onMoreTap,
          ),
        ),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          children[i],
        ],
      ],
    );
  }

  Widget _buildTopCircleButton({
    required Key key,
    required GlobalKey anchorKey,
    required double size,
    required double iconSize,
    required IconData icon,
    required bool active,
    required Color activeTint,
    required String semanticLabel,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
    required VoidCallback onTap,
    bool showDot = false,
  }) {
    return KeyedSubtree(
      key: anchorKey,
      child: Semantics(
        button: true,
        label: semanticLabel,
        child: _IosRefractivePressButton(
          key: key,
          reduceMotion: reduceMotion,
          onTap: onTap,
          child: _IosSpatialGlassSurface(
            width: size,
            height: size,
            borderRadius: size * 0.5,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            tint: active ? activeTint : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  icon,
                  color: active ? Colors.white : AppleColors.labelPrimary,
                  size: iconSize,
                ),
                if (showDot)
                  Positioned(
                    right: 7,
                    top: 7,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppleColors.systemOrange,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterTransport({
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
    required bool isUltraCompact,
  }) {
    final playButton = _IosRefractivePressButton(
      key: const Key('player-center-play-pause'),
      reduceMotion: reduceMotion,
      onTap: () {
        widget.onInteraction();
        widget.onPlayPause();
      },
      child: _IosSpatialGlassSurface(
        width: Ios26PlayerGlassMetrics.centerPrimaryButtonSizePt,
        height: Ios26PlayerGlassMetrics.centerPrimaryButtonSizePt,
        borderRadius: Ios26PlayerGlassMetrics.centerPrimaryButtonSizePt * 0.5,
        ios26Visual: ios26Visual,
        reduceTransparency: reduceTransparency,
        heroHighlight: true,
        child: Center(
          child: Icon(
            widget.playing
                ? CupertinoIcons.pause_fill
                : CupertinoIcons.play_fill,
            color: Colors.white,
            size: 34,
          ),
        ),
      ),
    );

    if (widget.isLive) return playButton;

    final gap = isUltraCompact ? 20.0 : 32.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IosRefractivePressButton(
          key: const Key('player-center-rewind'),
          reduceMotion: reduceMotion,
          onTap: () {
            widget.onInteraction();
            widget.onRewind15();
          },
          child: _IosSpatialGlassSurface(
            width: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            height: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            borderRadius:
                Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt * 0.5,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            child: const Center(
              child: Icon(
                CupertinoIcons.gobackward_15,
                color: AppleColors.labelPrimary,
                size: 25,
              ),
            ),
          ),
        ),
        SizedBox(width: gap),
        playButton,
        SizedBox(width: gap),
        _IosRefractivePressButton(
          key: const Key('player-center-forward'),
          reduceMotion: reduceMotion,
          onTap: () {
            widget.onInteraction();
            widget.onForward15();
          },
          child: _IosSpatialGlassSurface(
            width: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            height: Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt,
            borderRadius:
                Ios26PlayerGlassMetrics.centerSecondaryButtonSizePt * 0.5,
            ios26Visual: ios26Visual,
            reduceTransparency: reduceTransparency,
            child: const Center(
              child: Icon(
                CupertinoIcons.goforward_15,
                color: AppleColors.labelPrimary,
                size: 25,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Req 2: Single fused compact Liquid Glass deck combining the fluid
  /// scrubber bar and compact horizontal toolbar (~72pt total height).
  Widget _buildUnifiedBottomDeck({
    required double width,
    required bool ios26Visual,
    required bool reduceTransparency,
    required bool reduceMotion,
  }) {
    final actions = <_IosDockAction>[
      _IosDockAction(
        id: 'episodes',
        anchorKey: _episodesAnchorKey,
        icon: CupertinoIcons.square_grid_2x2_fill,
        label: widget.isLive ? '信号' : '选集',
        onTap: () => _triggerAnchored(
          _episodesAnchorKey,
          widget.onEpisodesAnchoredTap,
          widget.onEpisodesTap,
        ),
      ),
      if (widget.hasMultipleLines || !widget.isLive)
        _IosDockAction(
          id: 'lines',
          anchorKey: _linesAnchorKey,
          icon: widget.isLive
              ? CupertinoIcons.tv_fill
              : CupertinoIcons.layers_alt_fill,
          label: widget.isLive ? '频道' : '线路',
          onTap: () => _triggerAnchored(
            _linesAnchorKey,
            widget.onLinesAnchoredTap,
            widget.onLinesTap,
          ),
        ),
      if (!widget.isLive)
        _IosDockAction(
          id: 'speed',
          anchorKey: _speedAnchorKey,
          icon: CupertinoIcons.speedometer,
          label: IosPlayerChrome.formatSpeedBadge(widget.playbackSpeed),
          active: (widget.playbackSpeed - 1.0).abs() > 0.01,
          onTap: () => _triggerAnchored(
            _speedAnchorKey,
            widget.onSpeedAnchoredTap,
            widget.onSpeedTap,
          ),
        ),
      _IosDockAction(
        id: 'danmu',
        anchorKey: _danmuAnchorKey,
        icon: CupertinoIcons.chat_bubble_text_fill,
        label: '弹幕',
        active: widget.danmuEnabled,
        onTap: () => _triggerAnchored(
          _danmuAnchorKey,
          widget.onDanmuSettingsAnchoredTap,
          widget.onDanmuSettingsTap,
        ),
      ),
      _IosDockAction(
        id: 'aspect',
        anchorKey: _aspectAnchorKey,
        icon: CupertinoIcons.slider_horizontal_3,
        label: '画面',
        onTap: () => _triggerAnchored(
          _aspectAnchorKey,
          widget.onAspectAnchoredTap,
          widget.onAspectAndStrategyTap,
        ),
      ),
      _IosDockAction(
        key: const Key('ios-player-tracks-button'),
        id: 'tracks',
        anchorKey: _tracksAnchorKey,
        icon: CupertinoIcons.captions_bubble_fill,
        label: '音轨',
        onTap: () => _triggerAnchored(
          _tracksAnchorKey,
          widget.onAudioSubtitleAnchoredTap,
          widget.onAudioSubtitleTap,
        ),
      ),
      if (widget.onVocalLoudnessTap != null ||
          widget.onVocalLoudnessAnchoredTap != null)
        _IosDockAction(
          key: const Key('ios-player-loudness-button'),
          id: 'loudness',
          anchorKey: _loudnessAnchorKey,
          icon: CupertinoIcons.waveform_path_ecg,
          label: widget.vocalLoudnessLabel == '关闭'
              ? '响度'
              : widget.vocalLoudnessLabel,
          active: widget.vocalLoudnessActive,
          onTap: () => _triggerAnchored(
            _loudnessAnchorKey,
            widget.onVocalLoudnessAnchoredTap,
            widget.onVocalLoudnessTap,
          ),
        ),
      if (widget.onEngineSwitchTap != null ||
          widget.onEngineSwitchAnchoredTap != null)
        _IosDockAction(
          key: const Key('ios-player-engine-button'),
          id: 'engine',
          anchorKey: _engineAnchorKey,
          icon: widget.isAvPlayerActive
              ? CupertinoIcons.play_rectangle_fill
              : CupertinoIcons.gear_alt_fill,
          label: widget.engineLabel,
          active: widget.isAvPlayerActive,
          onTap: () => _triggerAnchored(
            _engineAnchorKey,
            widget.onEngineSwitchAnchoredTap,
            widget.onEngineSwitchTap,
          ),
        ),
      _IosDockAction(
        key: const Key('player-fullscreen-toggle'),
        id: 'fullscreen',
        icon: widget.isLandscape
            ? CupertinoIcons.fullscreen_exit
            : CupertinoIcons.fullscreen,
        label: widget.isLandscape ? '竖屏' : '全屏',
        onTap: () {
          widget.onInteraction();
          widget.onFullscreenToggle();
        },
      ),
      _IosDockAction(
        key: const Key('ios-player-more-button'),
        id: 'more',
        anchorKey: _moreAnchorKey,
        icon: CupertinoIcons.ellipsis,
        label: '更多',
        active: widget.sleepTimerActive,
        onTap: () => _triggerAnchored(
          _moreAnchorKey,
          widget.onMoreAnchoredTap,
          widget.onMoreTap,
        ),
      ),
    ];

    final bounded = actions
        .take(Ios26PlayerGlassMetrics.maxPrimaryDockActions)
        .toList(growable: false);
    final dockKey = widget.isLandscape
        ? const Key('ios-player-primary-dock')
        : const Key('player-tool-dock-portrait');
    final useScrollable = width < 480 || (width < 600 && bounded.length > 8);
    final innerPillRadius = Ios26PlayerGlassMetrics.concentricRadius(
      Ios26PlayerGlassMetrics.dockCapsuleRadiusPt,
      5.0,
    );

    final rowChildren = <Widget>[
      for (var i = 0; i < bounded.length; i++)
        useScrollable
            ? Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
                child: _buildCompactDockPill(
                  bounded[i],
                  reduceMotion: reduceMotion,
                  pillRadius: innerPillRadius,
                ),
              )
            : Expanded(
                child: _buildCompactDockPill(
                  bounded[i],
                  reduceMotion: reduceMotion,
                  pillRadius: innerPillRadius,
                ),
              ),
    ];

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => widget.onInteraction(),
      child: _IosSpatialGlassSurface(
        key: dockKey,
        borderRadius: Ios26PlayerGlassMetrics.dockCapsuleRadiusPt,
        ios26Visual: ios26Visual,
        reduceTransparency: reduceTransparency,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.isLive) ...[
              IosFluidScrubberCapsule(
                key: const Key('player-progress-bar'),
                position: widget.position,
                duration: widget.duration,
                isScrubbing: widget.isScrubbing,
                scrubPositionMs: widget.scrubPositionMs,
                skipIntroSec: widget.skipIntroSec,
                skipOutroSec: widget.skipOutroSec,
                ios26Visual: ios26Visual,
                reduceTransparency: reduceTransparency,
                reduceMotion: reduceMotion,
                embedded: true,
                onInteraction: widget.onInteraction,
                onScrubStart: widget.onScrubStart,
                onScrubUpdate: widget.onScrubUpdate,
                onScrubEnd: widget.onScrubEnd,
                onScrubCancel: widget.onScrubCancel,
              ),
              Container(
                height: 0.5,
                margin: const EdgeInsets.symmetric(vertical: 3),
                color: Colors.white.withValues(alpha: 0.12),
              ),
            ],
            SizedBox(
              key: const Key('ios-player-dock-actions-row'),
              height: 31,
              child: useScrollable
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: rowChildren,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: rowChildren,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Inline icon + label horizontal pill keeps the merged bottom deck ultra-low
  /// and crisp instead of tall stacked icon-over-text rows.
  Widget _buildCompactDockPill(
    _IosDockAction action, {
    required bool reduceMotion,
    double pillRadius = 14.0,
  }) {
    final fg = action.active ? AppleColors.systemCyan : AppleColors.labelPrimary;
    final button = _IosRefractivePressButton(
      key: action.key ?? ValueKey('ios-dock-action-${action.id}'),
      reduceMotion: reduceMotion,
      onTap: action.onTap,
      child: Container(
        height: 29,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        decoration: ShapeDecoration(
          color: action.active
              ? AppleColors.systemBlue.withValues(alpha: 0.26)
              : Colors.transparent,
          shape: ContinuousRectangleBorder(
            borderRadius: BorderRadius.circular(pillRadius),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, color: fg, size: 14.5),
            const SizedBox(width: 3.5),
            Flexible(
              child: Text(
                action.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: action.active ? fg : AppleColors.labelSecondary,
                  fontSize: 11,
                  fontWeight: action.active ? FontWeight.w700 : FontWeight.w600,
                  letterSpacing: -0.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (action.anchorKey != null) {
      return KeyedSubtree(key: action.anchorKey, child: button);
    }
    return button;
  }
}

class _IosDockAction {
  final Key? key;
  final GlobalKey? anchorKey;
  final String id;
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _IosDockAction({
    this.key,
    this.anchorKey,
    required this.id,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });
}

/// Interactive fluid expanding scrubber capsule for iOS/iPadOS 27:
/// - Resting track height: `5pt` (`scrubberTrackIdleHeightPt`).
/// - Active touch/drag height: springs to `12pt` (`scrubberTrackExpandedHeightPt`)
///   via the iOS 27 snappy physical spring (`duration: 0.28, bounce: 0.12`,
///   instant snap when `reduceMotion` is enabled) with subtle luminous glow,
///   light haptics, tabular numeric timestamps, strict single-pointer
///   `pointerId` tracking, opaque capsule hit absorption, and intro/outro ticks.
/// - Supports `embedded: true` when fused inside the unified bottom glass deck.
class IosFluidScrubberCapsule extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final bool isScrubbing;
  final int scrubPositionMs;
  final int skipIntroSec;
  final int skipOutroSec;
  final bool ios26Visual;
  final bool reduceTransparency;
  final bool reduceMotion;
  final bool embedded;
  final VoidCallback? onInteraction;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final ValueChanged<double> onScrubEnd;
  final VoidCallback onScrubCancel;

  const IosFluidScrubberCapsule({
    super.key,
    required this.position,
    required this.duration,
    required this.isScrubbing,
    required this.scrubPositionMs,
    required this.skipIntroSec,
    required this.skipOutroSec,
    required this.ios26Visual,
    required this.reduceTransparency,
    required this.reduceMotion,
    this.embedded = false,
    this.onInteraction,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onScrubCancel,
  });

  @override
  State<IosFluidScrubberCapsule> createState() =>
      _IosFluidScrubberCapsuleState();
}

class _IosFluidScrubberCapsuleState extends State<IosFluidScrubberCapsule>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _snappyTrackSpring =
      SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: (2 * math.pi / 0.28) * (2 * math.pi / 0.28),
    ratio: 0.88,
  );

  late final AnimationController _expandCtrl = AnimationController.unbounded(
    vsync: this,
    value: widget.isScrubbing ? 1.0 : 0.0,
  );

  int? _activePointerId;
  double _localDragMs = 0;

  bool get _pointerActive => _activePointerId != null;
  bool get _expanded => _pointerActive || widget.isScrubbing;

  void _syncSpringExpansion() {
    final target = _expanded ? 1.0 : 0.0;
    if (widget.reduceMotion) {
      _expandCtrl.stop();
      _expandCtrl.value = target;
      return;
    }
    final sim = SpringSimulation(
      _snappyTrackSpring,
      _expandCtrl.value,
      target,
      _expandCtrl.velocity,
    );
    _expandCtrl.animateWith(sim);
  }

  @override
  void didUpdateWidget(covariant IosFluidScrubberCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isScrubbing && !widget.isScrubbing) {
      _activePointerId = null;
    }
    if (oldWidget.isScrubbing != widget.isScrubbing ||
        oldWidget.reduceMotion != widget.reduceMotion) {
      _syncSpringExpansion();
    }
  }

  @override
  void dispose() {
    final wasDragging = _activePointerId != null;
    _activePointerId = null;
    _expandCtrl.dispose();
    if (wasDragging) {
      widget.onScrubCancel();
    }
    super.dispose();
  }

  double _valueForLocalX(double localX, double trackWidth) {
    final durMs = widget.duration.inMilliseconds;
    if (durMs <= 0 || trackWidth <= 0) return 0;
    final ratio = (localX / trackWidth).clamp(0.0, 1.0);
    return ratio * durMs;
  }

  @override
  Widget build(BuildContext context) {
    final durMs = widget.duration.inMilliseconds;
    final hasDuration = durMs > 0;
    final activeMs = _pointerActive
        ? _localDragMs
        : (widget.isScrubbing
            ? widget.scrubPositionMs.toDouble()
            : widget.position.inMilliseconds.toDouble());
    final clampedMs = hasDuration ? activeMs.clamp(0.0, durMs.toDouble()) : 0.0;
    final fraction = hasDuration ? (clampedMs / durMs).clamp(0.0, 1.0) : 0.0;
    final currentDuration = Duration(milliseconds: clampedMs.round());
    final remainingMs = math.max(0, durMs - clampedMs.round());
    final remainingLabel = hasDuration
        ? '-${IosPlayerChrome.formatTimestamp(Duration(milliseconds: remainingMs))}'
        : '--:--';

    final introFrac = hasDuration && widget.skipIntroSec > 0
        ? ((widget.skipIntroSec * 1000) / durMs).clamp(0.0, 1.0)
        : null;
    final outroFrac = hasDuration &&
            widget.skipOutroSec > 0 &&
            durMs > widget.skipOutroSec * 1000
        ? ((durMs - widget.skipOutroSec * 1000) / durMs).clamp(0.0, 1.0)
        : null;

    final row = Row(
      children: [
        Text(
          IosPlayerChrome.formatTimestamp(currentDuration),
          key: const Key('ios-fluid-scrubber-elapsed'),
          style: const TextStyle(
            color: AppleColors.labelPrimary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackW = math.max(1.0, constraints.maxWidth);
              return Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: hasDuration
                    ? (event) {
                        if (_activePointerId != null) return;
                        final nextMs =
                            _valueForLocalX(event.localPosition.dx, trackW);
                        HapticFeedback.lightImpact();
                        setState(() {
                          _activePointerId = event.pointer;
                          _localDragMs = nextMs;
                        });
                        _syncSpringExpansion();
                        widget.onScrubStart(nextMs);
                      }
                    : null,
                onPointerMove: hasDuration
                    ? (event) {
                        if (event.pointer != _activePointerId) return;
                        final nextMs =
                            _valueForLocalX(event.localPosition.dx, trackW);
                        setState(() => _localDragMs = nextMs);
                        widget.onScrubUpdate(nextMs);
                      }
                    : null,
                onPointerUp: hasDuration
                    ? (event) {
                        if (event.pointer != _activePointerId) return;
                        final nextMs =
                            _valueForLocalX(event.localPosition.dx, trackW);
                        setState(() => _activePointerId = null);
                        _syncSpringExpansion();
                        widget.onScrubEnd(nextMs);
                      }
                    : null,
                onPointerCancel: hasDuration
                    ? (event) {
                        if (event.pointer != _activePointerId) return;
                        setState(() => _activePointerId = null);
                        _syncSpringExpansion();
                        widget.onScrubCancel();
                      }
                    : null,
                child: GestureDetector(
                  key: const Key('ios-fluid-scrubber-hit-area'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: hasDuration ? (_) {} : null,
                  onHorizontalDragUpdate: hasDuration ? (_) {} : null,
                  onHorizontalDragEnd: hasDuration ? (_) {} : null,
                  child: SizedBox(
                    height: widget.embedded ? 24 : 28,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _expandCtrl,
                        builder: (context, _) {
                          final t = _expandCtrl.value;
                          final trackHeight =
                              (Ios26PlayerGlassMetrics.scrubberTrackIdleHeightPt +
                                      (Ios26PlayerGlassMetrics
                                                  .scrubberTrackExpandedHeightPt -
                                              Ios26PlayerGlassMetrics
                                                  .scrubberTrackIdleHeightPt) *
                                          t)
                                  .clamp(3.0, 16.0);
                          final glowActive =
                              t > 0.15 && !widget.reduceTransparency;
                          return Container(
                            key: const Key('ios-fluid-scrubber-track'),
                            height: trackHeight,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: widget.reduceTransparency
                                  ? const Color(0x66FFFFFF)
                                  : const Color(0x3DFFFFFF),
                              borderRadius:
                                  BorderRadius.circular(trackHeight * 0.5),
                              boxShadow: glowActive
                                  ? [
                                      BoxShadow(
                                        color: Colors.white.withValues(
                                          alpha: (0.22 * t).clamp(0.0, 0.28),
                                        ),
                                        blurRadius: 10,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(trackHeight * 0.5),
                              child: CustomPaint(
                                painter: _FluidTrackPainter(
                                  fraction: fraction,
                                  expanded: _expanded,
                                  introMarker: introFrac,
                                  outroMarker: outroFrac,
                                  reduceTransparency: widget.reduceTransparency,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        Text(
          remainingLabel,
          key: const Key('ios-fluid-scrubber-remaining'),
          style: const TextStyle(
            color: AppleColors.labelSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {
          if (!_pointerActive) {
            widget.onInteraction?.call();
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: row,
        ),
      );
    }

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (!_pointerActive) {
          widget.onInteraction?.call();
        }
      },
      child: _IosSpatialGlassSurface(
        borderRadius: Ios26PlayerGlassMetrics.dockCapsuleRadiusPt,
        ios26Visual: widget.ios26Visual,
        reduceTransparency: widget.reduceTransparency,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        child: row,
      ),
    );
  }
}

class _FluidTrackPainter extends CustomPainter {
  final double fraction;
  final bool expanded;
  final double? introMarker;
  final double? outroMarker;
  final bool reduceTransparency;

  const _FluidTrackPainter({
    required this.fraction,
    required this.expanded,
    required this.introMarker,
    required this.outroMarker,
    required this.reduceTransparency,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fillW = (size.width * fraction).clamp(0.0, size.width);
    if (fillW > 0) {
      final fillRect = Rect.fromLTWH(0, 0, fillW, size.height);
      final paint = Paint();
      if (expanded && !reduceTransparency) {
        paint.shader = const LinearGradient(
          colors: [Color(0xFFEBF5FF), Color(0xFFFFFFFF)],
        ).createShader(fillRect);
      } else {
        paint.color = Colors.white.withValues(alpha: expanded ? 1.0 : 0.92);
      }
      canvas.drawRect(fillRect, paint);
    }

    final markerPaint = Paint()..color = const Color(0xE6FFD60A);
    if (introMarker != null && introMarker! > 0.01 && introMarker! < 0.99) {
      final x = size.width * introMarker!;
      canvas.drawRect(Rect.fromLTWH(x - 1.0, 0, 2.0, size.height), markerPaint);
    }
    if (outroMarker != null && outroMarker! > 0.01 && outroMarker! < 0.99) {
      final x = size.width * outroMarker!;
      canvas.drawRect(Rect.fromLTWH(x - 1.0, 0, 2.0, size.height), markerPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FluidTrackPainter old) =>
      old.fraction != fraction ||
      old.expanded != expanded ||
      old.introMarker != introMarker ||
      old.outroMarker != outroMarker ||
      old.reduceTransparency != reduceTransparency;
}

class _IosRefractivePressButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final bool reduceMotion;

  const _IosRefractivePressButton({
    super.key,
    required this.child,
    required this.onTap,
    required this.reduceMotion,
  });

  @override
  State<_IosRefractivePressButton> createState() =>
      _IosRefractivePressButtonState();
}

class _IosRefractivePressButtonState extends State<_IosRefractivePressButton>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _snappyPressSpring =
      SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: (2 * math.pi / 0.28) * (2 * math.pi / 0.28),
    ratio: 0.88,
  );

  late final AnimationController _pressCtrl = AnimationController.unbounded(
    vsync: this,
    value: 0.0,
  );

  void _driveTo(double target) {
    if (widget.reduceMotion) {
      _pressCtrl.stop();
      _pressCtrl.value = target;
      return;
    }
    final sim = SpringSimulation(
      _snappyPressSpring,
      _pressCtrl.value,
      target,
      _pressCtrl.velocity,
    );
    _pressCtrl.animateWith(sim);
  }

  @override
  void didUpdateWidget(covariant _IosRefractivePressButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion && !oldWidget.reduceMotion) {
      _pressCtrl.stop();
      _pressCtrl.value = 0.0;
    }
  }

  @override
  void dispose() {
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _driveTo(1.0),
      onTapUp: (_) => _driveTo(0.0),
      onTapCancel: () => _driveTo(0.0),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: AnimatedBuilder(
        animation: _pressCtrl,
        child: widget.child,
        builder: (context, child) {
          final t = _pressCtrl.value.clamp(0.0, 1.35);
          // iOS 27 Fluid Gel Swell: outward expansion (1.0 -> 1.045x) + radial touch glow
          final scale = widget.reduceMotion ? 1.0 : (1.0 + 0.045 * t);
          return Transform.scale(
            scale: scale,
            child: CustomPaint(
              foregroundPainter: t > 0.01
                  ? _TouchIlluminationPainter(strength: t.clamp(0.0, 1.0))
                  : null,
              child: child,
            ),
          );
        },
      ),
    );
  }
}

class _TouchIlluminationPainter extends CustomPainter {
  final double strength;

  const _TouchIlluminationPainter({required this.strength});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strength <= 0.01) return;
    final rect = Offset.zero & size;
    final radius = math.max(size.width, size.height) * 0.68;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.22 * strength),
          Colors.white.withValues(alpha: 0.06 * strength),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: rect.center, radius: radius));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular(math.min(size.width, size.height) * 0.5),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _TouchIlluminationPainter old) =>
      old.strength != strength;
}

class _IosSpatialRimPainter extends CustomPainter {
  final ShapeBorder shape;
  final double strength;

  const _IosSpatialRimPainter({required this.shape, this.strength = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final outer = shape.getOuterPath(rect.deflate(0.5));
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.54 * strength),
          Colors.white.withValues(alpha: 0.16 * strength),
          Colors.white.withValues(alpha: 0.06 * strength),
          Colors.white.withValues(alpha: 0.24 * strength),
        ],
        stops: const [0.0, 0.30, 0.68, 1.0],
      ).createShader(rect);
    canvas.drawPath(outer, rim);

    final inner = shape.getOuterPath(rect.deflate(1.5));
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: 0.26 * strength),
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.08 * strength),
        ],
        stops: const [0.0, 0.46, 1.0],
      ).createShader(rect);
    canvas.drawPath(inner, glow);
  }

  @override
  bool shouldRepaint(covariant _IosSpatialRimPainter old) =>
      old.shape != shape || old.strength != strength;
}

class _IosSpatialGlassSurface extends StatelessWidget {
  static const Color _darkGlassTint = Color(0x3D161820);
  static const Color _heroDarkGlassTint = Color(0x52161820);

  final Widget child;
  final double? width;
  final double? height;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool ios26Visual;
  final bool reduceTransparency;
  final bool heroHighlight;
  final Color? tint;

  const _IosSpatialGlassSurface({
    super.key,
    required this.child,
    required this.borderRadius,
    required this.ios26Visual,
    required this.reduceTransparency,
    this.width,
    this.height,
    this.padding,
    this.heroHighlight = false,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final shape = ContinuousRectangleBorder(borderRadius: radius);

    if (reduceTransparency) {
      final base = tint != null
          ? Color.alphaBlend(
              tint!.withValues(alpha: 0.72),
              const Color(0xF51E1E22),
            )
          : (heroHighlight
              ? const Color(0xF526272E)
              : const Color(0xF51E1E22));
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x4D000000),
              blurRadius: 14,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Container(
          width: width,
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: radius,
            color: base,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.48),
              width: 1.0,
            ),
          ),
          child: child,
        ),
      );
    }

    if (!ios26Visual) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: [
            BoxShadow(
              color: heroHighlight
                  ? const Color(0x59000000)
                  : const Color(0x45000000),
              blurRadius: heroHighlight ? 22 : 14,
              offset: Offset(0, heroHighlight ? 8 : 5),
            ),
            const BoxShadow(
              color: Color(0x26000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          clipBehavior: Clip.antiAlias,
          child: CustomPaint(
            foregroundPainter: _IosSpatialRimPainter(
              shape: shape,
              strength: heroHighlight ? 0.92 : 0.76,
            ),
            child: Container(
              width: width,
              height: height,
              padding: padding,
              decoration: ShapeDecoration(
                shape: shape,
                gradient: _fallbackTranslucentGradient(),
              ),
              child: child,
            ),
          ),
        ),
      );
    }

    final baseTint = tint ?? (heroHighlight ? _heroDarkGlassTint : _darkGlassTint);
    final rimMultiplier = heroHighlight ? 1.12 : 1.0;

    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: [
          BoxShadow(
            color: heroHighlight
                ? const Color(0x66000000)
                : const Color(0x59000000),
            blurRadius: heroHighlight ? 30 : 24,
            offset: Offset(0, heroHighlight ? 12 : 10),
          ),
          const BoxShadow(
            color: Color(0x26000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        clipBehavior: Clip.antiAlias,
        child: GlassworkBackdrop(
          radius: borderRadius,
          child: ValueListenableBuilder<double>(
            valueListenable: GlassworkBackdrop.intensity,
            builder: (context, strength, _) {
              final s = strength.clamp(0.0, 1.0);
              return CustomPaint(
                foregroundPainter: _IosSpatialRimPainter(
                  shape: shape,
                  strength: rimMultiplier * (0.28 + 0.92 * s),
                ),
                child: Container(
                  width: width,
                  height: height,
                  padding: padding,
                  decoration: ShapeDecoration(
                    shape: shape,
                    gradient: _ios26RefractiveGradient(baseTint, s),
                  ),
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  LinearGradient _ios26RefractiveGradient(Color baseTint, double s) {
    if (tint != null) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            Color.fromRGBO(255, 255, 255, 0.04 + 0.08 * s),
            tint!.withValues(alpha: 0.60),
          ),
          tint!.withValues(alpha: 0.46),
          Color.alphaBlend(
            Color.fromRGBO(255, 255, 255, 0.02 + 0.045 * s),
            tint!.withValues(alpha: 0.52),
          ),
        ],
        stops: const [0.0, 0.52, 1.0],
      );
    }
    final topSpecAlpha = (heroHighlight ? 0.05 : 0.03) + 0.08 * s;
    final bottomSpecAlpha = (heroHighlight ? 0.02 : 0.015) + 0.045 * s;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          Color.fromRGBO(255, 255, 255, topSpecAlpha),
          baseTint,
        ),
        baseTint,
        Color.alphaBlend(
          Color.fromRGBO(255, 255, 255, bottomSpecAlpha),
          baseTint,
        ),
      ],
      stops: const [0.0, 0.52, 1.0],
    );
  }

  LinearGradient _fallbackTranslucentGradient() {
    if (tint != null) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            tint!.withValues(alpha: 0.70),
            const Color(0xCC161820),
          ),
          Color.alphaBlend(
            tint!.withValues(alpha: 0.56),
            const Color(0xC2161820),
          ),
        ],
      );
    }
    if (heroHighlight) {
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xD4232630), Color(0xC8161820), Color(0xD01C1E27)],
        stops: [0.0, 0.52, 1.0],
      );
    }
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xC41E2029), Color(0xB8161820), Color(0xC01A1C25)],
      stops: [0.0, 0.52, 1.0],
    );
  }
}
