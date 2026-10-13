import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/main.dart';

void main() {
  testWidgets('Settings shows Storage, and Delete All Data asks first', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await initStorage(path: (await Directory.systemTemp.createTemp('storage_ui')).path);
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.runAsync(
      () => container
          .read(catalogProvider.notifier)
          .import(
            headers: ['MPN'],
            rows: [
              ['LM358DR'],
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
    await tester.tap(find.text('Settings'));
    await settle();
    await tester.scrollUntilVisible(find.text('Delete All Data'), 200, scrollable: find.byType(Scrollable).last);
    await settle();
    expect(find.text('Data on This Device'), findsOneWidget);
    expect(find.text('Clear Cache'), findsOneWidget);

    await tester.tap(find.text('Delete All Data'));
    await settle();
    expect(find.text('Delete All Data?'), findsOneWidget);
    await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
    await settle();
    expect(container.read(catalogProvider).count, 1); // nothing deleted

    debugDefaultTargetPlatformOverride = null;
  });
}
