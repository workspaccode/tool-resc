import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'platform.dart';

/// Hive box names.
abstract final class Boxes {
  /// App settings, plus the registry of component lists.
  static const settings = 'settings';

  /// Each component list has two boxes. The first list keeps the original
  /// names so data imported before lists existed carries over.
  ///
  /// Meta: field definitions (imported Excel headers).
  static String componentsMeta(String listId) =>
      listId == defaultListId ? 'components_meta' : 'components_meta_$listId';

  /// Items: one entry per imported row, keyed `<mpnKey>~<n>`; values are
  /// `Map<String, String>` of field label -> cell value. Lazy so only keys
  /// stay in memory.
  static String components(String listId) => listId == defaultListId ? 'components' : 'components_$listId';

  static const defaultListId = 'default';
}

/// Keys in the settings box for the list registry.
abstract final class ListKeys {
  /// `List<Map>` of `{id, name}`, in display order.
  static const lists = 'lists';
  static const active = 'activeList';
}

/// Opens the settings and every list's boxes. [path] overrides the storage
/// folder (tests).
Future<void> initStorage({String? path}) async {
  if (path != null) {
    Hive.init(path);
  } else if (isDesktop) {
    // App support folder, not the user's Documents folder.
    Hive.init((await getApplicationSupportDirectory()).path);
  } else {
    await Hive.initFlutter();
  }
  final settings = await Hive.openBox<Object>(Boxes.settings);
  if (settings.get(ListKeys.lists) == null) {
    await settings.put(ListKeys.lists, [
      {'id': Boxes.defaultListId, 'name': 'Main List'},
    ]);
  }
  final lists = (settings.get(ListKeys.lists)! as List).cast<Map>();
  await Future.wait([for (final l in lists) openListBoxes(l['id'] as String)]);
}

Future<void> openListBoxes(String listId) =>
    Future.wait([Hive.openBox<Object>(Boxes.componentsMeta(listId)), Hive.openLazyBox<Map>(Boxes.components(listId))]);

/// Closes and deletes a list's boxes from disk.
Future<void> deleteListBoxes(String listId) async {
  await Hive.box<Object>(Boxes.componentsMeta(listId)).deleteFromDisk();
  await Hive.lazyBox<Map>(Boxes.components(listId)).deleteFromDisk();
}
