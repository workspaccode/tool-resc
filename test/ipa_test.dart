import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tool_resc/features/ipa/ipa_builder.dart';
import 'package:tool_resc/features/ipa/plist.dart';

/// 64-bit Mach-O header, enough to look like an executable.
final _machO = Uint8List.fromList([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01, ...List.filled(200, 7)]);

const _xmlPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Runner</string>
  <key>CFBundleIdentifier</key><string>com.example.app</string>
  <key>CFBundleShortVersionString</key><string>2.1.0</string>
  <key>CFBundleVersion</key><string>12</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>13.0</string>
</dict></plist>''';

late Directory tmp;

/// Writes a Flutter-like Runner.app. The executable is 0644 on purpose:
/// the export must still mark it executable.
Directory makeApp(String path, {String plist = _xmlPlist, bool signed = false, bool debug = false}) {
  final app = Directory(path)..createSync(recursive: true);
  void write(String rel, List<int> bytes) {
    final f = File(p.join(app.path, rel))..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  write('Info.plist', utf8.encode(plist));
  write('Runner', _machO);
  write('Frameworks/App.framework/App', _machO);
  write('Frameworks/App.framework/flutter_assets/AssetManifest.bin', List.filled(5000, 65));
  write('Frameworks/Flutter.framework/Flutter', _machO);
  write('.DS_Store', [1, 2, 3]);
  write('Frameworks/._App.framework', [1, 2, 3]);
  if (signed) {
    write('_CodeSignature/CodeResources', utf8.encode('<plist/>'));
    write('embedded.mobileprovision', [0]);
  }
  if (debug) write('Frameworks/App.framework/flutter_assets/kernel_blob.bin', [0]);
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['644', p.join(app.path, 'Runner')]);
    Link(p.join(app.path, 'Frameworks', 'Current')).createSync('App.framework');
  }
  return app;
}

/// Unix mode of each entry, from the zip's external attributes.
Map<String, ArchiveFile> readIpa(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  return {for (final f in archive.files) f.name: f};
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('ipa_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('plist', () {
    test('reads binary plists written by Xcode', () {
      final v = parsePlist(File('test/fixtures/Info.bplist').readAsBytesSync())! as Map;
      expect(v['CFBundleExecutable'], 'Runner');
      expect(v['CFBundleDisplayName'], 'Tool Résc ✓'); // UTF-16 string
      expect(v['CFBundleShortVersionString'], '1.0.0');
      expect(v['CFBundleSupportedPlatforms'], ['iPhoneOS']);
      expect(v['LSRequiresIPhoneOS'], true);
      expect(v['UIDeviceFamily'], [1, 2]);
      expect(v['Ratio'], 1.5);
      expect(v['Blob'], [0xDE, 0xAD, 0xBE, 0xEF]);
    });

    test('reads XML plists', () {
      final v = parsePlist(utf8.encode(_xmlPlist))! as Map;
      expect(v['CFBundleIdentifier'], 'com.example.app');
      expect(v['CFBundleSupportedPlatforms'], ['iPhoneOS']);
    });
  });

  group('inspect', () {
    test('reads the app details', () {
      makeApp(p.join(tmp.path, 'Runner.app'));
      final app = inspectFolderSync(p.join(tmp.path, 'Runner.app'));
      expect(app.source, IpaSource.appBundle);
      expect(app.bundleName, 'Runner.app');
      expect(app.bundleId, 'com.example.app');
      expect(app.versionLabel, '2.1.0 (12)');
      expect(app.suggestedFileName, 'Runner_2.1.0+12.ipa');
      expect(app.minimumOS, '13.0');
      expect(app.fileCount, 5, reason: '.DS_Store and ._ files are not counted');
      expect(app.signed, false);
      expect(app.warnings.map((w) => w.title), ['Not Signed']);
    });

    test('binary Info.plist, as in a real build', () {
      final app = makeApp(p.join(tmp.path, 'Runner.app'));
      File('test/fixtures/Info.bplist').copySync(p.join(app.path, 'Info.plist'));
      expect(inspectFolderSync(app.path).displayName, 'Tool Résc ✓');
    });

    test('finds the device build inside a build folder', () {
      makeApp(
        p.join(tmp.path, 'build', 'ios', 'iphonesimulator', 'Runner.app'),
        plist: _xmlPlist.replaceAll('iPhoneOS', 'iPhoneSimulator'),
      );
      makeApp(p.join(tmp.path, 'build', 'ios', 'iphoneos', 'Runner.app'));
      final app = inspectFolderSync(p.join(tmp.path, 'build'));
      expect(app.source, IpaSource.buildFolder);
      expect(app.appPath, contains('iphoneos'));
      expect(app.isSimulatorBuild, false);

      final sim = inspectFolderSync(p.join(tmp.path, 'build', 'ios', 'iphonesimulator'));
      expect(sim.isSimulatorBuild, true);
      expect(sim.warnings.first.title, 'Simulator Build');
    });

    test('a bundle folder named “Runner” gets .app inside Payload', () {
      makeApp(p.join(tmp.path, 'Runner'));
      expect(inspectFolderSync(p.join(tmp.path, 'Runner')).bundleName, 'Runner.app');
    });

    test('xcarchive and Payload folders', () {
      makeApp(p.join(tmp.path, 'Runner.xcarchive', 'Products', 'Applications', 'Runner.app'), signed: true);
      final archived = inspectFolderSync(p.join(tmp.path, 'Runner.xcarchive'));
      expect(archived.source, IpaSource.xcarchive);
      expect(archived.warnings, isEmpty);

      makeApp(p.join(tmp.path, 'out', 'Payload', 'Runner.app'), debug: true);
      final payload = inspectFolderSync(p.join(tmp.path, 'out'));
      expect(payload.source, IpaSource.payload);
      expect(payload.warnings.map((w) => w.title), contains('Debug Build'));
    });

    test('explains the ios/Runner source folder', () {
      final src = Directory(p.join(tmp.path, 'ios', 'Runner'))..createSync(recursive: true);
      File(p.join(src.path, 'Info.plist')).writeAsStringSync(_xmlPlist.replaceAll('Runner<', r'$(EXECUTABLE_NAME)<'));
      File(p.join(src.path, 'AppDelegate.swift')).writeAsStringSync('');
      expect(
        () => inspectFolderSync(src.path),
        throwsA(isA<IpaException>().having((e) => e.title, 'title', 'This Is the Source Folder')),
      );
      expect(
        () => inspectFolderSync(tmp.path),
        throwsA(isA<IpaException>().having((e) => e.title, 'title', 'No iOS App Found')),
      );
    });
  });

  group('export', () {
    test('writes Payload/Runner.app with permissions and links', () async {
      makeApp(p.join(tmp.path, 'Runner'));
      final app = inspectFolderSync(p.join(tmp.path, 'Runner'));
      final out = p.join(tmp.path, 'Runner.ipa');
      final progress = <double>[];
      await exportIpa(app, out, onProgress: progress.add);

      final files = readIpa(out);
      expect(files.keys, containsAll(['Payload/', 'Payload/Runner.app/', 'Payload/Runner.app/Info.plist']));
      expect(files.keys.where((n) => n.contains('.DS_Store') || n.contains('/._')), isEmpty);
      expect(files.keys.every((n) => n.startsWith('Payload/')), true);

      final exe = files['Payload/Runner.app/Runner']!;
      expect(exe.readBytes(), _machO);
      expect(exe.mode & 0x49, 0x49, reason: 'executable for everyone');
      expect(exe.mode & 0xF000, 0x8000, reason: 'regular file');

      final assets = files['Payload/Runner.app/Frameworks/App.framework/flutter_assets/AssetManifest.bin']!;
      expect(assets.readBytes(), List.filled(5000, 65));

      if (!Platform.isWindows) {
        final link = files['Payload/Runner.app/Frameworks/Current']!;
        expect(link.isSymbolicLink, true);
        expect(link.symbolicLink, 'App.framework');
      }
      expect(progress.last, 1.0);
    });

    test('Info-ZIP accepts the IPA and keeps the modes', () async {
      if (Platform.isWindows || !File('/usr/bin/unzip').existsSync()) return;
      makeApp(p.join(tmp.path, 'Runner.app'));
      final out = p.join(tmp.path, 'Runner.ipa');
      await exportIpa(inspectFolderSync(p.join(tmp.path, 'Runner.app')), out);

      expect(Process.runSync('unzip', ['-tq', out]).exitCode, 0);
      final x = Directory(p.join(tmp.path, 'x'))..createSync();
      expect(Process.runSync('unzip', ['-q', out, '-d', x.path]).exitCode, 0);
      final exe = File(p.join(x.path, 'Payload', 'Runner.app', 'Runner'));
      expect(exe.statSync().mode & 0x49, 0x49);
      expect(FileSystemEntity.isLinkSync(p.join(x.path, 'Payload', 'Runner.app', 'Frameworks', 'Current')), true);
    });

    test('a failed export leaves no file behind', () async {
      final app = inspectFolderSync(makeApp(p.join(tmp.path, 'Runner.app')).path);
      final out = p.join(tmp.path, 'missing', 'Runner.ipa');
      await expectLater(exportIpa(app, out), throwsA(isA<IpaException>()));
      expect(File(out).existsSync(), false);
    });
  });
}
