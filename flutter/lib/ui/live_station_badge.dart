import 'package:flutter/material.dart';

import '../core/live_channel_organizer.dart';
import '../core/models.dart';
import 'poster_image.dart';

/// Shared TV station logo badge: renders `channel.logo` (`tvg-logo` or custom
/// template) when present, falling back seamlessly to a crisp brand-colored
/// vector/monogram emblem from [LiveChannelOrganizer.resolveStationEmblem].
class LiveStationBadge extends StatelessWidget {
  final LiveChannel channel;
  final double size;
  final double radius;

  const LiveStationBadge({
    super.key,
    required this.channel,
    this.size = 42,
    this.radius = 11,
  });

  @override
  Widget build(BuildContext context) {
    final emblem = LiveChannelOrganizer.resolveStationEmblem(channel);
    final compact = size < 38;
    final fallbackBadge = Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(emblem.colorStart), Color(emblem.colorEnd)],
        ),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: Color(0x3DFFFFFF), width: 0.55),
        ),
      ),
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: size * 0.38,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(radius),
                ),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x28FFFFFF), Color(0x00FFFFFF)],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: emblem.topLine.isNotEmpty
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        emblem.topLine,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          color: Color(emblem.accentColor)
                              .withValues(alpha: 0.85),
                          fontSize: compact ? 6.8 : 7.8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          height: 1.02,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        emblem.mainText,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact
                              ? (emblem.mainText.length >= 3 ? 9.5 : 11.0)
                              : (emblem.mainText.length >= 3 ? 11.0 : 12.8),
                          fontWeight: FontWeight.w900,
                          height: 1.08,
                        ),
                      ),
                    ],
                  )
                : Text(
                    emblem.mainText,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 11.5 : 13.0,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
          ),
        ],
      ),
    );

    if (channel.logo.trim().isNotEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: DecoratedBox(
            decoration: const BoxDecoration(color: Color(0xFF1E202B)),
            child: PosterImage(
              url: channel.logo.trim(),
              fit: BoxFit.contain,
              fadeIn: false,
              placeholder: fallbackBadge,
            ),
          ),
        ),
      );
    }
    return fallbackBadge;
  }
}

/// Visual color + concise label for a live channel's connectivity probe status.
class LiveHealthVisual {
  static Color dotColor(LiveStreamHealth health) => switch (health) {
        LiveStreamHealth.fast => const Color(0xFF34D399),
        LiveStreamHealth.smooth => const Color(0xFF38BDF8),
        LiveStreamHealth.slow => const Color(0xFFFBBF24),
        LiveStreamHealth.unreachable => const Color(0xFFF87171),
        LiveStreamHealth.unknown => const Color(0x889CA3AF),
      };

  static String? badgeText(LiveChannel channel) {
    if (channel.health == LiveStreamHealth.unreachable) return '失效';
    final ms = channel.latencyMs;
    if (ms != null && ms > 0) return '${ms}ms';
    return switch (channel.health) {
      LiveStreamHealth.fast => '极速',
      LiveStreamHealth.smooth => '流畅',
      LiveStreamHealth.slow => '较慢',
      _ => null,
    };
  }
}
