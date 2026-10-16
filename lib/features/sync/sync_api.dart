import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'sync_prefs.dart';

/// A request the server answered with an error status.
class SyncHttpException implements Exception {
  const SyncHttpException(this.status, this.message);

  final int status;
  final String message;

  /// The request itself is wrong (bad data, too large); sending it again
  /// won't help. Auth and rate-limit errors are worth retrying.
  bool get isPermanent => status >= 400 && status < 500 && status != 401 && status != 408 && status != 429;

  @override
  String toString() => status == 401 ? 'Wrong or missing API key' : 'Server error $status: $message';
}

/// Talks to the ToolsResc Go backend (see backend/README.md).
class SyncApi {
  SyncApi(this._client);

  final http.Client _client;

  Future<void> health(SyncPrefs prefs) => _send(prefs, 'GET', 'healthz', timeout: const Duration(seconds: 10));

  Future<void> postScans(SyncPrefs prefs, List<Map<dynamic, dynamic>> scans) =>
      _send(prefs, 'POST', 'v1/scans', body: {'scans': scans}, timeout: const Duration(seconds: 30));

  Future<void> postImport(SyncPrefs prefs, String projectId, Map<dynamic, dynamic> body) => _send(
    prefs,
    'POST',
    'v1/projects/${Uri.encodeComponent(projectId)}/imports',
    body: body,
    timeout: const Duration(minutes: 3),
  );

  Future<void> _send(SyncPrefs prefs, String method, String path, {Object? body, required Duration timeout}) async {
    final request = http.Request(method, baseUri(prefs.serverUrl).resolve(path));
    if (prefs.apiKey.isNotEmpty) request.headers['Authorization'] = 'Bearer ${prefs.apiKey}';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(await _client.send(request).timeout(timeout));
    if (response.statusCode >= 300) {
      var message = response.body;
      try {
        message = (jsonDecode(response.body) as Map)['error'] as String? ?? message;
      } catch (_) {}
      throw SyncHttpException(response.statusCode, message);
    }
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
