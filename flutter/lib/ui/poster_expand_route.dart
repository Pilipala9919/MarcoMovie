import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';

import 'motion/ios27_springs.dart';
import 'poster_image.dart';

/// Tracks the currently expanding/collapsing poster card ID and its live
/// transition progress (`0.0` at rest -> `1.0` fully open) so:
/// - The originating poster card on Home / Discovery / Search / Library hides
///   cleanly without collapsing its layout [RenderBox], eliminating duplicate
///   stationary ghosting behind the flying container.
/// - Full-bleed Home Hero chrome (floating top header, title, CTA, dots) can
///   cross-fade in exact lockstep with the route animation.
class PosterExpandRegistry {
  PosterExpandRegistry._();

  static final ValueNotifier<String?> activeCardId =
      ValueNotifier<String?>(null);
  static final ValueNotifier<double> activeProgress =
      ValueNotifier<double>(0.0);
  static final List<String> _cardStack = <String>[];

  static void claim(String id) {
    if (id.isEmpty) return;
    _cardStack.add(id);
    activeCardId.value = id;
  }

  static void release(String id) {
    if (id.isEmpty) return;
    final idx = _cardStack.lastIndexOf(id);
    if (idx >= 0) {
      _cardStack.removeAt(idx);
    }
    activeCardId.value = _cardStack.isEmpty ? null : _cardStack.last;
    if (_cardStack.isEmpty) {
      activeProgress.value = 0.0;
    }
  }
}

/// Wraps a clickable poster card so it hides cleanly without collapsing layout
/// space strictly while its [PosterExpandRoute] is actively flying away from
/// rest (`activeProgress > 0.035`), keeping the real card painted underneath at
/// frame 0 of push and during the final landing frames of pop so there is NEVER
/// a 1-frame white hole flash or jump.
class PosterExpandSourceCard extends StatelessWidget {
  final String cardId;
  final Widget child;

  const PosterExpandSourceCard({
    super.key,
    required this.cardId,
    required this.child,
  });

  static final Listenable _registryListenable = Listenable.merge([
    PosterExpandRegistry.activeCardId,
    PosterExpandRegistry.activeProgress,
  ]);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _registryListenable,
      child: child,
      builder: (context, cardChild) {
        final activeId = PosterExpandRegistry.activeCardId.value;
        final progress = PosterExpandRegistry.activeProgress.value;
        final hidden =
            activeId != null && activeId == cardId && progress > 0.035;
        return Visibility(
          visible: !hidden,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: cardChild!,
        );
      },
    );
  }
}

/// iOS 27 Fluid `.zoom` shared-container route for every series/show card AND
/// full-bleed Home Hero on iOS / iPadOS:
///
/// - **iOS 27 Second-Order Spring (`Ios27Spring.smooth`)**: Driven by
///   `Spring(duration: 0.38, bounce: 0.0)` with zero overshoot, continuous
///   concentric corners (`RoundedSuperellipseBorder`), and exact forward/reverse
///   symmetry.
/// - **Interactive Pull-Down & Left-Edge Swipe-Back**: Tracks finger translation,
///   scale, and rounded corner growth (`32pt`) 1:1 in real time, and hands off
///   on release to a velocity-inherited [SpringSimulation] (`Ios27Spring.smooth`)
///   to smoothly fly back to the source card or re-expand to full screen.
/// - **Zero Ghosting & Zero Hard-Cut Swap**: Hides the originating card via
///   [PosterExpandRegistry] and paints an opaque shared poster base inside the
///   morphing container while [DetailScreen] dissolves cleanly over it.
/// - **Reduce Motion Accessibility**: Automatically degrades to a `150ms` pure
///   opacity fade when `MediaQuery.disableAnimationsOf(context)` is enabled.
class PosterExpandRoute<T> extends PageRoute<T> {
  final WidgetBuilder builder;
  final Rect initialSourceRect;
  final Rect? Function()? sourceRectResolver;
  final double sourceBorderRadius;
  final String? sourceCardId;
  final String posterUrl;
  final String title;
  final String year;
  final bool isFullBleedHero;
  final bool strictHighResPoster;
  final bool forBackdrop;
  final Alignment posterAlignment;
  final Color ambientColor;

  /// Critically damped zero-overshoot iOS 27 smooth spring curve.
  static final Curve _smoothSpringCurve = Ios27Spring.smooth.curve;

  @visibleForTesting
  static double evaluateTransitionProgress(
    double rawT, {
    bool reversing = false,
  }) {
    final t = rawT.clamp(0.0, 1.0);
    if (reversing) {
      return (1.0 - _smoothSpringCurve.transform(1.0 - t)).clamp(0.0, 1.0);
    }
    return _smoothSpringCurve.transform(t).clamp(0.0, 1.0);
  }

  final GlobalKey _pageBoundaryKey = GlobalKey();
  final GlobalKey _sharedPosterKey = GlobalKey();
  Widget? _cachedPage;
  Widget? _cachedSharedPoster;
  bool _claimedRegistry = false;
  bool _listenerAttached = false;

  // Tracks exact release state after interactive pull-down or left-edge swipe
  // so post-release continuation runs via a velocity-inherited SpringSimulation
  // from the exact finger position, translation offset, and corner radius.
  double? _gestureReleaseRawT;
  double _gestureReleaseRadiusOffset = 0.0;
  Offset _gestureDragOffset = Offset.zero;
  Offset _gestureReleaseOffset = Offset.zero;
  bool _gestureReleasePopping = false;
  bool _gestureUsingSpringSimulation = false;
  bool _routeDisposed = false;

  PosterExpandRoute({
    required this.builder,
    required this.initialSourceRect,
    this.sourceRectResolver,
    this.sourceBorderRadius = 14.0,
    this.sourceCardId,
    this.posterUrl = '',
    this.title = '',
    this.year = '',
    this.isFullBleedHero = false,
    this.strictHighResPoster = false,
    this.forBackdrop = false,
    this.posterAlignment = Alignment.center,
    this.ambientColor = const Color(0xFF0E1016),
    super.settings,
  });

  /// Captures a live widget's screen-space [Rect] safely, returning null if
  /// unmounted, detached, zero-sized, or completely offscreen.
  static Rect? captureRect(BuildContext? ctx) {
    if (ctx == null || !ctx.mounted) return null;
    try {
      final ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
      final size = ro.size;
      if (size.width < 8 || size.height < 8) return null;
      final offset = ro.localToGlobal(Offset.zero);
      if (!offset.dx.isFinite || !offset.dy.isFinite) return null;
      final rect = offset & size;
      final mq = MediaQuery.maybeSizeOf(ctx);
      if (mq != null) {
        final screenRect = Offset.zero & mq;
        if (!rect.overlaps(screenRect.inflate(60))) return null;
      }
      return rect;
    } catch (_) {
      return null;
    }
  }

  void _claimSourceCard() {
    final id = sourceCardId;
    if (id != null && id.isNotEmpty) {
      _claimedRegistry = true;
      PosterExpandRegistry.claim(id);
    }
  }

  void _releaseSourceCard() {
    final id = sourceCardId;
    if (_claimedRegistry && id != null && id.isNotEmpty) {
      PosterExpandRegistry.release(id);
    }
    _claimedRegistry = false;
  }

  void _handleAnimationTick() {
    final anim = animation;
    if (anim == null || !_claimedRegistry) return;
    if (PosterExpandRegistry.activeCardId.value != sourceCardId) return;
    final p = _computeProgress(
      rawT: anim.value.clamp(0.0, 1.0),
      status: anim.status,
      isGesture: navigator?.userGestureInProgress ?? false,
    );
    if ((PosterExpandRegistry.activeProgress.value - p).abs() > 0.0005) {
      PosterExpandRegistry.activeProgress.value = p;
    }
  }

  @override
  void install() {
    super.install();
    _claimSourceCard();
    if (!_listenerAttached && animation != null) {
      _listenerAttached = true;
      animation!.addListener(_handleAnimationTick);
    }
  }

  @override
  void dispose() {
    _routeDisposed = true;
    if (_listenerAttached && animation != null) {
      animation!.removeListener(_handleAnimationTick);
      _listenerAttached = false;
    }
    _releaseSourceCard();
    super.dispose();
  }

  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => Ios27Spring.smooth.nominalDuration;

  @override
  Duration get reverseTransitionDuration => Ios27Spring.smooth.nominalDuration;

  double _gestureRadiusBumpFor(double p, {required bool fullBleed}) {
    final lift = fullBleed ? 32.0 : 20.0;
    return lift * math.sin(math.pi * p.clamp(0.0, 1.0));
  }

  void _setInteractiveZoomProgress(
    double value, {
    Offset dragOffset = Offset.zero,
  }) {
    _gestureReleaseRawT = null;
    _gestureReleaseRadiusOffset = 0.0;
    _gestureReleaseOffset = Offset.zero;
    _gestureUsingSpringSimulation = false;
    _gestureDragOffset = dragOffset;
    controller?.value = value.clamp(0.0, 1.0);
  }

  void _endInteractiveZoom({
    required double velocity,
    required double referenceExtent,
  }) {
    final ctrl = controller;
    final nav = navigator;
    if (ctrl == null || nav == null) return;
    final releaseVal = ctrl.value.clamp(0.0, 1.0);
    final shouldPop = velocity > 380.0 || releaseVal < 0.72;
    _gestureReleaseRawT = releaseVal;
    _gestureReleaseRadiusOffset = _gestureRadiusBumpFor(
      releaseVal,
      fullBleed: isFullBleedHero,
    );
    _gestureReleaseOffset = _gestureDragOffset;
    _gestureReleasePopping = shouldPop;
    _gestureUsingSpringSimulation = true;

    final safeExtent = math.max(1.0, referenceExtent);
    // Positive finger swipe velocity decreases progress `p` (toward pop=0.0).
    final normalizedVelocity = (-velocity / safeExtent).clamp(-8.0, 8.0);

    if (shouldPop) {
      nav.pop();
      ctrl
          .animateWith(
            Ios27Spring.smooth.simulation(
              start: releaseVal,
              end: 0.0,
              velocity: normalizedVelocity,
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
          velocity: normalizedVelocity,
        ),
      );
    }
    nav.didStopUserGesture();
  }

  void _cancelInteractiveZoom() {
    final ctrl = controller;
    if (ctrl != null) {
      final releaseVal = ctrl.value.clamp(0.0, 1.0);
      _gestureReleaseRawT = releaseVal;
      _gestureReleaseRadiusOffset = _gestureRadiusBumpFor(
        releaseVal,
        fullBleed: isFullBleedHero,
      );
      _gestureReleaseOffset = _gestureDragOffset;
      _gestureReleasePopping = false;
      _gestureUsingSpringSimulation = true;
      ctrl.animateWith(
        Ios27Spring.smooth.simulation(
          start: releaseVal,
          end: 1.0,
        ),
      );
    }
    navigator?.didStopUserGesture();
  }

  double _computeProgress({
    required double rawT,
    required AnimationStatus status,
    required bool isGesture,
  }) {
    if (isGesture) return rawT;
    if (_gestureUsingSpringSimulation) {
      // Controller is already driven directly by SpringSimulation.
      return rawT;
    }
    final isReversing = status == AnimationStatus.reverse;
    final releaseT = _gestureReleaseRawT;
    if (releaseT != null && _gestureReleasePopping && isReversing) {
      final span = releaseT.clamp(0.001, 1.0);
      final u = ((releaseT - rawT) / span).clamp(0.0, 1.0);
      return (releaseT * (1.0 - _smoothSpringCurve.transform(u)))
          .clamp(0.0, 1.0);
    }
    if (releaseT != null && !_gestureReleasePopping && !isReversing) {
      final span = (1.0 - releaseT).clamp(0.001, 1.0);
      final u = ((rawT - releaseT) / span).clamp(0.0, 1.0);
      return (releaseT + (1.0 - releaseT) * _smoothSpringCurve.transform(u))
          .clamp(0.0, 1.0);
    }
    return evaluateTransitionProgress(rawT, reversing: isReversing);
  }

  double _releaseDecayFactor({
    required double rawT,
    required AnimationStatus status,
  }) {
    final releaseT = _gestureReleaseRawT;
    if (releaseT == null) return 0.0;
    final isReversing = _gestureUsingSpringSimulation
        ? _gestureReleasePopping
        : (status == AnimationStatus.reverse);
    if (_gestureReleasePopping && isReversing) {
      final span = releaseT.clamp(0.001, 1.0);
      return (rawT / span).clamp(0.0, 1.0);
    }
    if (!_gestureReleasePopping && !isReversing) {
      final span = (1.0 - releaseT).clamp(0.001, 1.0);
      return ((1.0 - rawT) / span).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  double _computeGestureRadiusOffset({
    required double rawT,
    required double p,
    required AnimationStatus status,
    required bool isGesture,
    required bool fullBleed,
  }) {
    if (isGesture) {
      return _gestureRadiusBumpFor(p, fullBleed: fullBleed);
    }
    if (_gestureReleaseRawT == null || _gestureReleaseRadiusOffset <= 0.01) {
      return 0.0;
    }
    if (_gestureUsingSpringSimulation) {
      return _gestureReleaseRadiusOffset *
          _releaseDecayFactor(rawT: rawT, status: status);
    }
    final releaseT = _gestureReleaseRawT!;
    final isReversing = status == AnimationStatus.reverse;
    if (_gestureReleasePopping && isReversing) {
      final span = releaseT.clamp(0.001, 1.0);
      final u = ((releaseT - rawT) / span).clamp(0.0, 1.0);
      return _gestureReleaseRadiusOffset *
          (1.0 - _smoothSpringCurve.transform(u));
    }
    if (!_gestureReleasePopping && !isReversing) {
      final span = (1.0 - releaseT).clamp(0.001, 1.0);
      final u = ((rawT - releaseT) / span).clamp(0.0, 1.0);
      return _gestureReleaseRadiusOffset *
          (1.0 - _smoothSpringCurve.transform(u));
    }
    return 0.0;
  }

  Offset _computeCurrentDragOffset({
    required double rawT,
    required AnimationStatus status,
    required bool isGesture,
  }) {
    if (isGesture) return _gestureDragOffset;
    if (_gestureReleaseRawT == null || _gestureReleaseOffset == Offset.zero) {
      return Offset.zero;
    }
    final decay = _releaseDecayFactor(rawT: rawT, status: status);
    return _gestureReleaseOffset * decay;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _cachedPage ??= RepaintBoundary(
      key: _pageBoundaryKey,
      child: _PosterExpandZoomGestureWrapper<T>(
        route: this,
        child: builder(context),
      ),
    );
  }

  ({Rect rect, bool hasLiveAnchor}) _resolveLiveTargetRect(Size screen) {
    final live = sourceRectResolver?.call();
    if (live != null &&
        live.width >= 8 &&
        live.height >= 8 &&
        live.overlaps((Offset.zero & screen).inflate(80))) {
      return (rect: live, hasLiveAnchor: true);
    }
    if (initialSourceRect.width >= 8 &&
        initialSourceRect.height >= 8 &&
        initialSourceRect.overlaps((Offset.zero & screen).inflate(80))) {
      final clampedW =
          initialSourceRect.width.clamp(8.0, screen.width).toDouble();
      final clampedH =
          initialSourceRect.height.clamp(8.0, screen.height).toDouble();
      final clampedLeft = initialSourceRect.left
          .clamp(0.0, math.max<double>(0.0, screen.width - clampedW))
          .toDouble();
      final clampedTop = initialSourceRect.top
          .clamp(0.0, math.max<double>(0.0, screen.height - clampedH))
          .toDouble();
      return (
        rect: Rect.fromLTWH(clampedLeft, clampedTop, clampedW, clampedH),
        hasLiveAnchor: true,
      );
    }
    final w = screen.width * 0.28;
    final h = w * 1.48;
    return (
      rect: Rect.fromCenter(
        center: Offset(screen.width * 0.5, screen.height * 0.5),
        width: w,
        height: h,
      ),
      hasLiveAnchor: false,
    );
  }

  bool get _hasSharedPoster =>
      posterUrl.trim().isNotEmpty || title.trim().isNotEmpty;

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

    final screen = MediaQuery.sizeOf(context);
    final fullRect = Offset.zero & screen;

    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, pageChild) {
        final rawT = animation.value.clamp(0.0, 1.0);

        // Settled fully open: paint directly with zero clipping or transform overhead.
        if (animation.status == AnimationStatus.completed &&
            rawT >= 0.999 &&
            !(navigator?.userGestureInProgress ?? false)) {
          _gestureReleaseRawT = null;
          _gestureReleaseRadiusOffset = 0.0;
          _gestureDragOffset = Offset.zero;
          _gestureReleaseOffset = Offset.zero;
          _gestureUsingSpringSimulation = false;
          return pageChild!;
        }
        if (animation.status == AnimationStatus.dismissed) {
          _gestureReleaseRawT = null;
          _gestureReleaseRadiusOffset = 0.0;
          _gestureDragOffset = Offset.zero;
          _gestureReleaseOffset = Offset.zero;
          _gestureUsingSpringSimulation = false;
        }

        final isGesture = navigator?.userGestureInProgress ?? false;
        final p = _computeProgress(
          rawT: rawT,
          status: animation.status,
          isGesture: isGesture,
        );

        final target = _resolveLiveTargetRect(screen);
        final sourceRect = target.rect;
        final effectiveFullBleedHero = isFullBleedHero ||
            (sourceBorderRadius <= 0.5 &&
                sourceRect.width >= screen.width * 0.94 &&
                sourceRect.top <= 4.0);

        final gestureRadiusOffset = _computeGestureRadiusOffset(
          rawT: rawT,
          p: p,
          status: animation.status,
          isGesture: isGesture,
          fullBleed: effectiveFullBleedHero,
        );

        final dragOffset = _computeCurrentDragOffset(
          rawT: rawT,
          status: animation.status,
          isGesture: isGesture,
        );

        final lerpedLeft = lerpDouble(sourceRect.left, fullRect.left, p)! +
            dragOffset.dx;
        final lerpedTop = lerpDouble(sourceRect.top, fullRect.top, p)! +
            dragOffset.dy;
        final lerpedRight = lerpDouble(sourceRect.right, fullRect.right, p)! +
            dragOffset.dx;
        final lerpedBottom = lerpDouble(sourceRect.bottom, fullRect.bottom, p)! +
            dragOffset.dy;
        final currentRect = Rect.fromLTRB(
          lerpedLeft,
          lerpedTop,
          lerpedRight > lerpedLeft + 1 ? lerpedRight : lerpedLeft + 1,
          lerpedBottom > lerpedTop + 1 ? lerpedBottom : lerpedTop + 1,
        );

        final baseRadius = effectiveFullBleedHero
            ? 0.0
            : (lerpDouble(sourceBorderRadius, 0.0, p) ?? 0.0);
        final currentRadius = (baseRadius + gestureRadiusOffset)
            .clamp(0.0, Ios27ConcentricGeometry.sheetOuterRadiusPt);

        final backdropDim =
            ((effectiveFullBleedHero ? 0.24 : 0.36) * p).clamp(0.0, 0.36);

        final isReversing = animation.status == AnimationStatus.reverse ||
            (_gestureUsingSpringSimulation && _gestureReleasePopping);
        if (effectiveFullBleedHero) {
          return _buildFullBleedHeroStage(
            screen: screen,
            currentRect: currentRect,
            currentRadius: currentRadius,
            backdropDim: backdropDim,
            p: p,
            rawT: rawT,
            hasLiveAnchor: target.hasLiveAnchor,
            isReversing: isReversing,
            pageChild: pageChild!,
          );
        }

        return _buildPosterCardStage(
          screen: screen,
          currentRect: currentRect,
          currentRadius: currentRadius,
          backdropDim: backdropDim,
          p: p,
          rawT: rawT,
          hasLiveAnchor: target.hasLiveAnchor,
          isReversing: isReversing,
          pageChild: pageChild!,
        );
      },
    );
  }

  Widget _sharedPosterLayer() {
    return _cachedSharedPoster ??= RepaintBoundary(
      key: _sharedPosterKey,
      child: PosterImage(
        url: posterUrl,
        title: title,
        year: year,
        highRes: true,
        strictHighRes: strictHighResPoster,
        forBackdrop: forBackdrop,
        fadeIn: false,
        fit: BoxFit.cover,
        alignment: posterAlignment,
        placeholder: ColoredBox(color: ambientColor),
      ),
    );
  }

  Widget _clipWithContinuousCorners(double radius, Widget child) {
    if (radius <= 0.25) {
      return ClipRect(child: child);
    }
    return ClipPath(
      clipper: ShapeBorderClipper(
        shape: Ios27ConcentricGeometry.continuousShape(radius: radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildFullBleedHeroStage({
    required Size screen,
    required Rect currentRect,
    required double currentRadius,
    required double backdropDim,
    required double p,
    required double rawT,
    required bool hasLiveAnchor,
    required bool isReversing,
    required Widget pageChild,
  }) {
    final detailOpacity =
        _hasSharedPoster ? ((p - 0.08) / 0.46).clamp(0.0, 1.0) : 1.0;

    final Widget detailLayer = SizedBox(
      width: screen.width,
      height: screen.height,
      child: pageChild,
    );

    final Widget content = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: ambientColor),
        if (_hasSharedPoster)
          Positioned.fill(
            child: _sharedPosterLayer(),
          ),
        if (detailOpacity < 0.98)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: currentRect.height * 0.48,
            child: IgnorePointer(
              child: Opacity(
                opacity: (1.0 - detailOpacity).clamp(0.0, 1.0),
                child: DecoratedBox(
                  key: const Key('poster-expand-hero-ambient-blend'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        ambientColor.withValues(alpha: 0.0),
                        ambientColor.withValues(alpha: 0.58),
                        ambientColor.withValues(alpha: 0.92),
                        ambientColor,
                      ],
                      stops: const [0.0, 0.36, 0.72, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),
        FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(detailOpacity),
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: screen.width,
            maxWidth: screen.width,
            minHeight: screen.height,
            maxHeight: screen.height,
            child: detailLayer,
          ),
        ),
      ],
    );

    Widget stageCard = currentRadius > 0.25
        ? DecoratedBox(
            decoration: ShapeDecoration(
              shape: Ios27ConcentricGeometry.continuousShape(
                radius: currentRadius,
              ),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.26 * (1.0 - p)),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: _clipWithContinuousCorners(currentRadius, content),
          )
        : ClipRect(child: content);

    final double edgeOpacity = !hasLiveAnchor
        ? (rawT / 0.16).clamp(0.0, 1.0)
        : (isReversing && p < 0.04 ? (p / 0.04).clamp(0.0, 1.0) : 1.0);
    if (edgeOpacity < 0.999) {
      stageCard = Opacity(opacity: edgeOpacity, child: stageCard);
    }

    return Stack(
      key: const Key('poster-expand-transition-stage'),
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: backdropDim),
          ),
        ),
        Positioned.fromRect(
          rect: currentRect,
          child: stageCard,
        ),
      ],
    );
  }

  Widget _buildPosterCardStage({
    required Size screen,
    required Rect currentRect,
    required double currentRadius,
    required double backdropDim,
    required double p,
    required double rawT,
    required bool hasLiveAnchor,
    required bool isReversing,
    required Widget pageChild,
  }) {
    final detailOpacity =
        _hasSharedPoster ? ((p - 0.06) / 0.42).clamp(0.0, 1.0) : 1.0;

    final Widget scaledDetail = FittedBox(
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: screen.width,
        height: screen.height,
        child: pageChild,
      ),
    );

    final Widget innerContent = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: ambientColor),
        if (_hasSharedPoster)
          Positioned.fill(
            child: _sharedPosterLayer(),
          ),
        FadeTransition(
          opacity: AlwaysStoppedAnimation<double>(detailOpacity),
          child: scaledDetail,
        ),
      ],
    );

    Widget flyingCard = DecoratedBox(
      decoration: ShapeDecoration(
        shape: Ios27ConcentricGeometry.continuousShape(
          radius: currentRadius,
        ),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28 * (1.0 - p)),
            blurRadius: 22.0 * (1.0 - p),
            offset: Offset(0, 6.0 * (1.0 - p)),
          ),
        ],
      ),
      child: _clipWithContinuousCorners(currentRadius, innerContent),
    );

    final double edgeOpacity = !hasLiveAnchor
        ? (rawT / 0.16).clamp(0.0, 1.0)
        : (isReversing && p < 0.04 ? (p / 0.04).clamp(0.0, 1.0) : 1.0);
    if (edgeOpacity < 0.999) {
      flyingCard = Opacity(opacity: edgeOpacity, child: flyingCard);
    }

    return Stack(
      key: const Key('poster-expand-transition-stage'),
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: ColoredBox(
            color: Colors.black.withValues(alpha: backdropDim),
          ),
        ),
        Positioned.fromRect(
          rect: currentRect,
          child: flyingCard,
        ),
      ],
    );
  }
}

/// Interactive iOS 27 `.zoom` gesture wrapper supporting both:
/// 1. Left-edge horizontal swipe-back (`dx <= 28pt`)
/// 2. Vertical pull-down `.zoom` dismiss (on non-scrollable content or when a
///    scrollable child overscrolls past top `-36pt`)
/// Both track finger translation & concentric corner rounding 1:1 and hand off
/// to a velocity-inherited [SpringSimulation] (`Ios27Spring.smooth`).
class _PosterExpandZoomGestureWrapper<T> extends StatefulWidget {
  final PosterExpandRoute<T> route;
  final Widget child;

  const _PosterExpandZoomGestureWrapper({
    required this.route,
    required this.child,
  });

  @override
  State<_PosterExpandZoomGestureWrapper<T>> createState() =>
      _PosterExpandZoomGestureWrapperState<T>();
}

class _PosterExpandZoomGestureWrapperState<T>
    extends State<_PosterExpandZoomGestureWrapper<T>> {
  bool _edgeDragging = false;
  double _edgeDragDx = 0.0;
  double _edgeDragDy = 0.0;

  bool _pullDragging = false;
  double _pullDragDy = 0.0;
  double _pullDragDx = 0.0;
  double _lastPullSampleDy = 0.0;
  int _lastPullSampleMicros = 0;
  double _pullEstimatedVy = 0.0;
  bool _atScrollTop = true;

  bool get _canStartGesture {
    if (widget.route.isFirst || !widget.route.isCurrent) return false;
    final nav = widget.route.navigator;
    return nav != null && !nav.userGestureInProgress;
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (!_canStartGesture) return;
    if (details.globalPosition.dx > 28.0) return;
    _edgeDragging = true;
    _edgeDragDx = 0.0;
    _edgeDragDy = 0.0;
    widget.route.navigator!.didStartUserGesture();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_edgeDragging) return;
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0) return;
    _edgeDragDx = (_edgeDragDx + details.delta.dx).clamp(0.0, size.width);
    _edgeDragDy += details.delta.dy * 0.25;
    final progress = (1.0 - (_edgeDragDx / size.width)).clamp(0.0, 1.0);
    widget.route._setInteractiveZoomProgress(
      progress,
      dragOffset: Offset(0.0, _edgeDragDy.clamp(-40.0, 80.0)),
    );
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!_edgeDragging) return;
    _edgeDragging = false;
    widget.route._endInteractiveZoom(
      velocity: details.primaryVelocity ?? 0.0,
      referenceExtent: MediaQuery.sizeOf(context).width,
    );
  }

  void _onHorizontalDragCancel() {
    if (!_edgeDragging) return;
    _edgeDragging = false;
    widget.route._cancelInteractiveZoom();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    if (!_canStartGesture || !_atScrollTop) return;
    _pullDragging = true;
    _pullDragDy = 0.0;
    _pullDragDx = 0.0;
    _pullEstimatedVy = 0.0;
    _lastPullSampleDy = 0.0;
    _lastPullSampleMicros = DateTime.now().microsecondsSinceEpoch;
    widget.route.navigator!.didStartUserGesture();
  }

  void _applyPullDelta(double dx, double dy) {
    final size = MediaQuery.sizeOf(context);
    if (size.height <= 0) return;
    _pullDragDy = math.max(0.0, _pullDragDy + dy);
    _pullDragDx += dx * 0.35;
    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    final dtSec = (nowMicros - _lastPullSampleMicros) / 1000000.0;
    if (dtSec > 0.002 && dtSec < 0.2) {
      _pullEstimatedVy = (_pullDragDy - _lastPullSampleDy) / dtSec;
      _lastPullSampleDy = _pullDragDy;
      _lastPullSampleMicros = nowMicros;
    }
    final extent = size.height * 0.52;
    final progress = (1.0 - (_pullDragDy / extent) * 0.78).clamp(0.14, 1.0);
    widget.route._setInteractiveZoomProgress(
      progress,
      dragOffset: Offset(
        _pullDragDx.clamp(-48.0, 48.0),
        (_pullDragDy * 0.36).clamp(0.0, 140.0),
      ),
    );
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (!_pullDragging) return;
    _applyPullDelta(details.delta.dx, details.delta.dy);
  }

  void _finishPullDrag(double velocity) {
    if (!_pullDragging) return;
    _pullDragging = false;
    widget.route._endInteractiveZoom(
      velocity: velocity,
      referenceExtent: MediaQuery.sizeOf(context).height * 0.52,
    );
  }

  void _cancelPullDrag() {
    if (!_pullDragging) return;
    _pullDragging = false;
    widget.route._cancelInteractiveZoom();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    _atScrollTop = notification.metrics.pixels <= 0.5;
    if (notification is ScrollUpdateNotification) {
      if (!_pullDragging &&
          _canStartGesture &&
          notification.metrics.pixels < -36.0 &&
          notification.dragDetails != null) {
        _pullDragging = true;
        _pullDragDy = (-notification.metrics.pixels - 36.0).clamp(0.0, 120.0);
        _pullDragDx = 0.0;
        _pullEstimatedVy = 0.0;
        _lastPullSampleDy = _pullDragDy;
        _lastPullSampleMicros = DateTime.now().microsecondsSinceEpoch;
        widget.route.navigator!.didStartUserGesture();
      } else if (_pullDragging && notification.dragDetails != null) {
        _applyPullDelta(
          notification.dragDetails!.delta.dx,
          notification.dragDetails!.delta.dy,
        );
      }
    } else if (notification is ScrollEndNotification && _pullDragging) {
      final vy = notification.dragDetails?.primaryVelocity ?? _pullEstimatedVy;
      _finishPullDrag(vy);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: _onVerticalDragStart,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: (d) => _finishPullDrag(d.primaryVelocity ?? 0.0),
        onVerticalDragCancel: _cancelPullDrag,
        child: Stack(
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
                onHorizontalDragStart: _onHorizontalDragStart,
                onHorizontalDragUpdate: _onHorizontalDragUpdate,
                onHorizontalDragEnd: _onHorizontalDragEnd,
                onHorizontalDragCancel: _onHorizontalDragCancel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
