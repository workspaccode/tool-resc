import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:tool_resc/app/settings.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/component_lists.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/features/home/storage_section.dart';

void main() {
  test('clear cache frees space and keeps data; delete all resets the app', () async {
    final dir = await Directory.systemTemp.createTemp('storage_test');
    await initStorage(path: dir.path);
    final app = ProviderContainer();
    addTearDown(() async {
      app.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    // Two lists, each imported then merged again: updated rows leave old
    // copies in the file until compacted.
    Future<void> importTwice(List<List<String>> rows) async {
      for (final mode in [ImportMode.replace, ImportMode.merge]) {
        await app.read(catalogProvider.notifier).import(headers: ['MPN', 'Bin'], rows: rows, mpnIndex: 0, mode: mode);
      }
    }

    await importTwice([
      for (var i = 0; i < 300; i++) ['PART-$i', 'A$i'],
    ]);
    final bomId = await app.read(listsProvider.notifier).create('BOM');
    await importTwice([
      ['LM358DR', 'B1'],
    ]);
    app.read(appearanceProvider.notifier).set(Appearance.dark);
    app.read(searchPrefsProvider.notifier).update((p) => p.copyWith(searchOnScan: false));

    // Clear cache: smaller files, same data and settings.
    await Hive.box<Object>(Boxes.settings).flush(); // settings writes aren't awaited
    final before = await databaseSize(app);
    final freed = await clearCache(app);
    // Hive also compacts on its own, so there may be little left to free.
    expect(freed, greaterThanOrEqualTo(0));
    expect(await databaseSize(app), lessThanOrEqualTo(before));
    expect(app.read(listsProvider).lists, hasLength(2));
    expect(app.read(listRepositoryProvider(Boxes.defaultListId)).count, 300);
    expect(app.read(catalogProvider).count, 1);
    expect(app.read(searchPrefsProvider).searchOnScan, isFalse);

    // Delete all: back to a fresh install.
    final bomFile = Hive.lazyBox<Map>(Boxes.components(bomId)).path!;
    await deleteAllData(app);
    expect(app.read(listsProvider).lists.single.name, 'Main List');
    expect(app.read(catalogProvider).isEmpty, isTrue);
    expect(app.read(appearanceProvider), Appearance.system);
    expect(app.read(searchPrefsProvider).searchOnScan, isTrue);
    expect(Hive.isBoxOpen(Boxes.components(bomId)), isFalse);
    expect(File(bomFile).existsSync(), isFalse);

    // The app keeps working, and the reset survives a restart.
    await app
        .read(catalogProvider.notifier)
        .import(
          headers: ['MPN'],
          rows: [
            ['NEW1'],
          ],
          mpnIndex: 0,
          mode: ImportMode.replace,
        );
    await Hive.close();
    await initStorage(path: dir.path);
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(restarted.read(listsProvider).lists.single.name, 'Main List');
    expect(restarted.read(catalogProvider).count, 1);
  });

  test('delete all works even after the starting list was deleted', () async {
    final dir = await Directory.systemTemp.createTemp('storage_test2');
    await initStorage(path: dir.path);
    final app = ProviderContainer();
    addTearDown(() async {
      app.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    await app.read(listsProvider.notifier).create('Other');
    await app.read(listsProvider.notifier).delete(Boxes.defaultListId); // its boxes are gone
    await deleteAllData(app);
    expect(app.read(listsProvider).lists.single.id, Boxes.defaultListId);
    expect(app.read(catalogProvider).isEmpty, isTrue);
  });
}
