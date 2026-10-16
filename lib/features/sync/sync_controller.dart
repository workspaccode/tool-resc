import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import '../components/component_lists.dart';
import '../components/components_providers.dart';
import '../components/components_repository.dart';
import '../components/label_parser.dart';
import 'projects_controller.dart';
import 'sync_api.dart';
import 'sync_prefs.dart';

/// How a scanned code reached the app.
enum ScanSource { camera, scanner, typed }

class SyncStatus {
  const SyncStatus({this.pending = 0, this.syncing = false, this.lastError, this.lastSyncedAt});

  /// Changes and scans waiting to be sent.
  final int pending;
  final bool syncing;

  /// Why the last attempt failed; cleared by the next success.
  final String? lastError;
  final DateTime? lastSyncedAt;
}

/// Optional server sync for lists shared in projects. Changes to shared
/// lists (imports, renames, deletes) and scans made in them go into a queue
/// on the device and are sent in order, so nothing is lost offline. Then
/// every project's lists are downloaded when another device changed them.
/// Lists that aren't in a project never leave the device; when sync is off,
/// nothing is recorded or sent.
class SyncController extends Notifier<SyncStatus> {
  static const _scanBatch = 500;
  static const _pullEvery = Duration(minutes: 2);

  Box<Map> get _queue => Hive.box<Map>(Boxes.syncQueue);
  SyncPrefs get _prefs => ref.read(syncPrefsProvider);
  SyncApi get _api => ref.read(syncApiProvider);
  ListsNotifier get _lists => ref.read(listsProvider.notifier);

  bool _running = false;
  bool _registered = false;
  Timer? _retry;
  Timer? _periodic;
  int _failures = 0;

  @override
  SyncStatus build() {
    ref.onDispose(() {
      _retry?.cancel();
      _periodic?.cancel();
    });
    ref.listen(syncPrefsProvider, (prev, next) {
      final changed =
          prev == null ||
          !prev.isReady ||
          prev.serverUrl != next.serverUrl ||
          prev.apiKey != next.apiKey ||
          prev.deviceName != next.deviceName;
      if (next.isReady && changed) {
        _failures = 0;
        _registered = false;
        unawaited(syncNow());
      }
      _schedule(next.isReady);
    });
    _schedule(_prefs.isReady);
    if (_prefs.isReady) Future.microtask(syncNow);
    return SyncStatus(pending: _queue.length);
  }

  // --- recording (called by the screens) ---

  /// Records a scan made while [list] was open; only lists in a project.
  void recordScan(ScannedLabel label, {required ComponentList list, required ScanSource source, required bool found}) {
    if (!_prefs.enabled || !list.isShared || mpnKey(label.mpn).isEmpty) return;
    _enqueue('scan', {
      'id': newSyncId(),
      'projectId': list.projectId,
      'listId': list.remoteId,
      'listName': list.name,
      'deviceName': _prefs.deviceName,
      'source': source.name,
      'raw': label.raw,
      'mpn': label.mpn,
      'supplierPart': ?label.supplierPart,
      'orderNumber': ?label.orderNumber,
      'quantity': ?label.quantity,
      'found': found,
      'scannedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Records an import into a shared list, with the rows as in the file.
  void recordImport({
    required ComponentList list,
    required List<String> headers,
    required List<List<String>> rows,
    required int mpnIndex,
    required ImportMode mode,
  }) {
    if (!_prefs.enabled || !list.isShared) return;
    _enqueue('import', {
      'eventId': newSyncId(),
      'projectId': list.projectId,
      'listId': list.remoteId,
      'name': list.name,
      'mode': mode.name,
      'headers': headers,
      'rows': rows,
      'mpnIndex': mpnIndex,
    });
  }

  void recordRename(ComponentList list, String name) {
    if (!_prefs.enabled || !list.isShared) return;
    _enqueue('rename', {'eventId': newSyncId(), 'projectId': list.projectId, 'listId': list.remoteId, 'name': name});
  }

  /// Removes a shared list from its project, for every member.
  void recordDelete(ComponentList list) {
    if (!_prefs.enabled || !list.isShared) return;
    _enqueue('delete', {'eventId': newSyncId(), 'projectId': list.projectId, 'listId': list.remoteId});
  }

  /// Shares a local list in a project and uploads its rows.
  Future<void> shareList(String listId, String projectId) async {
    _lists.share(listId, projectId);
    final list = ref.read(listsProvider).lists.firstWhere((l) => l.id == listId);
    final table = await ref.read(listRepositoryProvider(listId)).exportTable();
    if (table == null) return;
    recordImport(
      list: list,
      headers: table.headers,
      rows: table.rows,
      mpnIndex: table.mpnIndex,
      mode: ImportMode.replace,
    );
  }

  /// Checks the server can be reached with the current settings.
  Future<void> testConnection() => _api.health(_prefs);

  // --- syncing ---

  /// Sends the queue, then downloads what other devices changed. Stops at
  /// the first failure and retries later with backoff; changes the server
  /// rejects as invalid are dropped so they can't block the queue.
  Future<void> syncNow() async {
    if (_running || !_prefs.isReady) {
      if (!_running && ref.mounted) state = _status(lastError: state.lastError);
      return;
    }
    _running = true;
    _retry?.cancel();
    state = _status(syncing: true, lastError: state.lastError);
    String? dropped;
    try {
      if (!_registered) {
        await _api.registerDevice(_prefs);
        _registered = true;
      }
      dropped = await _flush();
      if (!ref.mounted) return;
      if (_queue.isEmpty) await _pull();
      if (!ref.mounted) return;
      _failures = 0;
      state = _status(lastError: dropped, lastSyncedAt: DateTime.now());
    } catch (e) {
      if (!ref.mounted) return;
      _failures++;
      state = _status(lastError: _describe(e));
      // 15 s, 30 s, 1 min ... up to 10 min.
      final delay = Duration(seconds: min(600, 15 * (1 << min(_failures - 1, 6))));
      _retry = Timer(delay, () => unawaited(syncNow()));
    } finally {
      _running = false;
    }
    // Something was queued while downloading.
    if (ref.mounted && _queue.isNotEmpty && state.lastError == null) unawaited(syncNow());
  }

  /// Deletes everything waiting to be sent.
  Future<void> clearQueue() async {
    await _queue.clear();
    state = _status();
  }

  Future<String?> _flush() async {
    String? dropped;
    while (_prefs.isReady && _queue.isNotEmpty) {
      final keys = _nextBatch();
      try {
        await _send(keys);
      } on SyncHttpException catch (e) {
        if (!e.isPermanent) rethrow;
        dropped = '$e';
      }
      await _queue.deleteAll(keys);
      if (!ref.mounted) return dropped;
      state = _status(syncing: true, lastError: dropped);
    }
    return dropped;
  }

  /// One change, or up to [_scanBatch] scans in a row.
  List<int> _nextBatch() {
    final keys = _queue.keys.cast<int>().toList();
    if (_queue.get(keys.first)!['type'] != 'scan') return [keys.first];
    return [for (final k in keys.take(_scanBatch).takeWhile((k) => _queue.get(k)!['type'] == 'scan')) k];
  }

  Future<void> _send(List<int> keys) async {
    final events = [for (final k in keys) _queue.get(k)!];
    final body = events.first['body'] as Map;
    switch (events.first['type']) {
      case 'import':
        final version = await _api.postImport(_prefs, body);
        // This device already has that data; don't download it again.
        final local = ref.read(listsProvider).lists.where((l) => l.remoteId == body['listId']).firstOrNull;
        if (local != null && version > (local.remoteVersion ?? 0)) _lists.setRemoteVersion(local.id, version);
      case 'rename':
        try {
          await _api.renameList(_prefs, body);
        } on SyncHttpException catch (e) {
          if (e.status != 404) rethrow; // renamed before it was uploaded, or deleted
        }
      case 'delete':
        await _api.deleteList(_prefs, body);
      default:
        await _api.postScans(_prefs, [for (final e in events) e['body'] as Map]);
    }
  }

  /// Brings every project's lists up to date on this device: new lists are
  /// added, changed ones downloaded, renamed ones renamed, and lists removed
  /// from the project deleted here too.
  Future<void> _pull() async {
    final projects = ref.read(projectsProvider.notifier);
    await projects.refresh();
    var activeChanged = false;
    for (final project in ref.read(projectsProvider)) {
      final remote = await _api.lists(_prefs, project.id);
      if (!ref.mounted) return;
      final remoteIds = {for (final r in remote) r.id};
      for (final r in remote) {
        var local = ref.read(listsProvider).lists.where((l) => l.remoteId == r.id).firstOrNull;
        if (local != null && local.name != r.name) _lists.rename(local.id, r.name);
        if (local != null && r.version <= (local.remoteVersion ?? 0)) continue;

        final table = await _api.table(_prefs, project.id, r.id);
        if (!ref.mounted) return;
        final id = local?.id ?? await _lists.addShared(name: r.name, projectId: project.id, remoteId: r.id);
        await ref
            .read(listRepositoryProvider(id))
            .import(headers: table.headers, rows: table.rows, mpnIndex: table.mpnIndex, mode: ImportMode.replace);
        _lists.setRemoteVersion(id, table.list.version);
        activeChanged |= id == ref.read(listsProvider).activeId;
      }
      // Removed from the project by another device (only lists this device
      // had confirmed; a list not uploaded yet is still on its way).
      for (final l in ref.read(listsProvider).lists.toList()) {
        if (l.projectId == project.id && l.remoteVersion != null && !remoteIds.contains(l.remoteId)) {
          activeChanged |= l.id == ref.read(listsProvider).activeId;
          await _lists.delete(l.id);
        }
      }
    }
    if (activeChanged) ref.invalidate(catalogProvider);
  }

  void _schedule(bool ready) {
    _periodic?.cancel();
    _periodic = ready ? Timer.periodic(_pullEvery, (_) => unawaited(syncNow())) : null;
  }

  void _enqueue(String type, Map<String, Object?> body) {
    _queue.add({'type': type, 'body': body}).then((_) {
      if (!ref.mounted) return;
      state = _status(syncing: _running, lastError: state.lastError);
      unawaited(syncNow());
    });
  }

  SyncStatus _status({bool syncing = false, String? lastError, DateTime? lastSyncedAt}) => SyncStatus(
    pending: _queue.length,
    syncing: syncing,
    lastError: lastError,
    lastSyncedAt: lastSyncedAt ?? stateOrNull?.lastSyncedAt,
  );

  static String _describe(Object e) => switch (e) {
    SyncHttpException() => '$e',
    TimeoutException() => 'The server didn’t answer in time',
    _ => 'Can’t reach the server',
  };
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
