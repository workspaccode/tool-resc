// Renders the desktop (macOS / Windows) layout for visual review.
// Not part of the normal test run. Writes PNGs to tool/screenshots/shots/:
//   flutter test --update-goldens tool/screenshots/desktop_screenshots_test.dart
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/app/settings.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/component_lists.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/features/components/components_screen.dart';
import 'package:tool_resc/features/components/excel_reader.dart';
import 'package:tool_resc/features/components/import_sheet.dart';
import 'package:tool_resc/features/home/settings_sheet.dart';
import 'package:tool_resc/main.dart';

Future<void> _font(String family, String path) async {
  final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

void main() {
  setUpAll(() async {
    await _font('CupertinoSystemText', '/System/Library/Fonts/SFNS.ttf');
    await _font('CupertinoSystemDisplay', '/System/Library/Fonts/SFNS.ttf');
    await _font(
      'packages/cupertino_icons/CupertinoIcons',
      '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev/cupertino_icons-1.0.8/assets/CupertinoIcons.ttf',
    );
  });

  testWidgets('desktop screens', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(2560, 1640); // 1280 x 820 window @2x
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await initStorage(path: (await Directory.systemTemp.createTemp('desktop_shots')).path);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    Future<void> shot(String name) async {
      for (final mode in [Appearance.light, Appearance.dark]) {
        container.read(appearanceProvider.notifier).set(mode);
        await settle();
        await expectLater(find.byType(CupertinoApp), matchesGoldenFile('shots/desktop_${name}_${mode.name}.png'));
      }
    }

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ToolRescApp()));
    await shot('1_empty');

    final tables = (await tester.runAsync(() => readExcel(File('test/fixtures/sample_lcsc.xlsx').readAsBytesSync())))!;
    final ctx = tester.element(find.byType(ComponentsScreen));
    showImportSheet(ctx, fileName: 'lcsc_order_WM2609230751.xlsx', tables: tables);
    await shot('2_import');
    Navigator.of(ctx, rootNavigator: true).pop();
    await tester.runAsync(
      () => container
          .read(catalogProvider.notifier)
          .import(headers: tables.single.headers, rows: tables.single.rows, mpnIndex: 1, mode: ImportMode.replace),
    );
    await shot('3_ready');

    // A USB scanner sends the LCSC QR payload as keystrokes + Enter.
    await _typeLikeScanner('{pc:C141700,pm:RC0805FR-07820KL,qty:100}');
    await shot('4_scanned');

    // A second list; scanning a part that's only in the first one.
    await tester.runAsync(() async {
      await container.read(listsProvider.notifier).create('BOM F280033');
      await container
          .read(catalogProvider.notifier)
          .import(
            headers: ['MPN', 'Description', 'Designator', 'Quantity'],
            rows: [
              ['CC0805KRX7R8BB104', 'CAP CER 100nF 25V X7R 0805', 'C1, C2, C4', '21'],
              ['CL21B106KOQNNNE', 'CAP CER 10UF 16V X7R 0805', 'C3, C6', '12'],
              ['LM358DR', 'Dual Op-Amp SOIC-8', 'U1', '1'],
            ],
            mpnIndex: 0,
            mode: ImportMode.replace,
          );
    });
    await _typeLikeScanner('{pc:C141700,pm:RC0805FR-07820KL,qty:100}');
    await shot('5_other_list');

    showSettingsSheet(tester.element(find.byType(ComponentsScreen)));
    await shot('6_settings');

    debugDefaultTargetPlatformOverride = null;
  });
}

/// Sends [text] as US-layout key presses, with Shift where needed, then Enter.
Future<void> _typeLikeScanner(String text) async {
  const shifted = {'{': '[', '}': ']', ':': ';', '_': '-'};
  const physical = {
    '[': PhysicalKeyboardKey.bracketLeft,
    ']': PhysicalKeyboardKey.bracketRight,
    ';': PhysicalKeyboardKey.semicolon,
    ',': PhysicalKeyboardKey.comma,
    '-': PhysicalKeyboardKey.minus,
  };
  for (final ch in text.split('')) {
    final upper = ch.toUpperCase() == ch && ch.toLowerCase() != ch;
    final base = shifted[ch] ?? ch.toLowerCase();
    final shift = upper || shifted.containsKey(ch);
    final key =
        physical[base] ??
        (RegExp('[a-z]').hasMatch(base)
            ? PhysicalKeyboardKey(0x00070004 + base.codeUnitAt(0) - 0x61)
            : PhysicalKeyboardKey(base == '0' ? 0x00070027 : 0x0007001E + base.codeUnitAt(0) - 0x31));
    if (shift) await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await simulateKeyDownEvent(LogicalKeyboardKey.keyA, physicalKey: key, character: ch);
    await simulateKeyUpEvent(LogicalKeyboardKey.keyA, physicalKey: key);
    if (shift) await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
  await simulateKeyDownEvent(LogicalKeyboardKey.enter);
  await simulateKeyUpEvent(LogicalKeyboardKey.enter);
}
