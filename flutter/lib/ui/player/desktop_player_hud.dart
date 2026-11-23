// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart'
    show
        Colors,
        Divider,
        IconButton,
        InkWell,
        Material,
        MaterialType,
        TextButton,
        Tooltip;

import '../../core/windows_video_quality.dart';
import '../apple_theme.dart';
import '../ios_liquid_glass.dart';
import '../windows_appearance.dart';

/// Desktop keyboard arrow hold fast-forward / rewind preview capsule.
class DesktopScrubPreviewCapsule extends StatelessWidget {
  final int direction;
  final String targetTimeText;
  final String deltaText;
  final double speedSecPerSec;
  final bool isHoldPreview;
  final bool reduceTransparency;

  const DesktopScrubPreviewCapsule({
    super.key,
    required this.direction,
    required this.targetTimeText,
    required this.deltaText,
    required this.speedSecPerSec,
    required this.isHoldPreview,
    this.reduceTransparency = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveReduce = reduceTransparency ||
        IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        MediaQuery.highContrastOf(context);
    final bgColor = effectiveReduce || isWindowsDesktopUi
        ? const Color(0xEB16161C)
        : const Color(0xCC16161C);
    final arrow = direction >= 0 ? '⏩' : '⏪';
    final speedPart =
        isHoldPreview ? ' · ${speedSecPerSec.round()}s/s' : '';

    return IgnorePointer(
      child: Container(
        key: const Key('desktop-scrub-preview-capsule'),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withValues(alpha: effectiveReduce ? 0.45 : 0.22),
            width: 0.85,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x52000000),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$arrow $targetTimeText ($deltaText)$speedPart',
              style: const TextStyle(
                color: AppleColors.labelPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              '松开方向键跳转 · 按 Esc 取消',
              style: TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Width breakpoints shared between [DesktopPlayerHud] and its overflow
/// "More" popover so primary bar items are never duplicated inside "More".
class DesktopHudBarVisibility {
  final bool showInlineVolume;
  final bool showSpeed;
  final bool showDanmu;
  final bool showSubtitles;
  final bool showAnime4k;
  final bool showVideoQuality;
  final bool showAudioLoudness;
  final bool showSleepTimer;

  const DesktopHudBarVisibility({
    required this.showInlineVolume,
    required this.showSpeed,
    required this.showDanmu,
    required this.showSubtitles,
    required this.showAnime4k,
    this.showVideoQuality = false,
    this.showAudioLoudness = false,
    required this.showSleepTimer,
  });

  factory DesktopHudBarVisibility.forWidth(
    double width, {
    required bool isLive,
    required bool danmuAvailable,
    required bool anime4kAvailable,
    bool videoQualityAvailable = false,
    bool audioLoudnessAvailable = false,
  }) {
    return DesktopHudBarVisibility(
      showInlineVolume: width >= 820,
      showSpeed: !isLive && width >= 760,
      showDanmu: !isLive && danmuAvailable && width >= 860,
      showSubtitles: !isLive && width >= 960,
      showAnime4k: anime4kAvailable && width >= 1080,
      showVideoQuality: videoQualityAvailable && width >= 1020,
      showAudioLoudness: audioLoudnessAvailable && width >= 1120,
      showSleepTimer: width >= 1160,
    );
  }
}

enum _DesktopHudQuickMenu { quality, loudness }

/// Refactored Windows desktop cinema player HUD:
/// - Top scrim header (back + title + fused badges, zero lock clutter)
/// - Midline far-left lock button (matching locked-state unlock anchor)
/// - Center canvas Play/Pause + Rewind 15s + Fast-Forward 15s transport controls
/// - Full-width edge-to-edge bottom progress bar & clean desktop action row
/// - PC-native anchored "More" & quick quality/loudness popovers (zero duplicates, zero focus steal)
class DesktopPlayerHud extends StatefulWidget {
  final bool embedded;
  final String title;
  final bool playing;
  final bool isLive;
  final bool isFullscreen;
  final double normalSpeed;
  final double volume;
  final Stream<double>? volumeStream;
  final ValueChanged<double>? onVolumeChanged;
  final VoidCallback? onMuteToggle;
  final bool hasPrevEpisode;
  final bool hasNextEpisode;
  final VoidCallback? onPrevEpisode;
  final VoidCallback? onNextEpisode;
  final bool moreControlsOpen;
  final bool sleepTimerActive;
  final String sleepTimerLabel;
  final bool danmuEnabled;
  final VoidCallback? onDanmuToggle;
  final VoidCallback? onDanmuSettingsTap;
  final bool anime4kVisible;
  final bool anime4kActive;
  final String anime4kLabel;
  final VoidCallback? onAnime4kTap;
  final bool videoQualityVisible;
  final bool videoQualityActive;
  final String? videoQualityLabel;
  final WindowsQualityPreset? videoQualityPreset;
  final VoidCallback? onVideoQualityTap;
  final ValueChanged<WindowsQualityPreset>? onVideoQualityChanged;
  final bool audioLoudnessVisible;
  final bool audioLoudnessActive;
  final String? audioLoudnessLabel;
  final AudioLoudnessPreset? audioLoudnessPreset;
  final VoidCallback? onAudioLoudnessTap;
  final ValueChanged<AudioLoudnessPreset>? onAudioLoudnessChanged;
  final Widget topHeader;
  final Widget? lockButton;
  final Widget? progressBar;
  final Widget transportButtons;
  final Widget moreToolsDock;
  final VoidCallback onExit;
  final VoidCallback onPlayPause;
  final VoidCallback onVolumeTap;
  final VoidCallback onEpisodesTap;
  final VoidCallback onSpeedTap;
  final VoidCallback onSubtitlesTap;
  final VoidCallback onSleepTimerTap;
  final VoidCallback onToggleMore;
  final VoidCallback? onCloseMore;
  final VoidCallback onToggleExpand;

  const DesktopPlayerHud({
    super.key,
    required this.embedded,
    required this.title,
    required this.playing,
    required this.isLive,
    this.isFullscreen = false,
    required this.normalSpeed,
    this.volume = 100.0,
    this.volumeStream,
    this.onVolumeChanged,
    this.onMuteToggle,
    this.hasPrevEpisode = false,
    this.hasNextEpisode = false,
    this.onPrevEpisode,
    this.onNextEpisode,
    required this.moreControlsOpen,
    required this.sleepTimerActive,
    required this.sleepTimerLabel,
    this.danmuEnabled = false,
    this.onDanmuToggle,
    this.onDanmuSettingsTap,
    this.anime4kVisible = false,
    this.anime4kActive = false,
    this.anime4kLabel = 'Anime4K',
    this.onAnime4kTap,
    this.videoQualityVisible = false,
    this.videoQualityActive = false,
    this.videoQualityLabel,
    this.videoQualityPreset,
    this.onVideoQualityTap,
    this.onVideoQualityChanged,
    this.audioLoudnessVisible = false,
    this.audioLoudnessActive = false,
    this.audioLoudnessLabel,
    this.audioLoudnessPreset,
    this.onAudioLoudnessTap,
    this.onAudioLoudnessChanged,
    required this.topHeader,
    this.lockButton,
    required this.progressBar,
    required this.transportButtons,
    required this.moreToolsDock,
    required this.onExit,
    required this.onPlayPause,
    required this.onVolumeTap,
    required this.onEpisodesTap,
    required this.onSpeedTap,
    required this.onSubtitlesTap,
    required this.onSleepTimerTap,
    required this.onToggleMore,
    this.onCloseMore,
    required this.onToggleExpand,
  });

  @override
  State<DesktopPlayerHud> createState() => _DesktopPlayerHudState();
}

class _DesktopPlayerHudState extends State<DesktopPlayerHud> {
  _DesktopHudQuickMenu? _activeQuickMenu;

  @override
  void didUpdateWidget(covariant DesktopPlayerHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.moreControlsOpen && !oldWidget.moreControlsOpen) ||
        (widget.embedded && !oldWidget.embedded)) {
      _activeQuickMenu = null;
    }
  }

  void _toggleQuickMenu(_DesktopHudQuickMenu menu) {
    if (widget.moreControlsOpen) {
      widget.onCloseMore?.call();
    }
    setState(() {
      _activeQuickMenu = _activeQuickMenu == menu ? null : menu;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return ExcludeFocus(
        child: Stack(
          key: const Key('desktop-player-hud-embedded'),
          children: [
            Positioned(
              left: 15,
              right: 15,
              top: 12,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '停止播放',
                    onPressed: widget.onExit,
                    icon: const Icon(CupertinoIcons.xmark, color: Colors.white),
                  ),
                ],
              ),
            ),
            if (widget.moreControlsOpen)
              Positioned(
                right: 12,
                bottom: 72,
                child: widget.moreToolsDock,
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: WinPanel(
                dark: true,
                padding: const EdgeInsets.all(6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: widget.playing ? '暂停' : '播放',
                      onPressed: widget.onPlayPause,
                      icon: Icon(
                        widget.playing
                            ? CupertinoIcons.pause_fill
                            : CupertinoIcons.play_fill,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '音量',
                      onPressed: widget.onVolumeTap,
                      icon: const Icon(
                        CupertinoIcons.volume_up,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '线路',
                      onPressed: widget.onEpisodesTap,
                      icon: const Icon(
                        CupertinoIcons.list_bullet,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '更多',
                      onPressed: widget.onToggleMore,
                      icon: const Icon(
                        CupertinoIcons.ellipsis,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: '展开播放',
                      onPressed: widget.onToggleExpand,
                      icon: const Icon(
                        CupertinoIcons.arrow_up_left_arrow_down_right,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final videoQualityAvailable = widget.videoQualityVisible &&
        (widget.onVideoQualityTap != null ||
            widget.onVideoQualityChanged != null);
    final audioLoudnessAvailable = widget.audioLoudnessVisible &&
        (widget.onAudioLoudnessTap != null ||
            widget.onAudioLoudnessChanged != null);
    final visibility = DesktopHudBarVisibility.forWidth(
      width,
      isLive: widget.isLive,
      danmuAvailable: widget.onDanmuToggle != null,
      anime4kAvailable: widget.anime4kVisible && widget.onAnime4kTap != null,
      videoQualityAvailable: videoQualityAvailable,
      audioLoudnessAvailable: audioLoudnessAvailable,
    );

    Widget barButton(
      String label,
      IconData icon,
      VoidCallback action, {
      bool highlighted = false,
      Key? key,
    }) {
      return TextButton.icon(
        key: key,
        onPressed: action,
        style: TextButton.styleFrom(
          foregroundColor:
              highlighted ? AppleColors.systemCyan : const Color(0xEEFFFFFF),
          backgroundColor: highlighted
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.transparent,
          overlayColor: Colors.white.withValues(alpha: 0.12),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
        ),
      );
    }

    Widget iconAction({
      Key? key,
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
      bool highlighted = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: IconButton(
          key: key,
          onPressed: onPressed,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          splashRadius: 18,
          icon: Icon(
            icon,
            size: 18,
            color: highlighted
                ? AppleColors.systemCyan
                : const Color(0xEEFFFFFF),
          ),
        ),
      );
    }

    Widget buildVolumeControl() {
      if (!visibility.showInlineVolume || widget.onVolumeChanged == null) {
        return iconAction(
          icon: widget.volume <= 0.1
              ? CupertinoIcons.volume_off
              : CupertinoIcons.volume_up,
          tooltip: '音量',
          onPressed: widget.onVolumeTap,
        );
      }
      return StreamBuilder<double>(
        stream: widget.volumeStream,
        initialData: widget.volume,
        builder: (context, snapshot) {
          final currentVol = (snapshot.data ?? widget.volume).clamp(0.0, 100.0);
          final icon = currentVol <= 0.5
              ? CupertinoIcons.volume_off
              : currentVol < 50
                  ? CupertinoIcons.volume_down
                  : CupertinoIcons.volume_up;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconAction(
                icon: icon,
                tooltip: currentVol <= 0.5 ? '取消静音 (M)' : '静音 (M)',
                onPressed: widget.onMuteToggle ?? widget.onVolumeTap,
              ),
              _DesktopInlineVolumeTrack(
                value: currentVol,
                onChanged: widget.onVolumeChanged!,
              ),
            ],
          );
        },
      );
    }

    final resolvedQualityLabel = widget.videoQualityLabel ??
        (widget.videoQualityPreset != null
            ? '画质·${widget.videoQualityPreset!.shortLabelZh}'
            : '画质');
    final resolvedQualityActive = widget.videoQualityActive ||
        (widget.videoQualityPreset != null &&
            widget.videoQualityPreset != WindowsQualityPreset.ecoCompat) ||
        _activeQuickMenu == _DesktopHudQuickMenu.quality;

    final resolvedLoudnessLabel = widget.audioLoudnessLabel ??
        (widget.audioLoudnessPreset != null &&
                widget.audioLoudnessPreset != AudioLoudnessPreset.off
            ? '人声·${widget.audioLoudnessPreset!.shortLabelZh}'
            : '人声');
    final resolvedLoudnessActive = widget.audioLoudnessActive ||
        (widget.audioLoudnessPreset != null &&
            widget.audioLoudnessPreset != AudioLoudnessPreset.off) ||
        _activeQuickMenu == _DesktopHudQuickMenu.loudness;

    final hasPopoverOpen = widget.moreControlsOpen || _activeQuickMenu != null;

    return ExcludeFocus(
      child: Stack(
        key: const Key('desktop-player-hud'),
        fit: StackFit.expand,
        children: [
          // Top soft cinema scrim + header
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xC8000000),
                    Color(0x52000000),
                    Color(0x00000000),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
                  child: widget.topHeader,
                ),
              ),
            ),
          ),
          // Center canvas transport controls: Rewind 15s, Play/Pause, Forward 15s
          Positioned.fill(
            child: Center(
              child: widget.transportButtons,
            ),
          ),
          // Midline far-left lock button (aligned with locked-state unlock anchor)
          if (widget.lockButton != null)
            Positioned(
              left: 20,
              top: 0,
              bottom: 0,
              child: SafeArea(
                right: false,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: widget.lockButton!,
                ),
              ),
            ),
          // Dismiss barrier when "More" or quick-switch popover is open
          if (hasPopoverOpen &&
              (widget.onCloseMore != null || _activeQuickMenu != null))
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_activeQuickMenu != null) {
                    setState(() => _activeQuickMenu = null);
                  }
                  if (widget.moreControlsOpen) {
                    widget.onCloseMore?.call();
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
          // Bottom full-width cinema control bar (progress bar + toolbar)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x00000000),
                    Color(0x9E000000),
                    Color(0xE8000000),
                  ],
                  stops: [0.0, 0.42, 1.0],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 26, 24, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!widget.isLive && widget.progressBar != null) ...[
                        widget.progressBar!,
                        const SizedBox(height: 6),
                      ],
                      Row(
                        children: [
                          if (widget.hasPrevEpisode &&
                              widget.onPrevEpisode != null)
                            iconAction(
                              icon: CupertinoIcons.backward_end_fill,
                              tooltip: widget.isLive ? '上一源 (P)' : '上一集 (P)',
                              onPressed: widget.onPrevEpisode!,
                            ),
                          if (widget.hasNextEpisode &&
                              widget.onNextEpisode != null)
                            iconAction(
                              icon: CupertinoIcons.forward_end_fill,
                              tooltip: widget.isLive ? '下一源 (N)' : '下一集 (N)',
                              onPressed: widget.onNextEpisode!,
                            ),
                          buildVolumeControl(),
                          const Spacer(),
                          if (visibility.showSpeed)
                            barButton(
                              '${widget.normalSpeed}×',
                              CupertinoIcons.speedometer,
                              widget.onSpeedTap,
                              highlighted: widget.normalSpeed != 1.0,
                            ),
                          if (visibility.showDanmu)
                            barButton(
                              widget.danmuEnabled ? '弹幕开' : '弹幕',
                              widget.danmuEnabled
                                  ? CupertinoIcons.chat_bubble_text_fill
                                  : CupertinoIcons.chat_bubble_text,
                              widget.onDanmuToggle!,
                              highlighted: widget.danmuEnabled,
                              key: const Key('desktop-danmu-toggle-button'),
                            ),
                          if (visibility.showSubtitles)
                            barButton(
                              '字幕',
                              CupertinoIcons.captions_bubble,
                              widget.onSubtitlesTap,
                            ),
                          if (visibility.showVideoQuality)
                            barButton(
                              resolvedQualityLabel,
                              CupertinoIcons.sparkles,
                              () {
                                if (widget.onVideoQualityTap != null) {
                                  if (_activeQuickMenu != null) {
                                    setState(() => _activeQuickMenu = null);
                                  }
                                  widget.onVideoQualityTap!();
                                } else {
                                  _toggleQuickMenu(
                                      _DesktopHudQuickMenu.quality);
                                }
                              },
                              highlighted: resolvedQualityActive,
                              key: const Key('desktop-video-quality-button'),
                            ),
                          if (visibility.showAudioLoudness)
                            barButton(
                              resolvedLoudnessLabel,
                              CupertinoIcons.waveform,
                              () {
                                if (widget.onAudioLoudnessTap != null) {
                                  if (_activeQuickMenu != null) {
                                    setState(() => _activeQuickMenu = null);
                                  }
                                  widget.onAudioLoudnessTap!();
                                } else {
                                  _toggleQuickMenu(
                                      _DesktopHudQuickMenu.loudness);
                                }
                              },
                              highlighted: resolvedLoudnessActive,
                              key: const Key('desktop-audio-loudness-button'),
                            ),
                          if (visibility.showAnime4k)
                            barButton(
                              widget.anime4kLabel,
                              CupertinoIcons.wand_stars,
                              widget.onAnime4kTap!,
                              highlighted: widget.anime4kActive,
                              key: const Key('desktop-anime4k-button'),
                            ),
                          if (visibility.showSleepTimer)
                            barButton(
                              widget.sleepTimerActive
                                  ? widget.sleepTimerLabel
                                  : '定时',
                              CupertinoIcons.moon_zzz_fill,
                              widget.onSleepTimerTap,
                              highlighted: widget.sleepTimerActive,
                              key: const Key('desktop-sleep-timer-button'),
                            ),
                          barButton(
                            widget.isLive ? '信号' : '选集',
                            CupertinoIcons.list_bullet,
                            widget.onEpisodesTap,
                          ),
                          barButton(
                            '更多',
                            CupertinoIcons.ellipsis,
                            () {
                              if (_activeQuickMenu != null) {
                                setState(() => _activeQuickMenu = null);
                              }
                              widget.onToggleMore();
                            },
                            highlighted: widget.moreControlsOpen,
                            key: const Key('desktop-more-button'),
                          ),
                          const SizedBox(width: 2),
                          iconAction(
                            key: const Key('player-fullscreen-toggle'),
                            icon: widget.isFullscreen
                                ? CupertinoIcons.fullscreen_exit
                                : CupertinoIcons.fullscreen,
                            tooltip:
                                widget.isFullscreen ? '退出全屏 (F)' : '全屏 (F)',
                            onPressed: widget.onToggleExpand,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Built-in quick quality/loudness popover when inline selector is active
          if (_activeQuickMenu != null && !widget.moreControlsOpen)
            Positioned(
              right: 24,
              bottom: widget.isLive ? 66 : 106,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 324,
                  maxHeight: math.max(180.0, size.height - 172.0),
                ),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) {},
                      );
                    }
                  },
                  child: DesktopPlayerMorePopover(
                    sections: [
                      if (_activeQuickMenu == _DesktopHudQuickMenu.quality &&
                          widget.onVideoQualityChanged != null)
                        DesktopVideoQualitySection(
                          currentPreset: widget.videoQualityPreset ??
                              WindowsQualityPreset.balancedHq,
                          anime4kActive: widget.anime4kActive,
                          onSelected: (preset) {
                            widget.onVideoQualityChanged!(preset);
                            setState(() => _activeQuickMenu = null);
                          },
                        ),
                      if (_activeQuickMenu == _DesktopHudQuickMenu.loudness &&
                          widget.onAudioLoudnessChanged != null)
                        DesktopAudioLoudnessSection(
                          currentPreset: widget.audioLoudnessPreset ??
                              AudioLoudnessPreset.off,
                          onSelected: (preset) {
                            widget.onAudioLoudnessChanged!(preset);
                            setState(() => _activeQuickMenu = null);
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          // Desktop PC-native anchored "More" popover menu (bottom-right above "更多")
          if (widget.moreControlsOpen)
            Positioned(
              right: 24,
              bottom: widget.isLive ? 66 : 106,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 324,
                  maxHeight: math.max(180.0, size.height - 172.0),
                ),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) {},
                      );
                    }
                  },
                  child: widget.moreToolsDock,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DesktopInlineVolumeTrack extends StatefulWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const _DesktopInlineVolumeTrack({
    required this.value,
    required this.onChanged,
  });

  @override
  State<_DesktopInlineVolumeTrack> createState() =>
      _DesktopInlineVolumeTrackState();
}

class _DesktopInlineVolumeTrackState extends State<_DesktopInlineVolumeTrack> {
  static const double _trackWidth = 78.0;
  bool _hovered = false;

  void _updateFromDx(double dx) {
    final next = ((dx / _trackWidth).clamp(0.0, 1.0) * 100.0);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final fraction = (widget.value / 100.0).clamp(0.0, 1.0);
    final fillW = _trackWidth * fraction;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _updateFromDx(d.localPosition.dx),
        onHorizontalDragUpdate: (d) => _updateFromDx(d.localPosition.dx),
        child: SizedBox(
          width: _trackWidth + 10,
          height: 28,
          child: Center(
            child: SizedBox(
              width: _trackWidth,
              height: 12,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    width: _trackWidth,
                    height: _hovered ? 4.0 : 3.0,
                    decoration: BoxDecoration(
                      color: const Color(0x40FFFFFF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Container(
                    width: fillW,
                    height: _hovered ? 4.0 : 3.0,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Positioned(
                    left: (fillW - 5).clamp(0.0, _trackWidth - 10),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x55000000),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reusable desktop popover menu card for secondary player controls.
class DesktopPlayerMorePopover extends StatelessWidget {
  final List<Widget> sections;

  const DesktopPlayerMorePopover({
    super.key,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('desktop-more-menu-popover'),
      width: 312,
      decoration: BoxDecoration(
        color: const Color(0xF2141821),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x7A000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 14,
                      indent: 14,
                      endIndent: 14,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  sections[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DesktopMoreMenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? valueText;
  final bool active;
  final Widget? trailing;
  final VoidCallback onTap;

  const DesktopMoreMenuRow({
    super.key,
    required this.icon,
    required this.label,
    this.valueText,
    this.active = false,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: active ? AppleColors.systemCyan : const Color(0xCCFFFFFF),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? AppleColors.systemCyan : Colors.white,
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (valueText != null && valueText!.isNotEmpty) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(
                  valueText!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else ...[
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.chevron_right,
                size: 12,
                color: Color(0x66FFFFFF),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Reusable 3-tier Windows MPV quality / HDR tone-mapping selector section for
/// [DesktopPlayerMorePopover] or quick-switch popovers.
class DesktopVideoQualitySection extends StatelessWidget {
  final WindowsQualityPreset currentPreset;
  final ValueChanged<WindowsQualityPreset> onSelected;
  final bool anime4kActive;

  const DesktopVideoQualitySection({
    super.key,
    required this.currentPreset,
    required this.onSelected,
    this.anime4kActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('desktop-video-quality-section'),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '画质与 HDR 映射',
                  style: TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                currentPreset == WindowsQualityPreset.cinemaUltra
                    ? '去色带 + 超清'
                    : (currentPreset == WindowsQualityPreset.balancedHq
                        ? 'HDR 动态映射'
                        : '低功耗'),
                style: TextStyle(
                  color: currentPreset == WindowsQualityPreset.ecoCompat
                      ? const Color(0x88FFFFFF)
                      : AppleColors.systemCyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < WindowsQualityPreset.values.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right:
                          i == WindowsQualityPreset.values.length - 1 ? 0 : 6,
                    ),
                    child: _DesktopSegmentPill(
                      key: Key(
                        'desktop-quality-preset-${WindowsQualityPreset.values[i].id}',
                      ),
                      label: WindowsQualityPreset.values[i].shortLabelZh,
                      selected:
                          currentPreset == WindowsQualityPreset.values[i],
                      onTap: () => onSelected(WindowsQualityPreset.values[i]),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            anime4kActive
                ? '${currentPreset.descriptionZh}（Anime4K 已开启，关闭后恢复当前缩放器）'
                : currentPreset.descriptionZh,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0x88FFFFFF),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable 4-tier `dynaudnorm` vocal dialogue & loudness selector section for
/// [DesktopPlayerMorePopover] or quick-switch popovers.
class DesktopAudioLoudnessSection extends StatelessWidget {
  final AudioLoudnessPreset currentPreset;
  final ValueChanged<AudioLoudnessPreset> onSelected;

  const DesktopAudioLoudnessSection({
    super.key,
    required this.currentPreset,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('desktop-audio-loudness-section'),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '人声响度增强',
                  style: TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                currentPreset == AudioLoudnessPreset.off
                    ? '原声'
                    : currentPreset.shortLabelZh,
                style: TextStyle(
                  color: currentPreset == AudioLoudnessPreset.off
                      ? const Color(0x88FFFFFF)
                      : AppleColors.systemCyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < AudioLoudnessPreset.values.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right:
                          i == AudioLoudnessPreset.values.length - 1 ? 0 : 6,
                    ),
                    child: _DesktopSegmentPill(
                      key: Key(
                        'desktop-loudness-preset-${AudioLoudnessPreset.values[i].id}',
                      ),
                      label: AudioLoudnessPreset.values[i].shortLabelZh,
                      selected:
                          currentPreset == AudioLoudnessPreset.values[i],
                      onTap: () => onSelected(AudioLoudnessPreset.values[i]),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            currentPreset.descriptionZh,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0x88FFFFFF),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopSegmentPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopSegmentPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2D4364)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF4C9AFF)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : const Color(0xCCFFFFFF),
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
