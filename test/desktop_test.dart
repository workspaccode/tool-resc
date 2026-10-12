import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/main.dart';

void main() {
  testWidgets('desktop: sidebar, split view, and a USB scanner scan opens the part', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      Hive.init((await Directory.systemTemp.createTemp('desktop_test')).path);
      await Hive.openBox<Object>(Boxes.settings);
      await Hive.openBox<Object>(Boxes.componentsMeta);
      await Hive.openLazyBox<Map>(Boxes.components);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container
          .read(catalogProvider.notifier)
          .import(
            headers: ['MPN', 'Manufacturer', 'Location'],
            rows: [
              ['RC0805FR-07820KL', 'YAGEO', 'Drawer A3'],
              ['LM358DR', 'TI', 'Drawer B1'],
            ],
            mpnIndex: 0,
            mode: ImportMode.replace,
          ),
    );

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ToolRescApp()));
    await settle();

    // Sidebar + Components open side by side, nothing selected yet.
    expect(find.text('Tool Resc'), findsOneWidget);
    expect(find.text('Scanner ready — scan a label'), findsOneWidget);
    expect(find.text('No Component Selected'), findsOneWidget);

    // The scanner "types" the MPN (all at once, like a real scanner) + Enter.
    for (final key in [
      PhysicalKeyboardKey.keyL,
      PhysicalKeyboardKey.keyM,
      PhysicalKeyboardKey.digit3,
      PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.keyD,
      PhysicalKeyboardKey.keyR,
    ]) {
      await simulateKeyDownEvent(LogicalKeyboardKey.findKeyByKeyId(key.usbHidUsage) ?? LogicalKeyboardKey.keyA, physicalKey: key);
      await simulateKeyUpEvent(LogicalKeyboardKey.findKeyByKeyId(key.usbHidUsage) ?? LogicalKeyboardKey.keyA, physicalKey: key);
    }
    await simulateKeyDownEvent(LogicalKeyboardKey.enter);
    await simulateKeyUpEvent(LogicalKeyboardKey.enter);
    await settle();

    // The part opened in the detail pane, with its fields.
    expect(find.text('No Component Selected'), findsNothing);
    expect(find.text('Drawer B1'), findsOneWidget);
    expect(find.text('In Database'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}
