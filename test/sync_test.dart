import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/components/component_lists.dart';
import 'package:tool_resc/features/components/components_providers.dart';
import 'package:tool_resc/features/components/components_repository.dart';
import 'package:tool_resc/features/components/label_parser.dart';
import 'package:tool_resc/features/sync/sync_api.dart';
import 'package:tool_resc/features/sync/sync_controller.dart';
import 'package:tool_resc/features/sync/sync_prefs.dart';

void main() {
  late ProviderContainer app;
  late List<http.Request> requests;
  var serverUp = true;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('sync_test');
    await initStorage(path: dir.path);
    requests = [];
    serverUp = true;
    final client = MockClient((request) async {
      requests.add(request);
      if (!serverUp) throw const SocketException('offline');
      return http.Response('{}', 200);
    });
    app = ProviderContainer(overrides: [syncApiProvider.overrideWithValue(SyncApi(client))]);
    addTearDown(() async {
      app.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
  });

  Future<void> importParts() => app
      .read(catalogProvider.notifier)
      .import(
        headers: ['MPN', 'Bin'],
        rows: [
          ['LM358DR', 'A1'],
          ['NE555', 'A2'],
        ],
        mpnIndex: 0,
        mode: ImportMode.replace,
      );

  void scan(String code) => app
      .read(syncProvider.notifier)
      .recordScan(
        ScannedLabel.parse(code),
        list: app.read(listsProvider).active,
        source: ScanSource.camera,
        found: true,
      );

  /// Waits until the queue is sent, or sending failed.
  Future<void> settle() async {
    for (var i = 0; i < 500; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final s = app.read(syncProvider);
      if (!s.syncing && (s.pending == 0 || s.lastError != null)) return;
    }
  }

  test('off by default: nothing is queued or sent', () async {
    expect(app.read(syncPrefsProvider).enabled, isFalse);
    scan('LM358DR');
    await settle();
    expect(app.read(syncProvider).pending, 0);
    expect(requests, isEmpty);
  });

  test('when on, lists and scans are sent in order; offline they wait', () async {
    await importParts();
    app.listen(syncProvider, (_, _) {}); // as the app does
    app.read(syncPrefsProvider.notifier).update((p) => p.copyWith(enabled: true, serverUrl: '10.0.0.5:8080'));
    expect(await app.read(syncProvider.notifier).uploadAllLists(), 1);
    scan('{pbn:P1,on:WM1,pc:C7950,pm:LM358DR,qty:100}');
    scan('NE555');
    await settle();

    expect(requests.map((r) => '${r.method} ${r.url}'), [
      'POST http://10.0.0.5:8080/v1/projects/default/imports',
      'POST http://10.0.0.5:8080/v1/scans',
    ]);
    final imp = jsonDecode(requests[0].body) as Map;
    expect(imp['mode'], 'replace');
    expect(imp['headers'], ['MPN', 'Bin']);
    expect((imp['rows'] as List), hasLength(2));
    final scans = (jsonDecode(requests[1].body) as Map)['scans'] as List;
    expect(scans, hasLength(2));
    expect(scans[0], containsPair('mpn', 'LM358DR'));
    expect(scans[0], containsPair('supplierPart', 'C7950'));
    expect(scans[0], containsPair('quantity', '100'));
    expect(scans[0], containsPair('projectName', 'Main List'));
    expect(scans[0]['deviceId'], app.read(syncPrefsProvider).deviceId);
    expect(app.read(syncProvider).pending, 0);

    // Offline: the scan stays queued and the error is shown.
    serverUp = false;
    scan('LM358DR');
    await settle();
    expect(app.read(syncProvider).pending, 1);
    expect(app.read(syncProvider).lastError, isNotNull);

    serverUp = true;
    await app.read(syncProvider.notifier).flush();
    expect(app.read(syncProvider).pending, 0);
    expect(app.read(syncProvider).lastError, isNull);
  });
}
