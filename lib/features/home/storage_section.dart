import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/settings.dart';
import '../../app/storage.dart';
import '../../app/theme.dart';
import '../../widgets/hud.dart';
import '../../widgets/icon_tile.dart';
import '../../widgets/section.dart';
import '../components/component_lists.dart';
import '../components/components_providers.dart';

/// Every open Hive box: settings plus each list's two boxes.
List<BoxBase<dynamic>> _boxes(ProviderContainer app) => [
  Hive.box<Object>(Boxes.settings),
  for (final l in app.read(listsProvider).lists) ...[
    Hive.box<Object>(Boxes.componentsMeta(l.id)),
    Hive.lazyBox<Map>(Boxes.components(l.id)),
  ],
];

/// Bytes the app's database uses on disk.
Future<int> databaseSize(ProviderContainer app) async {
  var total = 0;
  for (final box in _boxes(app)) {
    final path = box.path;
    if (path != null && await File(path).exists()) total += await File(path).length();
  }
  return total;
}

/// Frees space without removing data: compacts every box (Hive appends
/// changes and keeps old copies until compacted) and deletes the copies of
/// picked Excel files that the file picker keeps. Returns bytes freed.
Future<int> clearCache(ProviderContainer app) async {
  final before = await databaseSize(app);
  for (final box in _boxes(app)) {
    await box.compact();
  }
  try {
    await FilePicker.clearTemporaryFiles();
  } catch (_) {
    // Not every platform keeps temporary copies.
  }
  final after = await databaseSize(app);
  return before > after ? before - after : 0;
}

/// Deletes every list, all imported data and all settings, leaving the app
/// as it was when first installed.
///
/// The order matters: the app is first pointed at one empty starting list,
/// so no screen still reads a box when it gets deleted.
Future<void> deleteAllData(ProviderContainer app) async {
  const startId = Boxes.defaultListId;
  final others = [
    for (final l in app.read(listsProvider).lists)
      if (l.id != startId) l.id,
  ];

  // 1. An empty starting list (its boxes may be gone if it was deleted).
  if (!Hive.isBoxOpen(Boxes.components(startId))) await openListBoxes(startId);
  await app.read(listRepositoryProvider(startId)).clear();

  // 2. Settings back to defaults, keeping only the starting list.
  final settings = Hive.box<Object>(Boxes.settings);
  await settings.put(ListKeys.lists, [
    {'id': startId, 'name': 'Main List'},
  ]);
  await settings.deleteAll(settings.keys.where((k) => k != ListKeys.lists).toList());
  app.invalidate(listsProvider);
  app.invalidate(listRepositoryProvider(startId));
  app.invalidate(appearanceProvider);
  app.invalidate(searchPrefsProvider);
  app.read(searchQueryProvider.notifier).set('');
  app.read(scannedLabelProvider.notifier).set(null);

  // 3. Now nothing shows the other lists; delete them.
  for (final id in others) {
    await deleteListBoxes(id);
    app.invalidate(listRepositoryProvider(id));
  }
  try {
    await FilePicker.clearTemporaryFiles();
  } catch (_) {}
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Settings › Storage: space used, Clear Cache, Delete All Data.
class StorageSection extends ConsumerStatefulWidget {
  const StorageSection({super.key});

  @override
  ConsumerState<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<StorageSection> {
  int? _size;
  bool _busy = false;

  ProviderContainer get _app => ProviderScope.containerOf(context, listen: false);

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final size = await databaseSize(_app);
    if (mounted) setState(() => _size = size);
  }

  Future<void> _clearCache() async {
    setState(() => _busy = true);
    final freed = await clearCache(_app);
    await _measure();
    if (!mounted) return;
    setState(() => _busy = false);
    HapticFeedback.mediumImpact();
    showHud(
      context,
      icon: CupertinoIcons.checkmark_circle,
      message: freed > 0 ? 'Freed ${formatBytes(freed)}' : 'Cache Cleared',
    );
  }

  Future<void> _deleteAll() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('Delete All Data?'),
        content: const Text(
          'All lists, imported components and settings will be removed from this device. This can’t be undone.',
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await deleteAllData(_app);
    await _measure();
    if (!mounted) return;
    setState(() => _busy = false);
    HapticFeedback.heavyImpact();
    showHud(context, icon: CupertinoIcons.trash, message: 'All Data Deleted');
  }

  @override
  Widget build(BuildContext context) {
    final lists = ref.watch(listsProvider).lists.length;
    ref.watch(catalogProvider); // re-measure after imports
    final red = context.resolve(CupertinoColors.systemRed);
    final blue = context.resolve(CupertinoColors.systemBlue);

    return Section(
      header: 'Storage',
      footer:
          'Clear Cache frees space and removes temporary files; your lists stay. '
          'Delete All Data returns the app to how it was when first installed.',
      children: [
        CupertinoListTile(
          leading: const IconTile(icon: CupertinoIcons.archivebox_fill, color: CupertinoColors.systemGrey),
          title: const Text('Data on This Device'),
          additionalInfo: Text(
            _size == null ? '…' : '${formatBytes(_size!)} · $lists ${lists == 1 ? 'list' : 'lists'}',
          ),
        ),
        CupertinoListTile(
          leading: const IconTile(icon: CupertinoIcons.sparkles, color: CupertinoColors.systemBlue),
          title: Text('Clear Cache', style: TextStyle(color: blue)),
          trailing: _busy ? const CupertinoActivityIndicator() : null,
          onTap: _busy ? null : _clearCache,
        ),
        CupertinoListTile(
          leading: const IconTile(icon: CupertinoIcons.trash_fill, color: CupertinoColors.systemRed),
          title: Text('Delete All Data', style: TextStyle(color: red)),
          onTap: _busy ? null : _deleteAll,
        ),
      ],
    );
  }
}
