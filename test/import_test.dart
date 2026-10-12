import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tool_resc/features/components/components_db.dart';
import 'package:tool_resc/features/components/excel_reader.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('imports Excel columns as fields and searches by MPN', () async {
    final tables = await readExcel(File('test/fixtures/sample_lcsc.xlsx').readAsBytesSync());
    expect(tables, hasLength(1));
    final table = tables.single;
    expect(table.headers.first, 'LCSC Part Number');
    expect(table.rows, hasLength(4));
    expect(table.guessMpnColumn(), 1);

    final db = await ComponentsDb.open();
    await db.clear();
    final result = await db.import(
      headers: table.headers,
      rows: table.rows,
      mpnIndex: table.guessMpnColumn(),
      mode: ImportMode.replace,
    );
    expect(result.inserted, 3);
    expect(result.skipped, 1);

    final fields = await db.fields();
    expect(fields.map((f) => f.label), table.headers);
    expect(fields.singleWhere((f) => f.isMpn).label, 'Manufacture Part Number');

    final hit = await db.search('rc0805fr07820kl');
    expect(hit.single.values['LCSC Part Number'], 'C141700');
    expect(hit.single.values['Quantity'], '100');
    expect(await db.search('0805'), hasLength(2));

    // Merge: same MPN updates, a new column is added.
    final merged = await db.import(
      headers: ['Manufacture Part Number', 'Quantity', 'Location'],
      rows: [
        ['RC0805FR-07820KL', '250', 'Drawer A3'],
        ['NEW-PART-1', '5', 'Drawer B1'],
      ],
      mpnIndex: 0,
      mode: ImportMode.merge,
    );
    expect(merged.updated, 1);
    expect(merged.inserted, 1);
    expect(await db.count(), 4);
    final updated = (await db.search('RC0805FR-07820KL')).single;
    expect(updated.values['Quantity'], '250');
    expect(updated.values['Location'], 'Drawer A3');
    expect(updated.values['Manufacturer'], 'YAGEO');
  });

  test('reads shared strings, offset columns, dates and duplicate headers', () async {
    final tables = await readExcel(File('test/fixtures/sample_mixed.xlsx').readAsBytesSync());
    final table = tables.single; // the empty sheet is skipped
    expect(table.sheetName, 'مخزون');
    expect(table.headers, ['MPN', 'الوصف', 'الموقع', 'Received', 'MPN (2)']);
    expect(table.rows, [
      ['RC0805FR-07820KL', 'مقاومة 820 كيلو', 'A3', '2026-09-23', 'dup'],
      ['LM358DR', '', 'B1', '2025-12-09', ''],
    ]);
    expect(table.guessMpnColumn(), 0);
  });
}
