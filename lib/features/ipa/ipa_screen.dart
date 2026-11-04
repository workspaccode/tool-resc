import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/platform.dart';
import '../../app/theme.dart';
import '../../widgets/clickable_tile.dart';
import '../../widgets/hud.dart';
import '../../widgets/icon_tile.dart';
import '../../widgets/section.dart';
import 'devices_section.dart';
import 'ipa_builder.dart';

/// IPA Export: turns a Flutter iOS build (Runner.app) into an .ipa saved on
/// this computer.
class IpaScreen extends StatefulWidget {
  const IpaScreen({super.key});

  @override
  State<IpaScreen> createState() => _IpaScreenState();
}

class _IpaScreenState extends State<IpaScreen> {
  AppBundleInfo? _app;
  bool _reading = false;

  /// 0…1 while exporting.
  double? _progress;
  String? _savedPath;

  /// Installing on a device from [DevicesSection].
  bool _installing = false;

  bool get _busy => _reading || _progress != null || _installing;

  Future<void> _chooseFolder() async {
    final String? folder;
    try {
      folder = await FilePicker.getDirectoryPath(dialogTitle: 'Choose Runner.app or the Build Folder');
    } catch (e) {
      if (mounted) _alert('Can’t Open Folder', '$e');
      return;
    }
    if (folder == null || !mounted) return;
    setState(() => _reading = true);
    try {
      final app = await inspectFolder(folder);
      if (!mounted) return;
      setState(() {
        _app = app;
        _savedPath = null;
      });
    } on IpaException catch (e) {
      if (mounted) _alert(e.title, e.message);
    } catch (e) {
      if (mounted) _alert('Can’t Read Folder', '$e');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _export() async {
    final app = _app!;
    try {
      final saved = isDesktop ? await _exportDesktop(app) : await _exportMobile(app);
      if (saved == null || !mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _savedPath = saved);
      showHud(context, icon: CupertinoIcons.checkmark_circle, message: 'IPA Saved');
    } on IpaException catch (e) {
      if (mounted) _alert(e.title, e.message);
    } catch (e) {
      if (mounted) _alert('Can’t Save', '$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  /// Desktop: the save panel only picks the path, so the IPA is written
  /// straight there, without holding it in memory.
  Future<String?> _exportDesktop(AppBundleInfo app) async {
    final uri = await _saveDialog(app, Uint8List(0));
    if (uri == null) return null;
    final path = uri.isScheme('file') ? uri.toFilePath() : uri.path;
    setState(() => _progress = 0);
    await exportIpa(app, path, onProgress: _onProgress);
    return path;
  }

  /// iOS / Android: the system save sheet needs the bytes, so build in the
  /// temporary folder first.
  Future<String?> _exportMobile(AppBundleInfo app) async {
    final tmp = p.join((await getTemporaryDirectory()).path, app.suggestedFileName);
    setState(() => _progress = 0);
    try {
      await exportIpa(app, tmp, onProgress: _onProgress);
      final uri = await _saveDialog(app, await File(tmp).readAsBytes());
      return uri == null ? null : Uri.decodeComponent(p.basename(uri.path));
    } finally {
      try {
        await File(tmp).delete();
      } catch (_) {}
    }
  }

  Future<Uri?> _saveDialog(AppBundleInfo app, Uint8List bytes) => FilePicker.saveFile(
    fileName: app.suggestedFileName,
    bytes: bytes,
    mimeType: 'application/octet-stream',
    dialogTitle: 'Save IPA',
    type: FileType.custom,
    allowedExtensions: const ['ipa'],
  );

  void _onProgress(double v) {
    if (mounted && _progress != null) setState(() => _progress = v);
  }

  void _alert(String title, String message) {
    showCupertinoDialog<void>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(isDefaultAction: true, onPressed: () => Navigator.pop(dialog), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = _app;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('IPA Export'),
        trailing: app == null
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _busy ? null : _chooseFolder,
                child: const Text('Change'),
              ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              children: [
                if (app == null)
                  _sourceSection()
                else ...[
                  _appSection(app),
                  for (final w in app.warnings) _warningSection(w),
                  _exportSection(app),
                  if (_savedPath != null) _savedSection(_savedPath!),
                  // Device tools (Xcode, libimobiledevice) run on computers.
                  if (isDesktop) DevicesSection(app: app, onBusy: (v) => setState(() => _installing = v)),
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sourceSection() {
    return Section(
      header: 'Source',
      footer:
          'Choose Runner.app from build/ios/iphoneos after “flutter build ios --release”. '
          'The build folder, a Payload folder or an .xcarchive work too.',
      children: [
        ClickableTile(
          leading: const IconTile(icon: CupertinoIcons.folder_fill, color: CupertinoColors.systemBlue),
          title: const Text('Choose Folder…'),
          trailing: _reading ? const CupertinoActivityIndicator() : const CupertinoListTileChevron(),
          onTap: _busy ? null : _chooseFolder,
        ),
      ],
    );
  }

  Widget _appSection(AppBundleInfo app) {
    final secondary = context.resolve(CupertinoColors.secondaryLabel);
    Widget row(String title, String? value) => CupertinoListTile(
      title: Text(title),
      additionalInfo: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Text(value ?? '—', overflow: TextOverflow.ellipsis),
      ),
    );

    return Section(
      header: 'App',
      footer: app.pickedPath,
      children: [
        CupertinoListTile(
          leadingSize: 44,
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 14, 12),
          leading: const IconTile(icon: CupertinoIcons.app_fill, color: CupertinoColors.systemIndigo, size: 44),
          title: Text(app.displayName, style: AppText.headline),
          subtitle: Text(app.bundleName, style: AppText.footnote.copyWith(color: secondary)),
          trailing: _reading ? const CupertinoActivityIndicator() : null,
        ),
        row('Bundle ID', app.bundleId),
        row('Version', app.versionLabel),
        row('Minimum iOS', app.minimumOS),
        row('Size', '${_formatBytes(app.totalBytes)} · ${app.fileCount} files'),
        row('Signature', app.signed ? 'Signed' : 'Not signed'),
        row('Found In', app.source.label),
      ],
    );
  }

  Widget _warningSection(IpaWarning w) {
    final orange = context.resolve(CupertinoColors.systemOrange);
    return Section(
      footer: w.message,
      children: [
        CupertinoListTile(
          leading: Icon(CupertinoIcons.exclamationmark_triangle_fill, color: orange, size: 22),
          title: Text(w.title),
        ),
      ],
    );
  }

  Widget _exportSection(AppBundleInfo app) {
    final progress = _progress;
    return Section(
      header: 'Export',
      footer: 'Packs Payload/${app.bundleName} into ${app.suggestedFileName}, keeping file permissions and links.',
      children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: progress == null
              ? SizedBox(
                  width: double.infinity,
                  child: CupertinoButton.filled(onPressed: _busy ? null : _export, child: const Text('Export IPA…')),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Packing… ${(progress * 100).round()}%',
                      style: AppText.subheadline.copyWith(color: context.resolve(CupertinoColors.label)),
                    ),
                    const SizedBox(height: 10),
                    _ProgressBar(value: progress),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _savedSection(String path) {
    final green = context.resolve(CupertinoColors.systemGreen);
    return Section(
      header: 'Saved',
      children: [
        ClickableTile(
          leading: Icon(CupertinoIcons.checkmark_circle_fill, color: green, size: 24),
          title: Text(p.basename(path)),
          subtitle: p.dirname(path) == '.' ? null : Text(p.dirname(path), overflow: TextOverflow.ellipsis),
          trailing: const Icon(CupertinoIcons.doc_on_doc, size: 20),
          onTap: () {
            Clipboard.setData(ClipboardData(text: path));
            showHud(context, icon: CupertinoIcons.doc_on_clipboard, message: 'Path Copied');
          },
        ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['bytes', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return i == 0 ? '$bytes bytes' : '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: context.resolve(CupertinoColors.systemFill)),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value.clamp(0.0, 1.0),
              child: ColoredBox(color: context.resolve(CupertinoColors.systemBlue)),
            ),
          ],
        ),
      ),
    );
  }
}
