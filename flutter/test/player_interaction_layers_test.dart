import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/player_interaction_layers.dart';

void main() {
  testWidgets('two rapid seek taps both seek without pausing the video',
      (tester) async {
    var seeks = 0, pauses = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlayerInteractionLayers(
      surface: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => pauses++,
        child: const SizedBox.expand(),
      ),
      controls: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            key: const Key('rewind'),
            onPressed: () => seeks -= 15,
            icon: const Icon(Icons.replay_10)),
        IconButton(
            key: const Key('forward'),
            onPressed: () => seeks += 15,
            icon: const Icon(Icons.forward_10)),
      ])),
    ))));
    for (final key in ['forward', 'rewind']) {
      final before = seeks;
      await tester.tap(find.byKey(Key(key)));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(Key(key)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(seeks - before, key == 'forward' ? 30 : -30);
      expect(pauses, 0);
    }
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(pauses, 1, reason: 'Video background double tap remains available.');
  });
}
