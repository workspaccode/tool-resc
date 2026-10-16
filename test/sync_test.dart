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
import 'package:tool_resc/features/sync/projects_controller.dart';
import 'package:tool_resc/features/sync/sync_api.dart';
import 'package:tool_resc/features/sync/sync_controller.dart';
import 'package:tool_resc/features/sync/sync_prefs.dart';

/// A small in-memory stand-in for the Go server (same routes and shapes).
class FakeServer {
  bool up = true;
  final requests = <String>[];
  final scans = <Map>[];
  final projects = <String, Map<String, Object?>>{}; // id -> {code, name, members, lists}
  var _seq = 0;

  Map<String, Map<String, Object?>> lists(String pid) => (projects[pid]!['lists'] as Map).cast();

  /// Another device changes a list.
  void putList(String pid, String lid, String name, List<List<String>> rows) => lists(pid)[lid] = {
    'name': name,
    'headers': ['MPN', 'Bin'],
    'rows': rows,
    'mpnIndex': 0,
    'version': ++_seq,
  };

  Future<http.Response> handle(http.Request r) async {
    if (!up) throw const SocketException('offline');
    final path = r.url.path.substring(1);
    requests.add('${r.method} $path');
    final device = r.headers['X-Device-Id']!;
    final body = r.body.isEmpty ? const {} : jsonDecode(r.body) as Map;
    final seg = path.split('/');
    http.Response json(Object o, [int status = 200]) => http.Response(jsonEncode(o), status);
    Map info(String id) {
      final p = projects[id]!;
      return {
        'id': id,
        'code': p['code'],
        'name': p['name'],
        'members': (p['members'] as Set).length,
        'lists': lists(id).length,
      };
    }

    Map summary(String lid, Map l) => {
      'id': lid,
      'name': l['name'],
      'version': l['version'],
      'rows': (l['rows'] as List).length,
    };

    switch ((r.method, seg)) {
      case ('PUT', ['v1', 'device']):
        return json({});
      case ('GET', ['v1', 'projects']):
        return json({
          'projects': [
            for (final id in projects.keys)
              if ((projects[id]!['members'] as Set).contains(device)) info(id),
          ],
        });
      case ('POST', ['v1', 'projects']):
        final id = 'p${projects.length + 1}';
        projects[id] = {
          'code': 'AAAA-BBB$id',
          'name': body['name'],
          'members': {device},
          'lists': <String, Map>{},
        };
        return json(info(id), 201);
      case ('POST', ['v1', 'projects', 'join']):
        final id = projects.keys.where((k) => projects[k]!['code'] == body['code']).firstOrNull;
        if (id == null) return json({'error': 'not found'}, 404);
        (projects[id]!['members'] as Set).add(device);
        return json(info(id));
      case ('GET', ['v1', 'projects', final pid, 'lists']):
        return json({
          'lists': [for (final e in lists(pid).entries) summary(e.key, e.value)],
        });
      case ('GET', ['v1', 'projects', final pid, 'lists', final lid]):
        final l = lists(pid)[lid]!;
        return json({'list': summary(lid, l), 'headers': l['headers'], 'rows': l['rows'], 'mpnIndex': l['mpnIndex']});
      case ('POST', ['v1', 'projects', final pid, 'lists', final lid, 'imports']):
        final l = lists(pid)[lid] = {
          'name': body['name'],
          'headers': body['headers'],
          'rows': body['rows'],
          'mpnIndex': body['mpnIndex'],
          'version': ++_seq,
        };
        return json({'list': summary(lid, l)}, 201);
      case ('PATCH', ['v1', 'projects', final pid, 'lists', final lid]):
        lists(pid)[lid]!['name'] = body['name'];
        return http.Response('', 204);
      case ('DELETE', ['v1', 'projects', final pid, 'lists', final lid]):
        lists(pid).remove(lid);
        return http.Response('', 204);
      case ('POST', ['v1', 'scans']):
        scans.addAll((body['scans'] as List).cast<Map>());
        return json({'accepted': (body['scans'] as List).length});
    }
    return json({'error': 'no route'}, 404);
  }
}

void main() {
  late ProviderContainer app;
  late FakeServer server;

  setUp(() async {
    final dir = await Directory.systemTemp.createTemp('sync_test');
    await initStorage(path: dir.path);
    server = FakeServer();
    app = ProviderContainer(overrides: [syncApiProvider.overrideWithValue(SyncApi(MockClient(server.handle)))]);
    app.listen(syncProvider, (_, _) {}); // as the app does
    addTearDown(() async {
      app.dispose();
      await Hive.close();
      await dir.delete(recursive: true);
    });
  });

  SyncController sync() => app.read(syncProvider.notifier);
  ComponentList active() => app.read(listsProvider).active;

  Future<void> importRows(List<List<String>> rows) => app
      .read(catalogProvider.notifier)
      .import(headers: ['MPN', 'Bin'], rows: rows, mpnIndex: 0, mode: ImportMode.replace);

  void scan(String code) => sync().recordScan(
    ScannedLabel.parse(code),
    list: active(),
    source: ScanSource.camera,
    found: app.read(componentsRepositoryProvider).matchKey(ScannedLabel.parse(code).mpn) != null,
  );

  /// Waits until everything is sent, or sending failed.
  Future<void> settle() async {
    for (var i = 0; i < 500; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final s = app.read(syncProvider);
      if (!s.syncing && (s.pending == 0 || s.lastError != null)) return;
    }
  }

  void turnOn() =>
      app.read(syncPrefsProvider.notifier).update((p) => p.copyWith(enabled: true, serverUrl: '10.0.0.5:8080'));

  test('off by default: nothing is queued or sent', () async {
    expect(app.read(syncPrefsProvider).enabled, isFalse);
    expect(app.read(syncPrefsProvider).deviceId, isNotEmpty);
    scan('LM358DR');
    await settle();
    expect(app.read(syncProvider).pending, 0);
    expect(server.requests, isEmpty);
  });

  test('only lists shared in a project are sent; scans carry the list', () async {
    await importRows([
      ['LM358DR', 'A1'],
      ['NE555', 'A2'],
    ]);
    turnOn();
    await settle();

    // A local list: scans stay on the device.
    scan('LM358DR');
    await settle();
    expect(server.scans, isEmpty);

    final project = await app.read(projectsProvider.notifier).create('Site A');
    await sync().shareList(active().id, project.id);
    scan('{pbn:P1,on:WM1,pc:C7950,pm:LM358DR,qty:100}');
    scan('UNKNOWN-1');
    await settle();

    final remoteId = active().remoteId!;
    expect(server.lists(project.id)[remoteId]!['rows'], hasLength(2));
    expect(server.scans, hasLength(2));
    expect(server.scans[0], containsPair('projectId', project.id));
    expect(server.scans[0], containsPair('listId', remoteId));
    expect(server.scans[0], containsPair('supplierPart', 'C7950'));
    expect(server.scans[0], containsPair('quantity', '100'));
    expect(server.scans[0], containsPair('found', true));
    expect(server.scans[1], containsPair('found', false));
    // The upload's version is recorded, so this device doesn't download its own list again.
    expect(active().remoteVersion, server.lists(project.id)[remoteId]!['version']);
    expect(server.requests.where((r) => r.startsWith('GET') && r.endsWith('/lists/$remoteId')), isEmpty);
  });

  test('lists added, renamed and removed by other devices sync here', () async {
    turnOn();
    await settle();
    final project = await app.read(projectsProvider.notifier).create('Site A');

    // Another device adds a list.
    server.putList(project.id, 'r1', 'BOM 1', [
      ['LM358DR', 'A1'],
      ['NE555', 'B2'],
    ]);
    await sync().syncNow();
    final shared = app.read(listsProvider).lists.singleWhere((l) => l.remoteId == 'r1');
    expect(shared.name, 'BOM 1');
    expect(shared.projectId, project.id);
    expect(app.read(listRepositoryProvider(shared.id)).count, 2);
    expect(active().id, isNot(shared.id), reason: 'a downloaded list must not take over the screen');

    // It renames it and changes the rows.
    server.putList(project.id, 'r1', 'BOM One', [
      ['LM358DR', 'A1'],
    ]);
    await sync().syncNow();
    final renamed = app.read(listsProvider).lists.singleWhere((l) => l.remoteId == 'r1');
    expect(renamed.name, 'BOM One');
    expect(app.read(listRepositoryProvider(renamed.id)).count, 1);

    // It removes it from the project.
    server.lists(project.id).remove('r1');
    await sync().syncNow();
    expect(app.read(listsProvider).lists.where((l) => l.remoteId == 'r1'), isEmpty);
  });

  test('offline: changes wait and are sent later', () async {
    await importRows([
      ['LM358DR', 'A1'],
    ]);
    turnOn();
    await settle();
    final project = await app.read(projectsProvider.notifier).create('Site A');
    await sync().shareList(active().id, project.id);
    await settle();

    server.up = false;
    scan('LM358DR');
    await settle();
    expect(app.read(syncProvider).pending, 1);
    expect(app.read(syncProvider).lastError, isNotNull);

    server.up = true;
    await sync().syncNow();
    expect(app.read(syncProvider).pending, 0);
    expect(app.read(syncProvider).lastError, isNull);
    expect(server.scans, hasLength(1));
  });

  test('a wrong code is reported as not found', () async {
    turnOn();
    await settle();
    expect(
      () => app.read(projectsProvider.notifier).join('ZZZZ-ZZZZ'),
      throwsA(isA<SyncHttpException>().having((e) => e.status, 'status', 404)),
    );
  });
}
