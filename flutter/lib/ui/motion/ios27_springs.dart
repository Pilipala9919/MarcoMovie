// Copyright (C) 2026 Pilipala
// SPDX-License-Identifier: GPL-3.0-only
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'motion_tokens.dart';

/// Second-order spring specification aligned with Apple iOS 27
/// `Spring(duration:bounce:)` physics:
/// - angular frequency: $\omega = 2\pi / \text{duration}$
/// - damping ratio: $\zeta = 1 - \text{bounce}$
/// - stiffness: $k = m \omega^2$
/// - viscous damping: $c = 2 \zeta \sqrt{k m}$
@immutable
class Ios27SpringSpec {
  final double duration;
  final double bounce;
  final double mass;

  const Ios27SpringSpec({
    required this.duration,
    required this.bounce,
    this.mass = 1.0,
  });

  double get omega => (2.0 * math.pi) / duration;

  double get dampingRatio => (1.0 - bounce).clamp(0.05, 2.0);

  double get stiffness => mass * omega * omega;

  double get viscousDamping => 2.0 * dampingRatio * math.sqrt(stiffness * mass);

  Duration get nominalDuration =>
      Duration(microseconds: (duration * 1000000).round());

  SpringDescription get description => SpringDescription(
        mass: mass,
        stiffness: stiffness,
        damping: viscousDamping,
      );

  MotionSpringToken toMotionSpringToken() => MotionSpringToken(
        response: duration,
        dampingRatio: dampingRatio,
        mass: mass,
        stiffness: stiffness,
        viscousDamping: viscousDamping,
        motionSpringFrequency: omega,
      );

  /// Creates a Flutter [SpringSimulation] supporting gesture [velocity]
  /// inheritance and arbitrary [start] / [end] targets for mid-flight
  /// interruption and retargeting.
  SpringSimulation simulation({
    double start = 0.0,
    double end = 1.0,
    double velocity = 0.0,
    Tolerance tolerance = const Tolerance(
      velocity: 0.001,
      distance: 0.001,
    ),
  }) {
    return SpringSimulation(
      description,
      start,
      end,
      velocity,
      tolerance: tolerance,
    );
  }

  /// Normalized monotonic-friendly [Curve] backed by this spring's physical
  /// [SpringSimulation] over its settle horizon.
  Curve get curve => _Ios27SpringCurve(this);
}

class _Ios27SpringCurve extends Curve {
  final Ios27SpringSpec spec;
  late final SpringSimulation _sim = spec.simulation();
  late final double _horizonSec = _computeHorizon();

  _Ios27SpringCurve(this.spec);

  double _computeHorizon() {
    // Critically damped settles cleanly around ~1.35 * duration;
    // underdamped settles slightly later proportional to bounce.
    return spec.duration * (1.35 + spec.bounce * 1.4);
  }

  @override
  double transformInternal(double t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    final sampleTime = t * _horizonSec;
    final x = _sim.x(sampleTime);
    // Smoothly blend last 8% to exact 1.0 so Curve contract f(1)==1 holds
    // without a visual step at completion.
    if (t > 0.92) {
      final tail = (t - 0.92) / 0.08;
      return x + (1.0 - x) * tail;
    }
    return x;
  }
}

/// Canonical Apple iOS 27 second-order spring presets and velocity-inheriting
/// animation helpers.
abstract final class Ios27Spring {
  /// Tactile micro-gel swell (`1.035x` illumination), capsule switch, list tap.
  static const Ios27SpringSpec snappy = Ios27SpringSpec(
    duration: 0.28,
    bounce: 0.12,
  );

  /// Window route push/pop, floating liquid sheet rise/dismiss, modal scrim.
  static const Ios27SpringSpec smooth = Ios27SpringSpec(
    duration: 0.38,
    bounce: 0.0,
  );

  /// Fluid morphing popovers, rubber-band release, search bar focus expansion.
  static const Ios27SpringSpec bouncy = Ios27SpringSpec(
    duration: 0.44,
    bounce: 0.24,
  );

  /// Native iOS 27 button touch gel-swell target scale (`1.035x`).
  static const double pressSwellScale = 1.035;

  /// Drives [controller] toward [target] using a real [SpringSimulation].
  ///
  /// When [initialVelocity] is omitted and [controller] is already animating
  /// (mid-flight interruption), its live [AnimationController.velocity] is
  /// inherited seamlessly so direction reversals have zero velocity discontinuity.
  ///
  /// When [disableAnimations] is `true`, falls back to a clean `150ms` linear
  /// transition per accessibility Reduce Motion guidelines.
  static TickerFuture animate(
    AnimationController controller, {
    required Ios27SpringSpec spring,
    double target = 1.0,
    double? initialVelocity,
    bool disableAnimations = false,
    Tolerance tolerance = const Tolerance(
      velocity: 0.001,
      distance: 0.001,
    ),
  }) {
    if (disableAnimations) {
      return controller.animateTo(
        target,
        duration: Ios27ConcentricGeometry.reducedMotionDuration,
        curve: Curves.linear,
      );
    }
    final inheritedVelocity = initialVelocity ??
        (controller.isAnimating ? controller.velocity : 0.0);
    final sim = spring.simulation(
      start: controller.value,
      end: target,
      velocity: inheritedVelocity,
      tolerance: tolerance,
    );
    return controller.animateWith(sim);
  }
}

/// Apple rubber-band resistance helper for over-scroll and sheet drag bounds.
abstract final class Ios27RubberBand {
  static double apply(
    double offset, {
    double dimension = 300.0,
    double coefficient = 0.55,
  }) {
    if (offset == 0.0 || dimension <= 0.0) return 0.0;
    final abs = offset.abs();
    final damped =
        (1.0 - (1.0 / ((abs * coefficient / dimension) + 1.0))) * dimension;
    return offset.isNegative ? -damped : damped;
  }
}

/// iOS 27 Concentric Window & Floating Surface Geometry:
/// - Floating phone sheet inset margin: `10pt` bottom/sides
/// - Floating iPad/wide sheet: centered floating panel
/// - Concentric corner radius formula: $R_{\text{inner}} = \max(R_{\text{outer}} - \text{padding}, 8.0)$
/// - Reduce Motion accessibility duration: `150ms`
abstract final class Ios27ConcentricGeometry {
  static const double phoneInsetMarginPt = 10.0;
  static const double sheetOuterRadiusPt = 32.0;
  static const double minInnerRadiusPt = 8.0;
  static const Duration reducedMotionDuration = Duration(milliseconds: 150);

  /// Concentric inner corner radius: $\max(R_{\text{outer}} - \text{padding}, 8.0)$.
  static double innerRadius({
    required double outerRadius,
    required double padding,
  }) =>
      math.max(outerRadius - padding, minInnerRadiusPt);

  /// Whether floating sheets/panels should center as an iPad-style floating card.
  static bool isCenteredFloatingPanel(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide >= 600.0;
  }

  /// Safe-area-aware floating inset margins for iOS 27 liquid sheets.
  /// - Phone: `10pt` horizontal and bottom floating margin (above home indicator
  ///   or bottom bezel so the sheet visibly floats off all 4 edges).
  /// - iPad / wide display: generous centered margin around the floating panel.
  static EdgeInsets sheetInsets(
    BuildContext context, {
    bool ignoreKeyboardInsets = false,
  }) {
    final safe = MediaQuery.paddingOf(context);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height;
    final centered = isCenteredFloatingPanel(context);

    final keyboardBottom = ignoreKeyboardInsets ? 0.0 : viewInsets.bottom;
    final baseBottom = centered
        ? math.max(24.0, safe.bottom + 12.0)
        : (safe.bottom > 0
            ? math.max(safe.bottom - 12.0, phoneInsetMarginPt)
            : phoneInsetMarginPt);
    final bottom = keyboardBottom > 0
        ? keyboardBottom + (centered ? 24.0 : phoneInsetMarginPt)
        : (centered
            ? baseBottom
            : (isLandscape
                ? math.max(safe.bottom, phoneInsetMarginPt)
                : baseBottom));

    final sideBase = centered ? 24.0 : phoneInsetMarginPt;
    final left = math.max(sideBase, safe.left);
    final right = math.max(sideBase, safe.right);
    final top = centered
        ? math.max(24.0, safe.top + 12.0)
        : math.max(safe.top + 8.0, isLandscape ? 10.0 : 28.0);

    return EdgeInsets.fromLTRB(left, top, right, bottom);
  }

  /// Continuous superellipse shape matching Apple hardware & UIKit corner smoothing.
  static ShapeBorder continuousShape({
    required double radius,
    BorderSide side = BorderSide.none,
  }) =>
      RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
        side: side,
      );

  static bool isReduceMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Interactive iOS 27 touch-response wrapper powered by [Ios27Spring.snappy]:
/// - On Apple touch / desktop platforms (`!Windows` unless explicitly requested):
///   produces iOS 27's gentle `1.035x` gel-swell + radial touch illumination on
///   press, and rebounds cleanly via [SpringSimulation] with mid-flight
///   interruption momentum preservation.
/// - Respects `MediaQuery.disableAnimationsOf(context)` (`150ms` opacity fade).
class Ios27Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final double pressedOpacity;
  final double borderRadius;
  final bool enableIllumination;
  final bool enableHaptic;
  final HitTestBehavior behavior;

  const Ios27Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = Ios27Spring.pressSwellScale,
    this.pressedOpacity = 1.0,
    this.borderRadius = 999.0,
    this.enableIllumination = true,
    this.enableHaptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<Ios27Pressable> createState() => _Ios27PressableState();
}

class _Ios27PressableState extends State<Ios27Pressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Offset? _tapLocalNormalized;

  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

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

  bool get _interactive => widget.onTap != null || widget.onLongPress != null;

  void _updateTapPosition(Offset localPos) {
    final ro = context.findRenderObject();
    if (ro is RenderBox && ro.hasSize && ro.size.width > 0 && ro.size.height > 0) {
      final nx = ((localPos.dx / ro.size.width) * 2.0 - 1.0).clamp(-1.0, 1.0);
      final ny = ((localPos.dy / ro.size.height) * 2.0 - 1.0).clamp(-1.0, 1.0);
      _tapLocalNormalized = Offset(nx, ny);
    } else {
      _tapLocalNormalized = Offset.zero;
    }
  }

  void _handleTapDown(TapDownDetails details) {
    if (!_interactive) return;
    _updateTapPosition(details.localPosition);
    final disableAnim = Ios27ConcentricGeometry.isReduceMotion(context);
    Ios27Spring.animate(
      _controller,
      spring: Ios27Spring.snappy,
      target: 1.0,
      disableAnimations: disableAnim,
    );
  }

  void _handleRelease() {
    if (!mounted) return;
    final disableAnim = Ios27ConcentricGeometry.isReduceMotion(context);
    Ios27Spring.animate(
      _controller,
      spring: Ios27Spring.snappy,
      target: 0.0,
      disableAnimations: disableAnim,
    );
  }

  void _handleTap() {
    if (widget.onTap == null) return;
    if (widget.enableHaptic) {
      HapticFeedback.selectionClick();
    }
    widget.onTap!();
  }

  @override
  Widget build(BuildContext context) {
    if (!_interactive) return widget.child;
    final disableAnim = Ios27ConcentricGeometry.isReduceMotion(context);
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _handleTapDown,
      onTapUp: (_) => _handleRelease(),
      onTapCancel: _handleRelease,
      onTap: widget.onTap != null ? _handleTap : null,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final t = _controller.value;
          final effectiveScale = disableAnim || _isWindows
              ? 1.0
              : (1.0 + (widget.pressedScale - 1.0) * t).clamp(0.88, 1.12);
          final clampedT = t.clamp(0.0, 1.0);
          final effectiveOpacity =
              (1.0 - (1.0 - widget.pressedOpacity) * clampedT).clamp(0.0, 1.0);
          Widget result = child!;
          if (widget.enableIllumination && clampedT > 0.01) {
            final center = _tapLocalNormalized ?? Offset.zero;
            result = Stack(
              fit: StackFit.passthrough,
              children: [
                result,
                Positioned.fill(
                  child: IgnorePointer(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(widget.borderRadius),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment(center.dx, center.dy),
                            radius: 1.15,
                            colors: [
                              Colors.white.withValues(alpha: 0.22 * clampedT),
                              Colors.white.withValues(alpha: 0.06 * clampedT),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.55, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          if (effectiveOpacity < 0.999) {
            result = Opacity(opacity: effectiveOpacity, child: result);
          }
          if ((effectiveScale - 1.0).abs() > 0.0005) {
            result = Transform.scale(
              scale: effectiveScale,
              alignment: Alignment.center,
              child: result,
            );
          }
          return result;
        },
      ),
    );
  }
}
