import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'apple_theme.dart';

/// Immersive Windows 11 caption overlay that hides the legacy Win32 gray title
/// bar while letting full-bleed ambient backgrounds, hero posters, and video
/// surfaces extend seamlessly to `y = 0`.
class WindowsImmersiveFrame extends StatefulWidget {
  static const double titleBarHeight = 32.0;

  /// True while [PlayerScreen] has screen-lock active so window caption buttons
  /// and drag-to-move regions cannot be triggered accidentally.
  static final ValueNotifier<bool> interactionLocked = ValueNotifier<bool>(
    false,
  );

  final Widget child;
  final bool attachWindowListener;

  const WindowsImmersiveFrame({
    super.key,
    required this.child,
    this.attachWindowListener = true,
  });

  @override
  State<WindowsImmersiveFrame> createState() => _WindowsImmersiveFrameState();
}

class _WindowsImmersiveFrameState extends State<WindowsImmersiveFrame>
    with WindowListener {
  bool _isFullScreen = false;
  bool _isMaximized = false;
  bool _isFocused = true;

  @override
  void initState() {
    super.initState();
    if (widget.attachWindowListener) {
      windowManager.addListener(this);
      unawaited(_syncWindowState());
    }
  }

  Future<void> _syncWindowState() async {
    try {
      final full = await windowManager.isFullScreen();
      final max = await windowManager.isMaximized();
      if (!mounted) return;
      if (full != _isFullScreen || max != _isMaximized) {
        setState(() {
          _isFullScreen = full;
          _isMaximized = max;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    if (widget.attachWindowListener) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted && !_isFullScreen) setState(() => _isFullScreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted && _isFullScreen) setState(() => _isFullScreen = false);
    unawaited(_syncWindowState());
  }

  @override
  void onWindowMaximize() {
    if (mounted && !_isMaximized) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted && _isMaximized) setState(() => _isMaximized = false);
  }

  @override
  void onWindowFocus() {
    if (mounted && !_isFocused) setState(() => _isFocused = true);
  }

  @override
  void onWindowBlur() {
    if (mounted && _isFocused) setState(() => _isFocused = false);
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
        if (mounted) setState(() => _isMaximized = false);
      } else {
        await windowManager.maximize();
        if (mounted) setState(() => _isMaximized = true);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final topInset = _isFullScreen
        ? mq.padding.top
        : math.max(mq.padding.top, WindowsImmersiveFrame.titleBarHeight);
    final topViewPadding = _isFullScreen
        ? mq.viewPadding.top
        : math.max(mq.viewPadding.top, WindowsImmersiveFrame.titleBarHeight);

    return Stack(
      fit: StackFit.expand,
      children: [
        MediaQuery(
          data: mq.copyWith(
            padding: mq.padding.copyWith(top: topInset),
            viewPadding: mq.viewPadding.copyWith(top: topViewPadding),
          ),
          child: widget.child,
        ),
        if (!_isFullScreen)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: WindowsImmersiveFrame.titleBarHeight,
            child: ValueListenableBuilder<bool>(
              valueListenable: WindowsImmersiveFrame.interactionLocked,
              builder: (context, locked, titleBar) => IgnorePointer(
                ignoring: locked,
                child: AnimatedOpacity(
                  opacity: locked ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 160),
                  child: titleBar,
                ),
              ),
              child: WindowsTitleBar(
                isMaximized: _isMaximized,
                isFocused: _isFocused,
                onMinimize: () => unawaited(windowManager.minimize()),
                onToggleMaximize: _toggleMaximize,
                onClose: () => unawaited(windowManager.close()),
              ),
            ),
          ),
      ],
    );
  }
}

class WindowsTitleBar extends StatelessWidget {
  final bool isMaximized;
  final bool isFocused;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;

  const WindowsTitleBar({
    super.key,
    required this.isMaximized,
    required this.isFocused,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        key: const ValueKey('windows-immersive-title-bar'),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0x5806070A),
              Color(0x0006070A),
            ],
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: DragToMoveArea(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Opacity(
                      opacity: isFocused ? 0.78 : 0.45,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MarcoBrandLogo(iconSize: 15, showWordmark: false),
                          SizedBox(width: 7),
                          Text(
                            'Marco Movie',
                            style: TextStyle(
                              color: Color(0xFFE5E7EB),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _WindowsCaptionButton(
              key: const ValueKey('win-titlebar-minimize'),
              tooltip: '最小化',
              onTap: onMinimize,
              icon: CupertinoIcons.minus,
              iconSize: 13,
            ),
            _WindowsCaptionButton(
              key: const ValueKey('win-titlebar-maximize'),
              tooltip: isMaximized ? '向下还原' : '最大化',
              onTap: onToggleMaximize,
              icon: isMaximized
                  ? CupertinoIcons.uiwindow_split_2x1
                  : CupertinoIcons.square,
              iconSize: 12,
            ),
            _WindowsCaptionButton(
              key: const ValueKey('win-titlebar-close'),
              tooltip: '关闭',
              isClose: true,
              onTap: onClose,
              icon: CupertinoIcons.xmark,
              iconSize: 13,
            ),
          ],
        ),
      ),
    );
  }
}

class _WindowsCaptionButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final bool isClose;
  final VoidCallback onTap;

  const _WindowsCaptionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.iconSize,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WindowsCaptionButton> createState() => _WindowsCaptionButtonState();
}

class _WindowsCaptionButtonState extends State<_WindowsCaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    if (_pressed) {
      bg = widget.isClose ? const Color(0xFFC50F1F) : const Color(0x2EFFFFFF);
    } else if (_hovered) {
      bg = widget.isClose ? const Color(0xFFE81123) : const Color(0x1FFFFFFF);
    } else {
      bg = Colors.transparent;
    }

    final buttonBox = AnimatedContainer(
      duration: const Duration(milliseconds: 110),
      width: 46,
      height: WindowsImmersiveFrame.titleBarHeight,
      color: bg,
      alignment: Alignment.center,
      child: Icon(
        widget.icon,
        size: widget.iconSize,
        color: (_hovered && widget.isClose)
            ? Colors.white
            : const Color(0xD8FFFFFF),
      ),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Overlay.maybeOf(context) != null
            ? Tooltip(
                message: widget.tooltip,
                waitDuration: const Duration(milliseconds: 600),
                child: buttonBox,
              )
            : buttonBox,
      ),
    );
  }
}
