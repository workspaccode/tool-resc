import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/component_lists.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';

void main() {
  late Directory dir;
  late ProviderContainer container;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lists_test');
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<ImportResult> importRows(List<List<String>> rows) => container
      .read(catalogProvider.notifier)
      .import(headers: ['MPN', 'Location'], rows: rows, mpnIndex: 0, mode: ImportMode.replace);

  test('each import can be its own list; switching changes what is searched', () async {
    await initStorage(path: dir.path);
    container = ProviderContainer();
    final lists = container.read(listsProvider.notifier);

    // First import goes into the starting list.
    expect(container.read(listsProvider).lists.single.name, 'Main List');
    await importRows([
      ['RC0805FR-07820KL', 'A1'],
    ]);

    // A second import as a new list becomes active.
    final bomId = await lists.create('BOM F280033');
    await importRows([
      ['LM358DR', 'B1'],
      ['LM358DR', 'B2'],
    ]);
    expect(container.read(listsProvider).active.name, 'BOM F280033');
    expect(container.read(catalogProvider).count, 2);
    expect((await container.read(searchResultsProvider.future)).total, 0); // empty query

    // The current list doesn't have the resistor; another list does.
    expect(container.read(componentsRepositoryProvider).matchKey('RC0805FR-07820KL'), isNull);
    expect(lists.othersContaining('RC0805FR-07820KL').map((l) => l.name), ['Main List']);

    // Switching lists changes the catalog and search.
    final mainId = container.read(listsProvider).lists.first.id;
    lists.select(mainId);
    expect(container.read(catalogProvider).count, 1);
    container.read(searchQueryProvider.notifier).set('rc0805');
    expect((await container.read(searchResultsProvider.future)).items.single.values['Location'], 'A1');

    // Names stay unique; rename works.
    final dupId = await lists.create('BOM F280033');
    expect(container.read(listsProvider).active.name, 'BOM F280033 2');
    lists.rename(dupId, 'Customer K');
    expect(container.read(listsProvider).active.name, 'Customer K');

    // Deleting the active list removes its data and selects another.
    await lists.delete(dupId);
    expect(container.read(listsProvider).lists.map((l) => l.id), [mainId, bomId]);
    expect(Hive.isBoxOpen(Boxes.components(dupId)), isFalse);

    // The registry and data survive a restart.
    container.dispose();
    await Hive.close();
    await initStorage(path: dir.path);
    container = ProviderContainer();
    expect(container.read(listsProvider).lists.map((l) => l.name), ['Main List', 'BOM F280033']);
    container.read(listsProvider.notifier).select(bomId);
    expect(container.read(catalogProvider).count, 2);
  });

  test('deleting the only list clears it instead', () async {
    await initStorage(path: dir.path);
    container = ProviderContainer();
    await importRows([
      ['X1', 'A'],
    ]);
    await container.read(listsProvider.notifier).delete(container.read(listsProvider).activeId);
    expect(container.read(listsProvider).lists, hasLength(1));
    expect(container.read(catalogProvider).isEmpty, isTrue);
  });

  test('data imported before lists existed becomes the first list', () async {
    // Old layout: rows in the original box names, no list registry.
    Hive.init(dir.path);
    final meta = await Hive.openBox<Object>('components_meta');
    final items = await Hive.openLazyBox<Map>('components');
    await ComponentsRepository(meta: meta, items: items).import(
      headers: ['MPN'],
      rows: [
        ['OLD-PART-1'],
      ],
      mpnIndex: 0,
      mode: ImportMode.replace,
    );
    await Hive.close();

    await initStorage(path: dir.path);
    container = ProviderContainer();
    expect(container.read(listsProvider).lists.single.name, 'Main List');
    expect(container.read(catalogProvider).count, 1);
  });
}
