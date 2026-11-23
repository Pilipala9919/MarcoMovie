import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// A wrapper for horizontal scrollable widgets on desktop platforms.
///
/// Features:
/// 1. Mouse wheel mapping: Translates vertical wheel scrolls (`dy`) to horizontal
///    list scrolling when the list has room to scroll in that direction. If the
///    list has reached its boundary in the scroll direction, the event is NOT
///    registered with [GestureBinding.pointerSignalResolver], allowing outer
///    vertical scrollables to receive vertical wheel scrolling.
/// 2. Hover navigation arrows: Displays semi-transparent chevron buttons on hover
///    to scroll forward or backward by [arrowStep] (default 80% viewport width).
/// 3. Non-desktop pass-through: On non-desktop platforms (iOS, Android, Web),
///    returns [child] directly with zero overhead.
class DesktopHorizontalScroller extends StatefulWidget {
  final ScrollController? controller;
  final Widget child;
  final bool showArrows;
  final double? arrowStep;

  const DesktopHorizontalScroller({
    super.key,
    this.controller,
    required this.child,
    this.showArrows = true,
    this.arrowStep,
  });

  @override
  State<DesktopHorizontalScroller> createState() =>
      _DesktopHorizontalScrollerState();
}

class _DesktopHorizontalScrollerState extends State<DesktopHorizontalScroller> {
  ScrollController? _internalController;
  bool _isHovered = false;
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  bool get _isDesktop {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  ScrollController get _effectiveController {
    if (widget.controller != null) return widget.controller!;
    if (_internalController == null) {
      _internalController = ScrollController();
      _internalController!.addListener(_onScroll);
    }
    return _internalController!;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateScrollMetrics();
    });
  }

  @override
  void didUpdateWidget(covariant DesktopHorizontalScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onScroll);
      widget.controller?.addListener(_onScroll);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateScrollMetrics();
      });
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onScroll);
    _internalController?.dispose();
    super.dispose();
  }

  void _onScroll() {
    _updateScrollMetrics();
  }

  void _updateScrollMetrics() {
    if (!_effectiveController.hasClients) return;
    final pos = _effectiveController.position;
    final canLeft = pos.pixels > pos.minScrollExtent + 0.5;
    final canRight = pos.pixels < pos.maxScrollExtent - 0.5;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      if (mounted) {
        setState(() {
          _canScrollLeft = canLeft;
          _canScrollRight = canRight;
        });
      }
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent &&
        event.scrollDelta.dx.abs() < 0.001 &&
        event.scrollDelta.dy != 0) {
      if (!_effectiveController.hasClients) return;
      final pos = _effectiveController.position;
      final dy = event.scrollDelta.dy;
      final canScrollForward = dy > 0 && pos.pixels < pos.maxScrollExtent;
      final canScrollBackward = dy < 0 && pos.pixels > pos.minScrollExtent;

      if (canScrollForward || canScrollBackward) {
        GestureBinding.instance.pointerSignalResolver.register(event,
            (PointerSignalEvent resolved) {
          if (resolved is PointerScrollEvent &&
              _effectiveController.hasClients) {
            final currentPos = _effectiveController.position;
            final newOffset = (currentPos.pixels + resolved.scrollDelta.dy)
                .clamp(currentPos.minScrollExtent, currentPos.maxScrollExtent);
            if (newOffset != currentPos.pixels) {
              _effectiveController.jumpTo(newOffset);
            }
          }
        });
      }
    }
  }

  void _scrollByStep({required bool isLeft}) {
    if (!_effectiveController.hasClients) return;
    final pos = _effectiveController.position;
    final step = widget.arrowStep ?? (pos.viewportDimension * 0.8);
    final target = isLeft
        ? (_effectiveController.offset - step)
        : (_effectiveController.offset + step);
    final clamped = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _effectiveController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildArrow({required bool isLeft}) {
    return GestureDetector(
      key: isLeft
          ? const ValueKey('desktop_scroll_left_arrow')
          : const ValueKey('desktop_scroll_right_arrow'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _scrollByStep(isLeft: isLeft),
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: const Color(0xB31C1C1E),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x33FFFFFF), width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(
          isLeft ? CupertinoIcons.chevron_left : CupertinoIcons.chevron_right,
          size: 14,
          color: const Color(0xE6FFFFFF),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) {
      return widget.child;
    }

    final behavior = ScrollConfiguration.of(context);
    final draggableChild = behavior.dragDevices.contains(PointerDeviceKind.mouse)
        ? widget.child
        : ScrollConfiguration(
            behavior: behavior.copyWith(
              dragDevices: <PointerDeviceKind>{
                ...behavior.dragDevices,
                PointerDeviceKind.mouse,
              },
            ),
            child: widget.child,
          );

    final content = Listener(
      onPointerSignal: _handlePointerSignal,
      child: draggableChild,
    );

    return MouseRegion(
      onEnter: (_) {
        if (!_isHovered) {
          setState(() => _isHovered = true);
        }
        _updateScrollMetrics();
      },
      onHover: (_) => _updateScrollMetrics(),
      onExit: (_) {
        if (_isHovered) {
          setState(() => _isHovered = false);
        }
      },
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerLeft,
        children: [
          content,
          if (widget.showArrows && _isHovered) ...[
            if (_canScrollLeft)
              Positioned(
                left: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildArrow(isLeft: true),
                ),
              ),
            if (_canScrollRight)
              Positioned(
                right: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _buildArrow(isLeft: false),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
