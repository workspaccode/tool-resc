import 'dart:convert';
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tool_resc/app/storage.dart';
import 'package:tool_resc/features/ipa/devices_section.dart';
import 'package:tool_resc/features/ipa/ios_devices.dart';
import 'package:tool_resc/features/ipa/ipa_builder.dart';

AppBundleInfo app({bool signed = true, bool simulator = false, String minOS = '13.0'}) => AppBundleInfo(
  appPath: '/build/Runner.app',
  pickedPath: '/build/Runner.app',
  source: IpaSource.appBundle,
  bundleName: 'Runner.app',
  displayName: 'Runner',
  executable: 'Runner',
  bundleId: 'com.example.app',
  version: '1.0.0',
  build: '1',
  minimumOS: minOS,
  fileCount: 3,
  totalBytes: 100,
  signed: signed,
  hasProvisioningProfile: signed,
  isSimulatorBuild: simulator,
  isFlutterDebug: false,
);

/// devicectl JSON (Xcode 26): one wired iPhone, one offline iPad, one
/// simulator (skipped: simctl lists those).
final devicectlJson = jsonEncode({
  'result': {
    'devices': [
      {
        'identifier': 'AAAA-1111',
        'properties': {
          'connection': {'pairingState': 'paired', 'transportType': 'wired', 'state': 'connected'},
          'hardware': {
            'deviceType': 'iPhone',
            'marketingName': 'iPhone 16 Pro',
            'platform': 'iOS',
            'reality': 'physical',
            'udid': '00008140-0001',
          },
          'software': {
            'osVersionNumber': {'stringValue': '18.2'},
          },
          'state': {'name': 'Work iPhone'},
        },
      },
      {
        // Older Xcode: only the *Properties dictionaries.
        'identifier': 'BBBB-2222',
        'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'unavailable'},
        'hardwareProperties': {
          'deviceType': 'iPad',
          'productType': 'iPad14,1',
          'platform': 'iOS',
          'reality': 'physical',
        },
        'deviceProperties': {'name': 'Shop iPad', 'osVersionNumber': '17.5'},
      },
      {
        'identifier': 'CCCC-3333',
        'properties': {
          'hardware': {'reality': 'simulated', 'platform': 'iOS'},
          'state': {'name': 'iPhone 17'},
        },
      },
      {
        'identifier': 'DDDD-4444',
        'properties': {
          'connection': {'transportType': 'wired'},
          'hardware': {'reality': 'physical', 'platform': 'watchOS'},
          'state': {'name': 'Watch'},
        },
      },
    ],
  },
});

final simctlJson = jsonEncode({
  'devices': {
    'com.apple.CoreSimulator.SimRuntime.iOS-26-4': [
      {'udid': 'SIM-1', 'name': 'iPhone 17', 'state': 'Booted', 'isAvailable': true},
      {'udid': 'SIM-2', 'name': 'iPad Air', 'state': 'Shutdown', 'isAvailable': true},
    ],
    'com.apple.CoreSimulator.SimRuntime.watchOS-12-0': [
      {'udid': 'SIM-W', 'name': 'Apple Watch', 'state': 'Shutdown', 'isAvailable': true},
    ],
  },
});

/// Records commands and answers like Xcode with the devices above.
class FakeTools {
  final calls = <List<String>>[];
  int installExit = 0;
  String installError = '';

  Future<ProcessResult> run(String exe, List<String> args, {Duration timeout = Duration.zero}) async {
    calls.add([p.basename(exe), ...args]);
    ProcessResult ok([String out = '']) => ProcessResult(0, 0, out, '');
    if (exe.endsWith('xcode-select')) return ok('/Applications/Xcode.app/Contents/Developer');
    if (args.first == '--find') return ok('/usr/bin/devicectl');
    if (args.take(3).join(' ') == 'devicectl list devices') {
      File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(devicectlJson);
      return ok();
    }
    if (args.take(2).join(' ') == 'simctl list') return ok(simctlJson);
    if (args.contains('install')) return ProcessResult(0, installExit, '', installError);
    return ok();
  }
}

void main() {
  test('parses devicectl: physical iOS devices only, old and new JSON', () {
    final devices = parseDevicectlDevices(devicectlJson);
    expect(devices.map((d) => d.name), ['Work iPhone', 'Shop iPad']);
    final (iphone, ipad) = (devices[0], devices[1]);
    expect(iphone.connection, DeviceConnection.usb);
    expect(iphone.osVersion, '18.2');
    expect(iphone.detail, 'iPhone 16 Pro · iOS 18.2 · USB');
    expect(ipad.connection, DeviceConnection.offline);
    expect(ipad.isIpad, true);
    expect(ipad.osVersion, '17.5');
  });

  test('parses simctl: iOS simulators only', () {
    final sims = parseSimctlDevices(simctlJson);
    expect(sims.map((d) => d.id), ['SIM-1', 'SIM-2']);
    expect(sims.first.booted, true);
    expect(sims.first.osVersion, '26.4');
    expect(sims[1].isIpad, true);
    expect(sims.first.detail, 'Simulator · iOS 26.4 · Running');
  });

  test('ideviceinfo output and version compare', () {
    expect(parseKeyValues('DeviceName: Sam’s iPhone\nProductVersion: 17.4.1\n'), {
      'DeviceName': 'Sam’s iPhone',
      'ProductVersion': '17.4.1',
    });
    expect(compareVersions('17.4.1', '17.4'), 1);
    expect(compareVersions('13', '13.0'), 0);
    expect(compareVersions('12.5', '13.0'), -1);
  });

  test('which devices can install which builds', () {
    final [iphone, ipad] = parseDevicectlDevices(devicectlJson);
    final [sim, _] = parseSimctlDevices(simctlJson);
    expect(iphone.blockReason(app()), null);
    expect(iphone.blockReason(app(signed: false)), 'The app isn’t signed');
    expect(iphone.blockReason(app(minOS: '18.4')), 'Needs iOS 18.4 or later');
    expect(iphone.blockReason(app(simulator: true)), contains('Simulator builds'));
    expect(ipad.blockReason(app()), 'Not connected');
    expect(sim.blockReason(app()), contains('Needs a simulator build'));
    expect(sim.blockReason(app(simulator: true, signed: false)), null);
  });

  test('install error hints', () {
    expect(describeInstallError('ERROR: Developer Mode is disabled'), startsWith('Turn on Developer Mode'));
    expect(describeInstallError(''), 'The install didn’t finish.');
  });

  group('service', () {
    test('finds devices with Xcode, devices before simulators', () async {
      final tools = FakeTools();
      final devices = await IosDeviceService(run: tools.run, which: (_) => null, isMacOS: true).discover();
      expect(devices.map((d) => d.name), ['Work iPhone', 'iPhone 17', 'Shop iPad', 'iPad Air']);
    });

    test('installs the .app with devicectl, and boots simulators', () async {
      final tools = FakeTools();
      final service = IosDeviceService(run: tools.run, which: (_) => null, isMacOS: true);
      final [iphone, ..., ipadSim] = await service.discover();

      await service.install(iphone, app());
      expect(tools.calls.last, [
        'xcrun', 'devicectl', 'device', 'install', 'app', '--device', 'AAAA-1111', '/build/Runner.app', //
      ]);

      tools.calls.clear();
      await service.install(ipadSim, app(simulator: true));
      expect(tools.calls, [
        ['xcrun', 'simctl', 'boot', 'SIM-2'],
        ['open', '-a', 'Simulator'],
        ['xcrun', 'simctl', 'install', 'SIM-2', '/build/Runner.app'],
      ]);
    });

    test('a failed install explains why', () async {
      final tools = FakeTools()
        ..installExit = 1
        ..installError = 'Error: The device is locked.';
      final service = IosDeviceService(run: tools.run, which: (_) => null, isMacOS: true);
      final [iphone, ...] = await service.discover();
      await expectLater(
        service.install(iphone, app()),
        throwsA(isA<IpaException>().having((e) => e.message, 'message', startsWith('Unlock the device'))),
      );
    });

    test('libimobiledevice when there is no Xcode', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> run(String exe, List<String> args, {Duration timeout = Duration.zero}) async {
        calls.add([p.basename(exe), ...args]);
        return switch ((p.basename(exe), args)) {
          ('idevice_id', ['-l']) => ProcessResult(0, 0, 'UDID-USB\n', ''),
          ('idevice_id', ['-n']) => ProcessResult(0, 0, 'UDID-USB\nUDID-NET\n', ''),
          ('ideviceinfo', ['-u', 'UDID-USB']) => ProcessResult(0, 0, 'DeviceName: Bench\nProductVersion: 17.1\n', ''),
          _ => ProcessResult(0, 0, '', ''),
        };
      }

      final service = IosDeviceService(run: run, which: (n) => '/opt/homebrew/bin/$n', isMacOS: false);
      final devices = await service.discover();
      expect(devices.map((d) => (d.name, d.connection)), [
        ('Bench', DeviceConnection.usb),
        ('UDID-NET', DeviceConnection.network),
      ]);
      expect(calls, anyElement(equals(['ideviceinfo', '-u', 'UDID-NET', '-n'])));

      expect(
        () => IosDeviceService(run: run, which: (_) => null, isMacOS: false).discover(),
        throwsA(isA<IpaException>().having((e) => e.title, 'title', 'No Device Tools')),
      );
    });
  });

  test('moves data out of the old macOS sandbox container once', () {
    final home = Directory.systemTemp.createTempSync('home');
    addTearDown(() => home.deleteSync(recursive: true));
    const id = 'tool.resc.toolResc';
    final old = Directory(p.join(home.path, 'Library/Containers/$id/Data/Library/Application Support/$id'))
      ..createSync(recursive: true);
    File(p.join(old.path, 'settings.hive')).writeAsStringSync('old settings');
    File(p.join(old.path, 'components.hive')).writeAsStringSync('parts');
    File(p.join(old.path, 'settings.lock')).writeAsStringSync('');
    final dir = p.join(home.path, 'Library/Application Support/$id');

    migrateFromSandbox(dir, home: home.path);
    expect(File(p.join(dir, 'settings.hive')).readAsStringSync(), 'old settings');
    expect(File(p.join(dir, 'components.hive')).existsSync(), true);
    expect(File(p.join(dir, 'settings.lock')).existsSync(), false);
    expect(File(p.join(old.path, 'settings.hive')).existsSync(), true, reason: 'originals kept');

    // Never overwrites data the unsandboxed app already has.
    File(p.join(dir, 'settings.hive')).writeAsStringSync('new settings');
    migrateFromSandbox(dir, home: home.path);
    expect(File(p.join(dir, 'settings.hive')).readAsStringSync(), 'new settings');
  });

  testWidgets('pick a device and install', (tester) async {
    final tools = FakeTools();
    final service = IosDeviceService(run: tools.run, which: (_) => null, isMacOS: true);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: ListView(
              children: [DevicesSection(app: app(), service: service)],
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.text('Work iPhone'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget); // Shop iPad
    // Simulators are folded for a device build.
    expect(find.text('iPhone 17'), findsNothing);
    await tester.tap(find.text('Simulators'));
    await tester.pump();
    expect(find.text('iPhone 17'), findsOneWidget);

    // The only usable device is picked already.
    await tester.runAsync(() async {
      await tester.tap(find.text('Install'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Installed'), findsOneWidget);
    expect(tools.calls.last, contains('AAAA-1111'));
  });
}
