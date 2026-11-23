import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';
import '../core/ohos_runtime.dart';
import 'ios_liquid_glass.dart';
import 'motion/aurora_background.dart';
import 'motion/ios27_springs.dart';
import 'motion/motion_tokens.dart';
import 'windows_appearance.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get isWindowsDesktopUi =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

bool get _isWindowsDesktop => isWindowsDesktopUi;

/// Lightweight, single-layer desktop page transition for Windows ANGLE/D3D11:
/// avoids `CupertinoPageRoute`'s 500ms dual-page full-screen parallax + shadow
/// composite, animating only the incoming page in 185ms inside a [RepaintBoundary].
class WindowsSmoothPageTransitionsBuilder extends PageTransitionsBuilder {
  const WindowsSmoothPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (animation.status == AnimationStatus.completed &&
        !secondaryAnimation.isAnimating) {
      return child;
    }
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final beginOffset = route.fullscreenDialog
        ? const Offset(0.0, 0.024)
        : const Offset(0.016, 0.0);
    return RepaintBoundary(
      child: FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: beginOffset,
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ),
    );
  }
}

/// Platform-adaptive route builder: uses [Ios27PageRoute] (second-order
/// `Ios27Spring.smooth` physics & swipe-back velocity inheritance, preserving
/// [CupertinoPageTransition]) on iOS / iPadOS / macOS, preserves
/// [CupertinoPageRoute] on Android / HarmonyOS, and uses the crisp 185ms
/// GPU-friendly transition on Windows.
PageRoute<T> buildApplePageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
  bool maintainState = true,
}) {
  if (!isWindowsDesktopUi) {
    final isApple = !OhosRuntime.isOhos &&
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (isApple) {
      return Ios27PageRoute<T>(
        builder: builder,
        settings: settings,
        fullscreenDialog: fullscreenDialog,
        maintainState: maintainState,
      );
    }
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      fullscreenDialog: fullscreenDialog,
      maintainState: maintainState,
    );
  }
  return PageRouteBuilder<T>(
    settings: settings,
    fullscreenDialog: fullscreenDialog,
    maintainState: maintainState,
    opaque: true,
    transitionDuration: const Duration(milliseconds: 185),
    reverseTransitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (context, _, __) => builder(context),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return const WindowsSmoothPageTransitionsBuilder().buildTransitions<T>(
        ModalRoute.of(context)! as PageRoute<T>,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    },
  );
}

/// iOS 27 spring-physics [CupertinoPageRoute] driven by [Ios27Spring.smooth]
/// with velocity-inherited left-edge swipe-back and Reduce Motion `150ms`
/// opacity fade fallback.
class Ios27PageRoute<T> extends CupertinoPageRoute<T> {
  bool _routeDisposed = false;

  Ios27PageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog = false,
    super.maintainState = true,
  });

  @override
  void dispose() {
    _routeDisposed = true;
    super.dispose();
  }

  @override
  Duration get transitionDuration => Ios27Spring.smooth.nominalDuration;

  @override
  Duration get reverseTransitionDuration => Ios27Spring.smooth.nominalDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Ios27ConcentricGeometry.isReduceMotion(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.linear,
          reverseCurve: Curves.linear,
        ),
        child: child,
      );
    }
    final isGesture = navigator?.userGestureInProgress ?? false;
    final springCurve = Ios27Spring.smooth.curve;
    final primaryAnim = isGesture
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: springCurve,
            reverseCurve: springCurve.flipped,
          );
    final secondaryAnim = CurvedAnimation(
      parent: secondaryAnimation,
      curve: springCurve,
      reverseCurve: springCurve.flipped,
    );
    final transition = CupertinoPageTransition(
      primaryRouteAnimation: primaryAnim,
      secondaryRouteAnimation: secondaryAnim,
      linearTransition: true,
      child: child,
    );
    if (fullscreenDialog || isFirst) {
      return transition;
    }
    return _Ios27SwipeBackWrapper<T>(
      route: this,
      child: transition,
    );
  }

  void _updateEdgeSwipeProgress(double value) {
    controller?.value = value.clamp(0.0, 1.0);
  }

  void _finishEdgeSwipeWithVelocity({
    required double velocityPxPerSec,
    required double width,
  }) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) return;
    final safeW = math.max(1.0, width);
    final releaseVal = ctrl.value.clamp(0.0, 1.0);
    final shouldPop = velocityPxPerSec > 360.0 || releaseVal < 0.62;
    final normalizedVel = (-velocityPxPerSec / safeW).clamp(-8.0, 8.0);
    if (shouldPop) {
      nav.pop();
      ctrl
          .animateWith(
            Ios27Spring.smooth.simulation(
              start: releaseVal,
              end: 0.0,
              velocity: normalizedVel,
            ),
          )
          .whenComplete(() {
        if (!_routeDisposed && ctrl.status != AnimationStatus.dismissed) {
          ctrl.reverse(from: 0.0);
        }
      });
    } else {
      ctrl.animateWith(
        Ios27Spring.smooth.simulation(
          start: releaseVal,
          end: 1.0,
          velocity: normalizedVel,
        ),
      );
    }
    nav.didStopUserGesture();
  }

  void _cancelEdgeSwipe() {
    final ctrl = controller;
    if (ctrl != null) {
      ctrl.animateWith(
        Ios27Spring.smooth.simulation(
          start: ctrl.value.clamp(0.0, 1.0),
          end: 1.0,
        ),
      );
    }
    navigator?.didStopUserGesture();
  }
}

class _Ios27SwipeBackWrapper<T> extends StatefulWidget {
  final Ios27PageRoute<T> route;
  final Widget child;

  const _Ios27SwipeBackWrapper({
    required this.route,
    required this.child,
  });

  @override
  State<_Ios27SwipeBackWrapper<T>> createState() =>
      _Ios27SwipeBackWrapperState<T>();
}

class _Ios27SwipeBackWrapperState<T> extends State<_Ios27SwipeBackWrapper<T>> {
  bool _dragging = false;
  double _dragDx = 0.0;

  @override
  void dispose() {
    if (_dragging) {
      _dragging = false;
      final nav = widget.route.navigator;
      if (nav != null && nav.userGestureInProgress) {
        nav.didStopUserGesture();
      }
    }
    super.dispose();
  }

  void _onDragStart(DragStartDetails details) {
    if (_dragging) return;
    final nav = widget.route.navigator;
    if (widget.route.isFirst ||
        !widget.route.isCurrent ||
        !widget.route.popGestureEnabled ||
        nav == null ||
        nav.userGestureInProgress) {
      return;
    }
    if (details.globalPosition.dx > 28.0) return;
    _dragging = true;
    _dragDx = 0.0;
    nav.didStartUserGesture();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final w = MediaQuery.sizeOf(context).width;
    if (w <= 0) return;
    _dragDx = (_dragDx + details.delta.dx).clamp(0.0, w);
    widget.route._updateEdgeSwipeProgress(1.0 - (_dragDx / w));
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    widget.route._finishEdgeSwipeWithVelocity(
      velocityPxPerSec: details.primaryVelocity ?? 0.0,
      width: MediaQuery.sizeOf(context).width,
    );
  }

  void _onDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    widget.route._cancelEdgeSwipe();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 24,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
          ),
        ),
      ],
    );
  }
}

/// Runtime theme mode controller supporting automatic system light/dark
/// appearance (`ThemeMode.system`) as well as explicit minimalist light
/// (`ThemeMode.light`) and dark night (`ThemeMode.dark`) modes.
class AppleTheme {
  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.system);

  static ThemeMode fromPref(String value) => switch (value.trim().toLowerCase()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String toPref(ThemeMode value) => switch (value) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };

  static String labelFor(String pref) => switch (pref.trim().toLowerCase()) {
        'light' => '简约白底',
        'dark' => '深色夜间',
        _ => '跟随系统',
      };
}

/// Resolved semantic color palette for the active Light (简约白底) or Dark
/// (夜间暗色) theme.
@immutable
class ApplePalette {
  final bool isDark;
  final Color background;
  final Color canvas;
  final Color groupedPrimary;
  final Color groupedSecondary;
  final Color groupedTertiary;
  final Color fill;
  final Color fillStrong;
  final Color labelPrimary;
  final Color labelSecondary;
  final Color labelTertiary;
  final Color separator;
  final Color glassBorder;
  final Color glassSolid;
  final Color systemBlue;

  const ApplePalette({
    required this.isDark,
    required this.background,
    required this.canvas,
    required this.groupedPrimary,
    required this.groupedSecondary,
    required this.groupedTertiary,
    required this.fill,
    required this.fillStrong,
    required this.labelPrimary,
    required this.labelSecondary,
    required this.labelTertiary,
    required this.separator,
    required this.glassBorder,
    required this.glassSolid,
    required this.systemBlue,
  });

  static const ApplePalette dark = ApplePalette(
    isDark: true,
    background: Color(0xFF000000),
    canvas: Color(0xFF09090C),
    groupedPrimary: Color(0xF51C1C1E),
    groupedSecondary: Color(0xBF28282E),
    groupedTertiary: Color(0xFF36363D),
    fill: Color(0x38787884),
    fillStrong: Color(0x59787884),
    labelPrimary: Color(0xFFF5F5F7),
    labelSecondary: Color(0xFFD1D1DA),
    labelTertiary: Color(0x66EBEBF5),
    separator: Color(0x29FFFFFF),
    glassBorder: Color(0x26FFFFFF),
    glassSolid: Color(0xF51E1E22),
    systemBlue: Color(0xFF0A84FF),
  );

  static const ApplePalette light = ApplePalette(
    isDark: false,
    background: Color(0xFFE9ECF2),
    canvas: Color(0xFFE9ECF2),
    groupedPrimary: Color(0xFFF8F9FC),
    groupedSecondary: Color(0xFFF0F2F7),
    groupedTertiary: Color(0xFFDFE3EC),
    fill: Color(0x18111318),
    fillStrong: Color(0x2B111318),
    labelPrimary: Color(0xFF141821),
    labelSecondary: Color(0xFF4B5362),
    labelTertiary: Color(0xFF767F90),
    separator: Color(0x1C000000),
    glassBorder: Color(0x18000000),
    glassSolid: Color(0xF5F7F8FC),
    systemBlue: Color(0xFF007AFF),
  );

  Color get accent => systemBlue;
  Color get hairline => separator;
  Color get navBarBg =>
      isDark ? const Color(0xCC161618) : const Color(0xE0EDF0F5);

  static bool isDarkOf(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark;
  }

  static ApplePalette of(BuildContext context) =>
      isDarkOf(context) ? dark : light;
}

/// Window-geometry classifier supporting standard iPhone, iPhone Duo (5.4" outer
/// `466×678 pt` portrait / `678×466 pt` landscape, 7.6" unfolded inner
/// `669×951 pt` portrait / `951×669 pt` landscape, and Split View `~320 pt`),
/// iPadOS, and desktop displays without device-model hardcoding.
class AppleViewportLayout {
  final Size size;

  const AppleViewportLayout(this.size);

  factory AppleViewportLayout.of(BuildContext context) =>
      AppleViewportLayout(MediaQuery.sizeOf(context));

  double get width => size.width;
  double get height => size.height;

  bool get isLandscape => width > height;

  /// Narrow Split View / Slide Over window (e.g. `~320 × 951 pt`).
  bool get isCompactSplit => width < 360;

  /// Shorter-than-standard portrait display such as iPhone Duo 5.4" outer
  /// cover (`466 × 678 pt`) or compact phones (`height < 730 pt`).
  bool get isShortPortrait => !isLandscape && height < 730;

  /// Compact landscape viewport such as iPhone Duo outer cover landscape
  /// (`678 × 466 pt`) or standard phone landscape (`height < 520 pt`).
  bool get isShortLandscape => isLandscape && height < 520;

  /// Wide unfolded portrait display such as iPhone Duo 7.6" inner display
  /// (`669 × 951 pt`) or iPad portrait (`width >= 580 pt`, `height >= width`).
  bool get isExpandedPortrait => !isLandscape && width >= 580;

  /// Wide landscape display (`678 × 466 pt`, `951 × 669 pt`, iPad, desktop).
  bool get isWideLandscape => isLandscape && width >= 600;

  /// Whether [DetailScreen] should use the side-by-side cinema showcase layout.
  bool get prefersWideDetail =>
      width >= 720 || (width >= 600 && isLandscape);

  /// Adaptive horizontal margin for content columns across all window sizes.
  double horizontalPadding({required bool useSidebar}) {
    if (useSidebar || isExpandedPortrait) return 24.0;
    if (isCompactSplit) return 12.0;
    return 16.0;
  }

  /// Adaptive poster card maximum cross-axis extent for catalog / library grids.
  double posterGridExtent({
    required bool useSidebar,
    String density = 'normal',
  }) {
    if (useSidebar) {
      return switch (density) {
        'comfortable' => 210.0,
        'compact' => 148.0,
        _ => 176.0,
      };
    }
    if (isExpandedPortrait) {
      return switch (density) {
        'comfortable' => 196.0,
        'compact' => 138.0,
        _ => 162.0,
      };
    }
    if (isCompactSplit) {
      return switch (density) {
        'comfortable' => 168.0,
        'compact' => 124.0,
        _ => 148.0,
      };
    }
    if (width >= 440) {
      // iPhone Duo 5.4" outer cover (`466pt`): keep crisp 3-column card sizing
      // matching standard iPhones rather than squeezing 4 narrow columns.
      return switch (density) {
        'comfortable' => 172.0,
        'compact' => 116.0,
        _ => 144.0,
      };
    }
    return switch (density) {
      'comfortable' => 162.0,
      'compact' => 108.0,
      _ => 132.0,
    };
  }

  /// Adaptive immersive hero height on iOS Home across cover, unfolded, Split
  /// View, and standard iPhone heights (proportioned so the first shelf & card
  /// row shine right on the initial fold above the floating Dock).
  double iosHomeHeroHeight(double maxH) {
    if (isShortPortrait) {
      return (maxH * 0.60).clamp(360.0, 455.0);
    }
    if (isExpandedPortrait) {
      return (maxH * 0.58).clamp(500.0, 580.0);
    }
    if (isCompactSplit) {
      return (maxH * 0.55).clamp(420.0, 510.0);
    }
    return (maxH * 0.64).clamp(500.0, 585.0);
  }
}

/// Apple iOS 27 Liquid Glass design tokens (iOS / iPadOS / macOS dark appearance):
/// deep obsidian canvas, refractive translucent glass materials, specular rims.
class AppleColors {
  static bool isDark(BuildContext context) => ApplePalette.isDarkOf(context);
  static ApplePalette palette(BuildContext context) => ApplePalette.of(context);
  static const Color background = Color(0xFF000000);
  static const Color canvas = Color(0xFF09090C);
  static const Color groupedPrimary = Color(0xA81C1C21);
  static const Color groupedSecondary = Color(0xBF28282E);
  static const Color groupedTertiary = Color(0xFF36363D);
  static const Color fill = Color(0x38787884);
  static const Color fillStrong = Color(0x59787884);
  static const Color systemBlue = Color(0xFF0A84FF);
  static const Color systemCyan = Color(0xFF64D2FF);
  static const Color systemTeal = Color(0xFF5AC8FA);
  static const Color systemIndigo = Color(0xFF5E5CE6);
  static const Color systemPurple = Color(0xFFBF5AF2);
  static const Color systemGreen = Color(0xFF30D158);
  static const Color systemOrange = Color(0xFFFF9F0A);
  static const Color systemRed = Color(0xFFFF453A);
  static const Color systemPink = Color(0xFFFF375F);
  static const Color labelPrimary = Color(0xFFF5F5F7);
  static const Color labelSecondary = Color(0xFFD1D1DA);
  static const Color labelTertiary = Color(0x52EBEBF5);
  static const Color separator = Color(0x29FFFFFF);
  static const Color glassBorder = Color(0x26FFFFFF);
  static const Color glassBorderStrong = Color(0x3BFFFFFF);
  static const Color glassHighlight = Color(0x52FFFFFF);
}

/// Brand logo widget rendering the metallic film-ribbon `M` mark
/// (`assets/logo_mark.png`) and the signature two-tone `Marco Movie` wordmark.
class MarcoBrandLogo extends StatelessWidget {
  final double iconSize;
  final double fontSize;
  final bool showWordmark;
  final bool stacked;
  final bool forceLightInk;
  const MarcoBrandLogo({
    super.key,
    this.iconSize = 32,
    this.fontSize = 17,
    this.showWordmark = true,
    this.stacked = false,
    this.forceLightInk = false,
  });
  @override
  Widget build(BuildContext context) {
    final iconWidget = SizedBox(
      width: iconSize,
      height: iconSize,
      child: Image.asset(
        'assets/logo_mark.png',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _FallbackLogoMark(size: iconSize),
      ),
    );
    if (!showWordmark) return iconWidget;
    final useLightInk = forceLightInk || ApplePalette.isDarkOf(context);
    final wordmark = Text.rich(
      TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          letterSpacing: -0.4,
          height: 1.1,
          shadows: forceLightInk
              ? const [
                  Shadow(
                    color: Color(0x88000000),
                    blurRadius: 8,
                    offset: Offset(0, 1),
                  ),
                ]
              : null,
        ),
        children: [
          TextSpan(
            text: 'Marco',
            style: TextStyle(
              color: useLightInk ? const Color(0xFFF8FAFC) : const Color(0xFF111114),
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: ' Movie',
            style: TextStyle(
              color: useLightInk ? const Color(0xFFD8E0EE) : const Color(0xFF63636C),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // The wordmark follows the explicitly sized logo, not body-text scaling.
      textScaler: TextScaler.noScaling,
    );
    if (stacked) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(height: 10),
          wordmark,
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        iconWidget,
        const SizedBox(width: 8),
        Flexible(child: wordmark),
      ],
    );
  }
}

class _FallbackLogoMark extends StatelessWidget {
  final double size;
  const _FallbackLogoMark({required this.size});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF282C33), Color(0xFF1D2025)],
        ),
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: Colors.white24, width: 0.8),
      ),
      alignment: Alignment.center,
      child: Text(
        'M',
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          color: const Color(0xFFE5E7EB),
          fontSize: size * 0.52,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

/// Saturation colour matrix used by the Liquid Glass backdrop so content seen
/// through the glass stays vivid instead of turning muddy grey after blurring.
List<double> _saturationMatrix(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final ir = (1 - s) * lr, ig = (1 - s) * lg, ib = (1 - s) * lb;
  return <double>[
    ir + s, ig, ib, 0, 0, //
    ir, ig + s, ib, 0, 0, //
    ir, ig, ib + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// Glasswork dark material filter, from glass.css: 2px blur, 160% saturation, 80% brightness.
ImageFilter liquidGlassFilter({double blur = 2, double saturation = 1.6, double brightness = .8}) {
  final matrix = _saturationMatrix(saturation);
  for (var i = 0; i < 15; i++) { matrix[i] *= brightness; }
  return ImageFilter.compose(
    outer: ColorFilter.matrix(matrix),
    inner: ImageFilter.blur(
      sigmaX: blur,
      sigmaY: blur,
      tileMode: TileMode.mirror,
    ),
  );
}

/// Specular rim of a Liquid Glass shape: bright light catching the top-left
/// edge, fading along the sides and a softer bounce light on the bottom-right,
/// plus a faint inner top glow that reads as glass thickness.
class _LiquidRimPainter extends CustomPainter {
  final ShapeBorder shape;
  final double strength;
  final bool lightMode;
  const _LiquidRimPainter({
    required this.shape,
    this.strength = 1.0,
    this.lightMode = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final outer = shape.getOuterPath(rect.deflate(0.5));
    final s = strength.clamp(0.0, 1.4);
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: lightMode
            ? [
                Colors.white.withValues(alpha: (0.85 * s).clamp(0.0, 1.0)),
                Colors.black.withValues(alpha: (0.08 * s).clamp(0.0, 0.25)),
                Colors.black.withValues(alpha: (0.12 * s).clamp(0.0, 0.28)),
                Colors.white.withValues(alpha: (0.65 * s).clamp(0.0, 1.0)),
              ]
            : [
                Colors.white.withValues(alpha: (0.54 * s).clamp(0.0, 1.0)),
                Colors.white.withValues(alpha: (0.16 * s).clamp(0.0, 1.0)),
                Colors.white.withValues(alpha: (0.06 * s).clamp(0.0, 1.0)),
                Colors.white.withValues(alpha: (0.24 * s).clamp(0.0, 1.0)),
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
        colors: lightMode
            ? [
                Colors.white.withValues(alpha: (0.72 * s).clamp(0.0, 1.0)),
                Colors.white.withValues(alpha: 0.0),
                Colors.black.withValues(alpha: (0.04 * s).clamp(0.0, 0.16)),
              ]
            : [
                Colors.white.withValues(alpha: (0.26 * s).clamp(0.0, 1.0)),
                Colors.white.withValues(alpha: 0.0),
                Colors.white.withValues(alpha: (0.08 * s).clamp(0.0, 1.0)),
              ],
        stops: const [0.0, 0.46, 1.0],
      ).createShader(rect);
    canvas.drawPath(inner, glow);
  }

  @override
  bool shouldRepaint(covariant _LiquidRimPainter old) =>
      old.shape != shape ||
      old.strength != strength ||
      old.lightMode != lightMode;
}

bool _isSystemReduceTransparencyActive() =>
    !OhosRuntime.isOhos && IosLiquidGlassBridge.reduceTransparency;

final Listenable _sharedReduceTransparencyListenable = Listenable.merge([
  GlassworkBackdrop.reduceTransparency,
  IosLiquidGlassBridge.reduceTransparencyNotifier,
]);

/// Native equivalent of Glasswork's clipped rim, with an inexpensive blur on
/// renderers that cannot sample the backdrop through a fragment shader.
class GlassworkBackdrop extends StatefulWidget {
  static final reduceTransparency = ValueNotifier<bool>(false);
  static final intensity = ValueNotifier<double>(0.68);
  final double radius;
  final Widget child;
  const GlassworkBackdrop({super.key, required this.radius, required this.child});
  @override
  State<GlassworkBackdrop> createState() => _GlassworkBackdropState();
}

class _GlassworkBackdropState extends State<GlassworkBackdrop> {
  static Future<FragmentProgram>? _program;
  FragmentShader? _shader;
  bool _loadingLens = false;
  late final Listenable _mergedListenable = Listenable.merge([
    GlassworkBackdrop.reduceTransparency,
    GlassworkBackdrop.intensity,
    IosLiquidGlassBridge.reduceTransparencyNotifier,
  ]);
  @override
  void initState() {
    super.initState();
    if (!_isWindowsDesktop &&
        !GlassworkBackdrop.reduceTransparency.value &&
        !_isSystemReduceTransparencyActive() &&
        ImageFilter.isShaderFilterSupported) {
      _loadLens();
    }
  }
  Future<void> _loadLens() async {
    if (_loadingLens) return;
    _loadingLens = true;
    try {
      final program = await (_program ??= FragmentProgram.fromAsset('shaders/glasswork.frag'));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Fallback is also used while the GPU program is being prepared.
    } finally {
      _loadingLens = false;
    }
  }
  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _mergedListenable,
      builder: (context, _) {
        final isDark = ApplePalette.isDarkOf(context);
        final reduce = GlassworkBackdrop.reduceTransparency.value ||
            _isSystemReduceTransparencyActive();
        final strength = GlassworkBackdrop.intensity.value.clamp(0.0, 1.0);
        final opaque = reduce ||
            strength <= 0.02 ||
            MediaQuery.highContrastOf(context) ||
            MediaQuery.disableAnimationsOf(context);
        final winFastGlass = _isWindowsDesktop;
        if (!opaque &&
            !winFastGlass &&
            isDark &&
            _shader == null &&
            !_loadingLens &&
            ImageFilter.isShaderFilterSupported) {
          _loadLens();
        }
        // Use true continuous optical blur + intensity-reactive translucency so
        // dragging the Liquid Glass slider from 0% to 100% produces an immediate,
        // clearly visible visual transformation in both Light and Dark themes.
        // The dark lens shader is reserved for high-strength dark mode (>= 0.85)
        // where its refractive rim shines without masking slider changes.
        final useLensShader =
            !winFastGlass && !opaque && isDark && _shader != null && strength >= 0.85;
        final shader = useLensShader ? _shader : null;
        if (shader != null) {
          shader.setFloat(2, widget.radius);
          shader.setFloat(
            3,
            MediaQuery.devicePixelRatioOf(context) * (0.45 + 1.25 * strength),
          );
        }
        final blurSigma = 1.5 + 24.5 * strength;
        final Color veilColor;
        if (opaque) {
          veilColor = isDark ? const Color(0xF51E1E22) : const Color(0xFAFFFFFF);
        } else if (winFastGlass) {
          veilColor = isDark
              ? Color.fromRGBO(26, 28, 35, (0.93 - 0.34 * strength).clamp(0.55, 0.94))
              : Color.fromRGBO(255, 255, 255, (0.96 - 0.30 * strength).clamp(0.62, 0.96));
        } else if (shader != null) {
          // Slight subtle depth modulation even at 85%..100%
          veilColor = Color.fromRGBO(
            24,
            24,
            30,
            ((1.0 - strength) * 0.65).clamp(0.0, 0.14),
          );
        } else if (isDark) {
          veilColor = Color.fromRGBO(
            28,
            28,
            34,
            (0.92 - 0.62 * strength).clamp(0.24, 0.93),
          );
        } else {
          veilColor = Color.fromRGBO(
            255,
            255,
            255,
            (0.94 - 0.54 * strength).clamp(0.36, 0.95),
          );
        }
        return BackdropFilter(
          enabled: !opaque && !winFastGlass,
          filter: shader == null
              ? liquidGlassFilter(
                  blur: blurSigma,
                  saturation: isDark ? (1.05 + 0.85 * strength) : (1.08 + 0.45 * strength),
                  brightness: isDark ? (0.82 + 0.14 * strength) : 1.0,
                )
              : ImageFilter.shader(shader),
          // Keep the child at the same element-tree depth when the async GPU
          // shader arrives or transparency changes. Reparenting discarded
          // active update checks, text fields and nested settings navigation.
          child: ColoredBox(
            color: veilColor,
            child: widget.child,
          ),
        );
      },
    );
  }
}

/// Reusable Glasswork material: saturated optical blur, a light
/// top-to-bottom refraction tint, specular rim and a soft floating shadow.
/// Uses continuous (superellipse) corners like system controls.
class LiquidGlass extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final Color tint;
  final double blur;
  final double saturation;
  final double rimStrength;
  final bool elevated;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = 24,
    this.tint = const Color(0x001E1E22),
    this.blur = 2,
    this.saturation = 1.6,
    this.rimStrength = 1.0,
    this.elevated = true,
    this.padding,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = ApplePalette.isDarkOf(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
    );
    Widget content = child;
    if (padding != null) content = Padding(padding: padding!, child: content);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: elevated
            ? (isDark
                ? const [
                    BoxShadow(
                      color: Color(0x59000000),
                      blurRadius: 30,
                      offset: Offset(0, 12),
                    ),
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ]
                : const [
                    BoxShadow(
                      color: Color(0x1C000000),
                      blurRadius: 24,
                      offset: Offset(0, 8),
                    ),
                    BoxShadow(
                      color: Color(0x0F000000),
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ])
            : null,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        clipBehavior: Clip.antiAlias,
        child: AnimatedBuilder(
          animation: _sharedReduceTransparencyListenable,
          builder: (context, _) {
            final systemReduce = GlassworkBackdrop.reduceTransparency.value ||
                _isSystemReduceTransparencyActive();
            if (systemReduce) {
              final baseOpaque =
                  isDark ? const Color(0xF51E1E22) : const Color(0xFAFFFFFF);
              final solidBase = tint.a > 0.01
                  ? Color.alphaBlend(
                      tint.withValues(alpha: math.min(tint.a, isDark ? 0.35 : 0.16)),
                      baseOpaque,
                    )
                  : baseOpaque;
              return Container(
                width: width,
                height: height,
                decoration: ShapeDecoration(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(borderRadius),
                    side: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.48)
                          : Colors.black.withValues(alpha: 0.14),
                      width: 1.0,
                    ),
                  ),
                  color: solidBase,
                ),
                child: content,
              );
            }
            if (MediaQuery.highContrastOf(context) ||
                MediaQuery.disableAnimationsOf(context)) {
              return CustomPaint(
                foregroundPainter: _LiquidRimPainter(
                  shape: shape,
                  strength: rimStrength,
                  lightMode: !isDark,
                ),
                child: Container(
                  width: width,
                  height: height,
                  decoration: ShapeDecoration(
                    shape: shape,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDark
                          ? [
                              Color.alphaBlend(
                                const Color(0x28FFFFFF),
                                tint.withValues(alpha: 1),
                              ),
                              tint.withValues(alpha: 1),
                              Color.alphaBlend(
                                const Color(0x10FFFFFF),
                                tint.withValues(alpha: 1),
                              ),
                            ]
                          : const [
                              Color(0xFAFFFFFF),
                              Color(0xF2F6F7FA),
                              Color(0xFAFFFFFF),
                            ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                  child: content,
                ),
              );
            }
            return GlassworkBackdrop(
              radius: borderRadius,
              child: ValueListenableBuilder<double>(
                valueListenable: GlassworkBackdrop.intensity,
                builder: (context, strength, _) {
                  final s = strength.clamp(0.0, 1.0);
                  final effectiveTint = isDark
                      ? tint
                      : (tint.a > 0.01 &&
                              (tint.r > 0.25 || tint.g > 0.25 || tint.b > 0.25)
                          ? tint
                          : const Color(0x00FFFFFF));
                  return CustomPaint(
                    foregroundPainter: _LiquidRimPainter(
                      shape: shape,
                      strength: rimStrength * (0.28 + 0.92 * s),
                      lightMode: !isDark,
                    ),
                    child: Container(
                      width: width,
                      height: height,
                      decoration: ShapeDecoration(
                        shape: shape,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isDark
                              ? [
                                  Color.alphaBlend(
                                    Color.fromRGBO(255, 255, 255, 0.03 + 0.10 * s),
                                    effectiveTint.withValues(
                                      alpha: math.min(effectiveTint.a, 0.14),
                                    ),
                                  ),
                                  effectiveTint.withValues(
                                    alpha: math.min(effectiveTint.a, 0.08),
                                  ),
                                  Color.alphaBlend(
                                    Color.fromRGBO(255, 255, 255, 0.015 + 0.05 * s),
                                    effectiveTint.withValues(
                                      alpha: math.min(effectiveTint.a, 0.10),
                                    ),
                                  ),
                                ]
                              : [
                                  Color.alphaBlend(
                                    Color.fromRGBO(255, 255, 255, (0.88 - 0.22 * s).clamp(0.58, 0.92)),
                                    effectiveTint.withValues(
                                      alpha: math.min(effectiveTint.a, 0.16),
                                    ),
                                  ),
                                  Color.fromRGBO(250, 251, 254, (0.82 - 0.22 * s).clamp(0.52, 0.88)),
                                  Color.fromRGBO(244, 246, 251, (0.86 - 0.20 * s).clamp(0.56, 0.90)),
                                ],
                          stops: const [0.0, 0.52, 1.0],
                        ),
                      ),
                      child: content,
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Soft edge fade for horizontal shelves / vertical strips: content dissolves
/// into the background at the edges instead of being hard-clipped.
class AppleEdgeFade extends StatelessWidget {
  final Widget child;
  final double fadeWidth;
  final Axis axis;
  final bool fadeStart;
  final bool fadeEnd;
  const AppleEdgeFade({
    super.key,
    required this.child,
    this.fadeWidth = 22,
    this.axis = Axis.horizontal,
    this.fadeStart = true,
    this.fadeEnd = true,
  });

  @override
  Widget build(BuildContext context) {
    if (_isWindowsDesktop || fadeWidth <= 0 || (!fadeStart && !fadeEnd)) {
      return child;
    }
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final extent = axis == Axis.horizontal ? rect.width : rect.height;
        final f = extent <= 0 ? 0.0 : (fadeWidth / extent).clamp(0.0, 0.45);
        return LinearGradient(
          begin: axis == Axis.horizontal
              ? Alignment.centerLeft
              : Alignment.topCenter,
          end: axis == Axis.horizontal
              ? Alignment.centerRight
              : Alignment.bottomCenter,
          colors: [
            fadeStart ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            const Color(0xFFFFFFFF),
            fadeEnd ? const Color(0x00FFFFFF) : const Color(0xFFFFFFFF),
          ],
          stops: [0.0, f, 1.0 - f, 1.0],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

/// iOS 27 Liquid Glass surface: saturated optical blur, light refraction tint,
/// specular rim and optional soft depth shadow.
class AppleGlassSurface extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Color color;
  final Color? backgroundColor;
  final double blurSigma;
  final Border? border;
  final bool elevated;
  const AppleGlassSurface({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.padding,
    this.borderRadius,
    this.color = const Color(0x8C202026),
    this.backgroundColor,
    this.blurSigma = 34,
    this.border,
    this.elevated = false,
  });
  @override
  Widget build(BuildContext context) {
    final isDark = ApplePalette.isDarkOf(context);
    final radius = borderRadius ?? BorderRadius.circular(18);
    final effectiveColor = backgroundColor ?? color;
    final shape = RoundedRectangleBorder(borderRadius: radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: elevated
            ? [
                BoxShadow(
                  color: isDark
                      ? const Color(0x48000000)
                      : const Color(0x140F172A),
                  blurRadius: isDark ? 24 : 18,
                  offset: Offset(0, isDark ? 10 : 6),
                ),
              ]
            : (isDark
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x0D0F172A),
                      blurRadius: 12,
                      offset: Offset(0, 3),
                    ),
                  ]),
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: AnimatedBuilder(
          animation: _sharedReduceTransparencyListenable,
          builder: (context, _) {
            final systemReduce = GlassworkBackdrop.reduceTransparency.value ||
                _isSystemReduceTransparencyActive();
            if (systemReduce) {
              return Container(
                width: width,
                height: height,
                padding: padding,
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xF51E1E22)
                      : const Color(0xFAFFFFFF),
                  borderRadius: radius,
                  border: border ??
                      Border.all(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.48)
                            : Colors.black.withValues(alpha: 0.10),
                        width: 1.0,
                      ),
                ),
                child: child,
              );
            }
            if (MediaQuery.highContrastOf(context) ||
                MediaQuery.disableAnimationsOf(context)) {
              return CustomPaint(
                foregroundPainter: border == null
                    ? _LiquidRimPainter(
                        shape: shape,
                        strength: 0.8,
                        lightMode: !isDark,
                      )
                    : null,
                child: Container(
                  width: width,
                  height: height,
                  padding: padding,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDark
                          ? [
                              Color.alphaBlend(
                                const Color(0x20FFFFFF),
                                effectiveColor.withValues(
                                  alpha: math.max(effectiveColor.a, 0.90),
                                ),
                              ),
                              effectiveColor.withValues(
                                alpha: math.max(effectiveColor.a, 0.90),
                              ),
                            ]
                          : const [Color(0xFFFFFFFF), Color(0xFFF6F7FB)],
                    ),
                    borderRadius: radius,
                    border: border ??
                        (!isDark
                            ? Border.all(
                                color: Colors.black.withValues(alpha: 0.08),
                                width: 0.8,
                              )
                            : null),
                  ),
                  child: child,
                ),
              );
            }
            return GlassworkBackdrop(
              radius: radius.topLeft.x,
              child: ValueListenableBuilder<double>(
                valueListenable: GlassworkBackdrop.intensity,
                builder: (context, strength, _) {
                  final s = strength.clamp(0.0, 1.0);
                  return CustomPaint(
                    foregroundPainter: border == null && isDark
                        ? _LiquidRimPainter(
                            shape: shape,
                            strength: 0.25 + 0.85 * s,
                            lightMode: false,
                          )
                        : null,
                    child: Container(
                      width: width,
                      height: height,
                      padding: padding,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isDark
                              ? [
                                  Color.alphaBlend(
                                    Color.fromRGBO(255, 255, 255, 0.02 + 0.07 * s),
                                    effectiveColor.withValues(alpha: math.min(effectiveColor.a, .04)),
                                  ),
                                  effectiveColor.withValues(alpha: math.min(effectiveColor.a, .02)),
                                ]
                              : [
                                  Color.fromRGBO(249, 250, 253, (0.94 - 0.14 * s).clamp(0.76, 0.96)),
                                  Color.fromRGBO(243, 245, 250, (0.90 - 0.14 * s).clamp(0.72, 0.93)),
                                ],
                        ),
                        borderRadius: radius,
                        border: border ??
                            (!isDark
                                ? Border.all(
                                    color: Colors.white.withValues(alpha: 0.72),
                                    width: 0.8,
                                  )
                                : null),
                      ),
                      child: child,
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// iOS 26 Liquid Glass floating tab bar (Dock):
/// - Portrait on iOS 26+: true native UIKit `UITabBar` floating glass capsule +
///   detached circular `UIButton.Configuration.glass()` search button.
/// - Portrait fallback (iOS 15–18 / Android / Desktop / Tests): matching full-capsule
///   Liquid Glass pill (`62dp`) with dark inner selection capsule + detached circular
///   search button on the right.
/// - Landscape: compact vertical glass pill on the right edge + circular search button.
/// - Supports both discrete taps AND continuous press-and-slide (`按住左右/上下滑动聚焦切换`).
class AppleLiquidGlassDock extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool isLandscape;
  final List<(IconData, IconData, String)> items;
  final List<IosNativeDockItem>? nativeItems;
  final VoidCallback? onSearch;
  final VoidCallback? onScrollToTop;
  final bool hidden;
  final bool collapsed;

  const AppleLiquidGlassDock({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.isLandscape,
    required this.items,
    this.nativeItems,
    this.onSearch,
    this.onScrollToTop,
    this.hidden = false,
    this.collapsed = false,
  });

  static const double _dockRadius = 31;
  static const double _lensRadius = 26;
  static const double _pad = 5;
  static const double _itemH = 52;
  static const double _itemW = 60;
  static const double _searchGap = 10;
  static const Duration _motion = Duration(milliseconds: 440);
  static final Curve _curve = Ios27Spring.bouncy.curve;

  /// Width a landscape dock occupies (including its outer margin).
  static double landscapeFootprint(BuildContext context) {
    final right = MediaQuery.paddingOf(context).right;
    return _itemW + _pad * 2 + (right > 0 ? right + 4 : 10) + 8;
  }

  static double portraitFootprint(BuildContext context) {
    final safe = MediaQuery.paddingOf(context).bottom;
    return _itemH + 2 * _pad + (safe > 0 ? math.max(safe - 14, 10) : 12) + 8;
  }

  @override
  State<AppleLiquidGlassDock> createState() => _AppleLiquidGlassDockState();
}

class _AppleLiquidGlassDockState extends State<AppleLiquidGlassDock> {
  double? _dragLensSlot;
  int? _lastDragSelectedIndex;

  int get _safeIndex => widget.items.isEmpty
      ? 0
      : widget.selectedIndex.clamp(0, widget.items.length - 1);

  void _updateSlidePosition(double coord, double itemExtent) {
    final n = widget.items.length;
    if (n <= 0 || itemExtent <= 0) return;
    final relative = coord - AppleLiquidGlassDock._pad;
    final rawSlot = ((relative - itemExtent * 0.5) / itemExtent)
        .clamp(0.0, (n - 1).toDouble());
    final targetIndex = (relative / itemExtent).floor().clamp(0, n - 1);
    setState(() {
      _dragLensSlot = rawSlot;
    });
    final currentSelected = _lastDragSelectedIndex ?? _safeIndex;
    if (targetIndex != currentSelected) {
      _lastDragSelectedIndex = targetIndex;
      HapticFeedback.selectionClick();
      // Preview only. Commit the destination when the finger is released.
    }
  }

  void _endSlide({bool cancelled = false}) {
    if (_dragLensSlot == null && _lastDragSelectedIndex == null) return;
    final target = _lastDragSelectedIndex;
    setState(() {
      _dragLensSlot = null;
      _lastDragSelectedIndex = null;
    });
    if (!cancelled && target != null && target != _safeIndex) {
      widget.onSelect(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final portraitBottom =
        safe.bottom > 0 ? math.max(safe.bottom - 14.0, 10.0) : 12.0;

    return IosNativeRouteGate(
      builder: (context, nativeActive) {
        final useNativeIos26 = nativeActive &&
            !widget.isLandscape &&
            widget.nativeItems != null &&
            widget.nativeItems!.isNotEmpty;
        if (useNativeIos26) {
          return Padding(
            padding: EdgeInsets.only(bottom: portraitBottom),
            child: IosNativeDockView(
              selectedIndex: _safeIndex,
              items: widget.nativeItems!,
              onSelect: widget.onSelect,
              onSearch: widget.onSearch,
              onScrollToTop: widget.onScrollToTop,
              showSearch: widget.onSearch != null,
              hidden: widget.hidden,
              collapsed: widget.collapsed,
            ),
          );
        }

        // On iOS 26+ during route transitions (when IosNativeRouteGate temporarily
        // unmounts UiKitView to prevent Impeller cross-route black occlusion),
        // render a pixel-matched, zero-BackdropFilter placeholder identical in
        // geometry & visual style to MarcoDockContainerView so there is zero
        // size jump or legacy-style flash.
        if (IosLiquidGlassBridge.isAvailable &&
            !widget.isLandscape &&
            widget.nativeItems != null &&
            widget.nativeItems!.isNotEmpty) {
          Widget placeholder = Padding(
            padding: EdgeInsets.only(bottom: portraitBottom),
            child: _buildIos26TransitionDockPlaceholder(context),
          );
          if (widget.hidden) {
            placeholder = IgnorePointer(
              ignoring: true,
              child: Opacity(opacity: 0, child: placeholder),
            );
          }
          return placeholder;
        }

        final viewport = AppleViewportLayout.of(context);
        final portraitSideMargin = viewport.isCompactSplit ? 10.0 : 16.0;
        final margin = widget.isLandscape
            ? EdgeInsets.only(
                right: safe.right > 0 ? safe.right + 4 : 10,
                top: 12,
                bottom: 12,
              )
            : EdgeInsets.only(
                left: portraitSideMargin,
                right: portraitSideMargin,
                bottom: portraitBottom,
              );
        final double portraitBarH = viewport.width < 340
            ? 56.0
            : AppleLiquidGlassDock._itemH + AppleLiquidGlassDock._pad * 2;
        Widget content = Padding(
          padding: margin,
          child: widget.isLandscape
              ? _buildVertical()
              : SizedBox(
                  height: portraitBarH,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: widget.collapsed
                        ? _buildCollapsedLogoButton(context, barH: portraitBarH)
                        : _buildHorizontal(barH: portraitBarH),
                  ),
                ),
        );
        if (widget.hidden) {
          content = IgnorePointer(
            ignoring: true,
            child: Opacity(opacity: 0, child: content),
          );
        }
        return content;
      },
    );
  }

  Widget _buildIos26TransitionDockPlaceholder(BuildContext context) {
    const totalH = 76.0;
    const dockSize = 62.0;
    const outerMargin = 16.0;
    const gap = 10.0;
    const inset = 4.0;
    final hasSearch = widget.onSearch != null;
    final n = math.max(widget.items.length, 1);

    final isDark = ApplePalette.isDarkOf(context);
    final dockActiveFg =
        isDark ? const Color(0xFF5CB8FF) : AppleColors.systemBlue;
    final dockInactiveFg = isDark
        ? Colors.white.withValues(alpha: 0.70)
        : const Color(0xFF2C303A).withValues(alpha: 0.76);

    BoxDecoration glassDeco(double radius) => BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0x804E4E58), Color(0x6E34343C)]
                : const [Color(0xEBFFFFFF), Color(0xD8F2F4F8)],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.24)
                : Colors.black.withValues(alpha: 0.08),
            width: 0.65,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? const Color(0x36000000)
                  : const Color(0x180F172A),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        );

    return SizedBox(
      key: const ValueKey('ios26-dock-transition-placeholder'),
      width: double.infinity,
      height: totalH,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalW = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final isCompactSplit = totalW < 360.0;
          final effOuterMargin = isCompactSplit ? 10.0 : outerMargin;
          final effGap = isCompactSplit ? 8.0 : gap;
          final effDockSize = totalW < 340.0 ? 56.0 : dockSize;
          final maxCap = totalW >= 600.0 ? 468.0 : 440.0;
          final maxRowWidth = math.min(totalW, maxCap);
          final rowX = (totalW - maxRowWidth) * 0.5;

          if (widget.collapsed) {
            final rightInset = math.max(
              effOuterMargin,
              totalW - (rowX + maxRowWidth - effOuterMargin),
            );
            return Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: EdgeInsets.only(right: rightInset),
                child: SizedBox(
                  width: effDockSize,
                  height: effDockSize,
                  child: DecoratedBox(
                    decoration: glassDeco(effDockSize * 0.5),
                    child: const Center(
                      child: MarcoBrandLogo(
                        iconSize: 32,
                        showWordmark: false,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }

          final availTabW = hasSearch
              ? maxRowWidth - effOuterMargin * 2 - effDockSize - effGap
              : maxRowWidth - effOuterMargin * 2;
          final tabW = math.max(
            availTabW,
            math.min(180.0, math.max(availTabW, 132.0)),
          );
          final innerW = tabW - inset * 2;
          final slotW = innerW / n;
          final lensH = effDockSize - inset * 2;

          return Center(
            child: SizedBox(
              width: maxRowWidth,
              height: totalH,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: effOuterMargin),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: tabW,
                      height: effDockSize,
                      child: DecoratedBox(
                        decoration: glassDeco(effDockSize * 0.5),
                        child: Stack(
                          children: [
                            Positioned(
                              left: inset + slotW * _safeIndex,
                              top: inset,
                              width: slotW,
                              height: lensH,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(lensH * 0.5),
                                  color: isDark
                                      ? const Color(0x383894FF)
                                      : const Color(0x1F007AFF),
                                  border: Border.all(
                                    color: isDark
                                        ? const Color(0x478CCCFF)
                                        : const Color(0x29007AFF),
                                    width: 0.55,
                                  ),
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: Padding(
                                padding: const EdgeInsets.all(inset),
                                child: Row(
                                  children: [
                                    for (var i = 0; i < widget.items.length; i++)
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            MarcoAnimatedDockIcon(
                                              kind: MarcoAnimatedDockIcon
                                                  .resolveKind(
                                                explicitKind:
                                                    widget.nativeItems !=
                                                                null &&
                                                            i <
                                                                widget
                                                                    .nativeItems!
                                                                    .length
                                                        ? widget.nativeItems![i]
                                                            .kind
                                                        : null,
                                                label: widget.items[i].$3,
                                                icon: widget.items[i].$1,
                                              ),
                                              fallbackIcon: i == _safeIndex
                                                  ? widget.items[i].$2
                                                  : widget.items[i].$1,
                                              selected: i == _safeIndex,
                                              size: 24,
                                            ),
                                            const SizedBox(height: 2.5),
                                            Text(
                                              widget.items[i].$3,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                fontWeight: i == _safeIndex
                                                    ? FontWeight.w600
                                                    : FontWeight.w500,
                                                color: i == _safeIndex
                                                    ? dockActiveFg
                                                    : dockInactiveFg,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (hasSearch) ...[
                      SizedBox(width: effGap),
                      SizedBox(
                        width: effDockSize,
                        height: effDockSize,
                        child: DecoratedBox(
                          decoration: glassDeco(effDockSize * 0.5),
                          child: Center(
                            child: Icon(
                              CupertinoIcons.search,
                              size: 22,
                              color: isDark
                                  ? Colors.white
                                  : const Color(0xFF14161C),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCollapsedLogoButton(BuildContext context, {double? barH}) {
    final size = barH ??
        (AppleLiquidGlassDock._itemH + AppleLiquidGlassDock._pad * 2);
    final isDark = ApplePalette.isDarkOf(context);
    return LayoutBuilder(
      key: const ValueKey('dock-collapsed-logo-wrap'),
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
        final maxCap = available >= 560.0 ? 456.0 : 420.0;
        final rowWidth = math.min(available, maxCap);
        return SizedBox(
          width: rowWidth,
          height: size,
          child: Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            child: GestureDetector(
              key: const ValueKey('dock-collapsed-logo-button'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _showFallbackCollapsedBubble(context),
              child: RepaintBoundary(
                child: LiquidGlass(
                  width: size,
                  height: size,
                  borderRadius: size * 0.5,
                  tint: isDark
                      ? const Color(0x56161414)
                      : const Color(0xD8FFFFFF),
                  blur: 20,
                  saturation: 1.8,
                  child: const Center(
                    child: MarcoBrandLogo(
                      iconSize: 32,
                      showWordmark: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showFallbackCollapsedBubble(BuildContext context) async {
    HapticFeedback.lightImpact();
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final dockBottom =
        safeBottom > 0 ? math.max(safeBottom - 14.0, 10.0) : 12.0;
    final bottomOffset = dockBottom + 62.0 + 12.0;
    final chosen = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭快捷导航',
      barrierColor: const Color(0x28000000),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogCtx, _, __) {
        return Stack(
          children: [
            Positioned(
              right: 16,
              bottom: bottomOffset,
              child: Material(
                type: MaterialType.transparency,
                child: LiquidGlass(
                  key: const ValueKey('dock-collapsed-bubble-menu'),
                  width: 176,
                  borderRadius: 24,
                  tint: ApplePalette.isDarkOf(dialogCtx)
                      ? const Color(0xA616161C)
                      : const Color(0xF0FFFFFF),
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.onSearch != null) ...[
                        _bubbleMenuRow(
                          icon: CupertinoIcons.search,
                          label: '搜索影片',
                          selected: false,
                          onTap: () => Navigator.of(dialogCtx).pop('search'),
                        ),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          color: ApplePalette.of(dialogCtx).separator,
                        ),
                      ],
                      for (var i = 0; i < widget.items.length; i++)
                        _bubbleMenuRow(
                          icon: i == _safeIndex
                              ? widget.items[i].$2
                              : widget.items[i].$1,
                          label: widget.items[i].$3,
                          selected: i == _safeIndex,
                          onTap: () => Navigator.of(dialogCtx).pop('tab:$i'),
                        ),
                      if (widget.onScrollToTop != null) ...[
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          color: ApplePalette.of(dialogCtx).separator,
                        ),
                        _bubbleMenuRow(
                          icon: CupertinoIcons.arrow_up_to_line,
                          label: '回到顶部',
                          selected: false,
                          onTap: () => Navigator.of(dialogCtx).pop('top'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (dialogContext, anim, __, child) {
        if (Ios27ConcentricGeometry.isReduceMotion(dialogContext)) {
          return FadeTransition(opacity: anim, child: child);
        }
        final curved = CurvedAnimation(
          parent: anim,
          curve: Ios27Spring.bouncy.curve,
          reverseCurve: Ios27Spring.smooth.curve.flipped,
        );
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: anim,
            curve: Ios27Spring.smooth.curve,
          ),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.86, end: 1.0).animate(curved),
            alignment: Alignment.bottomRight,
            child: child,
          ),
        );
      },
    );
    if (chosen == null) return;
    if (chosen == 'search') {
      widget.onSearch?.call();
    } else if (chosen == 'top') {
      widget.onScrollToTop?.call();
    } else if (chosen.startsWith('tab:')) {
      final idx = int.tryParse(chosen.substring(4));
      if (idx != null) widget.onSelect(idx);
    }
  }

  Widget _bubbleMenuRow({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final palette = ApplePalette.of(context);
    final fg = selected
        ? (palette.isDark ? Colors.white : palette.systemBlue)
        : palette.labelPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: fg,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (selected)
              Icon(
                CupertinoIcons.checkmark_alt,
                size: 15,
                color: fg,
              ),
          ],
        ),
      ),
    );
  }

  Widget _shell({required Widget child, double? radius}) {
    final isDark = ApplePalette.isDarkOf(context);
    return RepaintBoundary(
      child: LiquidGlass(
        borderRadius: radius ?? AppleLiquidGlassDock._dockRadius,
        tint: isDark ? const Color(0x56161414) : const Color(0xD8FFFFFF),
        blur: 20,
        saturation: 1.8,
        child: child,
      ),
    );
  }

  Widget _buildHorizontal({double? barH}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = math.max(widget.items.length, 1);
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
        final hasSearch = widget.onSearch != null;
        final effBarH = barH ??
            (AppleLiquidGlassDock._itemH + AppleLiquidGlassDock._pad * 2);
        final effGap =
            available < 330.0 ? 8.0 : AppleLiquidGlassDock._searchGap;
        final maxCap = available >= 560.0 ? 456.0 : 420.0;
        final maxRowWidth = math.min(available, maxCap);
        final maxSearchPill =
            math.max(120.0, maxRowWidth - effBarH - effGap);
        final pillWidth = hasSearch
            ? math.min(
                maxSearchPill,
                available >= 560.0 ? 384.0 : 348.0,
              )
            : math.min(maxRowWidth, available >= 560.0 ? 360.0 : 320.0);
        final itemW = (pillWidth - AppleLiquidGlassDock._pad * 2) / n;
        final itemH = effBarH - AppleLiquidGlassDock._pad * 2;
        final isSliding = _dragLensSlot != null;
        final lensSlot = _dragLensSlot ?? _safeIndex.toDouble();

        final pill = _shell(
          radius: effBarH * 0.5,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) =>
                _updateSlidePosition(d.localPosition.dx, itemW),
            onHorizontalDragUpdate: (d) =>
                _updateSlidePosition(d.localPosition.dx, itemW),
            onHorizontalDragEnd: (_) => _endSlide(),
            onHorizontalDragCancel: () => _endSlide(cancelled: true),
            child: SizedBox(
              width: pillWidth,
              height: effBarH,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: isSliding
                        ? const Duration(milliseconds: 32)
                        : AppleLiquidGlassDock._motion,
                    curve: isSliding
                        ? Curves.linear
                        : AppleLiquidGlassDock._curve,
                    left: AppleLiquidGlassDock._pad + itemW * lensSlot,
                    top: AppleLiquidGlassDock._pad,
                    width: itemW,
                    height: itemH,
                    child: AnimatedScale(
                      scale: isSliding ? 1.05 : 1.0,
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      child: const _DockSelectionLens(),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding:
                          const EdgeInsets.all(AppleLiquidGlassDock._pad),
                      child: Row(
                        children: [
                          for (int i = 0; i < widget.items.length; i++)
                            Expanded(child: _item(i)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        if (!hasSearch) return pill;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            pill,
            SizedBox(width: effGap),
            _DockSearchCircleButton(
              size: effBarH,
              onTap: widget.onSearch!,
            ),
          ],
        );
      },
    );
  }

  Widget _buildVertical() {
    return Builder(
      builder: (context) {
        final n = math.max(widget.items.length, 1);
        final screenH = MediaQuery.sizeOf(context).height;
        final safeV = MediaQuery.paddingOf(context).vertical;
        final hasSearch = widget.onSearch != null;
        final searchSize = screenH < 480 ? 48.0 : 54.0;
        final searchReserve = hasSearch ? (searchSize + 10.0) : 0.0;
        final maxAvailableH =
            math.max(188.0, screenH - safeV - 28.0 - searchReserve);
        final idealMin = math.min(
          maxAvailableH,
          AppleLiquidGlassDock._itemH * n + AppleLiquidGlassDock._pad * 2 + 12.0,
        );
        final targetTotalH = (screenH * 0.72)
            .clamp(idealMin, math.min(316.0, maxAvailableH))
            .toDouble();
        final vItemH = (targetTotalH - AppleLiquidGlassDock._pad * 2) / n;
        final isSliding = _dragLensSlot != null;
        final lensSlot = _dragLensSlot ?? _safeIndex.toDouble();
        const pillW =
            AppleLiquidGlassDock._itemW + AppleLiquidGlassDock._pad * 2;
        final pill = _shell(
          radius: pillW * 0.5,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) =>
                _updateSlidePosition(d.localPosition.dy, vItemH),
            onVerticalDragUpdate: (d) =>
                _updateSlidePosition(d.localPosition.dy, vItemH),
            onVerticalDragEnd: (_) => _endSlide(),
            onVerticalDragCancel: () => _endSlide(cancelled: true),
            child: SizedBox(
              width: pillW,
              height: targetTotalH,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: isSliding
                        ? const Duration(milliseconds: 32)
                        : AppleLiquidGlassDock._motion,
                    curve: isSliding
                        ? Curves.linear
                        : AppleLiquidGlassDock._curve,
                    left: AppleLiquidGlassDock._pad,
                    top: AppleLiquidGlassDock._pad + vItemH * lensSlot,
                    width: AppleLiquidGlassDock._itemW,
                    height: vItemH,
                    child: AnimatedScale(
                      scale: isSliding ? 1.05 : 1.0,
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      child: const _DockSelectionLens(),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding:
                          const EdgeInsets.all(AppleLiquidGlassDock._pad),
                      child: Column(
                        children: [
                          for (int i = 0; i < widget.items.length; i++)
                            SizedBox(height: vItemH, child: _item(i)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (!hasSearch) return pill;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            pill,
            const SizedBox(height: 10),
            _DockSearchCircleButton(
              size: searchSize,
              onTap: widget.onSearch!,
            ),
          ],
        );
      },
    );
  }

  Widget _item(int index) {
    final item = widget.items[index];
    final activeIdx = _lastDragSelectedIndex ?? _safeIndex;
    final explicitKind = widget.nativeItems != null &&
            index < widget.nativeItems!.length
        ? widget.nativeItems![index].kind
        : null;
    return _DockItem(
      icon: item.$1,
      selectedIcon: item.$2,
      label: item.$3,
      kind: MarcoAnimatedDockIcon.resolveKind(
        explicitKind: explicitKind,
        label: item.$3,
        icon: item.$1,
      ),
      selected: index == activeIdx,
      onTap: () => widget.onSelect(index),
    );
  }
}

/// Detached circular Liquid Glass search button paired beside the iOS 27 Dock.
class _DockSearchCircleButton extends StatelessWidget {
  final double size;
  final VoidCallback onTap;

  const _DockSearchCircleButton({
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    return Ios27Pressable(
      key: const ValueKey('home-search-button'),
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: size * 0.5,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: RepaintBoundary(
        child: LiquidGlass(
          width: size,
          height: size,
          borderRadius: size * 0.5,
          tint: palette.isDark
              ? const Color(0x56161414)
              : const Color(0xD8FFFFFF),
          blur: 20,
          saturation: 1.8,
          child: Center(
            child: Icon(
              CupertinoIcons.search,
              size: 22,
              color: palette.labelPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Luminous tinted inner capsule lens behind the selected tab (iOS 26/27 style).
class _DockSelectionLens extends StatelessWidget {
  const _DockSelectionLens();
  @override
  Widget build(BuildContext context) {
    final isDark = ApplePalette.isDarkOf(context);
    final shape = RoundedRectangleBorder(
      borderRadius:
          BorderRadius.circular(AppleLiquidGlassDock._lensRadius),
    );
    return CustomPaint(
      foregroundPainter: _LiquidRimPainter(
        shape: shape,
        strength: isDark ? 0.54 : 0.72,
        lightMode: !isDark,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [
                    Color(0x423896FF),
                    Color(0x2A2068CC),
                  ]
                : const [
                    Color(0x26007AFF),
                    Color(0x14007AFF),
                  ],
          ),
        ),
      ),
    );
  }
}

/// Custom icon archetypes for the 4 bottom Dock tabs (`主页` / `直播` / `片库` / `设置`).
enum MarcoDockIconKind { home, live, library, settings }

/// Bespoke 24x24pt layered animated vector tab icon mirroring native iOS
/// `MarcoAnimatedTabIconView` pixel-for-pixel on iOS 15–18, landscape, Split
/// View, desktop, and iOS 26+ route-transition placeholders.
class MarcoAnimatedDockIcon extends StatefulWidget {
  final MarcoDockIconKind? kind;
  final IconData fallbackIcon;
  final bool selected;
  final double size;
  final int pulseTick;

  const MarcoAnimatedDockIcon({
    super.key,
    required this.kind,
    required this.fallbackIcon,
    required this.selected,
    this.size = 24.0,
    this.pulseTick = 0,
  });

  static MarcoDockIconKind? resolveKind({
    String? explicitKind,
    required String label,
    required IconData icon,
  }) {
    switch (explicitKind?.toLowerCase()) {
      case 'home':
        return MarcoDockIconKind.home;
      case 'live':
        return MarcoDockIconKind.live;
      case 'library':
        return MarcoDockIconKind.library;
      case 'settings':
        return MarcoDockIconKind.settings;
    }
    if (label.contains('主页') ||
        icon == CupertinoIcons.play_rectangle ||
        icon == CupertinoIcons.play_rectangle_fill) {
      return MarcoDockIconKind.home;
    }
    if (label.contains('直播') ||
        icon == CupertinoIcons.dot_radiowaves_left_right) {
      return MarcoDockIconKind.live;
    }
    if (label.contains('片库') ||
        icon == CupertinoIcons.square_stack_3d_up ||
        icon == CupertinoIcons.square_stack_3d_up_fill) {
      return MarcoDockIconKind.library;
    }
    if (label.contains('设置') ||
        icon == CupertinoIcons.gear_alt ||
        icon == CupertinoIcons.gear_alt_fill) {
      return MarcoDockIconKind.settings;
    }
    return null;
  }

  @override
  State<MarcoAnimatedDockIcon> createState() => _MarcoAnimatedDockIconState();
}

class _MarcoAnimatedDockIconState extends State<MarcoAnimatedDockIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant MarcoAnimatedDockIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    final becameSelected = !oldWidget.selected && widget.selected;
    final repulsed =
        widget.selected && oldWidget.pulseTick != widget.pulseTick;
    if (becameSelected || repulsed) {
      final reduceMotion =
          MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (reduceMotion) {
        _ctrl.value = 1.0;
      } else {
        _ctrl.forward(from: 0.0);
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ApplePalette.isDarkOf(context);
    final activePrimary =
        isDark ? const Color(0xFF40A6FF) : AppleColors.systemBlue;
    final activeSecondary =
        isDark ? const Color(0xFF76D6FF) : const Color(0xFF38B6FF);
    final liveRed =
        isDark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30);
    final inactiveColor = isDark
        ? Colors.white.withValues(alpha: 0.70)
        : const Color(0xFF2C303A).withValues(alpha: 0.74);

    if (widget.kind == null) {
      return AnimatedBuilder(
        animation: _ctrl,
        builder: (context, child) {
          final scale = widget.selected
              ? _evalKeyframes(
                  _ctrl.value,
                  const [0.0, 0.44, 0.76, 1.0],
                  const [0.84, 1.14, 0.97, 1.0],
                )
              : 1.0;
          return Transform.scale(scale: scale, child: child);
        },
        child: Icon(
          widget.fallbackIcon,
          size: widget.size * 0.88,
          color: widget.selected ? activePrimary : inactiveColor,
        ),
      );
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          key: ValueKey('marco-dock-icon-${widget.kind!.name}'),
          painter: _MarcoDockIconPainter(
            kind: widget.kind!,
            selected: widget.selected,
            progress: _ctrl.value,
            activePrimary: activePrimary,
            activeSecondary: activeSecondary,
            liveRed: liveRed,
            inactiveColor: inactiveColor,
          ),
        ),
      ),
    );
  }
}

double _evalKeyframes(double t, List<double> times, List<double> values) {
  final clamped = t.clamp(0.0, 1.0);
  for (var i = 0; i < times.length - 1; i++) {
    final t0 = times[i];
    final t1 = times[i + 1];
    if (clamped <= t1 || i == times.length - 2) {
      final span = math.max(t1 - t0, 1e-6);
      final local = ((clamped - t0) / span).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(local);
      return values[i] + (values[i + 1] - values[i]) * eased;
    }
  }
  return values.last;
}

class _MarcoDockIconPainter extends CustomPainter {
  final MarcoDockIconKind kind;
  final bool selected;
  final double progress;
  final Color activePrimary;
  final Color activeSecondary;
  final Color liveRed;
  final Color inactiveColor;

  const _MarcoDockIconPainter({
    required this.kind,
    required this.selected,
    required this.progress,
    required this.activePrimary,
    required this.activeSecondary,
    required this.liveRed,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 24.0;
    canvas.save();
    canvas.translate(
      (size.width - 24.0 * scale) * 0.5,
      (size.height - 24.0 * scale) * 0.5,
    );
    canvas.scale(scale, scale);

    switch (kind) {
      case MarcoDockIconKind.home:
        _paintHome(canvas);
      case MarcoDockIconKind.live:
        _paintLive(canvas);
      case MarcoDockIconKind.library:
        _paintLibrary(canvas);
      case MarcoDockIconKind.settings:
        _paintSettings(canvas);
    }

    canvas.restore();
  }

  void _withPivot(
    Canvas canvas,
    Offset pivot, {
    double scaleX = 1.0,
    double scaleY = 1.0,
    double translateX = 0.0,
    double translateY = 0.0,
    double rotation = 0.0,
    required VoidCallback draw,
  }) {
    canvas.save();
    canvas.translate(pivot.dx + translateX, pivot.dy + translateY);
    if (rotation != 0.0) canvas.rotate(rotation);
    if (scaleX != 1.0 || scaleY != 1.0) canvas.scale(scaleX, scaleY);
    canvas.translate(-pivot.dx, -pivot.dy);
    draw();
    canvas.restore();
  }

  void _paintHome(Canvas canvas) {
    final t = selected ? progress : 1.0;
    final screenScale = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.42, 0.76, 1.0],
            const [0.82, 1.12, 0.97, 1.0],
          )
        : 1.0;
    final standScaleX = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.48, 0.78, 1.0],
            const [0.38, 1.14, 0.98, 1.0],
          )
        : 1.0;
    final playTx = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.46, 0.78, 1.0],
            const [-2.4, 0.9, -0.2, 0.0],
          )
        : 0.0;
    final playScale = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.46, 0.78, 1.0],
            const [0.55, 1.18, 0.96, 1.0],
          )
        : 1.0;

    // Curved cinema stand arc
    _withPivot(
      canvas,
      const Offset(12.0, 19.6),
      scaleX: standScaleX,
      draw: () {
        final p = Path()
          ..moveTo(8.1, 20.5)
          ..quadraticBezierTo(12.0, 18.8, 15.9, 20.5);
        canvas.drawPath(
          p,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = selected ? 2.05 : 1.75
            ..color = selected
                ? activeSecondary
                : inactiveColor.withValues(alpha: inactiveColor.a * 0.74),
        );
      },
    );

    // Sculpted rounded cinema screen
    _withPivot(
      canvas,
      const Offset(12.0, 10.7),
      scaleX: screenScale,
      scaleY: screenScale,
      draw: () {
        final rrect = RRect.fromRectAndRadius(
          const Rect.fromLTWH(2.3, 3.9, 19.4, 13.6),
          const Radius.circular(4.3),
        );
        if (selected) {
          canvas.drawRRect(rrect, Paint()..color = activePrimary);
        } else {
          canvas.drawRRect(
            rrect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.85
              ..color = inactiveColor,
          );
        }
      },
    );

    // Play triangle
    _withPivot(
      canvas,
      const Offset(12.2, 10.7),
      translateX: playTx,
      scaleX: playScale,
      scaleY: playScale,
      draw: () {
        final tri = Path()
          ..moveTo(10.0, 8.3)
          ..lineTo(15.3, 10.7)
          ..lineTo(10.0, 13.1)
          ..close();
        if (selected) {
          canvas.drawPath(tri, Paint()..color = Colors.white);
          canvas.drawPath(
            tri,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = 0.9
              ..color = Colors.white,
          );
        } else {
          canvas.drawPath(
            tri,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round
              ..strokeWidth = 1.55
              ..color = inactiveColor,
          );
        }
      },
    );

    // Top-right 4-point cinema sparkle (selected only)
    if (selected) {
      final st = ((t - 0.10) / 0.90).clamp(0.0, 1.0);
      final spScale = _evalKeyframes(
        st,
        const [0.0, 0.52, 0.80, 1.0],
        const [0.01, 1.35, 0.92, 1.0],
      );
      final spRot = _evalKeyframes(
        st,
        const [0.0, 0.54, 0.82, 1.0],
        const [-0.78, 0.24, -0.05, 0.0],
      );
      _withPivot(
        canvas,
        const Offset(20.6, 3.4),
        scaleX: spScale,
        scaleY: spScale,
        rotation: spRot,
        draw: () {
          final star = Path();
          const sr = 2.75;
          const ir = 0.78;
          for (var k = 0; k < 8; k++) {
            final a = k * (math.pi / 4.0);
            final rr = k.isEven ? sr : ir;
            final pt = Offset(
              20.6 + math.cos(a) * rr,
              3.4 + math.sin(a) * rr,
            );
            if (k == 0) {
              star.moveTo(pt.dx, pt.dy);
            } else {
              star.lineTo(pt.dx, pt.dy);
            }
          }
          star.close();
          canvas.drawPath(star, Paint()..color = activeSecondary);
        },
      );
    }
  }

  void _paintLive(Canvas canvas) {
    final t = selected ? progress : 1.0;
    const bc = Offset(12.0, 10.6);

    final innerT = ((t - 0.08) / 0.82).clamp(0.0, 1.0);
    final outerT = ((t - 0.20) / 0.80).clamp(0.0, 1.0);

    final outerScale = selected
        ? _evalKeyframes(
            outerT,
            const [0.0, 0.50, 0.80, 1.0],
            const [0.64, 1.20, 0.98, 1.0],
          )
        : 1.0;
    final outerAlpha = selected
        ? _evalKeyframes(outerT, const [0.0, 0.44, 1.0], const [0.12, 1.0, 1.0])
        : 0.56;

    final innerScale = selected
        ? _evalKeyframes(
            innerT,
            const [0.0, 0.48, 0.78, 1.0],
            const [0.68, 1.16, 0.98, 1.0],
          )
        : 1.0;
    final innerAlpha = selected
        ? _evalKeyframes(innerT, const [0.0, 0.42, 1.0], const [0.22, 1.0, 1.0])
        : 1.0;

    // Outer broadcast wave arcs
    _withPivot(
      canvas,
      bc,
      scaleX: outerScale,
      scaleY: outerScale,
      draw: () {
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = selected ? 1.9 : 1.8
          ..color = (selected ? activeSecondary : inactiveColor).withValues(
            alpha: (selected ? 1.0 : inactiveColor.a) * outerAlpha,
          );
        final rect = Rect.fromCircle(center: bc, radius: 8.5);
        canvas.drawArc(
          rect,
          138.0 * math.pi / 180.0,
          84.0 * math.pi / 180.0,
          false,
          paint,
        );
        canvas.drawArc(
          rect,
          -42.0 * math.pi / 180.0,
          84.0 * math.pi / 180.0,
          false,
          paint,
        );
      },
    );

    // Inner broadcast wave arcs
    _withPivot(
      canvas,
      bc,
      scaleX: innerScale,
      scaleY: innerScale,
      draw: () {
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = selected ? 1.95 : 1.85
          ..color = (selected ? activePrimary : inactiveColor).withValues(
            alpha: (selected ? 1.0 : inactiveColor.a) * innerAlpha,
          );
        final rect = Rect.fromCircle(center: bc, radius: 5.25);
        canvas.drawArc(
          rect,
          140.0 * math.pi / 180.0,
          80.0 * math.pi / 180.0,
          false,
          paint,
        );
        canvas.drawArc(
          rect,
          -40.0 * math.pi / 180.0,
          80.0 * math.pi / 180.0,
          false,
          paint,
        );
      },
    );

    // Broadcast dish stand
    final standPath = Path()
      ..moveTo(12.0, 14.0)
      ..lineTo(12.0, 19.6)
      ..moveTo(8.2, 20.6)
      ..quadraticBezierTo(12.0, 18.8, 15.8, 20.6);
    canvas.drawPath(
      standPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = selected ? 1.95 : 1.8
        ..color = selected ? activePrimary : inactiveColor,
    );

    // Crimson Live Halo + Center Beacon
    if (selected) {
      final haloScale = _evalKeyframes(
        t,
        const [0.0, 0.45, 0.78, 1.0],
        const [0.55, 1.72, 1.08, 1.0],
      );
      final haloAlpha = _evalKeyframes(
        t,
        const [0.0, 0.48, 0.78, 1.0],
        const [0.42, 0.14, 0.28, 0.28],
      );
      _withPivot(
        canvas,
        bc,
        scaleX: haloScale,
        scaleY: haloScale,
        draw: () {
          canvas.drawCircle(
            bc,
            4.0,
            Paint()..color = liveRed.withValues(alpha: haloAlpha),
          );
        },
      );
      final beaconScale = _evalKeyframes(
        t,
        const [0.0, 0.38, 0.72, 1.0],
        const [0.58, 1.38, 0.94, 1.0],
      );
      _withPivot(
        canvas,
        bc,
        scaleX: beaconScale,
        scaleY: beaconScale,
        draw: () {
          canvas.drawCircle(bc, 2.35, Paint()..color = liveRed);
        },
      );
    } else {
      canvas.drawCircle(bc, 2.15, Paint()..color = inactiveColor);
    }
  }

  void _paintLibrary(Canvas canvas) {
    final t = selected ? progress : 1.0;
    final midT = ((t - 0.04) / 0.90).clamp(0.0, 1.0);
    final backT = ((t - 0.12) / 0.88).clamp(0.0, 1.0);

    final backTy = selected
        ? _evalKeyframes(
            backT,
            const [0.0, 0.48, 0.80, 1.0],
            const [5.2, -2.3, 0.4, 0.0],
          )
        : 0.0;
    final backSx = selected
        ? _evalKeyframes(
            backT,
            const [0.0, 0.48, 0.80, 1.0],
            const [0.74, 1.08, 0.98, 1.0],
          )
        : 1.0;

    final midTy = selected
        ? _evalKeyframes(
            midT,
            const [0.0, 0.46, 0.78, 1.0],
            const [3.2, -1.5, 0.3, 0.0],
          )
        : 0.0;
    final midSx = selected
        ? _evalKeyframes(
            midT,
            const [0.0, 0.46, 0.78, 1.0],
            const [0.84, 1.06, 0.99, 1.0],
          )
        : 1.0;

    final frontScale = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.42, 0.76, 1.0],
            const [0.86, 1.09, 0.98, 1.0],
          )
        : 1.0;
    final bmSy = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.46, 0.78, 1.0],
            const [0.42, 1.16, 0.96, 1.0],
          )
        : 1.0;

    // Back card 3
    _withPivot(
      canvas,
      const Offset(12.0, 4.1),
      translateY: backTy,
      scaleX: backSx,
      draw: () {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(6.6, 3.1, 10.8, 2.0),
            const Radius.circular(1.0),
          ),
          Paint()
            ..color = selected
                ? activeSecondary.withValues(alpha: 0.52)
                : inactiveColor.withValues(alpha: inactiveColor.a * 0.46),
        );
      },
    );

    // Mid card 2
    _withPivot(
      canvas,
      const Offset(12.0, 7.2),
      translateY: midTy,
      scaleX: midSx,
      draw: () {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(4.5, 6.1, 15.0, 2.15),
            const Radius.circular(1.08),
          ),
          Paint()
            ..color = selected
                ? activeSecondary.withValues(alpha: 0.84)
                : inactiveColor.withValues(alpha: inactiveColor.a * 0.72),
        );
      },
    );

    // Front card 1
    _withPivot(
      canvas,
      const Offset(12.0, 15.2),
      scaleX: frontScale,
      scaleY: frontScale,
      draw: () {
        final card = RRect.fromRectAndRadius(
          const Rect.fromLTWH(2.5, 9.4, 19.0, 11.6),
          const Radius.circular(3.7),
        );
        if (selected) {
          canvas.drawRRect(card, Paint()..color = activePrimary);
        } else {
          canvas.drawRRect(
            card,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.85
              ..color = inactiveColor,
          );
        }
      },
    );

    // Bookmark ribbon inside front card
    _withPivot(
      canvas,
      const Offset(12.0, 9.4),
      scaleY: bmSy,
      draw: () {
        final bm = Path()
          ..moveTo(9.3, 9.4)
          ..lineTo(14.7, 9.4)
          ..lineTo(14.7, 16.5)
          ..lineTo(12.0, 14.4)
          ..lineTo(9.3, 16.5)
          ..close();
        if (selected) {
          canvas.drawPath(bm, Paint()..color = Colors.white);
        } else {
          canvas.drawPath(
            bm,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round
              ..strokeWidth = 1.55
              ..color = inactiveColor,
          );
        }
      },
    );
  }

  void _paintSettings(Canvas canvas) {
    final t = selected ? progress : 1.0;
    const sixtyDeg = math.pi / 3.0;
    final rot = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.48, 0.78, 1.0],
            const [0.0, sixtyDeg * 1.18, sixtyDeg * 0.95, sixtyDeg],
          )
        : 0.0;
    final gearScale = selected
        ? _evalKeyframes(
            t,
            const [0.0, 0.42, 0.76, 1.0],
            const [0.86, 1.11, 0.98, 1.0],
          )
        : 1.0;

    final gear = Path();
    const samples = 96;
    for (var i = 0; i < samples; i++) {
      final th = (2.0 * math.pi * i) / samples - math.pi * 0.5;
      final wave = math.cos(6.0 * th);
      final shaped = (wave >= 0 ? 1.0 : -1.0) * math.pow(wave.abs(), 0.54);
      final r = 8.0 + 1.55 * shaped;
      final pt = Offset(12.0 + r * math.cos(th), 12.0 + r * math.sin(th));
      if (i == 0) {
        gear.moveTo(pt.dx, pt.dy);
      } else {
        gear.lineTo(pt.dx, pt.dy);
      }
    }
    gear.close();

    _withPivot(
      canvas,
      const Offset(12.0, 12.0),
      scaleX: gearScale,
      scaleY: gearScale,
      rotation: rot,
      draw: () {
        if (selected) {
          gear.addOval(
            Rect.fromCircle(center: const Offset(12.0, 12.0), radius: 3.65),
          );
          gear.fillType = PathFillType.evenOdd;
          canvas.drawPath(gear, Paint()..color = activePrimary);
        } else {
          canvas.drawPath(
            gear,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = 1.85
              ..color = inactiveColor,
          );
          canvas.drawCircle(
            const Offset(12.0, 12.0),
            3.25,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.75
              ..color = inactiveColor,
          );
        }
      },
    );

    if (selected) {
      final jt = ((t - 0.10) / 0.90).clamp(0.0, 1.0);
      final jScale = _evalKeyframes(
        jt,
        const [0.0, 0.48, 0.80, 1.0],
        const [0.20, 1.34, 0.94, 1.0],
      );
      _withPivot(
        canvas,
        const Offset(12.0, 12.0),
        scaleX: jScale,
        scaleY: jScale,
        draw: () {
          canvas.drawCircle(
            const Offset(12.0, 12.0),
            1.75,
            Paint()..color = activeSecondary,
          );
        },
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MarcoDockIconPainter old) {
    return old.kind != kind ||
        old.selected != selected ||
        old.progress != progress ||
        old.activePrimary != activePrimary ||
        old.activeSecondary != activeSecondary ||
        old.liveRed != liveRed ||
        old.inactiveColor != inactiveColor;
  }
}

class _DockItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final MarcoDockIconKind? kind;
  final bool selected;
  final VoidCallback onTap;
  const _DockItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.kind,
    required this.selected,
    required this.onTap,
  });
  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  int _pulseTick = 0;

  @override
  Widget build(BuildContext context) {
    final duration = Ios27ConcentricGeometry.isReduceMotion(context)
        ? Ios27ConcentricGeometry.reducedMotionDuration
        : const Duration(milliseconds: 240);
    final palette = ApplePalette.of(context);
    final selected = widget.selected;
    final labelColor = palette.isDark
        ? (selected
            ? const Color(0xFF5CB8FF)
            : Colors.white.withValues(alpha: 0.70))
        : (selected
            ? AppleColors.systemBlue
            : const Color(0xFF2C303A).withValues(alpha: 0.76));
    return Ios27Pressable(
      pressedScale: Ios27Spring.pressSwellScale,
      borderRadius: 24,
      enableHaptic: false,
      onTap: () {
        if (selected) {
          setState(() => _pulseTick++);
        }
        widget.onTap();
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          MarcoAnimatedDockIcon(
            kind: widget.kind,
            fallbackIcon: selected ? widget.selectedIcon : widget.icon,
            selected: selected,
            size: 24,
            pulseTick: _pulseTick,
          ),
          const SizedBox(height: 2.5),
          AnimatedDefaultTextStyle(
            duration: duration,
            curve: Ios27Spring.snappy.curve,
            style: DefaultTextStyle.of(context).style.merge(
              TextStyle(
                color: labelColor,
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              textScaler: TextScaler.noScaling,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tactile iOS 27 second-order spring press animation wrapper (`Ios27Spring.snappy`):
/// supports mid-flight interruption momentum inheritance and Reduce Motion fallback.
class ApplePressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final double pressedOpacity;
  final bool enableHaptic;
  final HitTestBehavior behavior;

  const ApplePressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.95,
    this.pressedOpacity = 0.90,
    this.enableHaptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<ApplePressableScale> createState() => _ApplePressableScaleState();
}

class _ApplePressableScaleState extends State<ApplePressableScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(
      vsync: this,
      value: 0.0,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    Ios27Spring.animate(
      _controller,
      spring: Ios27Spring.snappy,
      target: 1.0,
      disableAnimations: Ios27ConcentricGeometry.isReduceMotion(context),
    );
  }

  void _rebound() {
    if (!mounted) return;
    Ios27Spring.animate(
      _controller,
      spring: Ios27Spring.snappy,
      target: 0.0,
      disableAnimations: Ios27ConcentricGeometry.isReduceMotion(context),
    );
  }

  void _handleTapUp(TapUpDetails _) => _rebound();

  void _handleTapCancel() => _rebound();

  void _handleTap() {
    if (widget.onTap == null) return;
    if (widget.enableHaptic) {
      HapticFeedback.selectionClick();
    }
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onTap == null && widget.onLongPress == null) {
      return widget.child;
    }
    final disableAnim = Ios27ConcentricGeometry.isReduceMotion(context);
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      onTap: widget.onTap != null ? _handleTap : null,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value.clamp(-0.2, 1.3);
          final scale = disableAnim
              ? 1.0
              : 1.0 - (1.0 - widget.pressedScale) * t;
          final opacity =
              (1.0 - (1.0 - widget.pressedOpacity) * t.clamp(0.0, 1.0))
                  .clamp(0.0, 1.0);
          return Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: Opacity(
              opacity: opacity,
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// Anti-aliased rounded card container that clips its [child] first and paints
/// a dual-stop specular anti-aliased rim stroke OVER (and outside) the clip
/// boundary so high-contrast posters/backdrops never exhibit corner jaggies
/// (`交界处锯齿`) or subpixel bleed.
class AppleSmoothClipCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final Color? backgroundColor;
  final List<BoxShadow>? boxShadow;
  final double rimStrength;
  final Color? borderColor;

  const AppleSmoothClipCard({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.backgroundColor,
    this.boxShadow,
    this.rimStrength = 0.90,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    Widget inner = child;
    if (backgroundColor != null) {
      inner = ColoredBox(color: backgroundColor!, child: inner);
    }
    final clipped = ClipRRect(
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: inner,
    );
    final rimmed = CustomPaint(
      foregroundPainter: borderColor != null
          ? _SolidSmoothRimPainter(
              radius: borderRadius,
              color: borderColor!,
            )
          : _LiquidRimPainter(
              shape: shape,
              strength: rimStrength,
            ),
      child: clipped,
    );
    if (boxShadow == null || boxShadow!.isEmpty) {
      return rimmed;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: boxShadow,
      ),
      child: rimmed,
    );
  }
}

class _SolidSmoothRimPainter extends CustomPainter {
  final double radius;
  final Color color;
  const _SolidSmoothRimPainter({required this.radius, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.45),
      Radius.circular(math.max(0.0, radius - 0.45)),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..isAntiAlias = true
      ..color = color;
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _SolidSmoothRimPainter old) =>
      old.radius != radius || old.color != color;
}

/// iOS 27 Liquid Glass capsule button: pearl-white primary lens or translucent
/// specular Glasswork glass for secondary actions.
class AppleCapsuleButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;
  final bool compact;
  final bool useBackdrop;
  const AppleCapsuleButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.compact = false,
    this.useBackdrop = true,
  });
  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinButton(label, icon: icon, selected: primary, onPressed: onPressed,
          foregroundColor: destructive ? AppleColors.systemRed : null);
    }
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    final fg = destructive
        ? AppleColors.systemRed
        : (primary
            ? (isDark ? const Color(0xFF0A0A0E) : Colors.white)
            : palette.labelPrimary);
    final labelRow = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 20,
        vertical: compact ? 7 : 11,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 14.5 : 17, color: fg),
            SizedBox(width: compact ? 5.5 : 7),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: compact ? 12.5 : 15,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );
    final centeredLabelRow = Center(
      widthFactor: 1.0,
      heightFactor: 1.0,
      child: labelRow,
    );
    final Widget buttonBody;
    if (primary) {
      buttonBody = DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFFFFFFFF), Color(0xFFE7E9EE)]
                : const [Color(0xFF0A84FF), Color(0xFF0070EA)],
          ),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isDark
                ? const Color(0xB3FFFFFF)
                : const Color(0x33FFFFFF),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? const Color(0x38000000)
                  : const Color(0x33007AFF),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: centeredLabelRow,
      );
    } else {
      const rimShape = StadiumBorder();
      final surface = CustomPaint(
        foregroundPainter: _LiquidRimPainter(
          shape: rimShape,
          strength: destructive ? 0.95 : 0.88,
          lightMode: !isDark,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: !isDark && !destructive
                ? Border.all(
                    color: Colors.black.withValues(alpha: 0.08),
                    width: 0.8,
                  )
                : null,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: destructive
                  ? const [
                      Color(0x3DFF453A),
                      Color(0x22FF453A),
                    ]
                  : (!isDark
                      ? const [
                          Color(0xF5FFFFFF),
                          Color(0xE8F3F5FA),
                        ]
                      : (_isWindowsDesktop
                          ? const [
                              Color(0xCC282832),
                              Color(0xB81C1C24),
                            ]
                          : const [
                              Color(0x24FFFFFF),
                              Color(0x121E1E24),
                            ])),
            ),
          ),
          child: centeredLabelRow,
        ),
      );
      buttonBody = (_isWindowsDesktop || !useBackdrop)
          ? surface
          : GlassworkBackdrop(radius: 999, child: surface);
    }
    return Ios27Pressable(
      pressedScale: _isWindowsDesktop ? 1.0 : Ios27Spring.pressSwellScale,
      pressedOpacity: 0.92,
      borderRadius: 999,
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: compact ? 32 : 42),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          clipBehavior: Clip.antiAlias,
          child: buttonBody,
        ),
      ),
    );
  }
}

/// High-frame-rate (120fps) Liquid Glass card surface for scrollable Settings groups
/// and expandable drawers: reacts live to [GlassworkBackdrop.intensity] with the same
/// Glasswork dual-rim specular optics and refractive gradient sheen, without allocating
/// per-card GPU `BackdropFilter` saveLayers that thrash during route transitions or `AnimatedSize`.
class AppleSettingsGlassCard extends StatelessWidget {
  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;

  const AppleSettingsGlassCard({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinPanel(radius: borderRadius?.topLeft.x ?? 20,
          padding: padding ?? EdgeInsets.zero, child: child);
    }
    final isDark = ApplePalette.isDarkOf(context);
    final radius = borderRadius ?? BorderRadius.circular(16);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: isDark
              ? null
              : const [
                  BoxShadow(
                    color: Color(0x0D0F172A),
                    blurRadius: 14,
                    offset: Offset(0, 4),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: ValueListenableBuilder<double>(
            valueListenable: GlassworkBackdrop.intensity,
            builder: (context, strength, _) {
              final s = strength.clamp(0.0, 1.0);
              if (!isDark) {
                return CustomPaint(
                  foregroundPainter: _LiquidRimPainter(
                    shape: shape,
                    strength: 0.28 + 0.72 * s,
                    lightMode: true,
                  ),
                  child: Container(
                    padding: padding,
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.065),
                        width: 0.75,
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.fromRGBO(255, 255, 255, (0.98 - 0.14 * s).clamp(0.80, 0.99)),
                          Color.fromRGBO(249, 250, 253, (0.95 - 0.15 * s).clamp(0.76, 0.97)),
                        ],
                      ),
                    ),
                    child: child,
                  ),
                );
              }
              final topSheen = Color.fromRGBO(255, 255, 255, 0.04 + 0.12 * s);
              final baseTop = Color.fromRGBO(
                34,
                36,
                46,
                (0.84 - 0.30 * s).clamp(0.46, 0.88),
              );
              final baseBottom = Color.fromRGBO(
                22,
                23,
                30,
                (0.88 - 0.28 * s).clamp(0.52, 0.92),
              );
              return CustomPaint(
                foregroundPainter: _LiquidRimPainter(
                  shape: shape,
                  strength: 0.28 + 0.82 * s,
                ),
                child: Container(
                  padding: padding,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(topSheen, baseTop),
                        baseBottom,
                      ],
                    ),
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
}

/// Inset grouped section (Settings-app style) with Liquid Glass translucency.
class AppleGroupedSection extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> children;
  const AppleGroupedSection({
    super.key,
    this.header,
    this.footer,
    required this.children,
  });
  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinSettingsGroup(header: header, footer: footer, children: children);
    }
    final palette = ApplePalette.of(context);
    final separated = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          Container(
            height: 0.5,
            margin: const EdgeInsets.only(left: 58),
            color: palette.separator,
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null && header!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text(
              header!,
              style: TextStyle(
                color: palette.labelSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ),
        AppleSettingsGlassCard(
          borderRadius: BorderRadius.circular(16),
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: separated,
          ),
        ),
        if (footer != null && footer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, right: 16),
            child: Text(
              footer!,
              style: TextStyle(
                color: palette.labelSecondary,
                fontSize: 12.5,
                height: 1.45,
                letterSpacing: 0.1,
              ),
            ),
          ),
      ],
    );
  }
}

/// iOS System Settings list row: vivid superellipse icon badge, crisp title, optional subtitle, and clean right-hand value.
class AppleGroupedTile extends StatelessWidget {
  final IconData icon;
  final double minHeight;
  final Color iconBgColor;
  final String title;
  final String? subtitle;
  final String? trailingText;
  final Widget? trailing;
  final VoidCallback? onTap;
  const AppleGroupedTile({
    super.key,
    required this.icon,
    this.minHeight = 52,
    this.iconBgColor = AppleColors.systemBlue,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    if (usesWindowsSettings(context)) {
      return WinSettingsRow(title: title, subtitle: subtitle, icon: icon,
          value: trailingText, trailing: trailing, onTap: onTap);
    }
    final palette = ApplePalette.of(context);
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.alphaBlend(const Color(0x28FFFFFF), iconBgColor),
                    iconBgColor,
                  ],
                ),
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(7.5),
                  side: const BorderSide(
                    color: Color(0x33FFFFFF),
                    width: 0.5,
                  ),
                ),
              ),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Icon(icon, color: Colors.white, size: 17),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: palette.labelPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.1,
                      height: 1.28,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.labelSecondary,
                        fontSize: 12.5,
                        height: 1.38,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailingText != null && trailingText!.isNotEmpty) ...[
              const SizedBox(width: 10),
              Flexible(
                flex: 0,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    trailingText!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.labelSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: 6),
              Icon(
                CupertinoIcons.chevron_right,
                color: palette.labelTertiary,
                size: 14.5,
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return ApplePressableScale(
      pressedScale: 0.982,
      pressedOpacity: 0.84,
      onTap: onTap,
      child: content,
    );
  }
}

/// Tracks currently open Flutter `showAppleModalSheet` instances so active
/// overlays (e.g., PlayerScreen HUD) pause auto-hide while a sheet is open.
final ValueNotifier<int> activeAppleModalSheetCount = ValueNotifier<int>(0);

class _ModalSheetOverlayScope extends StatefulWidget {
  final Widget child;
  const _ModalSheetOverlayScope({required this.child});

  @override
  State<_ModalSheetOverlayScope> createState() =>
      _ModalSheetOverlayScopeState();
}

class _ModalSheetOverlayScopeState extends State<_ModalSheetOverlayScope> {
  @override
  void initState() {
    super.initState();
    activeAppleModalSheetCount.value++;
  }

  @override
  void dispose() {
    if (activeAppleModalSheetCount.value > 0) {
      activeAppleModalSheetCount.value--;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<T?> _showWindowsModalDialog<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext) builder,
  Widget? trailingAction,
  double? maxWidth,
  bool ignoreKeyboardInsets = false,
}) {
  // Legacy account/maintenance forms use light text. Keep a readable dark
  // surface while giving Windows sheets the same spacing and controls.
  return showDialog<T>(
    context: context,
    barrierColor: Colors.black26,
    builder: (dialogContext) => _ModalSheetOverlayScope(
      child: WindowsPanelTone(
        dark: true,
        child: WindowsSettingsRegion(
          child: Builder(
            builder: (ctx) {
              final size = MediaQuery.sizeOf(ctx);
              return Dialog(
                backgroundColor: Colors.transparent,
                elevation: 0,
                insetPadding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(maxWidth ?? 760, size.width - 48),
                    maxHeight: size.height -
                        48 -
                        (ignoreKeyboardInsets
                            ? 0
                            : MediaQuery.viewInsetsOf(ctx).bottom),
                  ),
                  child: WinPanel(
                    dark: true,
                    padding: EdgeInsets.zero,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 14, 14, 14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    color: winInk(ctx),
                                    fontSize: 19,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (trailingAction != null) trailingAction,
                              IconButton(
                                tooltip: '关闭',
                                icon: Icon(
                                  CupertinoIcons.xmark,
                                  color: winMuted(ctx),
                                  size: 18,
                                ),
                                onPressed: () => Navigator.of(ctx).pop(),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                          height: 1,
                          color: winMuted(ctx).withValues(alpha: .15),
                        ),
                        Flexible(
                          child: TextSelectionMouseGuard(child: builder(ctx)),
                        ),
                      ],
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
}

/// iOS 27 Floating Inset Concentric Liquid Glass Sheet:
/// - 4-side floating inset margins (`10pt` sides/bottom on phone via
///   [Ios27ConcentricGeometry.sheetInsets], centered floating panel on iPad)
/// - `32pt` continuous concentric superellipse corners
/// - Native-sized top Grabber (`36 × 5pt`)
/// - Interactive rubber-band drag dismiss with velocity-inherited
///   [Ios27Spring] physics (`smooth` dismiss, `bouncy` rebound)
/// - Automatic `150ms` opacity fade fallback under Reduce Motion
Future<T?> showIos27LiquidSheet<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext) builder,
  Widget? trailingAction,
  double? maxWidth,
  bool ignoreKeyboardInsets = false,
  bool showGrabber = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  if (usesWindowsAppearance(context)) {
    return _showWindowsModalDialog<T>(
      context: context,
      title: title,
      builder: builder,
      trailingAction: trailingAction,
      maxWidth: maxWidth,
      ignoreKeyboardInsets: ignoreKeyboardInsets,
    );
  }
  return Navigator.of(context, rootNavigator: false).push<T>(
    _Ios27LiquidSheetRoute<T>(
      title: title,
      builder: builder,
      trailingAction: trailingAction,
      maxWidth: maxWidth,
      ignoreKeyboardInsets: ignoreKeyboardInsets,
      showGrabber: showGrabber,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
    ),
  );
}

class _Ios27LiquidSheetRoute<T> extends PopupRoute<T> {
  final String title;
  final Widget Function(BuildContext) builder;
  final Widget? trailingAction;
  final double? maxWidth;
  final bool ignoreKeyboardInsets;
  final bool showGrabber;
  final bool isDismissible;
  final bool enableDrag;

  _Ios27LiquidSheetRoute({
    required this.title,
    required this.builder,
    this.trailingAction,
    this.maxWidth,
    this.ignoreKeyboardInsets = false,
    this.showGrabber = true,
    this.isDismissible = true,
    this.enableDrag = true,
  });

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.34);

  @override
  bool get barrierDismissible => isDismissible;

  @override
  String? get barrierLabel => '关闭浮层面板';

  @override
  Duration get transitionDuration => Ios27Spring.smooth.nominalDuration;

  @override
  Duration get reverseTransitionDuration => Ios27Spring.smooth.nominalDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final sheet = _Ios27LiquidSheetContainer(
      title: title,
      builder: builder,
      trailingAction: trailingAction,
      maxWidth: maxWidth,
      ignoreKeyboardInsets: ignoreKeyboardInsets,
      showGrabber: showGrabber,
      enableDrag: enableDrag,
      onDismissRequested: () => Navigator.of(context).maybePop(),
    );
    final wrapped = _ModalSheetOverlayScope(child: sheet);
    if (ignoreKeyboardInsets) {
      return MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: wrapped,
      );
    }
    return wrapped;
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Ios27ConcentricGeometry.isReduceMotion(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.linear,
          reverseCurve: Curves.linear,
        ),
        child: child,
      );
    }
    final centered = Ios27ConcentricGeometry.isCenteredFloatingPanel(context);
    final springCurve = Ios27Spring.smooth.curve;
    final curved = CurvedAnimation(
      parent: animation,
      curve: springCurve,
      reverseCurve: springCurve.flipped,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: Offset(0.0, centered ? 0.05 : 0.14),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween<double>(
            begin: centered ? 0.94 : 0.97,
            end: 1.0,
          ).animate(curved),
          alignment: centered ? Alignment.center : Alignment.bottomCenter,
          child: child,
        ),
      ),
    );
  }
}

class _Ios27LiquidSheetContainer extends StatefulWidget {
  final String title;
  final Widget Function(BuildContext) builder;
  final Widget? trailingAction;
  final double? maxWidth;
  final bool ignoreKeyboardInsets;
  final bool showGrabber;
  final bool enableDrag;
  final VoidCallback onDismissRequested;

  const _Ios27LiquidSheetContainer({
    required this.title,
    required this.builder,
    required this.onDismissRequested,
    this.trailingAction,
    this.maxWidth,
    this.ignoreKeyboardInsets = false,
    this.showGrabber = true,
    this.enableDrag = true,
  });

  @override
  State<_Ios27LiquidSheetContainer> createState() =>
      _Ios27LiquidSheetContainerState();
}

class _Ios27LiquidSheetContainerState extends State<_Ios27LiquidSheetContainer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dragCtrl;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _dragCtrl = AnimationController.unbounded(vsync: this, value: 0.0);
  }

  @override
  void dispose() {
    _dragCtrl.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (!widget.enableDrag || _dismissing) return;
    final current = _dragCtrl.value + details.delta.dy;
    _dragCtrl.value = current;
  }

  void _onDragEnd(DragEndDetails details) {
    if (!widget.enableDrag || _dismissing) return;
    final offset = _dragCtrl.value;
    final velocity = details.primaryVelocity ?? 0.0;
    final disableAnim = Ios27ConcentricGeometry.isReduceMotion(context);
    final screenH = MediaQuery.sizeOf(context).height;
    final dismissThreshold = math.min(130.0, screenH * 0.24);
    if (velocity > 420.0 || offset > dismissThreshold) {
      _dismissing = true;
      if (disableAnim) {
        widget.onDismissRequested();
        return;
      }
      final target = math.max(offset + 140.0, screenH * 0.42);
      _dragCtrl
          .animateWith(
            Ios27Spring.smooth.simulation(
              start: offset,
              end: target,
              velocity: velocity,
              tolerance: const Tolerance(velocity: 5.0, distance: 2.0),
            ),
          )
          .whenComplete(() {
        if (mounted) widget.onDismissRequested();
      });
      return;
    }
    Ios27Spring.animate(
      _dragCtrl,
      spring: Ios27Spring.bouncy,
      target: 0.0,
      initialVelocity: velocity,
      disableAnimations: disableAnim,
      tolerance: const Tolerance(velocity: 1.0, distance: 0.5),
    );
  }

  void _onDragCancel() {
    if (!widget.enableDrag || _dismissing) return;
    Ios27Spring.animate(
      _dragCtrl,
      spring: Ios27Spring.bouncy,
      target: 0.0,
      disableAnimations: Ios27ConcentricGeometry.isReduceMotion(context),
      tolerance: const Tolerance(velocity: 1.0, distance: 0.5),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;
    final centered = Ios27ConcentricGeometry.isCenteredFloatingPanel(context);
    final insets = Ios27ConcentricGeometry.sheetInsets(
      context,
      ignoreKeyboardInsets: widget.ignoreKeyboardInsets,
    );
    final effectiveMaxWidth = widget.maxWidth ??
        (centered
            ? math.min(screenSize.width - insets.horizontal, 580.0)
            : (isLandscape
                ? math.min(screenSize.width - insets.horizontal, 680.0)
                : 540.0));
    const outerRadius = Ios27ConcentricGeometry.sheetOuterRadiusPt;
    final continuousShape = Ios27ConcentricGeometry.continuousShape(
      radius: outerRadius,
    );

    final headerBar = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: widget.enableDrag ? _onDragUpdate : null,
      onVerticalDragEnd: widget.enableDrag ? _onDragEnd : null,
      onVerticalDragCancel: widget.enableDrag ? _onDragCancel : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.showGrabber) ...[
            const SizedBox(height: 8),
            Container(
              key: const ValueKey('ios27-liquid-sheet-grabber'),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: ApplePalette.isDarkOf(context)
                    ? const Color(0x66EBEBF5)
                    : const Color(0x36000000),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: ApplePalette.of(context).labelPrimary,
                      fontSize: 17.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.35,
                    ),
                  ),
                ),
                if (widget.trailingAction != null) widget.trailingAction!,
                Ios27Pressable(
                  pressedScale: Ios27Spring.pressSwellScale,
                  borderRadius: 999,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      CupertinoIcons.xmark_circle_fill,
                      color: ApplePalette.of(context).labelTertiary,
                      size: 26,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: ApplePalette.of(context).separator),
        ],
      ),
    );

    final sheetSurface = RepaintBoundary(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: effectiveMaxWidth,
          maxHeight: screenSize.height * (centered ? 0.84 : 0.88),
        ),
        child: ClipPath(
          key: const ValueKey('ios27-liquid-sheet-container'),
          clipper: ShapeBorderClipper(shape: continuousShape),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: LiquidGlass(
                      borderRadius: outerRadius,
                      rimStrength: 1.0,
                      tint: ApplePalette.isDarkOf(context)
                          ? const Color(0x001E1E22)
                          : const Color(0xE8F2F2F7),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              RepaintBoundary(
                child: Material(
                  color: Colors.transparent,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      headerBar,
                      Flexible(
                        child: TextSelectionMouseGuard(
                          child: widget.builder(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: insets,
      child: Align(
        alignment: centered ? Alignment.center : Alignment.bottomCenter,
        child: AnimatedBuilder(
          animation: _dragCtrl,
          child: sheetSurface,
          builder: (context, child) {
            final raw = _dragCtrl.value;
            final dy = raw < 0
                ? Ios27RubberBand.apply(raw, dimension: 140.0)
                : raw;
            final scale = raw > 0
                ? (1.0 - (raw / 1800.0).clamp(0.0, 0.045))
                : (1.0 + ((-dy) / 2800.0).clamp(0.0, 0.02));
            final fade = raw > 0
                ? (1.0 - (raw / (screenSize.height * 0.55)).clamp(0.0, 0.85))
                : 1.0;
            return Transform.translate(
              offset: Offset(0.0, dy),
              child: Transform.scale(
                scale: scale,
                alignment: centered ? Alignment.center : Alignment.bottomCenter,
                child: Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// iOS 27 Liquid Glass modal sheet: delegates to [showIos27LiquidSheet] on
/// iOS / iPadOS / macOS / Android and keeps [WinPanel] dialogs on Windows.
Future<T?> showAppleModalSheet<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext) builder,
  Widget? trailingAction,
  double? maxWidth,
  bool ignoreKeyboardInsets = false,
}) =>
    showIos27LiquidSheet<T>(
      context: context,
      title: title,
      builder: builder,
      trailingAction: trailingAction,
      maxWidth: maxWidth,
      ignoreKeyboardInsets: ignoreKeyboardInsets,
    );

/// iOS 27 Liquid Glass ambient app background: deep obsidian or themed canvas with
/// breathing dynamic flowing-light aurora orbs (`呼吸式动态流光氛围`), optional custom
/// wallpaper, and blurred artwork bleed.
class AppleAmbientBackground extends StatefulWidget {
  final Widget? artwork;
  final Widget? customWallpaper;
  final String preset;
  final bool showAmbientArtwork;
  final double blurSigma;
  final bool animate;

  const AppleAmbientBackground({
    super.key,
    this.artwork,
    this.customWallpaper,
    this.preset = 'obsidian',
    this.showAmbientArtwork = true,
    this.blurSigma = 60,
    this.animate = true,
  });

  @override
  State<AppleAmbientBackground> createState() => _AppleAmbientBackgroundState();
}

class _AppleAmbientBackgroundState extends State<AppleAmbientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathController;

  bool get _useAuroraShader =>
      widget.preset == 'aurora' && !OhosRuntime.isOhos && !_isWindowsDesktop;

  bool get _shouldAnimate {
    if (_useAuroraShader) return false;
    if (!widget.animate || !widget.showAmbientArtwork) return false;
    if (_isWindowsDesktop) return false;
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
      return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 7800),
      value: 0.45,
    );
    if (_shouldAnimate) {
      _breathController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant AppleAmbientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldAnimate && !_breathController.isAnimating) {
      _breathController.repeat(reverse: true);
    } else if (!_shouldAnimate && _breathController.isAnimating) {
      _breathController.stop();
      _breathController.value = 0.45;
    }
  }

  @override
  void dispose() {
    _breathController.dispose();
    super.dispose();
  }

  (List<Color>, Color, Color, Color) _resolveThemeColors() {
    switch (widget.preset) {
      case 'midnight':
        return (
          const [Color(0xFF10203B), Color(0xFF091122), Color(0xFF03050A)],
          const Color(0x340A84FF),
          const Color(0x2864D2FF),
          const Color(0x245E5CE6),
        );
      case 'aurora':
        return (
          const [Color(0xFF231338), Color(0xFF120A1E), Color(0xFF05020A)],
          const Color(0x36BF5AF2),
          const Color(0x28FF375F),
          const Color(0x245AC8FA),
        );
      case 'amber':
        return (
          const [Color(0xFF2D1D12), Color(0xFF150D08), Color(0xFF060402)],
          const Color(0x32FF9F0A),
          const Color(0x24FF453A),
          const Color(0x20FFD60A),
        );
      case 'emerald':
        return (
          const [Color(0xFF102A24), Color(0xFF081613), Color(0xFF020706)],
          const Color(0x3030D158),
          const Color(0x2464D2FF),
          const Color(0x2034C759),
        );
      default:
        return (
          const [Color(0xFF15161E), Color(0xFF0A0B0F), Color(0xFF020305)],
          const Color(0x2A5AC8FA),
          const Color(0x225E5CE6),
          const Color(0x1E0A84FF),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = ApplePalette.isDarkOf(context);
    if (!isDark) {
      // Soft soothing warm pearl-mist canvas — easy on the eyes instead of
      // stark clinical white, with subtle atmospheric top sheen.
      return RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFFEDF0F5),
                    Color(0xFFE8ECF3),
                    Color(0xFFE2E6EF),
                  ],
                  stops: [0.0, 0.48, 1.0],
                ),
              ),
            ),
            const Positioned(
              top: -90,
              left: -60,
              right: -60,
              height: 300,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.0, -0.4),
                      radius: 1.05,
                      colors: [
                        Color(0x16007AFF),
                        Color(0x0D7C5CE6),
                        Color(0x00FFFFFF),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_useAuroraShader)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.04,
                    child: AuroraBackground(
                      key: const Key('apple-ambient-aurora'),
                      active: widget.animate && widget.showAmbientArtwork,
                      strength: widget.showAmbientArtwork
                          ? MotionTokens.auroraDefaultStrength
                          : 0.28,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    final (gradientColors, primaryGlow, secondaryGlow, accentGlow) =
        _resolveThemeColors();
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_useAuroraShader)
            Positioned.fill(
              child: AuroraBackground(
                key: const Key('apple-ambient-aurora'),
                active: widget.animate && widget.showAmbientArtwork,
                strength: widget.showAmbientArtwork
                    ? MotionTokens.auroraDefaultStrength
                    : 0.28,
              ),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: gradientColors,
                  stops: const [0.0, 0.38, 0.82],
                ),
              ),
            ),
        if (widget.customWallpaper != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: (widget.blurSigma * 0.35).clamp(8.0, 36.0),
                      sigmaY: (widget.blurSigma * 0.35).clamp(8.0, 36.0),
                      tileMode: TileMode.decal,
                    ),
                    child: widget.customWallpaper,
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x7808090D),
                          Color(0xA608090D),
                          Color(0xCC050608),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (widget.artwork != null && widget.showAmbientArtwork)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 560,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: ClipRect(
                  child: _isWindowsDesktop
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            Opacity(
                              opacity: 0.44,
                              child: ImageFiltered(
                                imageFilter: ImageFilter.blur(
                                  sigmaX: math.min(widget.blurSigma, 24.0),
                                  sigmaY: math.min(widget.blurSigma, 24.0),
                                  tileMode: TileMode.decal,
                                ),
                                child: widget.artwork,
                              ),
                            ),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    const Color(0x00000000),
                                    gradientColors[1].withValues(alpha: 0.72),
                                    gradientColors[1],
                                  ],
                                  stops: const [0.0, 0.58, 0.96],
                                ),
                              ),
                            ),
                          ],
                        )
                      : ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: (rect) => const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x80FFFFFF),
                              Color(0x38FFFFFF),
                              Color(0x00FFFFFF),
                            ],
                            stops: [0.0, 0.45, 0.88],
                          ).createShader(rect),
                          child: ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: widget.blurSigma,
                              sigmaY: widget.blurSigma,
                              tileMode: TileMode.decal,
                            ),
                            child: widget.artwork,
                          ),
                        ),
                ),
              ),
            ),
          ),
        if (!_useAuroraShader)
          Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _breathController,
              builder: (context, _) {
                final t = Curves.easeInOutSine.transform(_breathController.value);
                final active = widget.showAmbientArtwork ? 1.0 : 0.45;
                final pAlpha = (primaryGlow.a * (0.72 + 0.34 * t) * active).clamp(0.0, 1.0);
                final sAlpha = (secondaryGlow.a * (1.02 - 0.32 * t) * active).clamp(0.0, 1.0);
                final aAlpha = (accentGlow.a * (0.68 + 0.32 * math.sin(t * math.pi)) * active).clamp(0.0, 1.0);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(-0.35 + 0.70 * t, -0.78 + 0.16 * t),
                          radius: 0.78 + 0.22 * t,
                          colors: [
                            primaryGlow.withValues(alpha: pAlpha),
                            const Color(0x00000000),
                          ],
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(0.55 - 0.75 * t, 0.05 + 0.25 * (1.0 - t)),
                          radius: 0.82 + 0.18 * (1.0 - t),
                          colors: [
                            secondaryGlow.withValues(alpha: sAlpha),
                            const Color(0x00000000),
                          ],
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: Alignment(-0.20 + 0.45 * (1.0 - t), 0.88 - 0.12 * t),
                          radius: 0.70 + 0.20 * t,
                          colors: [
                            accentGlow.withValues(alpha: aAlpha),
                            const Color(0x00000000),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        ],
      ),
    );
  }
}

/// Desktop & Windows IME-safe search field styled after iOS 27 Liquid Glass search pills.
/// Keeps a stable [FocusNode] across parent [StatefulBuilder] rebuilds, avoids rebuilding
/// the underlying [CupertinoTextField] during Win32 CJK IME composition, and retains keyboard
/// focus when clearing text or completing modal sheet transitions.
class AppleSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String placeholder;
  final bool autofocus;
  final bool borderless;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onSuffixTap;

  const AppleSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.placeholder = '搜索',
    this.autofocus = false,
    this.borderless = false,
    this.onChanged,
    this.onSubmitted,
    this.onSuffixTap,
  });

  @override
  State<AppleSearchField> createState() => _AppleSearchFieldState();
}

class _AppleSearchFieldState extends State<AppleSearchField> {
  FocusNode? _internalFocusNode;
  Animation<double>? _routeAnimation;
  DateTime? _lastSubmitAt;

  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_internalFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _effectiveFocusNode.onKeyEvent = _handleKeyEvent;
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _effectiveFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeAnim = ModalRoute.of(context)?.animation;
    if (routeAnim != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
      _routeAnimation = routeAnim;
      _routeAnimation?.addStatusListener(_onRouteAnimationStatus);
    }
  }

  @override
  void didUpdateWidget(covariant AppleSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.onKeyEvent = null;
      _effectiveFocusNode.onKeyEvent = _handleKeyEvent;
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && widget.autofocus && mounted) {
      _effectiveFocusNode.requestFocus();
    }
  }

  void _submit(String value) {
    final cb = widget.onSubmitted;
    if (cb == null) return;
    final now = DateTime.now();
    if (_lastSubmitAt != null &&
        now.difference(_lastSubmitAt!) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastSubmitAt = now;
    cb(value);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      if (!widget.controller.value.isComposingRangeValid &&
          widget.onSubmitted != null) {
        _submit(widget.controller.text);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    if (widget.focusNode != null) {
      widget.focusNode!.onKeyEvent = null;
    }
    _internalFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ApplePalette.of(context);
    final isDark = palette.isDark;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _effectiveFocusNode.requestFocus(),
      child: Container(
        constraints: BoxConstraints(minHeight: widget.borderless ? 36 : 38),
        padding: widget.borderless
            ? const EdgeInsets.symmetric(horizontal: 4, vertical: 0)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: widget.borderless
            ? null
            : BoxDecoration(
                color: isDark
                    ? const Color(0x40787884)
                    : const Color(0x16767680),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: isDark
                      ? const Color(0x24FFFFFF)
                      : const Color(0x14000000),
                  width: 0.65,
                ),
              ),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.search,
              size: 17,
              color: palette.labelSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextSelectionMouseGuard(
                child: CupertinoTextField.borderless(
                  controller: widget.controller,
                  focusNode: _effectiveFocusNode,
                  autofocus: widget.autofocus,
                  placeholder: widget.placeholder,
                  placeholderStyle: TextStyle(
                    color: palette.labelSecondary,
                    fontSize: 15,
                  ),
                  style: TextStyle(
                    color: palette.labelPrimary,
                    fontSize: 15,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  cursorColor: palette.systemBlue,
                  textInputAction: TextInputAction.search,
                  onChanged: widget.onChanged,
                  onSubmitted: _submit,
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return ExcludeFocus(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (widget.onSuffixTap != null) {
                        widget.onSuffixTap!();
                      } else {
                        widget.controller.clear();
                        widget.onChanged?.call('');
                      }
                      _effectiveFocusNode.requestFocus();
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(
                        left: 6,
                        right: 2,
                        top: 4,
                        bottom: 4,
                      ),
                      child: Icon(
                        CupertinoIcons.clear_thick_circled,
                        size: 17,
                        color: palette.labelSecondary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Excludes [PointerDeviceKind.mouse] from [ScrollConfiguration.dragDevices]
/// around text inputs (`TextField`, `TextFormField`, `CupertinoTextField`) so
/// mouse dragging selects text instead of scrolling the field's internal
/// [Scrollable] on desktop.
class TextSelectionMouseGuard extends StatelessWidget {
  final Widget child;

  const TextSelectionMouseGuard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    final devices = behavior.dragDevices;
    if (!devices.contains(PointerDeviceKind.mouse)) {
      return child;
    }
    final withoutMouse = <PointerDeviceKind>{
      for (final device in devices)
        if (device != PointerDeviceKind.mouse) device,
    };
    return ScrollConfiguration(
      behavior: behavior.copyWith(dragDevices: withoutMouse),
      child: child,
    );
  }
}
