import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/app/settings.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/main.dart';

void main() {
  testWidgets('optional search while typing and search after scan', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await initStorage(path: (await Directory.systemTemp.createTemp('prefs_test')).path);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container
          .read(catalogProvider.notifier)
          .import(
            headers: ['Part No', 'Bin'],
            rows: [
              ['LM358DR', 'B1'],
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

    final prefs = container.read(searchPrefsProvider.notifier);
    prefs.update((p) => p.copyWith(searchWhileTyping: false, searchOnScan: false));

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ToolRescApp()));
    await settle();
    // The search field names the imported search column, not a fixed "MPN".
    expect(find.textContaining('Search by Part No'), findsOneWidget);
    final field = tester.widget<CupertinoSearchTextField>(find.byType(CupertinoSearchTextField));

    // Typing doesn't search until Enter.
    field.controller!.text = 'LM358';
    field.onChanged!('LM358');
    await settle();
    expect(container.read(searchQueryProvider), '');
    field.onSubmitted!('LM358');
    await settle();
    expect(container.read(searchQueryProvider), 'LM358');

    // A USB scan only fills the field.
    field.controller!.clear();
    for (final key in [
      PhysicalKeyboardKey.keyL,
      PhysicalKeyboardKey.keyM,
      PhysicalKeyboardKey.digit3,
      PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.keyD,
      PhysicalKeyboardKey.keyR,
    ]) {
      await simulateKeyDownEvent(LogicalKeyboardKey.keyA, physicalKey: key);
      await simulateKeyUpEvent(LogicalKeyboardKey.keyA, physicalKey: key);
    }
    await simulateKeyDownEvent(LogicalKeyboardKey.enter);
    await simulateKeyUpEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(field.controller!.text, 'lm358dr');
    expect(find.text('No Component Selected'), findsOneWidget);

    // Turned back on, a scan searches and opens the part.
    prefs.update((p) => p.copyWith(searchOnScan: true));
    for (final key in [
      PhysicalKeyboardKey.keyL,
      PhysicalKeyboardKey.keyM,
      PhysicalKeyboardKey.digit3,
      PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.keyD,
      PhysicalKeyboardKey.keyR,
    ]) {
      await simulateKeyDownEvent(LogicalKeyboardKey.keyA, physicalKey: key);
      await simulateKeyUpEvent(LogicalKeyboardKey.keyA, physicalKey: key);
    }
    await simulateKeyDownEvent(LogicalKeyboardKey.enter);
    await simulateKeyUpEvent(LogicalKeyboardKey.enter);
    await settle();
    expect(find.text('B1'), findsWidgets);
    expect(find.text('In This List'), findsOneWidget);

    // Preferences are saved.
    expect(container.read(searchPrefsProvider).searchWhileTyping, isFalse);

    debugDefaultTargetPlatformOverride = null;
  });
}
