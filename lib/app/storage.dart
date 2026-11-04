import 'dart:io';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:path/path.dart' as p;
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

  /// Optional server sync: imports and scans waiting to be sent, keyed by
  /// an auto-increment int so they're sent in order.
  static const syncQueue = 'sync_queue';
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
    final dir = (await getApplicationSupportDirectory()).path;
    if (Platform.isMacOS) migrateFromSandbox(dir);
    Hive.init(dir);
  } else {
    await Hive.initFlutter();
  }
  final settings = await Hive.openBox<Object>(Boxes.settings);
  await Hive.openBox<Map>(Boxes.syncQueue);
  if (settings.get(ListKeys.lists) == null) {
    await settings.put(ListKeys.lists, [
      {'id': Boxes.defaultListId, 'name': 'Main List'},
    ]);
  }
  final lists = (settings.get(ListKeys.lists)! as List).cast<Map>();
  await Future.wait([for (final l in lists) openListBoxes(l['id'] as String)]);
}

/// The macOS app ran in the App Sandbox until IPA Export needed to reach
/// iOS devices. Its data then lived in the sandbox container; copy it to
/// [dir] (`~/Library/Application Support/<bundle id>`) the first time the
/// app starts without the sandbox. The originals are left in place.
/// [home] overrides the home folder (tests).
void migrateFromSandbox(String dir, {String? home}) {
  final env = Platform.environment;
  if (env.containsKey('APP_SANDBOX_CONTAINER_ID')) return; // Still sandboxed.
  final target = Directory(dir);
  if (File(p.join(dir, '${Boxes.settings}.hive')).existsSync()) return;

  final bundleId = p.basename(dir);
  final homeDir = home ?? env['HOME'];
  if (homeDir == null) return;
  final old = Directory(
    p.join(homeDir, 'Library', 'Containers', bundleId, 'Data', 'Library', 'Application Support', bundleId),
  );
  if (!old.existsSync()) return;
  try {
    target.createSync(recursive: true);
    for (final f in old.listSync().whereType<File>()) {
      if (f.path.endsWith('.hive')) f.copySync(p.join(dir, p.basename(f.path)));
    }
  } on FileSystemException {
    // Start fresh rather than fail to launch.
  }
}

Future<void> openListBoxes(String listId) =>
    Future.wait([Hive.openBox<Object>(Boxes.componentsMeta(listId)), Hive.openLazyBox<Map>(Boxes.components(listId))]);

/// Closes and deletes a list's boxes from disk.
Future<void> deleteListBoxes(String listId) async {
  await Hive.box<Object>(Boxes.componentsMeta(listId)).deleteFromDisk();
  await Hive.lazyBox<Map>(Boxes.components(listId)).deleteFromDisk();
}
