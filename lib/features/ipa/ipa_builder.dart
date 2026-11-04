import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ipa_zip.dart';
import 'plist.dart';

/// A problem the user can fix, with a short title for the alert.
class IpaException implements Exception {
  const IpaException(this.title, this.message);

  final String title;
  final String message;

  @override
  String toString() => '$title: $message';
}

/// What was picked: the .app itself, or a folder that contains one.
enum IpaSource {
  appBundle('App Bundle'),
  buildFolder('Build Folder'),
  payload('Payload Folder'),
  xcarchive('Xcode Archive');

  const IpaSource(this.label);
  final String label;
}

/// A built iOS app found in the picked folder.
class AppBundleInfo {
  const AppBundleInfo({
    required this.appPath,
    required this.pickedPath,
    required this.source,
    required this.bundleName,
    required this.displayName,
    required this.executable,
    required this.fileCount,
    required this.totalBytes,
    required this.signed,
    required this.hasProvisioningProfile,
    required this.isSimulatorBuild,
    required this.isFlutterDebug,
    this.bundleId,
    this.version,
    this.build,
    this.minimumOS,
  });

  /// Folder of the .app (Runner.app).
  final String appPath;
  final String pickedPath;
  final IpaSource source;

  /// Folder name inside Payload/, always ending in .app.
  final String bundleName;
  final String displayName;
  final String executable;
  final String? bundleId;
  final String? version;
  final String? build;
  final String? minimumOS;
  final int fileCount;
  final int totalBytes;

  /// Has `_CodeSignature/CodeResources`.
  final bool signed;

  /// Has `embedded.mobileprovision`.
  final bool hasProvisioningProfile;
  final bool isSimulatorBuild;

  /// Flutter debug (JIT) build: only starts when launched from Flutter/Xcode.
  final bool isFlutterDebug;

  String get versionLabel => switch ((version, build)) {
    (final v?, final b?) when v != b => '$v ($b)',
    (final v?, _) => v,
    (_, final b?) => b,
    _ => '—',
  };

  /// e.g. `Runner_1.0.0+1.ipa`.
  String get suggestedFileName {
    final base = p.basenameWithoutExtension(bundleName).replaceAll(RegExp(r'[^\w.\- ]'), '').trim();
    final v = [version, if (build != null && build != version) build].nonNulls.join('+');
    return '${base.isEmpty ? 'App' : base}${v.isEmpty ? '' : '_$v'}.ipa';
  }

  /// Things that will stop the IPA from installing as-is.
  List<IpaWarning> get warnings => [
    if (isSimulatorBuild)
      const IpaWarning(
        'Simulator Build',
        'This app only runs in the iOS Simulator, not on an iPhone or iPad. Build it with “flutter build ios --release” instead.',
      ),
    if (isFlutterDebug)
      const IpaWarning(
        'Debug Build',
        'On iOS 14 and later, debug builds only start from Flutter or Xcode. Use “flutter build ios --release” for an IPA you install.',
      ),
    if (!signed)
      const IpaWarning(
        'Not Signed',
        'Built with --no-codesign. The IPA must be signed before it installs, for example by a sideloading tool or when uploading with Xcode.',
      )
    else if (!hasProvisioningProfile && !isSimulatorBuild)
      const IpaWarning(
        'No Provisioning Profile',
        'The app is signed but has no embedded.mobileprovision, so devices will reject it until it is re-signed.',
      ),
  ];
}

class IpaWarning {
  const IpaWarning(this.title, this.message);
  final String title;
  final String message;
}

/// Finds the app in [folder] and reads its details. Runs off the UI thread.
Future<AppBundleInfo> inspectFolder(String folder) => Isolate.run(() => inspectFolderSync(folder));

/// Accepts the .app itself (named `Runner` or `Runner.app`), a build folder
/// such as `build/ios/iphoneos`, a `Payload` folder, or an `.xcarchive`.
AppBundleInfo inspectFolderSync(String folder) {
  final dir = Directory(folder);
  if (!dir.existsSync()) throw const IpaException('Folder Not Found', 'The folder doesn’t exist or can’t be read.');

  final (appDir, source) = _locateApp(dir);
  return _inspectApp(appDir, picked: folder, source: source);
}

(Directory, IpaSource) _locateApp(Directory dir) {
  final name = p.basename(dir.path);

  if (name.endsWith('.xcarchive')) {
    final apps = _appsIn(Directory(p.join(dir.path, 'Products', 'Applications')));
    if (apps.isEmpty) throw const IpaException('No App in Archive', 'The archive has no app in Products/Applications.');
    return (apps.first, IpaSource.xcarchive);
  }

  if (_isMacApp(dir)) {
    throw const IpaException('macOS App', 'This is a macOS app. An IPA can only be made from an iOS build.');
  }
  if (_isIosApp(dir)) return (dir, IpaSource.appBundle);

  final payload = name == 'Payload' ? dir : Directory(p.join(dir.path, 'Payload'));
  final inPayload = _appsIn(payload);
  if (inPayload.isNotEmpty) return (inPayload.first, IpaSource.payload);

  final found = _findApps(dir, depth: 4);
  if (found.isNotEmpty) {
    // Prefer device builds, then Flutter's default Runner.app.
    int score(Directory d) =>
        (d.path.contains('iphonesimulator') ? 2 : 0) + (p.basename(d.path) == 'Runner.app' ? 0 : 1);
    found.sort((a, b) => score(a).compareTo(score(b)));
    return (found.first, IpaSource.buildFolder);
  }

  if (_looksLikeSource(dir)) {
    throw const IpaException(
      'This Is the Source Folder',
      'This folder has the Xcode project, not a built app. Run “flutter build ios --release” (or add --no-codesign), '
          'then choose build/ios/iphoneos/Runner.app.',
    );
  }
  throw const IpaException(
    'No iOS App Found',
    'Choose Runner.app from build/ios/iphoneos, the build folder, a Payload folder, or an .xcarchive.',
  );
}

List<Directory> _appsIn(Directory dir) {
  if (!dir.existsSync()) return [];
  return [
    for (final e in dir.listSync(followLinks: false))
      if (e is Directory && _isIosApp(e)) e,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// Searches subfolders for .app bundles, without looking inside them.
List<Directory> _findApps(Directory dir, {required int depth}) {
  if (depth == 0) return [];
  final out = <Directory>[];
  List<FileSystemEntity> children;
  try {
    children = dir.listSync(followLinks: false);
  } on FileSystemException {
    return out;
  }
  for (final e in children) {
    if (e is! Directory) continue;
    final n = p.basename(e.path);
    if (n.startsWith('.') || n.endsWith('.framework') || n.endsWith('.xcodeproj') || n == 'Pods') continue;
    if (n.endsWith('.app')) {
      if (_isIosApp(e)) out.add(e);
      continue;
    }
    out.addAll(_findApps(e, depth: depth - 1));
  }
  return out;
}

/// An iOS bundle: Info.plist at the top with a main executable next to it.
bool _isIosApp(Directory dir) {
  final plist = File(p.join(dir.path, 'Info.plist'));
  if (!plist.existsSync()) return false;
  final info = _readPlist(plist);
  final exe = info?['CFBundleExecutable'];
  return exe is String && !exe.contains(r'$(') && File(p.join(dir.path, exe)).existsSync();
}

bool _isMacApp(Directory dir) => File(p.join(dir.path, 'Contents', 'Info.plist')).existsSync();

bool _looksLikeSource(Directory dir) {
  bool has(String n) => FileSystemEntity.typeSync(p.join(dir.path, n)) != FileSystemEntityType.notFound;
  return has('AppDelegate.swift') ||
      has('AppDelegate.m') ||
      has('Assets.xcassets') ||
      has('Runner.xcodeproj') ||
      has('Runner.xcworkspace') ||
      has('Podfile');
}

Map<String, Object?>? _readPlist(File f) {
  try {
    final v = parsePlist(f.readAsBytesSync());
    return v is Map<String, Object?> ? v : null;
  } catch (_) {
    return null;
  }
}

AppBundleInfo _inspectApp(Directory app, {required String picked, required IpaSource source}) {
  final info = _readPlist(File(p.join(app.path, 'Info.plist')));
  if (info == null) throw const IpaException('Can’t Read Info.plist', 'The app’s Info.plist is missing or damaged.');

  String? str(String key) => switch (info[key]) {
    final String s when s.isNotEmpty => s,
    _ => null,
  };

  final executable = str('CFBundleExecutable')!;
  final exeFile = File(p.join(app.path, executable));
  if (!_isMachO(exeFile)) {
    throw IpaException(
      'Not a Built App',
      '“$executable” isn’t an iOS executable. Choose the output of a finished build.',
    );
  }

  final platforms = info['CFBundleSupportedPlatforms'];
  final simulator =
      (platforms is List && platforms.contains('iPhoneSimulator')) ||
      (str('DTPlatformName')?.contains('simulator') ?? false);

  var files = 0;
  var bytes = 0;
  for (final e in app.listSync(recursive: true, followLinks: false)) {
    if (e is File && !_skip(p.basename(e.path))) {
      files++;
      bytes += e.lengthSync();
    }
  }

  final dirName = p.basename(app.path);
  bool exists(List<String> parts) => File(p.joinAll([app.path, ...parts])).existsSync();

  return AppBundleInfo(
    appPath: app.path,
    pickedPath: picked,
    source: source,
    // Inside Payload/ the folder must end in .app, even if picked as “Runner”.
    bundleName: dirName.endsWith('.app') ? dirName : '${dirName.isEmpty ? executable : dirName}.app',
    displayName: str('CFBundleDisplayName') ?? str('CFBundleName') ?? executable,
    executable: executable,
    bundleId: str('CFBundleIdentifier'),
    version: str('CFBundleShortVersionString'),
    build: str('CFBundleVersion'),
    minimumOS: str('MinimumOSVersion'),
    fileCount: files,
    totalBytes: bytes,
    signed: exists(['_CodeSignature', 'CodeResources']),
    hasProvisioningProfile: exists(['embedded.mobileprovision']),
    isSimulatorBuild: simulator,
    isFlutterDebug: exists(['Frameworks', 'App.framework', 'flutter_assets', 'kernel_blob.bin']),
  );
}

/// Finder and exFAT/FAT drives leave these behind. They aren't part of the
/// app, and extra files break a signed app's seal.
bool _skip(String name) => name == '.DS_Store' || name.startsWith('._');

/// Mach-O (thin or universal) executable or library.
bool _isMachO(File f) {
  try {
    final raf = f.openSync();
    try {
      final head = raf.readSync(4);
      if (head.length < 4) return false;
      final magic = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
      return const {
        0xFEEDFACE, 0xCEFAEDFE, // 32-bit
        0xFEEDFACF, 0xCFFAEDFE, // 64-bit
        0xCAFEBABE, 0xBEBAFECA, // universal
      }.contains(magic);
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return false;
  }
}

/// Writes `Payload/<App>.app/…` as an IPA at [outPath], keeping permissions
/// and symlinks. [onProgress] gets 0…1. Runs in a background isolate.
Future<void> exportIpa(AppBundleInfo app, String outPath, {void Function(double)? onProgress}) async {
  final port = ReceivePort();
  final done = Completer<void>();
  port.listen((message) {
    if (done.isCompleted) return;
    switch (message) {
      case final double v:
        onProgress?.call(v);
      case true:
        done.complete();
      case (final String title, final String text):
        done.completeError(IpaException(title, text));
      case [final Object? error, _]:
        // Uncaught error (onError sends [error, stack]).
        done.completeError(IpaException('Export Failed', '$error'));
      case null:
        // onExit before a result.
        done.completeError(const IpaException('Export Failed', 'The export stopped unexpectedly.'));
    }
  });
  final job = (port.sendPort, app.appPath, app.bundleName, app.totalBytes, outPath);
  final isolate = await Isolate.spawn(_exportEntry, job, onError: port.sendPort, onExit: port.sendPort);
  try {
    await done.future;
  } finally {
    isolate.kill();
    port.close();
  }
}

void _exportEntry((SendPort, String, String, int, String) job) {
  final (send, appPath, bundleName, totalBytes, outPath) = job;
  try {
    writeIpaSync(appPath, outPath, bundleName: bundleName, totalBytes: totalBytes, onProgress: send.send);
    send.send(true);
  } on IpaException catch (e) {
    _deleteQuietly(outPath);
    send.send((e.title, e.message));
  } on FileSystemException catch (e) {
    _deleteQuietly(outPath);
    send.send(('Can’t Write IPA', [e.message, e.osError?.message].nonNulls.join(': ')));
  } catch (e) {
    _deleteQuietly(outPath);
    send.send(('Export Failed', '$e'));
  }
}

void _deleteQuietly(String path) {
  try {
    File(path).deleteSync();
  } catch (_) {}
}

/// The synchronous export, for [exportIpa]'s isolate and tests.
void writeIpaSync(
  String appPath,
  String outPath, {
  String? bundleName,
  int? totalBytes,
  void Function(double)? onProgress,
}) {
  final app = Directory(appPath);
  final root = 'Payload/${bundleName ?? p.basename(appPath)}';
  final entries = app.listSync(recursive: true, followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
  // Windows has no Unix permissions to copy; use the usual defaults.
  final posix = !Platform.isWindows;
  final total = (totalBytes ?? 0) > 0 ? totalBytes! : 1;

  final zip = IpaZipWriter(outPath);
  try {
    zip.addDirectory('Payload/');
    zip.addDirectory('$root/', modified: app.statSync().modified);
    var written = 0;
    var lastReport = -1.0;
    for (final e in entries) {
      final rel = p.relative(e.path, from: appPath).split(p.separator).join('/');
      final name = '$root/$rel';
      if (_skip(p.basename(e.path))) continue;
      if (e is Link) {
        // Kept as a link (stat would follow it to the target).
        zip.addSymlink(name, e.targetSync());
        continue;
      }
      final stat = e.statSync();
      if (e is Directory) {
        zip.addDirectory(name, permissions: posix ? stat.mode & 0xFFF : 0x1ED, modified: stat.modified);
      } else if (e is File) {
        final bytes = e.readAsBytesSync();
        var perms = posix ? stat.mode & 0xFFF : 0x1A4;
        // Executables and dylibs must be executable on device, even if the
        // bit was lost copying through Windows or a zip tool.
        if (_isMachOBytes(bytes)) perms |= 0x49; // a+x
        zip.addFile(name, bytes, permissions: perms, modified: stat.modified);
        written += bytes.length;
        final progress = written / total;
        if (progress - lastReport >= 0.01) {
          onProgress?.call(progress.clamp(0.0, 1.0));
          lastReport = progress;
        }
      }
    }
    zip.close();
    onProgress?.call(1.0);
  } catch (_) {
    zip.abort();
    rethrow;
  }
}

bool _isMachOBytes(Uint8List b) {
  if (b.length < 4) return false;
  final magic = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  return magic == 0xFEEDFACE ||
      magic == 0xCEFAEDFE ||
      magic == 0xFEEDFACF ||
      magic == 0xCFFAEDFE ||
      magic == 0xCAFEBABE ||
      magic == 0xBEBAFECA;
}
