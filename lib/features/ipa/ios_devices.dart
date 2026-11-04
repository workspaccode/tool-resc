import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ipa_builder.dart';

/// How the device was found, which decides how apps are installed.
enum DeviceTool {
  /// Xcode's `devicectl` (physical devices, macOS).
  devicectl,

  /// Xcode's `simctl` (simulators, macOS).
  simctl,

  /// libimobiledevice: `idevice_id` / `ideviceinstaller` (any desktop).
  libimobiledevice,
}

enum DeviceConnection { usb, network, offline, local }

/// An iPhone, iPad or simulator that can install apps.
class IosDevice {
  const IosDevice({
    required this.id,
    required this.name,
    required this.tool,
    required this.connection,
    this.model,
    this.osVersion,
    this.isIpad = false,
    this.booted = false,
  });

  /// devicectl identifier, simulator UDID, or device UDID.
  final String id;
  final String name;
  final DeviceTool tool;
  final DeviceConnection connection;
  final String? model;
  final String? osVersion;
  final bool isIpad;

  /// Simulators: already running.
  final bool booted;

  bool get isSimulator => tool == DeviceTool.simctl;

  String get detail => [
    if (isSimulator) 'Simulator' else ?model,
    if (osVersion != null) 'iOS $osVersion',
    switch (connection) {
      DeviceConnection.usb => 'USB',
      DeviceConnection.network => 'Wi-Fi',
      DeviceConnection.offline => 'Not connected',
      DeviceConnection.local => booted ? 'Running' : null,
    },
  ].nonNulls.join(' · ');

  /// Why [app] can't be installed here, or null if it can.
  String? blockReason(AppBundleInfo app) {
    if (isSimulator && !app.isSimulatorBuild) return 'Needs a simulator build (flutter build ios --simulator)';
    if (!isSimulator && app.isSimulatorBuild) return 'Simulator builds don’t run on devices';
    if (connection == DeviceConnection.offline) return 'Not connected';
    if (!isSimulator && !app.signed) return 'The app isn’t signed';
    final min = app.minimumOS;
    if (min != null && osVersion != null && compareVersions(osVersion!, min) < 0) return 'Needs iOS $min or later';
    return null;
  }
}

/// Compares dotted versions: `compareVersions('17.0', '13.4') > 0`.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final s in v.split('.')) int.tryParse(s.replaceAll(RegExp(r'\D.*'), '')) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

typedef RunCommand = Future<ProcessResult> Function(String executable, List<String> arguments, {Duration timeout});

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 30),
}) => Process.run(executable, arguments).timeout(
  timeout,
  onTimeout: () =>
      throw IpaException('Timed Out', '${p.basename(executable)} didn’t answer in ${timeout.inSeconds} s.'),
);

/// Finds iOS devices and installs apps on them, using Xcode's tools on
/// macOS and libimobiledevice elsewhere (or when Xcode isn't installed).
class IosDeviceService {
  IosDeviceService({RunCommand? run, String? Function(String name)? which, bool? isMacOS})
    : _runCmd = run ?? _run,
      _which = which ?? findExecutable,
      _isMacOS = isMacOS ?? Platform.isMacOS;

  final RunCommand _runCmd;
  final String? Function(String) _which;
  final bool _isMacOS;

  bool? _hasXcode;

  /// `xcode-select -p` succeeds and Xcode has devicectl. Checked first so
  /// the /usr/bin/xcrun stub never asks to install the command line tools.
  Future<bool> _xcodeAvailable() async {
    if (!_isMacOS) return false;
    if (_hasXcode != null) return _hasXcode!;
    try {
      final selected = await _runCmd('/usr/bin/xcode-select', ['-p']);
      if (selected.exitCode != 0) return _hasXcode = false;
      final found = await _runCmd('/usr/bin/xcrun', ['--find', 'devicectl']);
      return _hasXcode = found.exitCode == 0;
    } catch (_) {
      return _hasXcode = false;
    }
  }

  /// All devices and simulators. Throws [IpaException] if there's no tool
  /// to find them with.
  Future<List<IosDevice>> discover() async {
    final devices = <IosDevice>[];
    if (await _xcodeAvailable()) {
      final results = await Future.wait([_devicectlDevices(), _simulators()]);
      devices
        ..addAll(results[0])
        ..addAll(results[1]);
    } else if (_which('idevice_id') != null) {
      devices.addAll(await _libimobiledeviceDevices());
    } else {
      throw IpaException(
        'No Device Tools',
        _isMacOS
            ? 'Install Xcode to find iPhones, iPads and simulators. Or install libimobiledevice: brew install libimobiledevice ideviceinstaller'
            : 'Install libimobiledevice and ideviceinstaller to find iPhones and iPads connected to this computer.',
      );
    }
    // Connected devices first, then running simulators, then the rest.
    int rank(IosDevice d) => switch (d) {
      IosDevice(isSimulator: false, connection: DeviceConnection.offline) => 2,
      IosDevice(isSimulator: false) => 0,
      IosDevice(booted: true) => 1,
      _ => 3,
    };
    return devices..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  Future<List<IosDevice>> _devicectlDevices() async {
    final tmp = await Directory.systemTemp.createTemp('devicectl');
    try {
      final out = p.join(tmp.path, 'devices.json');
      final r = await _runCmd('/usr/bin/xcrun', ['devicectl', 'list', 'devices', '--json-output', out, '--quiet']);
      final file = File(out);
      if (r.exitCode != 0 || !file.existsSync()) return [];
      return parseDevicectlDevices(file.readAsStringSync());
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  Future<List<IosDevice>> _simulators() async {
    final r = await _runCmd('/usr/bin/xcrun', ['simctl', 'list', 'devices', 'available', '--json']);
    if (r.exitCode != 0) return [];
    return parseSimctlDevices('${r.stdout}');
  }

  Future<List<IosDevice>> _libimobiledeviceDevices() async {
    final tool = _which('idevice_id')!;
    final info = _which('ideviceinfo');
    final usb = await _runCmd(tool, ['-l']);
    final net = await _runCmd(tool, ['-n']);
    List<String> ids(ProcessResult r) => r.exitCode == 0
        ? LineSplitter.split('${r.stdout}').map((l) => l.trim()).where((l) => l.isNotEmpty).toList()
        : [];
    final usbIds = ids(usb);
    final found = [
      for (final id in usbIds) (id, DeviceConnection.usb),
      for (final id in ids(net))
        if (!usbIds.contains(id)) (id, DeviceConnection.network),
    ];
    return Future.wait([
      for (final (id, conn) in found)
        () async {
          final props = <String, String>{};
          if (info != null) {
            final r = await _runCmd(info, ['-u', id, if (conn == DeviceConnection.network) '-n']);
            if (r.exitCode == 0) props.addAll(parseKeyValues('${r.stdout}'));
          }
          return IosDevice(
            id: id,
            name: props['DeviceName'] ?? id,
            tool: DeviceTool.libimobiledevice,
            connection: conn,
            model: props['ProductType'],
            osVersion: props['ProductVersion'],
            isIpad: props['DeviceClass'] == 'iPad' || (props['ProductType']?.startsWith('iPad') ?? false),
          );
        }(),
    ]);
  }

  /// Installs [app] on [device]. libimobiledevice needs an .ipa, so one is
  /// made in the temporary folder first.
  Future<void> install(IosDevice device, AppBundleInfo app) async {
    final ProcessResult r;
    switch (device.tool) {
      case DeviceTool.devicectl:
        r = await _runCmd('/usr/bin/xcrun', [
          'devicectl', 'device', 'install', 'app', '--device', device.id, app.appPath, //
        ], timeout: const Duration(minutes: 10));
      case DeviceTool.simctl:
        if (!device.booted) {
          // Fails harmlessly if it's already booted.
          await _runCmd('/usr/bin/xcrun', ['simctl', 'boot', device.id], timeout: const Duration(minutes: 3));
        }
        if (_isMacOS) await _runCmd('/usr/bin/open', ['-a', 'Simulator']);
        r = await _runCmd('/usr/bin/xcrun', [
          'simctl', 'install', device.id, app.appPath, //
        ], timeout: const Duration(minutes: 5));
      case DeviceTool.libimobiledevice:
        final tool = _which('ideviceinstaller');
        if (tool == null) {
          throw const IpaException('ideviceinstaller Missing', 'Install ideviceinstaller to install apps on devices.');
        }
        final tmp = await Directory.systemTemp.createTemp('ipa_install');
        try {
          final ipa = p.join(tmp.path, app.suggestedFileName);
          await exportIpa(app, ipa);
          final net = device.connection == DeviceConnection.network ? ['-n'] : <String>[];
          var result = await _runCmd(tool, [
            '-u',
            device.id,
            ...net,
            'install',
            ipa,
          ], timeout: const Duration(minutes: 10));
          if (result.exitCode != 0 && '${result.stderr}${result.stdout}'.contains('Usage')) {
            // ideviceinstaller before 1.1.2 takes -i instead of `install`.
            result = await _runCmd(tool, ['-u', device.id, ...net, '-i', ipa], timeout: const Duration(minutes: 10));
          }
          r = result;
        } finally {
          await tmp.delete(recursive: true);
        }
    }
    final output = '${r.stderr}\n${r.stdout}';
    // Old ideviceinstaller exits 0 even when the install fails.
    if (r.exitCode != 0 || RegExp(r'^ERROR:', multiLine: true).hasMatch(output)) {
      throw IpaException('Install Failed', describeInstallError(output));
    }
  }
}

/// Parses `devicectl list devices --json-output`. Only physical devices:
/// simulators come from simctl, which every Xcode version lists.
List<IosDevice> parseDevicectlDevices(String json) {
  final root = jsonDecode(json);
  final result = root is Map ? root['result'] : null;
  final list = result is Map && result['devices'] is List ? result['devices'] as List : const [];
  final out = <IosDevice>[];
  for (final d in list.whereType<Map>()) {
    // Newer Xcode: `properties`; older: the *Properties dictionaries.
    final props = d['properties'] as Map? ?? const {};
    final hw = props['hardware'] as Map? ?? d['hardwareProperties'] as Map? ?? const {};
    final conn = props['connection'] as Map? ?? d['connectionProperties'] as Map? ?? const {};
    final state = props['state'] as Map? ?? const {};
    final dev = d['deviceProperties'] as Map? ?? const {};
    final sw = props['software'] as Map? ?? const {};

    if (hw['reality'] != 'physical') continue;
    final platform = hw['platform'];
    if (platform != null && platform != 'iOS') continue; // watchOS, tvOS, visionOS.

    final transport = conn['transportType'];
    final connected = conn['tunnelState'] != 'unavailable' && (transport == 'wired' || transport == 'localNetwork');
    final osNumber = sw['osVersionNumber'];
    final os = (osNumber is Map ? osNumber['stringValue'] : null) ?? dev['osVersionNumber'];
    out.add(
      IosDevice(
        id: '${d['identifier']}',
        name: '${state['name'] ?? dev['name'] ?? hw['marketingName'] ?? 'iOS Device'}',
        tool: DeviceTool.devicectl,
        connection: !connected
            ? DeviceConnection.offline
            : transport == 'wired'
            ? DeviceConnection.usb
            : DeviceConnection.network,
        model: hw['marketingName'] as String? ?? hw['productType'] as String?,
        osVersion: os as String?,
        isIpad: hw['deviceType'] == 'iPad',
      ),
    );
  }
  return out;
}

/// Parses `simctl list devices available --json`: iOS simulators only.
List<IosDevice> parseSimctlDevices(String json) {
  final root = jsonDecode(json);
  final devices = root is Map ? root['devices'] : null;
  final runtimes = devices is Map ? devices : const {};
  final out = <IosDevice>[];
  for (final MapEntry(:key, :value) in runtimes.entries) {
    // com.apple.CoreSimulator.SimRuntime.iOS-26-4
    final m = RegExp(r'SimRuntime\.iOS-([\d-]+)$').firstMatch('$key');
    if (m == null || value is! List) continue;
    final version = m.group(1)!.replaceAll('-', '.');
    for (final s in value.whereType<Map>()) {
      if (s['isAvailable'] == false) continue;
      out.add(
        IosDevice(
          id: '${s['udid']}',
          name: '${s['name']}',
          tool: DeviceTool.simctl,
          connection: DeviceConnection.local,
          osVersion: version,
          isIpad: '${s['deviceTypeIdentifier'] ?? s['name']}'.contains('iPad'),
          booted: s['state'] == 'Booted',
        ),
      );
    }
  }
  return out;
}

/// `Key: Value` lines, as printed by ideviceinfo.
Map<String, String> parseKeyValues(String text) {
  final out = <String, String>{};
  for (final line in LineSplitter.split(text)) {
    final i = line.indexOf(': ');
    if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 2).trim();
  }
  return out;
}

/// Turns tool output into a short reason, with hints for common failures.
String describeInstallError(String output) {
  final text = output.trim();
  final hints = <(Pattern, String)>[
    (
      RegExp('developer mode', caseSensitive: false),
      'Turn on Developer Mode on the device: Settings › Privacy & Security › Developer Mode.',
    ),
    (
      RegExp('ApplicationVerificationFailed|No code signature|not signed', caseSensitive: false),
      'The app isn’t signed correctly for this device.',
    ),
    (
      RegExp('provisioning profile|DeviceNotProvisioned|0xe8008012|0xe800801c', caseSensitive: false),
      'The provisioning profile doesn’t include this device. Add its UDID to the profile and build again.',
    ),
    (RegExp('locked|PasswordProtected', caseSensitive: false), 'Unlock the device and try again.'),
    (RegExp('trust|pair', caseSensitive: false), 'Unlock the device and tap Trust when asked, then try again.'),
    (
      RegExp('MismatchedApplicationIdentifierEntitlement', caseSensitive: false),
      'A version of the app signed by another team is installed. Delete it from the device first.',
    ),
    (
      RegExp('Incompatible|MinimumOSVersion|DeviceOSVersionTooLow', caseSensitive: false),
      'The device’s iOS version is too old for this app.',
    ),
  ];
  for (final (pattern, hint) in hints) {
    if (text.contains(pattern)) return '$hint\n\n${_lastLines(text)}';
  }
  return text.isEmpty ? 'The install didn’t finish.' : _lastLines(text);
}

String _lastLines(String text) {
  final lines = LineSplitter.split(text).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  return lines.skip(lines.length > 6 ? lines.length - 6 : 0).join('\n');
}

/// Looks for [name] on PATH and where Homebrew installs. Apps opened from
/// Finder get a short PATH without /opt/homebrew/bin.
String? findExecutable(String name) {
  final windows = Platform.isWindows;
  final dirs = [
    ...?Platform.environment['PATH']?.split(windows ? ';' : ':'),
    if (!windows) ...['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin'],
  ];
  for (final dir in dirs.where((d) => d.isNotEmpty)) {
    for (final candidate in [p.join(dir, name), if (windows) p.join(dir, '$name.exe')]) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}
