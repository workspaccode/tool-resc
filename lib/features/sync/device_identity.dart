import 'dart:convert';
import 'dart:math';

import 'package:android_id/android_id.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive_ce.dart';

import '../../app/storage.dart';

/// Settings keys for this device's identity.
abstract final class DeviceKeys {
  /// e.g. `android-3f9c…`: the platform plus a hash of the hardware id.
  static const id = 'deviceId';
  static const platform = 'devicePlatform';
  static const model = 'deviceModel';
}

/// Identifies this phone or computer without an account: the server knows
/// it by an id made from the hardware id (Android ID, Windows MachineGuid,
/// macOS hardware UUID, iOS identifierForVendor, Linux machine-id), so it
/// stays the same after a reinstall where the OS allows it. The raw id is
/// hashed and never sent. Falls back to a random id per install.
Future<void> ensureDeviceIdentity() async {
  final settings = Hive.box<Object>(Boxes.settings);
  String platform = defaultTargetPlatform.name;
  String? hardwareId;
  String? model;
  try {
    final info = DeviceInfoPlugin();
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await info.androidInfo;
        hardwareId = await const AndroidId().getId();
        model = '${a.manufacturer} ${a.model}';
      case TargetPlatform.iOS:
        final i = await info.iosInfo;
        hardwareId = i.identifierForVendor;
        model = i.utsname.machine;
      case TargetPlatform.windows:
        final w = await info.windowsInfo;
        hardwareId = w.deviceId;
        model = w.computerName;
      case TargetPlatform.macOS:
        final m = await info.macOsInfo;
        hardwareId = m.systemGUID;
        model = m.computerName;
      case TargetPlatform.linux:
        final l = await info.linuxInfo;
        hardwareId = l.machineId;
        model = l.prettyName;
      case TargetPlatform.fuchsia:
        break;
    }
  } catch (_) {
    // No plugin (tests) or no access: keep or make a random id.
  }

  final String id;
  if (hardwareId != null && hardwareId.trim().isNotEmpty) {
    final hash = sha256.convert(utf8.encode('toolsresc:$platform:${hardwareId.trim()}')).toString();
    id = '$platform-${hash.substring(0, 32)}';
  } else {
    id = (settings.get(DeviceKeys.id) as String?) ?? 'install-${_randomHex()}';
  }
  await settings.putAll({DeviceKeys.id: id, DeviceKeys.platform: platform, DeviceKeys.model: ?model});
}

String _randomHex() {
  final r = Random.secure();
  return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}
