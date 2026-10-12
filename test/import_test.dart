import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/features/components/excel_reader.dart';

void main() {
  late Directory dir;
  late ComponentsRepository repo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hive_test');
    Hive.init(dir.path);
    repo = ComponentsRepository(meta: await Hive.openBox<Object>('meta'), items: await Hive.openLazyBox<Map>('items'));
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('imports Excel columns as fields and searches by MPN', () async {
    final tables = await readExcel(File('test/fixtures/sample_lcsc.xlsx').readAsBytesSync());
    final table = tables.single;
    expect(table.headers.first, 'LCSC Part Number');
    expect(table.rows, hasLength(4));
    expect(table.guessMpnColumn(), 1);

    final result = await repo.import(
      headers: table.headers,
      rows: table.rows,
      mpnIndex: table.guessMpnColumn(),
      mode: ImportMode.replace,
    );
    expect(result.inserted, 3);
    expect(result.skipped, 1);
    expect(repo.count, 3);
    expect(repo.fields, table.headers);
    expect(repo.mpnField, 'Manufacture Part Number');

    final hit = await repo.search('rc0805fr07820kl');
    expect(hit.total, 1);
    expect(hit.items.single.mpn, 'RC0805FR-07820KL');
    expect(hit.items.single.values['LCSC Part Number'], 'C141700');
    expect(hit.items.single.values['Quantity'], '100');

    // Exact match ranks before longer matches.
    final partial = await repo.search('0805');
    expect(partial.total, 2);
    expect(partial.items.first.mpn, '0805W8F1002T5E'); // prefix match first

    // Merge: same MPN updates, a new field is appended, other fields kept.
    final merged = await repo.import(
      headers: ['manufacture part number', 'Quantity', 'Location'],
      rows: [
        ['RC0805FR-07820KL', '250', 'Drawer A3'],
        ['NEW-PART-1', '5', 'Drawer B1'],
        ['new part 1', '6', 'Drawer B2'],
      ],
      mpnIndex: 0,
      mode: ImportMode.merge,
    );
    expect((merged.inserted, merged.updated, merged.duplicates), (1, 1, 1));
    expect(repo.count, 4);
    expect(repo.fields.last, 'Location');
    final updated = (await repo.search('RC0805FR-07820KL')).items.single;
    expect(updated.values['Quantity'], '250');
    expect(updated.values['Location'], 'Drawer A3');
    expect(updated.values['Manufacturer'], 'YAGEO');
    expect((await repo.search('NEWPART1')).items.single.values['Quantity'], '6');

    // Replace wipes old fields and rows.
    await repo.import(
      headers: ['MPN'],
      rows: [
        ['X1'],
      ],
      mpnIndex: 0,
      mode: ImportMode.replace,
    );
    expect(repo.count, 1);
    expect(repo.fields, ['MPN']);
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
