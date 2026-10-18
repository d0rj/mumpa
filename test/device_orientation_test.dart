import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/ui/device_orientation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final orientations = <List<dynamic>>[];
  setUp(() {
    orientations.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            orientations.add(List<dynamic>.from(call.arguments as List));
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  void display(WidgetTester tester, Size size, double ratio) {
    tester.view.display.size = size;
    tester.view.display.devicePixelRatio = ratio;
    addTearDown(tester.view.display.reset);
  }

  Future<void> show(WidgetTester tester) =>
      tester.pumpWidget(const PhoneOrientation(child: SizedBox()));

  for (final size in [const Size(1080, 2400), const Size(2400, 1080)]) {
    testWidgets(
      'phone display $size requests portrait',
      (tester) async {
        display(tester, size, 3);
        await show(tester);
        expect(orientations, [
          ['DeviceOrientation.portraitUp'],
        ]);
        tester.view.physicalSize = const Size(800, 400);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pump();
        expect(orientations, hasLength(1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final size in [
    const Size(1600, 2560),
    const Size(2560, 1600),
    const Size(1200, 2000),
  ]) {
    testWidgets(
      'tablet display $size permits rotation even with a narrow window',
      (tester) async {
        display(tester, size, 2);
        tester.view.physicalSize = const Size(700, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        await show(tester);
        expect(orientations, [isEmpty]);
        tester.view.physicalSize = const Size(1000, 700);
        await tester.pump();
        expect(orientations, hasLength(1));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'folding and unfolding updates the orientation policy',
    (tester) async {
      display(tester, const Size(1080, 2400), 3);
      await show(tester);
      tester.view.display.size = const Size(2400, 2400);
      await tester.pump();
      tester.view.display.size = const Size(1080, 2400);
      await tester.pump();
      expect(orientations, [
        ['DeviceOrientation.portraitUp'],
        isEmpty,
        ['DeviceOrientation.portraitUp'],
      ]);
      await tester.pumpWidget(const SizedBox());
      tester.view.display.size = const Size(2400, 2400);
      await tester.pump();
      expect(orientations, hasLength(3));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'small desktop windows do not set device orientation',
    (tester) async {
      display(tester, const Size(400, 700), 1);
      await show(tester);
      expect(orientations, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
