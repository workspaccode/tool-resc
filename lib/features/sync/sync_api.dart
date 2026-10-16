import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'sync_prefs.dart';

/// A request the server answered with an error status.
class SyncHttpException implements Exception {
  const SyncHttpException(this.status, this.message);

  final int status;
  final String message;

  /// The request itself is wrong (bad data, too large, not a member);
  /// sending it again won't help. Auth and rate-limit errors are worth
  /// retrying.
  bool get isPermanent => status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  @override
  String toString() => switch (status) {
    401 => 'Wrong or missing API key',
    404 => 'Not found',
    429 => 'Too many attempts. Try again in a few minutes.',
    _ => 'Server error $status: $message',
  };
}

/// A project as the server describes it.
class ProjectInfo {
  const ProjectInfo({
    required this.id,
    required this.code,
    required this.name,
    this.members = 0,
    this.lists = 0,
    this.scans = 0,
  });

  factory ProjectInfo.fromJson(Map m) => ProjectInfo(
    id: m['id'] as String,
    code: m['code'] as String,
    name: m['name'] as String,
    members: m['members'] as int? ?? 0,
    lists: m['lists'] as int? ?? 0,
    scans: m['scans'] as int? ?? 0,
  );

  final String id;
  final String code;
  final String name;
  final int members;
  final int lists;
  final int scans;

  Map<String, Object> toJson() => {
    'id': id,
    'code': code,
    'name': name,
    'members': members,
    'lists': lists,
    'scans': scans,
  };
}

/// A list of a project, without its rows.
class RemoteList {
  const RemoteList({required this.id, required this.name, required this.version, this.rows = 0, this.scans = 0});

  factory RemoteList.fromJson(Map m) => RemoteList(
    id: m['id'] as String,
    name: m['name'] as String,
    version: m['version'] as int? ?? 0,
    rows: m['rows'] as int? ?? 0,
    scans: m['scans'] as int? ?? 0,
  );

  final String id;
  final String name;
  final int version;
  final int rows;
  final int scans;
}

/// A whole list, to download.
class RemoteTable {
  const RemoteTable({required this.list, required this.headers, required this.rows, required this.mpnIndex});

  final RemoteList list;
  final List<String> headers;
  final List<List<String>> rows;
  final int mpnIndex;
}

/// One scan in a project's history.
class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.mpn,
    required this.listName,
    required this.deviceId,
    required this.deviceName,
    required this.found,
    required this.scannedAt,
    this.quantity = 0,
    this.supplierPart,
    this.source = '',
  });

  factory ScanRecord.fromJson(Map m) => ScanRecord(
    id: m['id'] as String,
    mpn: m['mpn'] as String? ?? '',
    listName: m['listName'] as String? ?? '',
    deviceId: m['deviceId'] as String? ?? '',
    deviceName: m['deviceName'] as String? ?? '',
    found: m['found'] as bool? ?? false,
    scannedAt: DateTime.parse(m['scannedAt'] as String).toLocal(),
    quantity: m['quantity'] as int? ?? 0,
    supplierPart: m['supplierPart'] as String?,
    source: m['source'] as String? ?? '',
  );

  final String id;
  final String mpn;
  final String listName;
  final String deviceId;
  final String deviceName;
  final bool found;
  final DateTime scannedAt;
  final int quantity;
  final String? supplierPart;
  final String source;
}

class MemberInfo {
  const MemberInfo({required this.id, required this.name, required this.scans});

  factory MemberInfo.fromJson(Map m) =>
      MemberInfo(id: m['id'] as String, name: m['name'] as String? ?? 'Device', scans: m['scans'] as int? ?? 0);

  final String id;
  final String name;
  final int scans;
}

/// What a member sees when opening a project.
class ProjectDetail {
  const ProjectDetail({required this.project, required this.members, required this.lists});

  factory ProjectDetail.fromJson(Map m) => ProjectDetail(
    project: ProjectInfo.fromJson(m),
    members: [for (final x in (m['memberList'] as List? ?? const [])) MemberInfo.fromJson(x as Map)],
    lists: [for (final x in (m['listInfo'] as List? ?? const [])) RemoteList.fromJson(x as Map)],
  );

  final ProjectInfo project;
  final List<MemberInfo> members;
  final List<RemoteList> lists;
}

/// Talks to the ToolsResc Go backend (see backend/README.md). Every request
/// carries this device's id; there is no account.
class SyncApi {
  SyncApi(this._client);

  final http.Client _client;

  static const _short = Duration(seconds: 20);
  static const _long = Duration(minutes: 3);

  Future<void> health(SyncPrefs p) => _send(p, 'GET', 'healthz');

  Future<void> registerDevice(SyncPrefs p) =>
      _send(p, 'PUT', 'v1/device', body: {'name': p.deviceName, 'platform': p.platform, 'model': p.model});

  Future<List<ProjectInfo>> myProjects(SyncPrefs p) async {
    final m = await _send(p, 'GET', 'v1/projects') as Map;
    return [for (final x in m['projects'] as List) ProjectInfo.fromJson(x as Map)];
  }

  Future<ProjectInfo> createProject(SyncPrefs p, String name) async =>
      ProjectInfo.fromJson(await _send(p, 'POST', 'v1/projects', body: {'name': name}) as Map);

  Future<ProjectInfo> joinProject(SyncPrefs p, String code) async =>
      ProjectInfo.fromJson(await _send(p, 'POST', 'v1/projects/join', body: {'code': code}) as Map);

  Future<void> leaveProject(SyncPrefs p, String projectId) => _send(p, 'POST', '${_project(projectId)}/leave');

  Future<ProjectDetail> project(SyncPrefs p, String projectId) async =>
      ProjectDetail.fromJson(await _send(p, 'GET', _project(projectId)) as Map);

  /// The project's scans, newest first; [mine] = only this device's.
  Future<({List<ScanRecord> scans, int total})> history(
    SyncPrefs p,
    String projectId, {
    bool mine = false,
    int limit = 50,
  }) async {
    final m = await _send(p, 'GET', '${_project(projectId)}/scans?limit=$limit${mine ? '&device=me' : ''}') as Map;
    return (scans: [for (final x in m['scans'] as List) ScanRecord.fromJson(x as Map)], total: m['total'] as int? ?? 0);
  }

  Future<List<RemoteList>> lists(SyncPrefs p, String projectId) async {
    final m = await _send(p, 'GET', '${_project(projectId)}/lists') as Map;
    return [for (final x in m['lists'] as List) RemoteList.fromJson(x as Map)];
  }

  Future<RemoteTable> table(SyncPrefs p, String projectId, String listId) async {
    final m = await _send(p, 'GET', _list(projectId, listId), timeout: _long) as Map;
    return RemoteTable(
      list: RemoteList.fromJson(m['list'] as Map),
      headers: (m['headers'] as List).cast<String>(),
      rows: [for (final r in m['rows'] as List) (r as List).cast<String>()],
      mpnIndex: m['mpnIndex'] as int,
    );
  }

  /// Returns the list's new data version.
  Future<int> postImport(SyncPrefs p, Map body) async {
    final m = await _send(
      p,
      'POST',
      '${_list(body['projectId'] as String, body['listId'] as String)}/imports',
      body: body,
      timeout: _long,
    ) as Map;
    return (m['list'] as Map?)?['version'] as int? ?? 0;
  }

  Future<void> renameList(SyncPrefs p, Map body) => _send(
    p,
    'PATCH',
    _list(body['projectId'] as String, body['listId'] as String),
    body: {'eventId': body['eventId'], 'name': body['name']},
  );

  Future<void> deleteList(SyncPrefs p, Map body) =>
      _send(p, 'DELETE', '${_list(body['projectId'] as String, body['listId'] as String)}?eventId=${body['eventId']}');

  Future<void> postScans(SyncPrefs p, List<Map> scans) => _send(p, 'POST', 'v1/scans', body: {'scans': scans});

  static String _project(String id) => 'v1/projects/${Uri.encodeComponent(id)}';
  static String _list(String projectId, String listId) => '${_project(projectId)}/lists/${Uri.encodeComponent(listId)}';

  Future<Object?> _send(SyncPrefs p, String method, String path, {Object? body, Duration timeout = _short}) async {
    final request = http.Request(method, baseUri(p.serverUrl).resolve(path));
    request.headers['X-Device-Id'] = p.deviceId;
    if (p.apiKey.isNotEmpty) request.headers['Authorization'] = 'Bearer ${p.apiKey}';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await _client.send(request).timeout(timeout)).timeout(timeout);
    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 300) {
      var message = text;
      try {
        message = (jsonDecode(text) as Map)['error'] as String? ?? message;
      } catch (_) {}
      throw SyncHttpException(response.statusCode, message);
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// `192.168.1.20:8080` -> `http://192.168.1.20:8080/`.
  static Uri baseUri(String server) {
    var s = server.trim();
    if (!s.contains('://')) s = 'http://$s';
    if (!s.endsWith('/')) s = '$s/';
    return Uri.parse(s);
  }
}

final syncApiProvider = Provider<SyncApi>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return SyncApi(client);
});
