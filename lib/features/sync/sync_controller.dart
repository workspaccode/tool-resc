import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';
import '../components/component_lists.dart';
import '../components/components_repository.dart';
import '../components/label_parser.dart';
import 'sync_api.dart';
import 'sync_prefs.dart';

/// How a scanned code reached the app.
enum ScanSource { camera, scanner, typed }

class SyncStatus {
  const SyncStatus({this.pending = 0, this.syncing = false, this.lastError, this.lastSyncedAt});

  /// Imports and scans waiting to be sent.
  final int pending;
  final bool syncing;

  /// Why the last attempt failed; cleared by the next success.
  final String? lastError;
  final DateTime? lastSyncedAt;
}

/// Optional server sync. When on, every import and every scan is put in a
/// queue on the device and sent in order, so nothing is lost offline; when
/// off, nothing is recorded or sent.
class SyncController extends Notifier<SyncStatus> {
  static const _scanBatch = 500;

  Box<Map> get _queue => Hive.box<Map>(Boxes.syncQueue);
  SyncPrefs get _prefs => ref.read(syncPrefsProvider);

  bool _flushing = false;
  Timer? _retry;
  int _failures = 0;

  @override
  SyncStatus build() {
    ref.onDispose(() => _retry?.cancel());
    ref.listen(syncPrefsProvider, (prev, next) {
      if (next.isReady &&
          (prev == null || !prev.isReady || prev.serverUrl != next.serverUrl || prev.apiKey != next.apiKey)) {
        _failures = 0;
        unawaited(flush());
      }
    });
    if (_prefs.isReady && _queue.isNotEmpty) Future.microtask(flush);
    return SyncStatus(pending: _queue.length);
  }

  /// Records a scan, checked against [list] ([found]: it is in the list).
  void recordScan(ScannedLabel label, {required ComponentList list, required ScanSource source, required bool found}) {
    final prefs = _prefs;
    if (!prefs.enabled || mpnKey(label.mpn).isEmpty) return;
    _enqueue('scan', {
      'id': newSyncId(),
      'projectId': list.id,
      'projectName': list.name,
      'deviceId': prefs.deviceId,
      'deviceName': prefs.deviceName,
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

  /// Records an import into [list], with the rows as they were in the file.
  void recordImport({
    required ComponentList list,
    required List<String> headers,
    required List<List<String>> rows,
    required int mpnIndex,
    required ImportMode mode,
  }) {
    final prefs = _prefs;
    if (!prefs.enabled) return;
    _enqueue('import', {
      'eventId': newSyncId(),
      'projectId': list.id,
      'name': list.name,
      'deviceId': prefs.deviceId,
      'mode': mode.name,
      'headers': headers,
      'rows': rows,
      'mpnIndex': mpnIndex,
    });
  }

  /// Sends every list as it is now (replacing what the server has), so
  /// scans can be checked and counted against them. Returns how many lists
  /// were queued.
  Future<int> uploadAllLists() async {
    if (!_prefs.enabled) return 0;
    var queued = 0;
    for (final list in ref.read(listsProvider).lists) {
      final table = await ref.read(listRepositoryProvider(list.id)).exportTable();
      if (table == null) continue;
      recordImport(
        list: list,
        headers: table.headers,
        rows: table.rows,
        mpnIndex: table.mpnIndex,
        mode: ImportMode.replace,
      );
      queued++;
    }
    return queued;
  }

  /// Checks the server can be reached with the current settings.
  Future<void> testConnection() => ref.read(syncApiProvider).health(_prefs);

  /// Sends the queue, oldest first. Stops at the first failure and retries
  /// later with backoff; events the server rejects as invalid are dropped
  /// so they can't block the queue.
  Future<void> flush() async {
    if (_flushing || !_prefs.isReady || _queue.isEmpty) {
      if (!_flushing) state = _status();
      return;
    }
    _flushing = true;
    _retry?.cancel();
    state = _status(syncing: true, lastError: state.lastError);
    String? dropped;
    try {
      while (_prefs.isReady && _queue.isNotEmpty) {
        final keys = _nextBatch();
        try {
          await _send(keys);
        } on SyncHttpException catch (e) {
          if (!e.isPermanent) rethrow;
          dropped = '$e';
        }
        await _queue.deleteAll(keys);
        if (!ref.mounted) return;
        state = _status(syncing: true, lastError: dropped);
      }
      _failures = 0;
      state = _status(lastError: dropped, lastSyncedAt: DateTime.now());
    } catch (e) {
      if (!ref.mounted) return;
      _failures++;
      state = _status(lastError: _describe(e), lastSyncedAt: state.lastSyncedAt);
      // 15 s, 30 s, 1 min ... up to 10 min.
      final delay = Duration(seconds: min(600, 15 * (1 << min(_failures - 1, 6))));
      _retry = Timer(delay, () => unawaited(flush()));
    } finally {
      _flushing = false;
    }
  }

  /// Deletes everything waiting to be sent.
  Future<void> clearQueue() async {
    await _queue.clear();
    state = _status();
  }

  /// One import, or up to [_scanBatch] scans in a row.
  List<int> _nextBatch() {
    final keys = _queue.keys.cast<int>().toList();
    if (_queue.get(keys.first)!['type'] != 'scan') return [keys.first];
    return [for (final k in keys.take(_scanBatch).takeWhile((k) => _queue.get(k)!['type'] == 'scan')) k];
  }

  Future<void> _send(List<int> keys) {
    final api = ref.read(syncApiProvider);
    final events = [for (final k in keys) _queue.get(k)!];
    if (events.first['type'] == 'import') {
      final body = events.first['body'] as Map;
      return api.postImport(_prefs, body['projectId'] as String, body);
    }
    return api.postScans(_prefs, [for (final e in events) e['body'] as Map]);
  }

  void _enqueue(String type, Map<String, Object?> body) {
    _queue.add({'type': type, 'body': body}).then((_) {
      if (!ref.mounted) return;
      state = _status(syncing: _flushing, lastError: state.lastError, lastSyncedAt: state.lastSyncedAt);
      unawaited(flush());
    });
  }

  SyncStatus _status({bool syncing = false, String? lastError, DateTime? lastSyncedAt}) => SyncStatus(
    pending: _queue.length,
    syncing: syncing,
    lastError: lastError,
    lastSyncedAt: lastSyncedAt ?? state.lastSyncedAt,
  );

  static String _describe(Object e) => switch (e) {
    SyncHttpException() => '$e',
    TimeoutException() => 'The server didn’t answer in time',
    _ => 'Can’t reach the server',
  };
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);
