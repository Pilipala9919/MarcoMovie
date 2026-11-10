import 'package:flutter/widgets.dart';

/// Buttons and sliders are siblings of the video gesture surface, so repeated
/// control taps never enter the video's double-tap or long-press recognizers.
class PlayerInteractionLayers extends StatelessWidget {
  final Widget surface;
  final Widget? controls;
  const PlayerInteractionLayers(
      {super.key, required this.surface, this.controls});

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [surface, if (controls != null) controls!],
      );
}
