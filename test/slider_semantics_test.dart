import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mumpa/ui/accessible_slider.dart';

class _SemanticsRecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  final nodes = <int, List<int>>{};
  final orphans = <int>[];
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(this);
}

class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this.owner);
  final _SemanticsRecordingBinding owner;
  final delegate = ui.SemanticsUpdateBuilder();
  final updated = <int>[];
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final id = invocation.namedArguments[#id] as int;
      owner.nodes[id] = List<int>.from(
        invocation.namedArguments[#childrenInTraversalOrder] as Iterable,
      );
      updated.add(id);
      return Function.apply(
        delegate.updateNode,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        delegate.updateCustomAction,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in owner.nodes[id] ?? <int>[]) {
        visit(child);
      }
    }

    visit(0);
    owner.orphans.addAll(updated.where((id) => !reachable.contains(id)));
    return delegate.build();
  }
}

void main() {
  final binding = _SemanticsRecordingBinding();
  testWidgets(
    'slider remains attached to the semantics tree across route changes',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const Dialog(
                      child: SizedBox(
                        width: 300,
                        height: 200,
                        child: _Control(),
                      ),
                    ),
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Slider), const Offset(40, 0));
        await tester.pumpAndSettle();
        final before = tester.widget<Slider>(find.byType(Slider)).value;
        SemanticsNode? node;
        void visit(SemanticsNode candidate) {
          if (candidate.getSemanticsData().hasAction(
            ui.SemanticsAction.increase,
          )) {
            node = candidate;
          }
          candidate.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(tester.getSemantics(find.byType(Slider)));
        expect(node, isNotNull);
        final adjustable = node!;
        adjustable.owner!.performAction(
          adjustable.id,
          ui.SemanticsAction.increase,
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<Slider>(find.byType(Slider)).value,
          greaterThan(before),
        );
        final accessibleValue = tester
            .widget<Slider>(find.byType(Slider))
            .value;
        tester.widget<Slider>(find.byType(Slider)).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Slider>(find.byType(Slider)).value,
          greaterThan(accessibleValue),
        );
        expect(
          binding.orphans,
          isEmpty,
          reason: 'Every serialized node must be reachable by Windows AXTree',
        );
        expect(find.byType(Slider), findsOneWidget);
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pumpAndSettle();
        expect(binding.orphans, isEmpty);
      } finally {
        semantics.dispose();
      }
    },
  );
}

class _Control extends StatefulWidget {
  const _Control();
  @override
  State<_Control> createState() => _ControlState();
}

class _ControlState extends State<_Control> {
  double value = .3;
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AccessibleSlider(
    child: Slider(
      focusNode: focus,
      value: value,
      onChanged: (next) => setState(() => value = next),
    ),
  );
}
