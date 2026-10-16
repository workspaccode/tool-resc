import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';

/// Optional server sync settings. Off by default: nothing leaves the device
/// until it's turned on and a server is set.
class SyncPrefs {
  const SyncPrefs({
    this.enabled = false,
    this.serverUrl = '',
    this.apiKey = '',
    required this.deviceId,
    required this.deviceName,
  });

  final bool enabled;

  /// e.g. `http://192.168.1.20:8080`; `http://` is added when missing.
  final String serverUrl;

  /// Sent as a Bearer token; empty when the server has no key.
  final String apiKey;

  /// Random, created once per install; scans are counted per device by it.
  final String deviceId;
  final String deviceName;

  /// On, with somewhere to send to.
  bool get isReady => enabled && serverUrl.trim().isNotEmpty;

  /// The server address as typed, for display.
  String get serverLabel => serverUrl.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/+$'), '');

  SyncPrefs copyWith({bool? enabled, String? serverUrl, String? apiKey, String? deviceName}) => SyncPrefs(
    enabled: enabled ?? this.enabled,
    serverUrl: serverUrl ?? this.serverUrl,
    apiKey: apiKey ?? this.apiKey,
    deviceId: deviceId,
    deviceName: deviceName ?? this.deviceName,
  );
}

class SyncPrefsNotifier extends Notifier<SyncPrefs> {
  static const _key = 'syncPrefs';
  static const _deviceIdKey = 'deviceId';

  Box<Object> get _box => Hive.box<Object>(Boxes.settings);

  @override
  SyncPrefs build() {
    var deviceId = _box.get(_deviceIdKey) as String?;
    if (deviceId == null) {
      deviceId = newSyncId();
      _box.put(_deviceIdKey, deviceId);
    }
    final m = (_box.get(_key) as Map?) ?? const {};
    return SyncPrefs(
      enabled: m['enabled'] as bool? ?? false,
      serverUrl: m['serverUrl'] as String? ?? '',
      apiKey: m['apiKey'] as String? ?? '',
      deviceId: deviceId,
      deviceName: m['deviceName'] as String? ?? _defaultDeviceName(),
    );
  }

  void update(SyncPrefs Function(SyncPrefs) change) {
    final next = change(state);
    _box.put(_key, {
      'enabled': next.enabled,
      'serverUrl': next.serverUrl.trim(),
      'apiKey': next.apiKey.trim(),
      'deviceName': next.deviceName.trim(),
    });
    state = next;
  }

  static String _defaultDeviceName() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    TargetPlatform.linux => 'Linux PC',
    TargetPlatform.fuchsia => 'Device',
  };
}

final syncPrefsProvider = NotifierProvider<SyncPrefsNotifier, SyncPrefs>(SyncPrefsNotifier.new);

final _random = Random.secure();

/// A random 128-bit hex id, for devices and events.
String newSyncId() => [for (var i = 0; i < 16; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
