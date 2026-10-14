import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/component_lists.dart';
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
      await initStorage(path: (await Directory.systemTemp.createTemp('desktop_test')).path);
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
      await simulateKeyDownEvent(
        LogicalKeyboardKey.findKeyByKeyId(key.usbHidUsage) ?? LogicalKeyboardKey.keyA,
        physicalKey: key,
      );
      await simulateKeyUpEvent(
        LogicalKeyboardKey.findKeyByKeyId(key.usbHidUsage) ?? LogicalKeyboardKey.keyA,
        physicalKey: key,
      );
    }
    await simulateKeyDownEvent(LogicalKeyboardKey.enter);
    await simulateKeyUpEvent(LogicalKeyboardKey.enter);
    await settle();

    // The part opened in the detail pane, with its fields.
    expect(find.text('No Component Selected'), findsNothing);
    expect(find.text('Drawer B1'), findsOneWidget);
    expect(find.text('In This List'), findsOneWidget);

    // Click into the search field first, then scan: the field keeps focus
    // and ends up with the scanned value, and the part opens.
    Future<void> scanKeys(List<PhysicalKeyboardKey> keys, {bool enter = true}) async {
      for (final key in keys) {
        await simulateKeyDownEvent(LogicalKeyboardKey.keyA, physicalKey: key);
        await simulateKeyUpEvent(LogicalKeyboardKey.keyA, physicalKey: key);
      }
      if (enter) {
        await simulateKeyDownEvent(LogicalKeyboardKey.enter);
        await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      }
    }

    await tester.tap(find.byType(CupertinoSearchTextField));
    await settle();
    final searchFocus = tester.widget<EditableText>(find.byType(EditableText)).focusNode;
    expect(searchFocus.hasFocus, isTrue);
    await scanKeys([
      PhysicalKeyboardKey.keyR,
      PhysicalKeyboardKey.keyC,
      PhysicalKeyboardKey.digit0,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.digit0,
      PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.keyF,
      PhysicalKeyboardKey.keyR,
      PhysicalKeyboardKey.minus,
      PhysicalKeyboardKey.digit0,
      PhysicalKeyboardKey.digit7,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.digit2,
      PhysicalKeyboardKey.digit0,
      PhysicalKeyboardKey.keyK,
      PhysicalKeyboardKey.keyL,
    ]);
    await settle();
    expect(searchFocus.hasFocus, isTrue);
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, 'RC0805FR-07820KL');
    expect(find.text('Drawer A3'), findsOneWidget);

    // A scanner that sends no Enter: the scan is taken after a short pause.
    await scanKeys([
      PhysicalKeyboardKey.keyL,
      PhysicalKeyboardKey.keyM,
      PhysicalKeyboardKey.digit3,
      PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.keyD,
      PhysicalKeyboardKey.keyR,
    ], enter: false);
    await settle();
    expect(find.text('Drawer B1'), findsOneWidget);

    // A slow scanner's QR text lands in the search field; Enter still
    // handles it as a scan.
    const qr = '{pc:C141700,pm:RC0805FR-07820KL,qty:100}';
    final field = tester.widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField));
    field.controller!.text = qr;
    field.onSubmitted!(qr);
    await settle();
    expect(find.text('Drawer A3'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(CupertinoSearchTextField), matching: find.text('RC0805FR-07820KL')),
      findsOneWidget,
    );

    // A second list: the title and sidebar follow the active list.
    await tester.runAsync(() async {
      await container.read(listsProvider.notifier).create('BOM F280033');
      await container
          .read(catalogProvider.notifier)
          .import(
            headers: ['MPN'],
            rows: [
              ['ABC123'],
            ],
            mpnIndex: 0,
            mode: ImportMode.replace,
          );
    });
    await settle();
    final navBar = find.byType(CupertinoSliverNavigationBar);
    expect(find.descendant(of: navBar, matching: find.text('BOM F280033')), findsWidgets);
    expect(find.descendant(of: navBar, matching: find.text('Main List')), findsNothing);

    // The part from the first list is reported as being in another list.
    expect(find.text('Not in This List'), findsOneWidget);
    expect(find.text('Found in'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}
