import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart' show DefaultMaterialLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/modbus/modbus_controller.dart';
import 'package:tool_resc/features/modbus/ui/modbus_screen.dart';

/// Pumps through sheet/tab animations (a focused text field's cursor
/// blinks forever, so pumpAndSettle would never return).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  testWidgets('setup, library → poll, registers and cloud share', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await initStorage(path: (await Directory.systemTemp.createTemp('modbus_ui')).path);
    });
    final app = ProviderContainer();
    addTearDown(app.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: app,
        child: const CupertinoApp(
          localizationsDelegates: [DefaultMaterialLocalizations.delegate, DefaultCupertinoLocalizations.delegate],
          home: ModbusScreen(),
        ),
      ),
    );
    expect(find.text('Modbus Poll'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('IP Address'), findsOneWidget);

    // Serial settings appear for RTU.
    await tester.tap(find.text('Serial RTU'));
    await settle(tester);
    expect(find.text('Baud Rate'), findsOneWidget);
    expect(app.read(modbusProvider).config.kind.name, 'rtu');

    // Add a register from the library.
    await tester.tap(find.text('Library'));
    await settle(tester);
    await tester.enterText(find.byType(CupertinoSearchTextField), '5030');
    await settle(tester);
    await tester.tap(find.text('Real-Time Power'));
    await settle(tester);
    await tester.tap(find.text('OK'));
    await settle(tester);
    expect(app.read(modbusProvider).polls.single.def.address, 5030);

    await tester.tap(find.text('Registers'));
    await settle(tester);
    expect(find.text('5030'), findsOneWidget);

    // Cloud Share settings live under Setup.
    await tester.tap(find.text('Setup'));
    await settle(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    for (var i = 0; i < 6 && find.text('Upload Live').evaluate().isEmpty; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await settle(tester);
    }
    expect(find.text('Cloud Share'.toUpperCase()), findsOneWidget);
    expect(find.text('○ Off'), findsOneWidget);
  });
}
