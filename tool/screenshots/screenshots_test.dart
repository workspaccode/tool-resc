// Renders the main screens at iPhone 17 Pro Max size for visual review.
// Not part of the normal test run. Writes PNGs to tool/screenshots/shots/:
//   flutter test --update-goldens tool/screenshots/screenshots_test.dart
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:tool_resc/app/settings.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/features/components/components_screen.dart';
import 'package:tool_resc/features/components/excel_reader.dart';
import 'package:tool_resc/features/components/import_sheet.dart';
import 'package:tool_resc/features/components/label_parser.dart';
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

  testWidgets('screens', (tester) async {
    tester.view.physicalSize = const Size(1320, 2868); // 440 x 956 pt @3x
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    tester.view.viewPadding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      if (!Hive.isBoxOpen(Boxes.settings)) {
        Hive.init((await Directory.systemTemp.createTemp('shots')).path);
      }
      await (await Hive.openBox<Object>(Boxes.settings)).clear();
      await (await Hive.openBox<Object>(Boxes.componentsMeta)).clear();
      await (await Hive.openLazyBox<Map>(Boxes.components)).clear();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    // Each screen in light and dark.
    Future<void> shot(String name) async {
      for (final mode in [Appearance.light, Appearance.dark]) {
        container.read(appearanceProvider.notifier).set(mode);
        await settle();
        await expectLater(find.byType(CupertinoApp), matchesGoldenFile('shots/${name}_${mode.name}.png'));
      }
    }

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ToolRescApp()));
    await shot('1_home');

    await tester.tap(find.text('Components'));
    await shot('2_empty');

    final tables = (await tester.runAsync(() => readExcel(File('test/fixtures/sample_lcsc.xlsx').readAsBytesSync())))!;
    final ctx = tester.element(find.byType(ComponentsScreen));
    showImportSheet(ctx, fileName: 'lcsc_order_WM2609230751.xlsx', tables: tables);
    await shot('3_import');
    await tester.runAsync(
      () => container
          .read(catalogProvider.notifier)
          .import(headers: tables.single.headers, rows: tables.single.rows, mpnIndex: 1, mode: ImportMode.replace),
    );
    Navigator.of(ctx, rootNavigator: true).pop();
    await shot('4_ready');

    container.read(searchQueryProvider.notifier).set('0805');
    await shot('5_results');

    container.read(searchQueryProvider.notifier).set('RC0805FR-07820KL');
    container
        .read(scannedLabelProvider.notifier)
        .set(ScannedLabel.parse('{on:WM2609230751,pc:C141700,pm:RC0805FR-07820KL,qty:100}'));
    await shot('6_scanned');

    await tester.tap(find.text('RC0805FR-07820KL').last);
    await shot('7_detail');

    showSettingsSheet(tester.element(find.byType(CupertinoPageScaffold).last));
    await shot('8_settings');
  });
}
