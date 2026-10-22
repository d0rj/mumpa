import 'package:flutter/material.dart';

/// Keeps the Material value-indicator portal inside its slider's semantics tree.
/// Flutter 3.44 can otherwise serialize an orphan when a route/dialog changes:
/// https://github.com/flutter/flutter/issues/190357
class AccessibleSlider extends StatelessWidget {
  const AccessibleSlider({super.key, required this.child});
  final Slider child;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    alwaysSizeToContent: true,
    clipBehavior: Clip.none,
    child: child,
  );
}
