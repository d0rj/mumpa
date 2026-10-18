import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Uses the display, not a resized/letterboxed app window, to distinguish phones
/// from tablets. A rotated phone must remain a phone.
class PhoneOrientation extends StatefulWidget {
  const PhoneOrientation({super.key, required this.child});
  final Widget child;

  @override
  State<PhoneOrientation> createState() => _PhoneOrientationState();
}

class _PhoneOrientationState extends State<PhoneOrientation>
    with WidgetsBindingObserver {
  ui.FlutterView? _view;
  bool? _locked;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.maybeOf(context);
    _apply();
  }

  @override
  void didChangeMetrics() => _apply();

  void _apply() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final display = _view?.display;
    if (display == null || display.size.isEmpty) return;
    final lock = display.size.shortestSide / display.devicePixelRatio < 600;
    if (_locked == lock) return;
    _locked = lock;
    SystemChrome.setPreferredOrientations(
      lock ? const [DeviceOrientation.portraitUp] : const [],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
