import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'apple_theme.dart';
import 'ios_liquid_glass.dart';
import 'poster_image.dart';

/// Collectible designer postcard variants cycled randomly on each Favorite tap.
enum FavoritePostcardStyle {
  /// Scalloped wavy postage-stamp border on warm cream cotton paper.
  wavyPostageStamp,

  /// Midnight-obsidian & champagne-gold cinema ticket stub with side notches.
  cinemaTicketStub,

  /// Ivory linen airmail postcard with crimson/navy diagonal stripes.
  vintageAirMail,

  /// Matte 35mm cinema film frame with top/bottom sprocket holes.
  filmFrameCard,
}

/// Plays the vintage-camera-flash -> wider collectible Marco Movie branded
/// postcard (random designer variant) -> parabolic flight into the Dynamic
/// Island -> Dynamic Island elastic capsule (`已收藏 <剧名>`) animation.
class FavoritePostcardFlightOverlay {
  FavoritePostcardFlightOverlay._();

  static OverlayEntry? _activeEntry;
  static final math.Random _rng = math.Random();
  static int _lastStyleIdx = -1;

  static FavoritePostcardStyle _pickNextStyle(
    FavoritePostcardStyle? override,
  ) {
    if (override != null) return override;
    const all = FavoritePostcardStyle.values;
    var next = _rng.nextInt(all.length);
    if (next == _lastStyleIdx && all.length > 1) {
      next = (next + 1 + _rng.nextInt(all.length - 1)) % all.length;
    }
    _lastStyleIdx = next;
    return all[next];
  }

  static Future<void> show(
    BuildContext context, {
    required String title,
    String posterUrl = '',
    String year = '',
    Uint8List? cachedBytes,
    Rect? originRect,
    @visibleForTesting FavoritePostcardStyle? styleOverride,
  }) async {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _activeEntry?.remove();
    _activeEntry = null;

    final style = _pickNextStyle(styleOverride);
    final bytes = cachedBytes ??
        PosterLoader.peekMemory(posterUrl, title: title, year: year);

    final islandMeta =
        await IosLiquidGlassBridge.triggerFavoriteDynamicIslandFeedback(
      'shutter',
    );
    if (!context.mounted) return;

    final completer = Completer<void>();
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _FavoritePostcardAnimationWidget(
        title: title,
        posterUrl: posterUrl,
        year: year,
        cachedBytes: bytes,
        originRect: originRect,
        islandMeta: islandMeta,
        style: style,
        onFinished: () {
          if (_activeEntry == entry) {
            _activeEntry = null;
          }
          entry.remove();
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    _activeEntry = entry;
    overlay.insert(entry);
    return completer.future;
  }
}

class _FavoritePostcardAnimationWidget extends StatefulWidget {
  final String title;
  final String posterUrl;
  final String year;
  final Uint8List? cachedBytes;
  final Rect? originRect;
  final Map<String, dynamic>? islandMeta;
  final FavoritePostcardStyle style;
  final VoidCallback onFinished;

  const _FavoritePostcardAnimationWidget({
    required this.title,
    required this.posterUrl,
    required this.year,
    required this.cachedBytes,
    required this.originRect,
    required this.islandMeta,
    required this.style,
    required this.onFinished,
  });

  @override
  State<_FavoritePostcardAnimationWidget> createState() =>
      _FavoritePostcardAnimationWidgetState();
}

class _FavoritePostcardAnimationWidgetState
    extends State<_FavoritePostcardAnimationWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _arrivalTriggered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    _controller.addListener(_onTick);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onFinished();
      }
    });
    HapticFeedback.mediumImpact();
    _controller.forward();
  }

  void _onTick() {
    if (!_arrivalTriggered && _controller.value >= 0.45) {
      _arrivalTriggered = true;
      HapticFeedback.heavyImpact();
      IosLiquidGlassBridge.triggerFavoriteDynamicIslandFeedback('arrive');
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose();
    super.dispose();
  }

  Rect _resolveIslandRect(Size screen, EdgeInsets safePadding) {
    final meta = widget.islandMeta;
    if (meta != null && meta['hasDynamicIsland'] == true) {
      final w = (meta['islandWidth'] as num?)?.toDouble() ?? 126.0;
      final h = (meta['islandHeight'] as num?)?.toDouble() ?? 37.0;
      final y = (meta['islandTop'] as num?)?.toDouble() ?? 11.0;
      final x = (meta['islandX'] as num?)?.toDouble() ?? ((screen.width - w) / 2);
      return Rect.fromLTWH(x, y, w, h);
    }
    const w = 126.0;
    const h = 36.0;
    final top =
        math.max(10.0, safePadding.top > 24 ? 11.0 : safePadding.top + 6.0);
    return Rect.fromLTWH((screen.width - w) / 2, top, w, h);
  }

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final islandRect = _resolveIslandRect(screen, safe);

    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;

            final flashOpacity = reducedMotion
                ? 0.0
                : (t < 0.035
                    ? Curves.easeOut.transform(t / 0.035) * 0.86
                    : (t < 0.12
                        ? (1.0 -
                                Curves.easeInCubic
                                    .transform((t - 0.035) / 0.085)) *
                            0.86
                        : 0.0));

            final showPostcard = !reducedMotion && t >= 0.04 && t <= 0.48;
            double cardOpacity = 0.0;
            double cardScale = 1.0;
            double cardRotateZ = 0.0;
            double cardTiltX = 0.0;
            Offset cardCenter = Offset(screen.width / 2, screen.height * 0.46);
            double developWash = 0.0;

            if (showPostcard) {
              if (t < 0.14) {
                final p = Curves.easeOutBack
                    .transform(((t - 0.04) / 0.10).clamp(0.0, 1.0));
                cardOpacity = ((t - 0.04) / 0.06).clamp(0.0, 1.0);
                cardScale = 0.78 + 0.24 * p;
                cardRotateZ = -0.055 * (1.0 - p) - 0.02;
                developWash = (1.0 - p).clamp(0.0, 1.0) * 0.62;
              } else if (t < 0.30) {
                final p = (t - 0.14) / 0.16;
                cardOpacity = 1.0;
                cardScale = 1.02 - 0.02 * math.sin(p * math.pi);
                cardRotateZ = -0.02 + 0.038 * p;
              } else {
                final p = Curves.easeInOutCubic
                    .transform(((t - 0.30) / 0.18).clamp(0.0, 1.0));
                final p0 = Offset(screen.width / 2, screen.height * 0.46);
                final p2 = Offset(islandRect.center.dx, islandRect.bottom + 6);
                final p1 = Offset(
                  screen.width * 0.68,
                  math.min(p0.dy, p2.dy) + (p0.dy - p2.dy) * 0.28,
                );
                final inv = 1.0 - p;
                cardCenter = Offset(
                  inv * inv * p0.dx + 2 * inv * p * p1.dx + p * p * p2.dx,
                  inv * inv * p0.dy + 2 * inv * p * p1.dy + p * p * p2.dy,
                );
                cardScale = 1.0 * (1.0 - p) + 0.16 * p;
                cardRotateZ = 0.018 * (1.0 - p) + 0.22 * p;
                cardTiltX = 0.45 * math.sin(p * math.pi);
                cardOpacity = p > 0.82
                    ? (1.0 - (p - 0.82) / 0.18).clamp(0.0, 1.0)
                    : 1.0;
              }
            }

            final showIslandFeedback = reducedMotion
                ? (t >= 0.05 && t <= 0.92)
                : (t >= 0.44 && t <= 0.98);
            double islandExpand = 0.0;
            if (showIslandFeedback) {
              if (reducedMotion) {
                islandExpand = 1.0;
              } else if (t < 0.56) {
                final p = ((t - 0.44) / 0.12).clamp(0.0, 1.0);
                islandExpand = Curves.easeOutBack.transform(p);
              } else if (t < 0.84) {
                islandExpand = 1.0;
              } else {
                final p = ((t - 0.84) / 0.14).clamp(0.0, 1.0);
                islandExpand = 1.0 - Curves.easeInCubic.transform(p);
              }
            }

            // Wider boutique postcard ratio (~1.52, e.g. 314 x 206 on iPhone).
            final cardWidth = math.min(314.0, screen.width * 0.84);
            final cardHeight = cardWidth / 1.52;

            return Stack(
              fit: StackFit.expand,
              children: [
                if (showPostcard)
                  ColoredBox(
                    color: Colors.black.withValues(
                      alpha: 0.30 * cardOpacity * (t < 0.34 ? 1.0 : 0.35),
                    ),
                  ),
                if (flashOpacity > 0.005)
                  _RetroCameraFlashLayer(opacity: flashOpacity),
                if (showPostcard)
                  Positioned(
                    left: cardCenter.dx - cardWidth / 2,
                    top: cardCenter.dy - cardHeight / 2,
                    width: cardWidth,
                    height: cardHeight,
                    child: Opacity(
                      opacity: cardOpacity.clamp(0.0, 1.0),
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.0014)
                          ..rotateX(cardTiltX)
                          ..rotateZ(cardRotateZ)
                          ..scaleByDouble(cardScale, cardScale, 1.0, 1.0),
                        child: _BrandedPostcardCard(
                          key: const Key('favorite-postcard-card'),
                          title: widget.title,
                          posterUrl: widget.posterUrl,
                          year: widget.year,
                          cachedBytes: widget.cachedBytes,
                          developWash: developWash,
                          style: widget.style,
                        ),
                      ),
                    ),
                  ),
                if (showIslandFeedback)
                  _DynamicIslandFeedbackPill(
                    key: const Key('favorite-dynamic-island-feedback'),
                    islandRect: islandRect,
                    expandProgress: islandExpand,
                    title: widget.title,
                    posterUrl: widget.posterUrl,
                    year: widget.year,
                    cachedBytes: widget.cachedBytes,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RetroCameraFlashLayer extends StatelessWidget {
  final double opacity;
  const _RetroCameraFlashLayer({required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 1.05,
                colors: [
                  const Color(0xFFFFFDF4),
                  const Color(0xFFFFF4D6).withValues(alpha: 0.92),
                  const Color(0xFFFFD89B).withValues(alpha: 0.52),
                ],
              ),
            ),
          ),
          Center(
            child: SizedBox(
              width: 268,
              height: 176,
              child: CustomPaint(painter: _ViewfinderCornersPainter()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewfinderCornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xCC1C1C1E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    const len = 18.0;
    canvas.drawLine(Offset.zero, const Offset(len, 0), paint);
    canvas.drawLine(Offset.zero, const Offset(0, len), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width - len, 0), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, len), paint);
    canvas.drawLine(Offset(0, size.height), Offset(len, size.height), paint);
    canvas.drawLine(Offset(0, size.height), Offset(0, size.height - len), paint);
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - len, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - len),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BrandedPostcardCard extends StatelessWidget {
  final String title;
  final String posterUrl;
  final String year;
  final Uint8List? cachedBytes;
  final double developWash;
  final FavoritePostcardStyle style;

  const _BrandedPostcardCard({
    super.key,
    required this.title,
    required this.posterUrl,
    required this.year,
    required this.cachedBytes,
    required this.developWash,
    required this.style,
  });

  Widget _buildPhoto() {
    final placeholder = Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2B3242), Color(0xFF151822)],
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.film_fill,
        color: Colors.white38,
        size: 36,
      ),
    );
    return cachedBytes != null
        ? Image.memory(
            cachedBytes!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          )
        : PosterImage(
            url: posterUrl,
            title: title,
            year: year,
            fit: BoxFit.cover,
            fadeIn: false,
            placeholder: placeholder,
          );
  }

  Widget _buildBrandStamp({
    required Color bg,
    required Color border,
    required Color textColor,
    String label = 'MARCO MOVIE',
    double angle = 0.05,
  }) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        key: const Key('favorite-postcard-brand-stamp'),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border, width: 0.85),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3.5),
              child: Image.asset(
                'assets/logo_mark.png',
                width: 13,
                height: 13,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  CupertinoIcons.film,
                  size: 11.5,
                  color: textColor,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: textColor,
                fontSize: 8.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final dateStamp =
        '${now.year}.${now.month.toString().padLeft(2, '0')}.${now.day.toString().padLeft(2, '0')}';

    return switch (style) {
      FavoritePostcardStyle.wavyPostageStamp =>
        _buildWavyPostageStamp(dateStamp),
      FavoritePostcardStyle.cinemaTicketStub =>
        _buildCinemaTicketStub(dateStamp),
      FavoritePostcardStyle.vintageAirMail => _buildVintageAirMail(dateStamp),
      FavoritePostcardStyle.filmFrameCard => _buildFilmFrameCard(dateStamp),
    };
  }

  /// Style 1: Scalloped wavy postage-stamp border on warm cream paper + ink postmark.
  Widget _buildWavyPostageStamp(String dateStamp) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.38),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipPath(
        clipper: const _WavyStampClipper(scallopRadius: 6.5),
        child: Container(
          color: const Color(0xFFFAF5E8),
          padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left 62%: Crisp framed film still
              Expanded(
                flex: 62,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildPhoto(),
                      if (developWash > 0.01)
                        ColoredBox(
                          color: const Color(0xFFFFF9EA)
                              .withValues(alpha: developWash.clamp(0.0, 1.0)),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Right 38%: Postcard correspondence column + circular postmark + logo stamp
              Expanded(
                flex: 38,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: _buildBrandStamp(
                          bg: const Color(0xFF1A191E),
                          border: const Color(0xFFD9B468),
                          textColor: const Color(0xFFFFEAB8),
                          label: 'MARCO',
                          angle: 0.06,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 36,
                      child: CustomPaint(
                        size: const Size(double.infinity, 36),
                        painter: _PostmarkStampPainter(),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      title.isNotEmpty ? title : '我的收藏',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                        color: Color(0xFF1F1C18),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Container(
                      height: 0.8,
                      color: const Color(0xFFD5C9B2),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          CupertinoIcons.heart_fill,
                          size: 10,
                          color: Color(0xFFD94A5A),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            dateStamp,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: TextScaler.noScaling,
                            style: const TextStyle(
                              color: Color(0xFF837868),
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Style 2: Collector's Cinema Ticket Stub with side notches & perforated tear line.
  Widget _buildCinemaTicketStub(String dateStamp) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.44),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipPath(
        clipper: const _CinemaTicketClipper(notchRadius: 11),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1C1E26), Color(0xFF101218)],
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left main movie frame
              Expanded(
                flex: 68,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildPhoto(),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.18),
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.82),
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 14,
                      right: 10,
                      bottom: 11,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title.isNotEmpty ? title : '我的收藏',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: TextScaler.noScaling,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'SCREEN 01 · $dateStamp',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: TextScaler.noScaling,
                            style: const TextStyle(
                              color: Color(0xFFD8B872),
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (developWash > 0.01)
                      ColoredBox(
                        color: const Color(0xFFFFF4D6)
                            .withValues(alpha: developWash.clamp(0.0, 1.0)),
                      ),
                  ],
                ),
              ),
              // Perforated tear divider
              SizedBox(
                width: 2,
                child: CustomPaint(painter: _TicketDashLinePainter()),
              ),
              // Right gold ticket stub with Marco seal & barcode
              Expanded(
                flex: 32,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 12, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _buildBrandStamp(
                          bg: const Color(0x28D8B872),
                          border: const Color(0xAAD8B872),
                          textColor: const Color(0xFFFFE5A8),
                          label: 'MARCO',
                          angle: 0.0,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'ADMIT ONE',
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 8,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        height: 44,
                        width: double.infinity,
                        child: CustomPaint(painter: _MiniBarcodePainter()),
                      ),
                      const SizedBox(height: 6),
                      const Icon(
                        CupertinoIcons.heart_fill,
                        size: 12,
                        color: AppleColors.systemPink,
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
  }

  /// Style 3: Vintage Air Mail Postcard with crimson/navy diagonal stripes.
  Widget _buildVintageAirMail(String dateStamp) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.36),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: CustomPaint(
          painter: _AirMailStripeBorderPainter(),
          child: Container(
            margin: const EdgeInsets.all(5.5),
            padding: const EdgeInsets.fromLTRB(9, 9, 9, 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFCF8F0),
              borderRadius: BorderRadius.circular(8.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildPhoto(),
                        Positioned(
                          top: 7,
                          left: 7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2.5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xD61F3E7A),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'PAR AVION',
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 6,
                          right: 7,
                          child: _buildBrandStamp(
                            bg: const Color(0xE8B92B38),
                            border: const Color(0xFFFFD8B0),
                            textColor: Colors.white,
                            label: 'MARCO',
                            angle: -0.06,
                          ),
                        ),
                        if (developWash > 0.01)
                          ColoredBox(
                            color: const Color(0xFFFFF9EA)
                                .withValues(alpha: developWash.clamp(0.0, 1.0)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.heart_fill,
                      size: 11.5,
                      color: Color(0xFFC93342),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        title.isNotEmpty ? title : '我的收藏',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textScaler: TextScaler.noScaling,
                        style: const TextStyle(
                          color: Color(0xFF1D2230),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      dateStamp,
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                        color: Color(0xFF6B7386),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Style 4: 35mm Cinema Film Frame with top & bottom sprocket perforations.
  Widget _buildFilmFrameCard(String dateStamp) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF141418),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: const Color(0x44F6C26B),
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.44),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: CustomPaint(
        painter: _FilmSprocketPainter(),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 22, 12, 22),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildPhoto(),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.14),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.78),
                      ],
                      stops: const [0.0, 0.50, 1.0],
                    ),
                  ),
                ),
                Positioned(
                  top: 7,
                  right: 7,
                  child: _buildBrandStamp(
                    bg: const Color(0xD8111116),
                    border: const Color(0xBBF6C26B),
                    textColor: const Color(0xFFF6C26B),
                    label: '35MM · MARCO',
                    angle: 0.0,
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title.isNotEmpty ? title : '我的收藏',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textScaler: TextScaler.noScaling,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        dateStamp,
                        textScaler: TextScaler.noScaling,
                        style: const TextStyle(
                          color: Color(0xFFF6C26B),
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                if (developWash > 0.01)
                  ColoredBox(
                    color: const Color(0xFFFFF4DC)
                        .withValues(alpha: developWash.clamp(0.0, 1.0)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scalloped wavy postage-stamp perimeter clipper.
class _WavyStampClipper extends CustomClipper<Path> {
  final double scallopRadius;
  const _WavyStampClipper({required this.scallopRadius});

  @override
  Path getClip(Size size) {
    final r = scallopRadius;
    final outer = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(6),
        ),
      );
    final holes = Path();
    final step = r * 2.55;

    for (double x = step * 0.7; x < size.width - step * 0.5; x += step) {
      holes.addOval(Rect.fromCircle(center: Offset(x, 0), radius: r));
      holes.addOval(Rect.fromCircle(center: Offset(x, size.height), radius: r));
    }
    for (double y = step * 0.7; y < size.height - step * 0.5; y += step) {
      holes.addOval(Rect.fromCircle(center: Offset(0, y), radius: r));
      holes.addOval(Rect.fromCircle(center: Offset(size.width, y), radius: r));
    }
    return Path.combine(PathOperation.difference, outer, holes);
  }

  @override
  bool shouldReclip(covariant _WavyStampClipper oldClipper) =>
      oldClipper.scallopRadius != scallopRadius;
}

class _PostmarkStampPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final ink = Paint()
      ..color = const Color(0x558B7355)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final cx = size.width * 0.34;
    final cy = size.height * 0.52;
    canvas.drawCircle(Offset(cx, cy), 14, ink);
    canvas.drawCircle(Offset(cx, cy), 10.5, ink);
    for (int i = -1; i <= 1; i++) {
      final y = cy + i * 5.0;
      final wave = Path()
        ..moveTo(cx + 15, y)
        ..quadraticBezierTo(cx + 26, y - 3, cx + 36, y)
        ..quadraticBezierTo(cx + 46, y + 3, size.width - 2, y);
      canvas.drawPath(wave, ink);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CinemaTicketClipper extends CustomClipper<Path> {
  final double notchRadius;
  const _CinemaTicketClipper({required this.notchRadius});

  @override
  Path getClip(Size size) {
    final outer = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(14),
        ),
      );
    final tearX = size.width * 0.68;
    final cutouts = Path()
      ..addOval(
        Rect.fromCircle(center: Offset(0, size.height * 0.5), radius: notchRadius),
      )
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width, size.height * 0.5),
          radius: notchRadius,
        ),
      )
      ..addOval(
        Rect.fromCircle(center: Offset(tearX, 0), radius: 7.5),
      )
      ..addOval(
        Rect.fromCircle(center: Offset(tearX, size.height), radius: 7.5),
      );
    return Path.combine(PathOperation.difference, outer, cutouts);
  }

  @override
  bool shouldReclip(covariant _CinemaTicketClipper oldClipper) =>
      oldClipper.notchRadius != notchRadius;
}

class _TicketDashLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0x55D8B872)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (double y = 12; y < size.height - 12; y += 9) {
      canvas.drawLine(Offset(1, y), Offset(1, y + 4.5), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _MiniBarcodePainter extends CustomPainter {
  static const List<double> _bars = [
    1.8, 1.0, 2.6, 1.2, 1.0, 3.0, 1.4, 1.0, 2.2, 1.2, 2.8, 1.0, 1.6,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0x88FFE5A8);
    double x = 4;
    for (int i = 0; i < _bars.length && x < size.width - 4; i++) {
      final w = _bars[i];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 4, w, size.height - 8),
          const Radius.circular(0.8),
        ),
        p,
      );
      x += w + (i.isEven ? 2.4 : 1.8);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _AirMailStripeBorderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFAF6EC),
    );
    final red = Paint()..color = const Color(0xFFD63B48);
    final blue = Paint()..color = const Color(0xFF22468A);
    const stripeW = 11.0;
    const gap = 7.0;
    int idx = 0;
    for (double start = -size.height;
        start < size.width + size.height;
        start += stripeW + gap) {
      final path = Path()
        ..moveTo(start, 0)
        ..lineTo(start + stripeW, 0)
        ..lineTo(start + stripeW - size.height, size.height)
        ..lineTo(start - size.height, size.height)
        ..close();
      canvas.drawPath(path, idx.isEven ? red : blue);
      idx++;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FilmSprocketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final hole = Paint()..color = const Color(0xFF2B2D36);
    final holeRim = Paint()
      ..color = const Color(0x33F6C26B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;
    const w = 11.0;
    const h = 8.0;
    const step = 22.0;
    for (double x = 14; x < size.width - 14; x += step) {
      final topRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 7, w, h),
        const Radius.circular(2),
      );
      final botRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - 15, w, h),
        const Radius.circular(2),
      );
      canvas.drawRRect(topRect, hole);
      canvas.drawRRect(topRect, holeRim);
      canvas.drawRRect(botRect, hole);
      canvas.drawRRect(botRect, holeRim);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DynamicIslandFeedbackPill extends StatelessWidget {
  final Rect islandRect;
  final double expandProgress;
  final String title;
  final String posterUrl;
  final String year;
  final Uint8List? cachedBytes;

  const _DynamicIslandFeedbackPill({
    super.key,
    required this.islandRect,
    required this.expandProgress,
    required this.title,
    required this.posterUrl,
    required this.year,
    required this.cachedBytes,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final p = expandProgress.clamp(0.0, 1.15);
    final clamped = expandProgress.clamp(0.0, 1.0);
    final targetW = math.min(312.0, screen.width - 24.0);
    final targetH = islandRect.height + 58.0;
    final currentW = islandRect.width + (targetW - islandRect.width) * p;
    final currentH = islandRect.height + (targetH - islandRect.height) * p;
    final left = (islandRect.center.dx - currentW / 2)
        .clamp(12.0, screen.width - currentW - 12.0);
    final top = islandRect.top;
    final cornerRadius =
        (islandRect.height / 2) + (28.0 - islandRect.height / 2) * clamped;

    final thumbPlaceholder = Container(
      color: const Color(0xFF23252C),
      alignment: Alignment.center,
      child: const Icon(CupertinoIcons.film, color: Colors.white54, size: 14),
    );
    final displayTitle = title.trim();
    final feedbackLine =
        displayTitle.isNotEmpty ? '已收藏 $displayTitle' : '已收藏影片';

    return Positioned(
      left: left,
      top: top,
      width: currentW.clamp(islandRect.width, screen.width - 20),
      height: currentH.clamp(islandRect.height, islandRect.height + 72),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF000000),
          borderRadius: BorderRadius.circular(cornerRadius),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.14 * clamped),
            width: 0.7,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45 * clamped),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        padding: EdgeInsets.fromLTRB(14, islandRect.height + 4, 14, 10),
        child: Opacity(
          opacity: ((clamped - 0.15) / 0.85).clamp(0.0, 1.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  width: 40,
                  height: 28,
                  padding: const EdgeInsets.all(1.5),
                  color: const Color(0xFFFAF6EE),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: cachedBytes != null
                        ? Image.memory(
                            cachedBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        : PosterImage(
                            url: posterUrl,
                            title: title,
                            year: year,
                            fit: BoxFit.cover,
                            fadeIn: false,
                            placeholder: thumbPlaceholder,
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Marco Movie',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1.5),
                    Text(
                      feedbackLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppleColors.systemPink.withValues(alpha: 0.22),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  CupertinoIcons.heart_fill,
                  size: 14.5,
                  color: AppleColors.systemPink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
