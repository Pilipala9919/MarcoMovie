import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get _isWindowsDesktop => !kIsWeb && Platform.isWindows;

/// Apple iOS 27 Liquid Glass design tokens (iOS / iPadOS / macOS dark appearance):
/// deep obsidian canvas, refractive translucent glass materials, specular rims.
class AppleColors {
  static const Color background = Color(0xFF000000);
  static const Color canvas = Color(0xFF09090C);
  static const Color groupedPrimary = Color(0xA81C1C21);
  static const Color groupedSecondary = Color(0xBF28282E);
  static const Color groupedTertiary = Color(0xFF36363D);
  static const Color fill = Color(0x38787884);
  static const Color fillStrong = Color(0x59787884);
  static const Color systemBlue = Color(0xFF0A84FF);
  static const Color systemCyan = Color(0xFF64D2FF);
  static const Color systemIndigo = Color(0xFF5E5CE6);
  static const Color systemPurple = Color(0xFFBF5AF2);
  static const Color systemGreen = Color(0xFF30D158);
  static const Color systemOrange = Color(0xFFFF9F0A);
  static const Color systemRed = Color(0xFFFF453A);
  static const Color labelPrimary = Color(0xFFF5F5F7);
  static const Color labelSecondary = Color(0xFFD1D1DA);
  static const Color labelTertiary = Color(0x52EBEBF5);
  static const Color separator = Color(0x29FFFFFF);
  static const Color glassBorder = Color(0x26FFFFFF);
  static const Color glassBorderStrong = Color(0x3BFFFFFF);
  static const Color glassHighlight = Color(0x52FFFFFF);
}

/// Brand logo widget rendering the user's frosted-glass clapperboard squircle icon
/// (`assets/logo_mark.png`) and the signature two-tone `Marco Movie` wordmark.
class MarcoBrandLogo extends StatelessWidget {
  final double iconSize;
  final double fontSize;
  final bool showWordmark;
  final bool stacked;
  const MarcoBrandLogo({
    super.key,
    this.iconSize = 32,
    this.fontSize = 17,
    this.showWordmark = true,
    this.stacked = false,
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
        errorBuilder: (_, __, ___) => _FallbackLogoMark(size: iconSize),
      ),
    );
    if (!showWordmark) return iconWidget;
    final wordmark = RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(
          fontSize: fontSize,
          letterSpacing: -0.4,
          height: 1.1,
        ),
        children: const [
          TextSpan(
            text: 'Marco',
            style: TextStyle(
              color: Color(0xFFF8FAFC),
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: ' Movie',
            style: TextStyle(
              color: Color(0xFFB8C2D4),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
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
          colors: [Color(0xFFF4F5F7), Color(0xFFD6DAE0)],
        ),
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: Colors.white54, width: 0.8),
      ),
      alignment: Alignment.center,
      child: Container(
        width: size * 0.62,
        height: size * 0.54,
        decoration: BoxDecoration(
          color: const Color(0xFF2B3038),
          borderRadius: BorderRadius.circular(size * 0.12),
        ),
        alignment: Alignment.center,
        child: Icon(
          CupertinoIcons.play_fill,
          color: const Color(0xFFF4F5F7),
          size: size * 0.3,
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
  const _LiquidRimPainter({required this.shape, this.strength = 1.0});

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
  bool shouldRepaint(covariant _LiquidRimPainter old) =>
      old.shape != shape || old.strength != strength;
}

/// Native equivalent of Glasswork's clipped rim, with an inexpensive blur on
/// renderers that cannot sample the backdrop through a fragment shader.
class GlassworkBackdrop extends StatefulWidget {
  static final reduceTransparency = ValueNotifier<bool>(false);
  final double radius;
  final Widget child;
  const GlassworkBackdrop({super.key, required this.radius, required this.child});
  @override
  State<GlassworkBackdrop> createState() => _GlassworkBackdropState();
}

class _GlassworkBackdropState extends State<GlassworkBackdrop> {
  static Future<FragmentProgram>? _program;
  FragmentShader? _shader;
  @override
  void initState() {
    super.initState();
    if (ImageFilter.isShaderFilterSupported) _loadLens();
  }
  Future<void> _loadLens() async {
    try {
      final program = await (_program ??= FragmentProgram.fromAsset('shaders/glasswork.frag'));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Fallback is also used while the GPU program is being prepared.
    }
  }
  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: GlassworkBackdrop.reduceTransparency,
      builder: (context, reduce, _) {
        if (reduce || MediaQuery.highContrastOf(context) || MediaQuery.disableAnimationsOf(context)) {
          return ColoredBox(color: const Color(0xF51E1E22), child: widget.child);
        }
        final shader = _shader;
        if (shader != null) {
          shader.setFloat(2, widget.radius);
          shader.setFloat(3, MediaQuery.devicePixelRatioOf(context));
        }
        return BackdropFilter(
          filter: shader == null ? liquidGlassFilter(blur: 2, saturation: 1.6) : ImageFilter.shader(shader),
          child: shader == null ? ColoredBox(color: const Color(0xb31e1e22), child: widget.child) : widget.child,
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
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
    );
    Widget content = child;
    if (padding != null) content = Padding(padding: padding!, child: content);
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: elevated
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
            : null,
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        clipBehavior: Clip.antiAlias,
        child: (MediaQuery.highContrastOf(context) || MediaQuery.disableAnimationsOf(context))
            ? CustomPaint(
                foregroundPainter:
                    _LiquidRimPainter(shape: shape, strength: rimStrength),
                child: Container(
                  width: width,
                  height: height,
                  decoration: ShapeDecoration(
                    shape: shape,
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(
                          const Color(0x28FFFFFF),
                          tint.withValues(alpha: 1),
                        ),
                        tint.withValues(alpha: 1),
                        Color.alphaBlend(
                          const Color(0x10FFFFFF),
                          tint.withValues(alpha: 1),
                        ),
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                  child: content,
                ),
              )
            : GlassworkBackdrop(
                radius: borderRadius,
                child: CustomPaint(
                  foregroundPainter:
                      _LiquidRimPainter(shape: shape, strength: rimStrength),
                  child: Container(
                    width: width,
                    height: height,
                    decoration: ShapeDecoration(
                      shape: shape,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                            const Color(0x12FFFFFF),
                            tint.withValues(alpha: math.min(tint.a, 0.08)),
                          ),
                          tint.withValues(alpha: math.min(tint.a, 0.04)),
                          Color.alphaBlend(
                            const Color(0x08FFFFFF),
                            tint.withValues(alpha: math.min(tint.a, 0.06)),
                          ),
                        ],
                        stops: const [0.0, 0.52, 1.0],
                      ),
                    ),
                    child: content,
                  ),
                ),
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
    if (fadeWidth <= 0 || (!fadeStart && !fadeEnd)) return child;
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
    final radius = borderRadius ?? BorderRadius.circular(18);
    final effectiveColor = backgroundColor ?? color;
    final shape = RoundedRectangleBorder(borderRadius: radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: elevated
            ? const [
                BoxShadow(
                  color: Color(0x48000000),
                  blurRadius: 24,
                  offset: Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: (MediaQuery.highContrastOf(context) || MediaQuery.disableAnimationsOf(context))
            ? CustomPaint(
                foregroundPainter: border == null
                    ? _LiquidRimPainter(shape: shape, strength: 0.8)
                    : null,
                child: Container(
                  width: width,
                  height: height,
                  padding: padding,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.alphaBlend(
                          const Color(0x20FFFFFF),
                          effectiveColor.withValues(
                            alpha: math.max(effectiveColor.a, 0.90),
                          ),
                        ),
                        effectiveColor.withValues(
                          alpha: math.max(effectiveColor.a, 0.90),
                        ),
                      ],
                    ),
                    borderRadius: radius,
                    border: border,
                  ),
                  child: child,
                ),
              )
            : GlassworkBackdrop(
                radius: radius.topLeft.x,
                child: CustomPaint(
                  foregroundPainter: border == null
                      ? _LiquidRimPainter(shape: shape, strength: 0.92)
                      : null,
                  child: Container(
                    width: width,
                    height: height,
                    padding: padding,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                            const Color(0x10FFFFFF),
                            effectiveColor.withValues(alpha: math.min(effectiveColor.a, .04)),
                          ),
                          effectiveColor.withValues(alpha: math.min(effectiveColor.a, .02)),
                        ],
                      ),
                      borderRadius: radius,
                      border: border,
                    ),
                    child: child,
                  ),
                ),
              ),
      ),
    );
  }
}

/// iOS 27 Liquid Glass tab bar (Dock):
/// - Portrait: floating glass bar (`64dp`) above the home indicator.
/// - Landscape: compact vertical glass bar on the right edge.
/// - Supports both discrete taps AND continuous press-and-slide (`按住左右/上下滑动聚焦切换`):
///   holding and sliding across the dock smoothly glides the lighter glass lens
///   under the finger and switches tabs live with haptic selection clicks.
class AppleLiquidGlassDock extends StatefulWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool isLandscape;
  final List<(IconData, IconData, String)> items;

  const AppleLiquidGlassDock({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.isLandscape,
    required this.items,
  });

  static const double _dockRadius = 26;
  static const double _lensRadius = 20;
  static const double _pad = 6;
  static const double _itemH = 52;
  static const double _itemW = 60;
  static const Duration _motion = Duration(milliseconds: 420);
  static const Curve _curve = Cubic(0.2, 1.15, 0.36, 1.0);

  /// Width a landscape dock occupies (including its outer margin).
  static double landscapeFootprint(BuildContext context) {
    final right = MediaQuery.paddingOf(context).right;
    return _itemW + _pad * 2 + (right > 0 ? right + 4 : 10) + 8;
  }
  static double portraitFootprint(BuildContext context) {
    final safe = MediaQuery.paddingOf(context).bottom;
    return _itemH + 2 * _pad + (safe > 0 ? math.max(safe - 4, 8) : 12) + 8;
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
    if (!cancelled && target != null && target != _safeIndex) widget.onSelect(target);
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final margin = widget.isLandscape
        ? EdgeInsets.only(
            right: safe.right > 0 ? safe.right + 4 : 10,
            top: 12,
            bottom: 12,
          )
        : EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: safe.bottom > 0 ? math.max(safe.bottom - 4, 8) : 12,
          );
    return Padding(
      padding: margin,
      child: widget.isLandscape ? _buildVertical() : _buildHorizontal(),
    );
  }

  Widget _shell({required Widget child}) {
    return LiquidGlass(
      borderRadius: AppleLiquidGlassDock._dockRadius,
      tint: const Color(0x52141418),
      blur: 20,
      saturation: 1.8,
      child: child,
    );
  }

  Widget _buildHorizontal() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final n = math.max(widget.items.length, 1);
        final available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 360.0;
        // Shortened, compact iOS 27 pill length in portrait mode
        final width = math.min(available * 0.82, 284.0).clamp(248.0, 288.0);
        final itemW = (width - AppleLiquidGlassDock._pad * 2) / n;
        final isSliding = _dragLensSlot != null;
        final lensSlot = _dragLensSlot ?? _safeIndex.toDouble();
        return _shell(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) =>
                _updateSlidePosition(d.localPosition.dx, itemW),
            onHorizontalDragUpdate: (d) =>
                _updateSlidePosition(d.localPosition.dx, itemW),
            onHorizontalDragEnd: (_) => _endSlide(),
            onHorizontalDragCancel: () => _endSlide(cancelled: true),
            child: SizedBox(
              width: width,
              height:
                  AppleLiquidGlassDock._itemH + AppleLiquidGlassDock._pad * 2,
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
                    height: AppleLiquidGlassDock._itemH,
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
      },
    );
  }

  Widget _buildVertical() {
    return Builder(
      builder: (context) {
        final n = math.max(widget.items.length, 1);
        final screenH = MediaQuery.sizeOf(context).height;
        // Lengthened vertical dock in landscape mode
        final targetTotalH = (screenH * 0.74).clamp(
          AppleLiquidGlassDock._itemH * n + AppleLiquidGlassDock._pad * 2 + 44.0,
          324.0,
        );
        final vItemH = (targetTotalH - AppleLiquidGlassDock._pad * 2) / n;
        final isSliding = _dragLensSlot != null;
        final lensSlot = _dragLensSlot ?? _safeIndex.toDouble();
        return _shell(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) =>
                _updateSlidePosition(d.localPosition.dy, vItemH),
            onVerticalDragUpdate: (d) =>
                _updateSlidePosition(d.localPosition.dy, vItemH),
            onVerticalDragEnd: (_) => _endSlide(),
            onVerticalDragCancel: () => _endSlide(cancelled: true),
            child: SizedBox(
              width:
                  AppleLiquidGlassDock._itemW + AppleLiquidGlassDock._pad * 2,
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
      },
    );
  }

  Widget _item(int index) {
    final item = widget.items[index];
    return _DockItem(
      icon: item.$1,
      selectedIcon: item.$2,
      label: item.$3,
      selected: index == _safeIndex,
      onTap: () => widget.onSelect(index),
    );
  }
}

/// The lighter glass lens behind the selected tab (iOS 27 tab bar selection).
class _DockSelectionLens extends StatelessWidget {
  const _DockSelectionLens();
  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius:
          BorderRadius.circular(AppleLiquidGlassDock._lensRadius),
    );
    return CustomPaint(
      foregroundPainter: _LiquidRimPainter(shape: shape, strength: 0.92),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0x30FFFFFF),
              Color(0x14FFFFFF),
              Color(0x223E9BFF),
            ],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DockItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 240);
    final selected = widget.selected;
    final color =
        selected ? const Color(0xFF3E9BFF) : const Color(0xE0F5F5F7);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: duration,
              curve: Curves.easeOut,
              builder: (context, value, _) => Icon(
                selected ? widget.selectedIcon : widget.icon,
                size: 22,
                color: value ?? color,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: duration,
              curve: Curves.easeOut,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                letterSpacing: 0.1,
              ),
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ),
      ),
    );
  }
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
  const AppleCapsuleButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) {
    final fg = destructive
        ? AppleColors.systemRed
        : (primary ? const Color(0xFF0A0A0E) : AppleColors.labelPrimary);
    final labelRow = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 20,
        vertical: compact ? 7 : 11,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 14.5 : 17, color: fg),
            SizedBox(width: compact ? 5.5 : 7),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
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
    final Widget buttonBody;
    if (primary) {
      buttonBody = DecoratedBox(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFFFFFF), Color(0xFFE7E9EE)],
          ),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xB3FFFFFF), width: 0.8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x38000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: labelRow,
      );
    } else {
      final rimShape = const StadiumBorder();
      final surface = CustomPaint(
        foregroundPainter: _LiquidRimPainter(
          shape: rimShape,
          strength: destructive ? 0.95 : 0.88,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: destructive
                  ? const [
                      Color(0x3DFF453A),
                      Color(0x22FF453A),
                    ]
                  : (_isWindowsDesktop
                      ? const [
                          Color(0xCC282832),
                          Color(0xB81C1C24),
                        ]
                      : const [
                          Color(0x24FFFFFF),
                          Color(0x121E1E24),
                        ]),
            ),
          ),
          child: labelRow,
        ),
      );
      buttonBody = _isWindowsDesktop
          ? surface
          : GlassworkBackdrop(radius: 999, child: surface);
    }
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: compact ? 32 : 42,
      pressedOpacity: 0.72,
      onPressed: onPressed,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: buttonBody,
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
    final separated = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      separated.add(children[i]);
      if (i < children.length - 1) {
        separated.add(
          Container(
            height: 0.5,
            margin: const EdgeInsets.only(left: 64, right: 16),
            color: const Color(0x22FFFFFF),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null && header!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 14, bottom: 9),
            child: Text(
              header!.toUpperCase(),
              style: const TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
        AppleGlassSurface(
          borderRadius: BorderRadius.circular(20),
          padding: EdgeInsets.zero,
          color: const Color(0xB81C1C22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: separated,
          ),
        ),
        if (footer != null && footer!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 8, right: 14),
            child: Text(
              footer!,
              style: const TextStyle(
                color: AppleColors.labelSecondary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
      ],
    );
  }
}

/// Settings-style list row with a translucent Glasswork icon badge, title, subtitle and capsule trailing badge.
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
    this.minHeight = 70,
    this.iconBgColor = AppleColors.systemBlue,
    required this.title,
    this.subtitle,
    this.trailingText,
    this.trailing,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            DecoratedBox(
              decoration: ShapeDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    iconBgColor.withValues(alpha: 0.24),
                    iconBgColor.withValues(alpha: 0.12),
                  ],
                ),
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(11),
                  side: BorderSide(
                    color: iconBgColor.withValues(alpha: 0.45),
                    width: 0.85,
                  ),
                ),
              ),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(icon, color: iconBgColor, size: 18.5),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppleColors.labelPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppleColors.labelSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailingText != null && trailingText!.isNotEmpty) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                decoration: BoxDecoration(
                  color: const Color(0x1CFFFFFF),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0x28FFFFFF),
                    width: 0.7,
                  ),
                ),
                child: Text(
                  trailingText!,
                  style: const TextStyle(
                    color: Color(0xE6F5F5F7),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: 6),
              const Icon(
                CupertinoIcons.chevron_right,
                color: AppleColors.labelTertiary,
                size: 14.5,
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        highlightColor: Colors.white10,
        splashColor: Colors.transparent,
        child: content,
      ),
    );
  }
}

/// iOS 27 Liquid Glass modal sheet: deep optical blur, specular rim, grabber, and close button.
Future<T?> showAppleModalSheet<T>({
  required BuildContext context,
  required String title,
  required Widget Function(BuildContext) builder,
  Widget? trailingAction,
  double? maxWidth,
  bool ignoreKeyboardInsets = false,
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (ctx) {
      final viewInsets = MediaQuery.viewInsetsOf(ctx);
      final safe = MediaQuery.paddingOf(ctx);
      final screenSize = MediaQuery.sizeOf(ctx);
      final isLandscape = screenSize.width > screenSize.height;
      final effectiveMaxWidth =
          maxWidth ?? (isLandscape ? math.min(screenSize.width - 28, 720.0) : 560.0);
      final sheetContent = Padding(
        padding: EdgeInsets.only(
          bottom: ignoreKeyboardInsets
              ? math.max(safe.bottom, 12.0)
              : (viewInsets.bottom > 0
                  ? viewInsets.bottom
                  : (isLandscape ? math.max(safe.bottom, 8.0) : 0)),
          left: math.max(10.0, safe.left),
          right: math.max(10.0, safe.right),
          top: ignoreKeyboardInsets
              ? math.max(safe.top, 12.0)
              : (isLandscape ? math.max(8.0, safe.top) : 0),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: effectiveMaxWidth,
              maxHeight: screenSize.height * 0.88,
            ),
            child: LiquidGlass(
              borderRadius: 28,
              rimStrength: 1.0,
              child: Material(
                color: Colors.transparent,
                child: SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  bottom: !isLandscape && !ignoreKeyboardInsets,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 9),
                      Container(
                        width: 40,
                        height: 4.5,
                        decoration: BoxDecoration(
                          color: const Color(0x66EBEBF5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  color: AppleColors.labelPrimary,
                                  fontSize: 17.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.35,
                                ),
                              ),
                            ),
                            if (trailingAction != null) trailingAction,
                            CupertinoButton(
                              padding: const EdgeInsets.all(6),
                              minSize: 30,
                              onPressed: () => Navigator.of(ctx).pop(),
                              child: const Icon(
                                CupertinoIcons.xmark_circle_fill,
                                color: AppleColors.labelTertiary,
                                size: 26,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(height: 0.5, color: const Color(0x22FFFFFF)),
                      Flexible(child: builder(ctx)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (ignoreKeyboardInsets) {
        return MediaQuery.removeViewInsets(
          context: ctx,
          removeBottom: true,
          child: sheetContent,
        );
      }
      return sheetContent;
    },
  );
}

/// iOS 27 Liquid Glass ambient app background: deep obsidian or themed canvas with
/// optional custom wallpaper, soft refractive ambient light, and blurred artwork bleed.
class AppleAmbientBackground extends StatelessWidget {
  final Widget? artwork;
  final Widget? customWallpaper;
  final String preset;
  final bool showAmbientArtwork;
  final double blurSigma;

  const AppleAmbientBackground({
    super.key,
    this.artwork,
    this.customWallpaper,
    this.preset = 'obsidian',
    this.showAmbientArtwork = true,
    this.blurSigma = 60,
  });

  (List<Color>, Color) _resolveThemeColors() {
    switch (preset) {
      case 'midnight':
        return (
          const [Color(0xFF10203B), Color(0xFF091122), Color(0xFF03050A)],
          const Color(0x260A84FF),
        );
      case 'aurora':
        return (
          const [Color(0xFF231338), Color(0xFF120A1E), Color(0xFF05020A)],
          const Color(0x26BF5AF2),
        );
      case 'amber':
        return (
          const [Color(0xFF2D1D12), Color(0xFF150D08), Color(0xFF060402)],
          const Color(0x24FF9F0A),
        );
      case 'emerald':
        return (
          const [Color(0xFF102A24), Color(0xFF081613), Color(0xFF020706)],
          const Color(0x2230D158),
        );
      default:
        return (
          const [Color(0xFF15161E), Color(0xFF0A0B0F), Color(0xFF000000)],
          const Color(0x1864D2FF),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (gradientColors, radialGlow) = _resolveThemeColors();
    return Stack(
      fit: StackFit.expand,
      children: [
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
        if (customWallpaper != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: (blurSigma * 0.35).clamp(8.0, 36.0),
                      sigmaY: (blurSigma * 0.35).clamp(8.0, 36.0),
                      tileMode: TileMode.decal,
                    ),
                    child: customWallpaper,
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
                if (artwork != null && showAmbientArtwork)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 560,
            child: IgnorePointer(
              child: RepaintBoundary(
                child: ClipRect(
                  child: ShaderMask(
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
                        sigmaX: _isWindowsDesktop
                            ? math.min(blurSigma, 24.0)
                            : blurSigma,
                        sigmaY: _isWindowsDesktop
                            ? math.min(blurSigma, 24.0)
                            : blurSigma,
                        tileMode: TileMode.decal,
                      ),
                      child: artwork,
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: -240,
          left: -80,
          right: -80,
          height: 540,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 0.75,
                  colors: [radialGlow, const Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
