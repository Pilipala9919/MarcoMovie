import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/cloud_media_proxy.dart';
import 'package:marco_movie/core/models.dart';
import 'package:marco_movie/ui/player_screen.dart';

class _Lease extends Fake implements CloudMediaLease {
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
  }
}

void main() {
  test('changing quality of the same cloud file keeps its transport alive',
      () async {
    final lease = _Lease();
    final owner = PlayerCloudMediaSession()..adopt(lease);
    final quality = CmsEpisode(
        name: '原画',
        url: 'http://127.0.0.1/media',
        playbackSession: {'cloudMediaLease': lease});
    expect(owner.owns(PlayerCloudMediaSession.of(quality)), isTrue);
    await owner.releaseUnless(PlayerCloudMediaSession.of(quality));
    expect(lease.closes, 0);
    expect(owner.current, same(lease));
  });

  test('changing episodes releases the old transport before accepting the next',
      () async {
    final old = _Lease();
    final next = _Lease();
    final owner = PlayerCloudMediaSession()..adopt(old);
    await owner.releaseUnless(next);
    expect(old.closes, 1);
    expect(owner.current, isNull);
    owner.adopt(next);
    await owner.discard(old);
    expect(next.closes, 0);
    expect(owner.current, same(next));
  });

  test('late resolved file is released without revoking the current file',
      () async {
    final current = _Lease();
    final late = _Lease();
    final owner = PlayerCloudMediaSession()..adopt(current);
    await owner.discard(late);
    expect(late.closes, 1);
    expect(current.closes, 0);
    await owner.discard(current);
    expect(current.closes, 0,
        reason:
            'A late same-lease quality callback must not close its successor.');
  });

  test('leaving the page detaches lease for release after decoder disposal',
      () async {
    final lease = _Lease();
    final owner = PlayerCloudMediaSession()..adopt(lease);
    final detached = owner.detach();
    expect(owner.current, isNull);
    expect(lease.closes, 0);
    // The actual player closes this only after its serialized decoder disposal.
    await detached?.close();
    expect(lease.closes, 1);
    expect(owner.detach(), isNull);
  });

  test('ordinary media and unexpected metadata do not become transport owners',
      () {
    expect(
        PlayerCloudMediaSession.of(
            const CmsEpisode(name: 'one', url: 'https://media.test/1.mp4')),
        isNull);
    expect(
        PlayerCloudMediaSession.of(const CmsEpisode(
            name: 'one',
            url: 'https://media.test/1.mp4',
            playbackSession: {'cloudMediaLease': 'untrusted'})),
        isNull);
  });
}
