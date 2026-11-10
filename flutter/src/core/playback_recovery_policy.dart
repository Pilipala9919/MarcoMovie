import 'models.dart';

enum PlaybackRecoveryDecision { nextQuality, alternateLine, stop }

/// Automatic recovery must not resolve another cloud share or switch accounts.
/// Explicit user line selection does not use this policy.
class PlaybackRecoveryPolicy {
  static PlaybackRecoveryDecision decide({
    required CmsEpisode episode,
    required bool isTrial,
    required bool hasNextQuality,
  }) {
    if (!isTrial && hasNextQuality) {
      return PlaybackRecoveryDecision.nextQuality;
    }
    return episode.cloudProvider == null
        ? PlaybackRecoveryDecision.alternateLine
        : PlaybackRecoveryDecision.stop;
  }

  static bool isAutomaticLineCandidate(CmsEpisode episode) =>
      episode.cloudProvider == null &&
      (episode.isDirectPlayable || episode.needsSourceResolution);
}
