import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/core/playback_recovery_policy.dart';

void main() {
  final cloudEpisodes = <String, CmsEpisode>{
    'Quark share': const CmsEpisode(
      name: '第01集',
      url:
          'mmwogg://quark?share=https%3A%2F%2Fpan.quark.cn%2Fs%2Ffirst&fid=one',
    ),
    'Quark account':
        const CmsEpisode(name: '第01集', url: 'mmquark://owned?fid=one'),
    'UC share':
        const CmsEpisode(name: '第01集', url: 'mmcloud://uc?share=first&fid=one'),
    'Baidu share': const CmsEpisode(
        name: '第01集', url: 'mmcloud://baidu?share=first&fid=one'),
    'Ali share': const CmsEpisode(
        name: '第01集', url: 'mmcloud://ali?share=first&fid=one'),
  };

  for (final entry in cloudEpisodes.entries) {
    for (final isTrial in [false, true]) {
      for (final hasNextQuality in [false, true]) {
        test(
            '${entry.key}: trial=$isTrial nextQuality=$hasNextQuality stays on its file',
            () {
          expect(
            PlaybackRecoveryPolicy.decide(
              episode: entry.value,
              isTrial: isTrial,
              hasNextQuality: hasNextQuality,
            ),
            !isTrial && hasNextQuality
                ? PlaybackRecoveryDecision.nextQuality
                : PlaybackRecoveryDecision.stop,
          );
        });
      }
    }
    test('${entry.key} is never an automatic alternate-line target', () {
      expect(PlaybackRecoveryPolicy.isAutomaticLineCandidate(entry.value),
          isFalse);
    });
  }

  test(
      'same provider with a different share is still blocked after quality failure',
      () {
    final current = cloudEpisodes['Quark share']!;
    const otherShare = CmsEpisode(
      name: '第01集',
      url:
          'mmwogg://quark?share=https%3A%2F%2Fpan.quark.cn%2Fs%2Fsecond&fid=two',
    );
    expect(current.cloudProvider, otherShare.cloudProvider);
    expect(
      PlaybackRecoveryPolicy.decide(
          episode: current, isTrial: false, hasNextQuality: false),
      PlaybackRecoveryDecision.stop,
    );
    expect(
        PlaybackRecoveryPolicy.isAutomaticLineCandidate(otherShare), isFalse);
  });

  const ordinaryEpisodes = [
    CmsEpisode(name: '第01集', url: 'https://media.test/one.m3u8'),
    CmsEpisode(name: '第01集', url: 'mmjs://play?id=one'),
    CmsEpisode(name: '第01集', url: 'mmpaw://play?id=one'),
  ];
  for (final episode in ordinaryEpisodes) {
    test(
        '${Uri.parse(episode.url).scheme} retains ordinary recovery and quality priority',
        () {
      expect(PlaybackRecoveryPolicy.isAutomaticLineCandidate(episode), isTrue);
      for (final isTrial in [false, true]) {
        expect(
          PlaybackRecoveryPolicy.decide(
              episode: episode, isTrial: isTrial, hasNextQuality: false),
          PlaybackRecoveryDecision.alternateLine,
        );
      }
      expect(
        PlaybackRecoveryPolicy.decide(
            episode: episode, isTrial: false, hasNextQuality: true),
        PlaybackRecoveryDecision.nextQuality,
      );
      expect(
        PlaybackRecoveryPolicy.decide(
            episode: episode, isTrial: true, hasNextQuality: true),
        PlaybackRecoveryDecision.alternateLine,
      );
    });
  }

  test(
      'ordinary recovery skips native cloud entries and preserves source order',
      () {
    final candidates = [
      cloudEpisodes['Baidu share']!,
      cloudEpisodes['Quark share']!,
      const CmsEpisode(name: 'unplayable', url: 'unsupported://one'),
      ...ordinaryEpisodes,
    ];
    final eligible = candidates
        .where(PlaybackRecoveryPolicy.isAutomaticLineCandidate)
        .toList();
    expect(eligible, ordinaryEpisodes);
    expect(eligible.first, same(ordinaryEpisodes.first));
  });

  test(
      'ordinary titles and arbitrary metadata cannot impersonate native cloud identity',
      () {
    const direct = CmsEpisode(
      name: '夸克 4K 第01集',
      url: 'https://media.test/one.mp4',
      playbackSession: {'cloudProvider': 'baidu'},
    );
    expect(direct.cloudProvider, isNull);
    expect(PlaybackRecoveryPolicy.isAutomaticLineCandidate(direct), isTrue);
  });
}
