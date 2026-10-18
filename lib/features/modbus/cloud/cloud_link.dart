import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Cloud Share settings (Inverter Cloud protocol, see protocol.md).
class CloudConfig {
  const CloudConfig({
    this.enabled = false,
    this.url = 'ws://localhost:8790',
    this.site = 'SITE-001',
    this.device = 'INV-001',
  });

  factory CloudConfig.fromMap(Map m) => CloudConfig(
    enabled: m['enabled'] as bool? ?? false,
    url: m['url'] as String? ?? 'ws://localhost:8790',
    site: m['site'] as String? ?? 'SITE-001',
    device: m['device'] as String? ?? 'INV-001',
  );

  final bool enabled;

  /// Backend base (`ws://host:8790`) or the full `/ingest` URL.
  final String url;
  final String site;
  final String device;

  Map<String, Object> toMap() => {'enabled': enabled, 'url': url, 'site': site, 'device': device};

  CloudConfig copyWith({bool? enabled, String? url, String? site, String? device}) => CloudConfig(
    enabled: enabled ?? this.enabled,
    url: url ?? this.url,
    site: site ?? this.site,
    device: device ?? this.device,
  );

  /// The upload endpoint: always `.../ingest`.
  Uri get ingestUri {
    var base = url.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) base = 'ws://localhost:8790';
    if (!base.contains('://')) base = 'ws://$base';
    base = base.replaceFirst(RegExp(r'^http'), 'ws'); // http(s):// -> ws(s)://
    base = base.replaceFirst(RegExp(r'/(ingest|data|stats)$'), '');
    return Uri.parse('$base/ingest');
  }

  /// Where subscribers get the live feed.
  Uri get feedUri => ingestUri.replace(path: ingestUri.path.replaceFirst(RegExp(r'ingest$'), 'data'));
}

enum CloudState { off, connecting, live }

/// Uploads every poll reading to the cloud backend in real time over a
/// WebSocket: `hello` on connect, then one `reading` per successful poll.
/// The backend re-broadcasts them to every subscriber on `/data`.
/// Reconnects every 5 s while enabled; readings made while offline are not
/// kept (it is a live feed, like the web gateway).
class CloudLink {
  CloudLink({required this.onChange, required this.onLog, this.retryEvery = const Duration(seconds: 5)});

  final void Function() onChange;
  final void Function(String message, {bool error}) onLog;
  final Duration retryEvery;

  static const app = 'toolsresc-modbus-gateway v1.0';

  CloudConfig _config = const CloudConfig();
  WebSocket? _ws;
  Timer? _retry;
  bool _wasLive = false;
  int _generation = 0;

  CloudState state = CloudState.off;
  int sent = 0;

  CloudConfig get config => _config;

  /// Applies new settings; reconnects if the target changed.
  void configure(CloudConfig config) {
    final target =
        config.enabled != _config.enabled ||
        config.ingestUri != _config.ingestUri ||
        config.site != _config.site ||
        config.device != _config.device;
    _config = config;
    if (!target) return;
    _disconnect();
    if (config.enabled) {
      _connect();
    } else {
      onLog('Cloud Share off.');
    }
  }

  /// Sends one reading; ignored when not live.
  void push({
    required int pollId,
    required String name,
    required int func,
    required int addr,
    required List<int> values,
    required int unitId,
  }) {
    final ws = _ws;
    if (state != CloudState.live || ws == null) return;
    try {
      ws.add(
        jsonEncode({
          'type': 'reading',
          'site': _config.site.trim(),
          'device': _config.device.trim(),
          'pollId': pollId,
          'name': name,
          'func': func,
          'addr': addr,
          'values': values,
          'unitId': '$unitId',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      sent++;
      onChange();
    } catch (e) {
      onLog('Cloud upload failed: $e', error: true);
    }
  }

  void dispose() {
    _config = _config.copyWith(enabled: false);
    _disconnect();
  }

  Future<void> _connect() async {
    if (!_config.enabled) return;
    final gen = ++_generation;
    final uri = _config.ingestUri;
    state = CloudState.connecting;
    onChange();
    onLog('Cloud: connecting to $uri …');
    try {
      final ws = await WebSocket.connect(uri.toString()).timeout(const Duration(seconds: 10));
      if (gen != _generation || !_config.enabled) {
        await ws.close();
        return;
      }
      _ws = ws;
      ws.add(
        jsonEncode({
          'type': 'hello',
          'site': _config.site.trim(),
          'device': _config.device.trim(),
          'app': app,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      state = CloudState.live;
      _wasLive = true;
      onChange();
      onLog('Cloud linked — every poll reading is uploaded live.');
      ws.listen(
        (raw) {
          try {
            final m = jsonDecode(raw as String) as Map;
            if (m['type'] == 'ack') onLog('Cloud: ${m['message'] ?? 'ack'}');
            if (m['type'] == 'error') onLog('Cloud: ${m['message']}', error: true);
          } catch (_) {}
        },
        onDone: () => _lost(gen),
        onError: (_) => _lost(gen),
        cancelOnError: true,
      );
    } catch (e) {
      if (gen != _generation) return;
      _ws = null;
      state = _config.enabled ? CloudState.connecting : CloudState.off;
      onChange();
      onLog('Cloud backend not reachable at $uri. Retrying in ${retryEvery.inSeconds} s…', error: true);
      _scheduleRetry();
    }
  }

  void _lost(int gen) {
    if (gen != _generation) return; // a stale socket
    _ws = null;
    if (!_config.enabled) return;
    state = CloudState.connecting;
    onChange();
    if (_wasLive) onLog('Cloud link lost — retrying in ${retryEvery.inSeconds} s…', error: true);
    _wasLive = false;
    _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(retryEvery, _connect);
  }

  void _disconnect() {
    _generation++;
    _retry?.cancel();
    _retry = null;
    final ws = _ws;
    _ws = null;
    ws?.close().catchError((_) {});
    _wasLive = false;
    state = CloudState.off;
    onChange();
  }
}
