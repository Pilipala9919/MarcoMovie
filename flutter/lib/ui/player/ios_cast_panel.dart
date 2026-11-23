// Copyright (C) 2026 Pilipala. SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../../core/cast_service.dart';
import '../apple_theme.dart';
import '../ios_glass_popover.dart' show activeIosGlassPopoverCount;
import '../ios_liquid_glass.dart';
import '../poster_image.dart';

/// Opens the iOS 27 4-side inset concentric Liquid Glass casting panel
/// highlighting dual-channel **Apple AirPlay 2** + **LAN DLNA** casting.
///
/// Backward-compatible with existing `showIosCastPopover` callers while
/// replacing legacy pointed arrow popovers with an iOS 27 inset concentric
/// Liquid Glass floating sheet driven by `SpringSimulation`.
Future<void> showIosCastPopover({
  required BuildContext context,
  Rect? anchorRect,
  required CastController controller,
  required Future<void> Function(CastDevice device) onSelectDevice,
  bool isAirPlayActive = false,
  String? airPlayDeviceName,
  Future<bool> Function()? onOpenAirPlayPicker,
}) {
  if (!controller.scanning) {
    controller.scanDevices();
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return _Ios27InsetCastPanelOverlay(
        anchorRect: anchorRect,
        controller: controller,
        onSelectDevice: onSelectDevice,
        isAirPlayActive: isAirPlayActive,
        airPlayDeviceName: airPlayDeviceName,
        onOpenAirPlayPicker: onOpenAirPlayPicker,
      );
    },
    transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(dialogContext)) {
        return FadeTransition(opacity: animation, child: child);
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

class _Ios27InsetCastPanelOverlay extends StatefulWidget {
  final Rect? anchorRect;
  final CastController controller;
  final Future<void> Function(CastDevice device) onSelectDevice;
  final bool isAirPlayActive;
  final String? airPlayDeviceName;
  final Future<bool> Function()? onOpenAirPlayPicker;

  const _Ios27InsetCastPanelOverlay({
    required this.anchorRect,
    required this.controller,
    required this.onSelectDevice,
    required this.isAirPlayActive,
    required this.airPlayDeviceName,
    required this.onOpenAirPlayPicker,
  });

  @override
  State<_Ios27InsetCastPanelOverlay> createState() =>
      _Ios27InsetCastPanelOverlayState();
}

class _Ios27InsetCastPanelOverlayState
    extends State<_Ios27InsetCastPanelOverlay>
    with SingleTickerProviderStateMixin {
  static const double _outerInsetPt = 10.0;
  static const double _outerRadiusPt = 28.0;
  static const double _innerRadiusPt = 16.0;

  static final SpringDescription _sheetSpring =
      SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: (2 * math.pi / 0.36) * (2 * math.pi / 0.36),
    ratio: 0.88,
  );

  late final AnimationController _dragOffsetCtrl = AnimationController.unbounded(
    vsync: this,
    value: 0.0,
  );

  @override
  void initState() {
    super.initState();
    activeIosGlassPopoverCount.value++;
  }

  @override
  void dispose() {
    if (activeIosGlassPopoverCount.value > 0) {
      activeIosGlassPopoverCount.value--;
    }
    _dragOffsetCtrl.dispose();
    super.dispose();
  }

  void _springDragBack(double velocityY) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _dragOffsetCtrl.value = 0.0;
      return;
    }
    final sim = SpringSimulation(
      _sheetSpring,
      _dragOffsetCtrl.value,
      0.0,
      velocityY,
    );
    _dragOffsetCtrl.animateWith(sim);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final safe = media.padding;
    final screen = media.size;
    final isWide = screen.width >= 560;
    final reduceTransparency = IosLiquidGlassBridge.reduceTransparency ||
        GlassworkBackdrop.reduceTransparency.value ||
        GlassworkBackdrop.intensity.value <= 0.02 ||
        MediaQuery.highContrastOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    final bottomInset = math.max(safe.bottom, _outerInsetPt) +
        (safe.bottom > 0 ? 4.0 : _outerInsetPt);
    final topInset = math.max(safe.top, _outerInsetPt) + 8.0;
    final sideInset = math.max(safe.left, safe.right) + _outerInsetPt;
    final maxPanelWidth = isWide ? 416.0 : math.max(260.0, screen.width - sideInset * 2);
    final maxPanelHeight = math.min(
      screen.height * 0.78,
      math.max(260.0, screen.height - topInset - bottomInset),
    );

    final controller = widget.controller;
    final airPlayTitle = widget.isAirPlayActive &&
            (widget.airPlayDeviceName?.isNotEmpty ?? false)
        ? '隔空播放 2 · ${widget.airPlayDeviceName}'
        : '隔空播放 2 (AirPlay 2)';

    final panel = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxPanelWidth,
        maxHeight: maxPanelHeight,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
          data: Theme.of(context).copyWith(brightness: Brightness.dark),
          child: DecoratedBox(
            key: const Key('ios-cast-inset-panel'),
            decoration: ShapeDecoration(
              shape: ContinuousRectangleBorder(
                borderRadius: BorderRadius.circular(_outerRadiusPt),
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.52),
                  blurRadius: 34,
                  spreadRadius: -4,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: ClipPath(
              clipper: ShapeBorderClipper(
                shape: ContinuousRectangleBorder(
                  borderRadius: BorderRadius.circular(_outerRadiusPt),
                ),
              ),
              child: LiquidGlass(
                borderRadius: _outerRadiusPt,
                blur: 28,
                tint: reduceTransparency
                    ? const Color(0xF51E1E22)
                    : const Color(0x9C15171F),
                rimStrength: 1.05,
                elevated: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Grabber + Header with spring rubber-band dismiss gesture
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (details) {
                        final next = _dragOffsetCtrl.value + details.delta.dy;
                        _dragOffsetCtrl.value =
                            next < 0 ? next * 0.22 : next;
                      },
                      onVerticalDragEnd: (details) {
                        final vy = details.velocity.pixelsPerSecond.dy;
                        if (_dragOffsetCtrl.value > 72 || vy > 520) {
                          Navigator.of(context).maybePop();
                        } else {
                          _springDragBack(vy);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 36,
                              height: 4.5,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.34),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: ShapeDecoration(
                                    color: AppleColors.systemBlue
                                        .withValues(alpha: 0.22),
                                    shape: ContinuousRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: const Icon(
                                    CupertinoIcons.tv_fill,
                                    size: 15,
                                    color: AppleColors.systemCyan,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '无线投屏 · AirPlay 2 & DLNA',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -0.25,
                                        ),
                                      ),
                                      Text(
                                        '零损耗隔空播放 2 直投 · 局域网电视跨屏',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                AnimatedBuilder(
                                  animation: controller,
                                  builder: (context, _) {
                                    return CupertinoButton(
                                      key: const Key('ios-cast-refresh-button'),
                                      padding: const EdgeInsets.all(6),
                                      minimumSize: const Size(32, 32),
                                      onPressed: controller.scanning
                                          ? null
                                          : () => controller.scanDevices(),
                                      child: controller.scanning
                                          ? const CupertinoActivityIndicator(
                                              radius: 7.5,
                                              color: Colors.white70,
                                            )
                                          : const Icon(
                                              CupertinoIcons.refresh,
                                              size: 16,
                                              color: Colors.white70,
                                            ),
                                    );
                                  },
                                ),
                                CupertinoButton(
                                  padding: const EdgeInsets.all(6),
                                  minimumSize: const Size(32, 32),
                                  onPressed: () =>
                                      Navigator.of(context).maybePop(),
                                  child: Container(
                                    width: 26,
                                    height: 26,
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.12),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      CupertinoIcons.xmark,
                                      size: 13,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 0.6,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                    Flexible(
                      child: AnimatedBuilder(
                        animation: controller,
                        builder: (context, _) {
                          final devices = controller.devices;
                          return SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // Channel 1: Native AirPlay 2 Hero Card
                                _CastRowTile(
                                  key: const Key('ios-cast-airplay-row'),
                                  icon: CupertinoIcons.tv_circle_fill,
                                  accent: AppleColors.systemBlue,
                                  title: airPlayTitle,
                                  subtitle:
                                      'Apple TV · HomePod · 支持隔空播放 2 的智能电视',
                                  badgeText: 'AirPlay 2',
                                  selected: widget.isAirPlayActive,
                                  reduceMotion: reduceMotion,
                                  cornerRadius: _innerRadiusPt,
                                  trailing: Icon(
                                    widget.isAirPlayActive
                                        ? CupertinoIcons.checkmark_circle_fill
                                        : CupertinoIcons.chevron_right,
                                    size: 16,
                                    color: widget.isAirPlayActive
                                        ? AppleColors.systemGreen
                                        : Colors.white54,
                                  ),
                                  onTap: () async {
                                    HapticFeedback.selectionClick();
                                    Navigator.of(context).pop();
                                    if (widget.onOpenAirPlayPicker != null) {
                                      await widget.onOpenAirPlayPicker!();
                                    } else {
                                      await controller.openAirPlayPicker();
                                    }
                                  },
                                ),
                                const SizedBox(height: 12),
                                // Channel 2: LAN DLNA Section Header
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      const Text(
                                        '局域网 DLNA 电视 / 盒子',
                                        style: TextStyle(
                                          color: Colors.white60,
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        controller.scanning
                                            ? '正在搜索…'
                                            : '发现 ${devices.length} 台',
                                        style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (devices.isEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 16,
                                    ),
                                    decoration: ShapeDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.06),
                                      shape: ContinuousRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          _innerRadiusPt,
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          controller.scanning
                                              ? CupertinoIcons.wifi
                                              : CupertinoIcons.tv,
                                          size: 24,
                                          color: Colors.white54,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          controller.scanning
                                              ? '正在搜索同一 Wi-Fi 下的投屏设备…'
                                              : (controller.statusMessage ??
                                                  '暂未发现 DLNA 电视或盒子'),
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        const Text(
                                          '请确认手机与电视在同一 Wi-Fi（关闭代理/VPN），并已允许「本地网络」权限',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: 10.5,
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                else
                                  for (final device in devices) ...[
                                    _CastRowTile(
                                      key: Key('ios-cast-device-${device.id}'),
                                      icon: CupertinoIcons.tv_fill,
                                      accent:
                                          controller.activeDevice?.id ==
                                                  device.id
                                              ? AppleColors.systemGreen
                                              : Colors.white,
                                      title: device.name,
                                      subtitle: device.subtitle,
                                      badgeText: 'DLNA',
                                      selected:
                                          controller.activeDevice?.id ==
                                              device.id,
                                      reduceMotion: reduceMotion,
                                      cornerRadius: _innerRadiusPt,
                                      trailing:
                                          controller.activeDevice?.id ==
                                                  device.id
                                              ? const Icon(
                                                  CupertinoIcons
                                                      .checkmark_circle_fill,
                                                  size: 16,
                                                  color:
                                                      AppleColors.systemGreen,
                                                )
                                              : const Text(
                                                  '投屏',
                                                  style: TextStyle(
                                                    color:
                                                        AppleColors.systemBlue,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                      onTap: () {
                                        HapticFeedback.selectionClick();
                                        Navigator.of(context).pop();
                                        widget.onSelectDevice(device);
                                      },
                                    ),
                                    const SizedBox(height: 7),
                                  ],
                                const SizedBox(height: 6),
                                _CastRowTile(
                                  key: const Key('ios-cast-manual-ip-row'),
                                  icon: CupertinoIcons.add_circled_solid,
                                  accent: AppleColors.systemTeal,
                                  title: '手动输入电视 IP 连接',
                                  subtitle: '免组播直连 Marco Movie TV 或任意 DLNA 电视',
                                  reduceMotion: reduceMotion,
                                  cornerRadius: _innerRadiusPt,
                                  trailing: const Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 14,
                                    color: Colors.white54,
                                  ),
                                  onTap: () async {
                                    HapticFeedback.selectionClick();
                                    final input =
                                        await _promptManualTvAddress(context);
                                    if (input == null ||
                                        input.trim().isEmpty) {
                                      return;
                                    }
                                    final dev = await controller
                                        .probeManualTarget(input);
                                    if (dev != null && context.mounted) {
                                      Navigator.of(context).pop();
                                      await widget.onSelectDevice(dev);
                                    }
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.expand(),
          ),
        ),
        SafeArea(
          minimum: EdgeInsets.fromLTRB(
            _outerInsetPt,
            _outerInsetPt,
            _outerInsetPt,
            _outerInsetPt,
          ),
          child: Align(
            alignment: isWide ? Alignment.center : Alignment.bottomCenter,
            child: AnimatedBuilder(
              animation: _dragOffsetCtrl,
              child: panel,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _dragOffsetCtrl.value),
                  child: child,
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

Future<String?> _promptManualTvAddress(BuildContext context) async {
  final textCtrl = TextEditingController();
  try {
    return await showCupertinoDialog<String>(
      context: context,
      builder: (dialogCtx) => CupertinoAlertDialog(
        title: const Text('手动连接局域网电视'),
        content: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '输入电视局域网 IP（如 10.0.0.88 或电视端显示的 IP:端口）',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              CupertinoTextField(
                key: const Key('ios-cast-manual-ip-field'),
                controller: textCtrl,
                autofocus: true,
                keyboardType: TextInputType.url,
                placeholder: '电视局域网 IP 或 IP:18652',
                clearButtonMode: OverlayVisibilityMode.editing,
                onSubmitted: (v) => Navigator.of(dialogCtx).pop(v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogCtx).pop(textCtrl.text.trim()),
            child: const Text('探测并投屏'),
          ),
        ],
      ),
    );
  } finally {
    textCtrl.dispose();
  }
}

class _Ios27CastSpringButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool reduceMotion;

  const _Ios27CastSpringButton({
    super.key,
    required this.child,
    required this.onTap,
    this.reduceMotion = false,
  });

  @override
  State<_Ios27CastSpringButton> createState() => _Ios27CastSpringButtonState();
}

class _Ios27CastSpringButtonState extends State<_Ios27CastSpringButton>
    with SingleTickerProviderStateMixin {
  static final SpringDescription _snappy = SpringDescription.withDampingRatio(
    mass: 1.0,
    stiffness: (2 * math.pi / 0.28) * (2 * math.pi / 0.28),
    ratio: 0.88,
  );

  late final AnimationController _ctrl = AnimationController.unbounded(
    vsync: this,
    value: 0.0,
  );

  void _drive(double target) {
    if (widget.reduceMotion || widget.onTap == null) {
      _ctrl.stop();
      _ctrl.value = 0.0;
      return;
    }
    _ctrl.animateWith(
      SpringSimulation(_snappy, _ctrl.value, target, _ctrl.velocity),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap != null ? (_) => _drive(1.0) : null,
      onTapUp: widget.onTap != null ? (_) => _drive(0.0) : null,
      onTapCancel: widget.onTap != null ? () => _drive(0.0) : null,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _ctrl,
        child: widget.child,
        builder: (context, child) {
          final scale = widget.reduceMotion
              ? 1.0
              : (1.0 + 0.032 * _ctrl.value.clamp(0.0, 1.3));
          return Transform.scale(scale: scale, child: child);
        },
      ),
    );
  }
}

class _CastRowTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final String? badgeText;
  final Widget trailing;
  final bool selected;
  final bool reduceMotion;
  final double cornerRadius;
  final VoidCallback onTap;

  const _CastRowTile({
    super.key,
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    this.badgeText,
    required this.trailing,
    this.selected = false,
    this.reduceMotion = false,
    this.cornerRadius = 16.0,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final innerIconRadius = math.max(cornerRadius - 6.0, 8.0);
    return _Ios27CastSpringButton(
      reduceMotion: reduceMotion,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: ShapeDecoration(
          color: selected
              ? AppleColors.systemBlue.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.08),
          shape: ContinuousRectangleBorder(
            borderRadius: BorderRadius.circular(cornerRadius),
            side: BorderSide(
              color: selected
                  ? AppleColors.systemBlue.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.12),
              width: 0.8,
            ),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: ShapeDecoration(
                color: accent.withValues(alpha: 0.18),
                shape: ContinuousRectangleBorder(
                  borderRadius: BorderRadius.circular(innerIconRadius),
                ),
              ),
              child: Icon(icon, size: 18, color: accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (badgeText != null && badgeText!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5.5,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            badgeText!,
                            style: TextStyle(
                              color: accent == Colors.white
                                  ? Colors.white70
                                  : AppleColors.systemCyan,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// iOS 27 Spatial Cinema / Apple TV Remote-style active casting remote control stage.
class IosCastingRemoteStage extends StatefulWidget {
  final CastController controller;
  final String episodeLabel;
  final String? posterUrl;
  final VoidCallback onBack;
  final VoidCallback onSwitchDevice;
  final VoidCallback onExitCast;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onOpenEpisodes;
  final VoidCallback? onOpenLines;
  final bool compact;
  final bool halfScreen;

  const IosCastingRemoteStage({
    super.key,
    required this.controller,
    required this.episodeLabel,
    this.posterUrl,
    required this.onBack,
    required this.onSwitchDevice,
    required this.onExitCast,
    this.onPreviousEpisode,
    this.onNextEpisode,
    this.onOpenEpisodes,
    this.onOpenLines,
    this.compact = false,
    this.halfScreen = false,
  });

  @override
  State<IosCastingRemoteStage> createState() => _IosCastingRemoteStageState();
}

class _IosCastingRemoteStageState extends State<IosCastingRemoteStage> {
  static const List<double> _speedOptions = [0.75, 1.0, 1.25, 1.5, 2.0];

  double? _draggingProgress;

  String _fmt(Duration d) {
    final s = d.inSeconds.clamp(0, 359999);
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${sToPad(sec)}';
    }
    return '${m.toString().padLeft(2, '0')}:${sToPad(sec)}';
  }

  String sToPad(int v) => v.toString().padLeft(2, '0');

  String _formatSpeedLabel(double speed) {
    if ((speed - speed.roundToDouble()).abs() < 0.001) {
      return '${speed.toStringAsFixed(1)}x';
    }
    return '${speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '')}x';
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final device = controller.activeDevice;
        final isPlaying = controller.state == CastSessionState.playing;
        final isConnecting = controller.state == CastSessionState.connecting;
        final durMs = controller.duration.inMilliseconds.clamp(1, 1 << 31);
        final posMs = controller.position.inMilliseconds.clamp(0, durMs);
        final liveProgress = (posMs / durMs).clamp(0.0, 1.0);
        final sliderProgress = (_draggingProgress ?? liveProgress).clamp(0.0, 1.0);
        final displayPos = _draggingProgress != null && controller.duration > Duration.zero
            ? Duration(
                milliseconds: (controller.duration.inMilliseconds * sliderProgress).round(),
              )
            : controller.position;

        final poster = widget.posterUrl?.trim() ?? '';

        return LayoutBuilder(
          builder: (context, constraints) {
            final availH = constraints.maxHeight;
            final expandedRemote = widget.halfScreen || (!widget.compact && availH >= 320);
            final tight = availH < 345;
            final centerSize = expandedRemote ? (tight ? 58.0 : 66.0) : (widget.compact ? 50.0 : 60.0);
            final sideBtnSize = expandedRemote ? (tight ? 42.0 : 46.0) : 40.0;

            return ClipRect(
              child: Container(
                key: const Key('ios-casting-remote-stage'),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF131B2E),
                      Color(0xFF0C101B),
                      Color(0xFF070A11),
                    ],
                  ),
                  border: widget.halfScreen
                      ? Border(
                          bottom: BorderSide(
                            color: Colors.white.withValues(alpha: 0.12),
                            width: 0.7,
                          ),
                        )
                      : null,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (poster.isNotEmpty)
                      Positioned.fill(
                        child: Opacity(
                          opacity: 0.22,
                          child: ImageFiltered(
                            imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                            child: PosterImage(
                              url: poster,
                              fit: BoxFit.cover,
                              placeholder: const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              const Color(0xFF0E1424).withValues(alpha: 0.72),
                              const Color(0xFF0A0E18).withValues(alpha: 0.86),
                              const Color(0xFF070910).withValues(alpha: 0.96),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SafeArea(
                      top: !widget.halfScreen,
                      bottom: !widget.compact && !widget.halfScreen,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: expandedRemote ? 18 : (widget.compact ? 14 : 24),
                          vertical: expandedRemote ? (tight ? 10 : 14) : (widget.compact ? 8 : 14),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // 1. Top header: Back + Casting Status + Switch Device / Exit
                            Row(
                              children: [
                                _Ios27CastSpringButton(
                                  reduceMotion: reduceMotion,
                                  onTap: widget.onBack,
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.12),
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.16),
                                        width: 0.7,
                                      ),
                                    ),
                                    child: const Icon(
                                      CupertinoIcons.chevron_back,
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 7,
                                            height: 7,
                                            decoration: BoxDecoration(
                                              color: isConnecting
                                                  ? AppleColors.systemOrange
                                                  : AppleColors.systemGreen,
                                              shape: BoxShape.circle,
                                              boxShadow: [
                                                BoxShadow(
                                                  color: (isConnecting
                                                          ? AppleColors.systemOrange
                                                          : AppleColors.systemGreen)
                                                      .withValues(alpha: 0.6),
                                                  blurRadius: 6,
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              isConnecting
                                                  ? '正在连接 ${device?.name ?? "电视"}…'
                                                  : '正在投屏 · ${device?.name ?? "电视"}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (widget.episodeLabel.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 1.5),
                                          child: Text(
                                            widget.episodeLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white60,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _CastPillButton(
                                  key: const Key('ios-cast-switch-device'),
                                  label: '换设备',
                                  reduceMotion: reduceMotion,
                                  onTap: widget.onSwitchDevice,
                                ),
                                const SizedBox(width: 6),
                                _CastPillButton(
                                  key: const Key('ios-cast-exit-button'),
                                  label: '退出投屏',
                                  danger: true,
                                  reduceMotion: reduceMotion,
                                  onTap: widget.onExitCast,
                                ),
                              ],
                            ),

                            // 2. Main Remote Transport Deck
                            Padding(
                              padding: EdgeInsets.symmetric(
                                vertical: expandedRemote ? (tight ? 2 : 6) : 0,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (expandedRemote)
                                    _RemoteCircleBtn(
                                      key: const Key('ios-cast-prev-episode'),
                                      icon: CupertinoIcons.backward_end_fill,
                                      label: '上一集',
                                      size: sideBtnSize,
                                      enabled: widget.onPreviousEpisode != null,
                                      reduceMotion: reduceMotion,
                                      onTap: widget.onPreviousEpisode ?? () {},
                                    )
                                  else
                                    _RemoteCircleBtn(
                                      icon: CupertinoIcons.speaker_1_fill,
                                      label: '音量-',
                                      size: sideBtnSize,
                                      reduceMotion: reduceMotion,
                                      onTap: () => controller.adjustVolume(-8),
                                    ),
                                  _RemoteCircleBtn(
                                    key: const Key('ios-cast-seek-back'),
                                    icon: CupertinoIcons.gobackward_15,
                                    label: '快退15s',
                                    size: sideBtnSize,
                                    reduceMotion: reduceMotion,
                                    onTap: () => controller.seek(
                                      controller.position - const Duration(seconds: 15),
                                    ),
                                  ),
                                  _Ios27CastSpringButton(
                                    key: const Key('ios-cast-play-pause'),
                                    reduceMotion: reduceMotion,
                                    onTap: () {
                                      HapticFeedback.mediumImpact();
                                      controller.togglePlayPause();
                                    },
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: centerSize,
                                          height: centerSize,
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                AppleColors.systemBlue,
                                                AppleColors.systemBlue.withValues(alpha: 0.78),
                                              ],
                                            ),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white.withValues(alpha: 0.28),
                                              width: 1.0,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: AppleColors.systemBlue
                                                    .withValues(alpha: 0.42),
                                                blurRadius: 20,
                                                spreadRadius: 1,
                                              ),
                                            ],
                                          ),
                                          child: Icon(
                                            isPlaying
                                                ? CupertinoIcons.pause_fill
                                                : CupertinoIcons.play_fill,
                                            color: Colors.white,
                                            size: expandedRemote ? 30 : 24,
                                          ),
                                        ),
                                        if (expandedRemote) ...[
                                          const SizedBox(height: 5),
                                          Text(
                                            isPlaying ? '暂停' : '播放',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  _RemoteCircleBtn(
                                    key: const Key('ios-cast-seek-forward'),
                                    icon: CupertinoIcons.goforward_15,
                                    label: '快进15s',
                                    size: sideBtnSize,
                                    reduceMotion: reduceMotion,
                                    onTap: () => controller.seek(
                                      controller.position + const Duration(seconds: 15),
                                    ),
                                  ),
                                  if (expandedRemote)
                                    _RemoteCircleBtn(
                                      key: const Key('ios-cast-next-episode'),
                                      icon: CupertinoIcons.forward_end_fill,
                                      label: '下一集',
                                      size: sideBtnSize,
                                      enabled: widget.onNextEpisode != null,
                                      reduceMotion: reduceMotion,
                                      onTap: widget.onNextEpisode ?? () {},
                                    )
                                  else
                                    _RemoteCircleBtn(
                                      icon: CupertinoIcons.speaker_3_fill,
                                      label: '音量+',
                                      size: sideBtnSize,
                                      reduceMotion: reduceMotion,
                                      onTap: () => controller.adjustVolume(8),
                                    ),
                                ],
                              ),
                            ),

                            // 3. Smooth Scrubber Progress Bar
                            Row(
                              children: [
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    _fmt(displayPos),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w500,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: expandedRemote ? 5.0 : 3.5,
                                      thumbShape: RoundSliderThumbShape(
                                        enabledThumbRadius: expandedRemote ? 7.5 : 6,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 15,
                                      ),
                                      activeTrackColor: AppleColors.systemBlue,
                                      inactiveTrackColor:
                                          Colors.white.withValues(alpha: 0.2),
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      key: const Key('ios-cast-progress-slider'),
                                      value: sliderProgress,
                                      onChangeStart: (v) {
                                        setState(() => _draggingProgress = v);
                                      },
                                      onChanged: (v) {
                                        setState(() => _draggingProgress = v);
                                      },
                                      onChangeEnd: (v) {
                                        setState(() => _draggingProgress = null);
                                        if (controller.duration > Duration.zero) {
                                          controller.seek(
                                            Duration(
                                              milliseconds:
                                                  (controller.duration.inMilliseconds * v)
                                                      .round(),
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    _fmt(controller.duration),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11.5,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            // 4. Playback Speed Strip (`0.75x / 1.0x / 1.25x / 1.5x / 2.0x`)
                            if (expandedRemote)
                              Container(
                                key: const Key('ios-cast-speed-strip'),
                                padding: const EdgeInsets.all(3.5),
                                decoration: ShapeDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  shape: ContinuousRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    side: BorderSide(
                                      color: Colors.white.withValues(alpha: 0.11),
                                      width: 0.7,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.symmetric(horizontal: 9),
                                      child: Text(
                                        '倍速',
                                        style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    for (final s in _speedOptions)
                                      Expanded(
                                        child: GestureDetector(
                                          key: Key(
                                            'ios-cast-speed-${_formatSpeedLabel(s)}',
                                          ),
                                          onTap: () {
                                            HapticFeedback.selectionClick();
                                            controller.setSpeed(s);
                                          },
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 180),
                                            padding: const EdgeInsets.symmetric(vertical: 6.5),
                                            decoration: ShapeDecoration(
                                              color: (controller.speed - s).abs() < 0.01
                                                  ? AppleColors.systemBlue
                                                  : Colors.transparent,
                                              shape: ContinuousRectangleBorder(
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                            ),
                                            child: Text(
                                              _formatSpeedLabel(s),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                color: (controller.speed - s).abs() < 0.01
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontSize: 11.5,
                                                fontWeight: (controller.speed - s).abs() < 0.01
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                            // 5. Bottom Remote Utility Bar: TV Volume Rocker + Quick Episodes / Lines
                            if (expandedRemote)
                              Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      key: const Key('ios-cast-volume-capsule'),
                                      height: 38,
                                      decoration: ShapeDecoration(
                                        color: Colors.white.withValues(alpha: 0.09),
                                        shape: ContinuousRectangleBorder(
                                          borderRadius: BorderRadius.circular(15),
                                          side: BorderSide(
                                            color: Colors.white.withValues(alpha: 0.12),
                                            width: 0.7,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: GestureDetector(
                                              key: const Key('ios-cast-vol-down'),
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                controller.adjustVolume(-8);
                                              },
                                              child: const Center(
                                                child: Icon(
                                                  CupertinoIcons.speaker_1_fill,
                                                  color: Colors.white70,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 0.6,
                                            height: 18,
                                            color: Colors.white.withValues(alpha: 0.14),
                                          ),
                                          Expanded(
                                            flex: 2,
                                            child: GestureDetector(
                                              key: const Key('ios-cast-mute-toggle'),
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                controller.toggleMute();
                                              },
                                              child: Row(
                                                mainAxisAlignment: MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    controller.muted
                                                        ? CupertinoIcons.speaker_slash_fill
                                                        : CupertinoIcons.speaker_2_fill,
                                                    color: controller.muted
                                                        ? AppleColors.systemOrange
                                                        : Colors.white70,
                                                    size: 14,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    controller.muted
                                                        ? '已静音'
                                                        : '${controller.volume}%',
                                                    style: TextStyle(
                                                      color: controller.muted
                                                          ? AppleColors.systemOrange
                                                          : Colors.white70,
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.w600,
                                                      fontFeatures: const [
                                                        FontFeature.tabularFigures(),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          Container(
                                            width: 0.6,
                                            height: 18,
                                            color: Colors.white.withValues(alpha: 0.14),
                                          ),
                                          Expanded(
                                            child: GestureDetector(
                                              key: const Key('ios-cast-vol-up'),
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                controller.adjustVolume(8);
                                              },
                                              child: const Center(
                                                child: Icon(
                                                  CupertinoIcons.speaker_3_fill,
                                                  color: Colors.white70,
                                                  size: 16,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  if (widget.onOpenEpisodes != null) ...[
                                    const SizedBox(width: 8),
                                    _RemoteActionChip(
                                      key: const Key('ios-cast-open-episodes'),
                                      icon: CupertinoIcons.square_grid_2x2_fill,
                                      label: '选集',
                                      reduceMotion: reduceMotion,
                                      onTap: widget.onOpenEpisodes!,
                                    ),
                                  ],
                                  if (widget.onOpenLines != null) ...[
                                    const SizedBox(width: 8),
                                    _RemoteActionChip(
                                      key: const Key('ios-cast-open-lines'),
                                      icon: CupertinoIcons.layers_alt_fill,
                                      label: '换线路',
                                      reduceMotion: reduceMotion,
                                      onTap: widget.onOpenLines!,
                                    ),
                                  ],
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _RemoteActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool reduceMotion;
  final VoidCallback onTap;

  const _RemoteActionChip({
    super.key,
    required this.icon,
    required this.label,
    this.reduceMotion = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _Ios27CastSpringButton(
      reduceMotion: reduceMotion,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: ShapeDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          shape: ContinuousRectangleBorder(
            borderRadius: BorderRadius.circular(15),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.14),
              width: 0.7,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CastPillButton extends StatelessWidget {
  final String label;
  final bool danger;
  final bool reduceMotion;
  final VoidCallback onTap;

  const _CastPillButton({
    super.key,
    required this.label,
    this.danger = false,
    this.reduceMotion = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _Ios27CastSpringButton(
      reduceMotion: reduceMotion,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: danger
              ? AppleColors.systemRed.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: danger
                ? AppleColors.systemRed.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.18),
            width: 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: danger ? const Color(0xFFFF8E88) : Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _RemoteCircleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final double size;
  final bool enabled;
  final bool reduceMotion;
  final VoidCallback onTap;

  const _RemoteCircleBtn({
    super.key,
    required this.icon,
    required this.label,
    this.size = 42,
    this.enabled = true,
    this.reduceMotion = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _Ios27CastSpringButton(
      reduceMotion: reduceMotion,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.34,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.11),
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.15),
                  width: 0.8,
                ),
              ),
              child: Icon(icon, color: Colors.white, size: size * 0.44),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
